// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { ILineVenue, ProgramVenue } from "./ProgramVenue.sol";
import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { ISettlementTokenGuard } from "./interfaces/ISettlementTokenGuard.sol";
import { CAPTURE_BEYOND, CAPTURE_FINAL, CAPTURE_FREE, ISource } from "./interfaces/ISource.sol";

/// @title CreditSource
/// @notice Lenders' credit lines as one funding source of a card authorization contract (its PROGRAM). Each leg is a
///         hold on the lender's own balance, placed here through holdFrom and payable to the program's settlement
///         account, so every approved part is backed by funds the lender reserved. The borrower owes what legs
///         captured, net of refunds, plus simple interest at the yearly rate it accepted, never past the debt bound
///         it accepted. A secured line locks the borrower's Earn shares as it borrows, at its loan-to-value, and the
///         lender may sell locked shares that no longer cover it. Statements close at the lender's call and collect
///         through the borrower's autopay sources.
/// @dev Amounts across ISource are settlement units; a line lends the program's settlement token at opening, so a
///      unit is a token unit. Positions are line ids.
/// @custom:reentrancy-guard _locked
contract CreditSource is ISource, ISettlementTokenGuard {
    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    /// @inheritdoc ISource
    uint8 public constant KIND = 4;
    uint256 private constant BPS = 10_000;
    /// @dev The settlement-token-in-use reason for open credit lines.
    uint8 private constant IN_USE_LINES = 7;
    /// @dev How long one commitment or lock hold lasts; the core caps holds at 31 days.
    uint256 private constant TERM = 30 days;
    uint256 private constant YEAR = 365 days;
    uint256 private constant MAX_AUTOPAY = 4;

    /// @notice The card authorization contract whose purchases draw these lines.
    ICardAuth public immutable PROGRAM;

    struct Line {
        address lender;
        /// @dev No draws from the due date on.
        uint64 dueDate;
        bool accepted;
        bool closed;
        uint16 ltvBps;
        address borrower;
        /// @dev The yearly interest rate the borrower accepted, in basis points: simple interest on what is owed.
        uint16 aprBps;
        uint64 lastAccrued;
        /// @dev The borrower locks shares in collateralVault as it borrows.
        bool locking;
        address token;
        uint128 limit;
        /// @dev Captured, net of refunds, plus interest, not yet repaid or liquidated.
        uint128 owed;
        /// @dev What the line's live legs still hold on the lender.
        uint128 pending;
        /// @dev The most the borrower agreed to owe and have pending, interest included.
        uint128 maxDebt;
        /// @dev Zero for an unsecured line.
        IEarnVault collateralVault;
    }

    struct Terms {
        uint16 aprBps;
        uint128 maxDebt;
    }

    /// @dev What a treasury repaid on a line for one reference through repayFor, and what redraw drew again for it.
    struct RefRepayment {
        uint128 repaid;
        uint128 redrawn;
    }

    /// @dev A leg as the line last applied it: what it held, what counted toward what the borrower owes, and its
    ///      captures less refunds (gross), which the core forgets once the hold settles. One slot.
    struct Leg {
        uint64 lineId;
        uint64 held;
        uint64 net;
        uint64 gross;
    }

    enum StatementStatus {
        None,
        Due,
        Paid,
        PastDue
    }

    struct Statement {
        uint64 dueAt;
        StatementStatus status;
        uint128 balance;
        uint128 paid;
    }

    /// @dev A line's statement count, the first statement collection has not reached, and the first one not yet paid.
    struct Statements {
        uint32 count;
        uint32 collectFrom;
        uint32 payFrom;
    }

    uint64 public lineCount;
    mapping(uint64 lineId => Line) internal _lines;
    /// @notice The open line each lender has for each borrower, if any.
    mapping(address lender => mapping(address borrower => uint64 lineId)) public lineIdOf;
    mapping(uint64 lineId => Terms) public offerOf;
    mapping(bytes32 holdId => Leg) internal _legs;
    /// @notice The hold committing a line's undrawn limit on the lender's balance, and the hold locking its shares.
    mapping(uint64 lineId => bytes32 holdId) public commitmentOf;
    mapping(uint64 lineId => bytes32 holdId) public lockOf;
    /// @dev Commitment and lock holds placed so far, numbering their ids.
    mapping(uint64 lineId => uint64) internal _holds;
    mapping(uint64 lineId => mapping(bytes32 ref => RefRepayment)) public repaymentOf;
    mapping(uint64 lineId => mapping(uint32 n => Statement)) internal _statements;
    mapping(uint64 lineId => Statements) public statementsOf;
    mapping(uint64 lineId => address[]) internal _autopay;
    /// @dev Accepted, open lines in each token that still have a limit, a balance owed or a live leg.
    mapping(address token => uint256) internal _activeLines;
    mapping(uint64 lineId => bool) internal _active;
    /// @dev Charges so far (redraws, overpaid refunds), which number their ids.
    uint64 internal _charges;

    bool private transient _locked;

    event LineOpened(
        uint64 indexed lineId,
        address indexed lender,
        address indexed borrower,
        address token,
        uint128 limit,
        uint64 dueDate,
        address collateralVault,
        uint16 ltvBps
    );
    event TermsOffered(uint64 indexed lineId, uint16 aprBps, uint128 maxDebt);
    event LineAccepted(uint64 indexed lineId, uint16 aprBps, uint128 maxDebt);
    event LineClosed(uint64 indexed lineId);
    event LimitSet(uint64 indexed lineId, uint128 limit);
    /// @notice A leg changed: what the borrower owes and what the line's legs hold now.
    event Synced(uint64 indexed lineId, bytes32 indexed holdId, uint128 owed, uint128 pending);
    event Repaid(uint64 indexed lineId, address indexed payer, uint128 amount, uint128 owed);
    event RepaidFor(uint64 indexed lineId, bytes32 indexed ref, uint128 amount);
    /// @notice A refund past what the borrower owed went from the lender to the borrower.
    event Overpaid(uint64 indexed lineId, bytes32 holdId, uint128 amount);
    event Redrawn(uint64 indexed lineId, bytes32 indexed ref, address indexed payee, uint128 amount, uint128 owed);
    event Committed(uint64 indexed lineId, bytes32 holdId, uint128 amount);
    event LockingEnabled(uint64 indexed lineId);
    event Locked(uint64 indexed lineId, bytes32 holdId, uint128 shares);
    event Liquidated(uint64 indexed lineId, uint128 shares, uint256 assets, uint128 owed);
    event InterestAccrued(uint64 indexed lineId, uint16 aprBps, uint128 interest, uint128 owed);
    event StatementClosed(uint64 indexed lineId, uint32 indexed n, uint128 balance, uint64 dueAt);
    event StatementCollected(
        uint64 indexed lineId, uint32 indexed n, uint128 balance, uint128 paid, StatementStatus status
    );
    event AutopaySet(uint64 indexed lineId, address[] sources);
    event Autopaid(uint64 indexed lineId, uint32 indexed n, address source, uint128 amount);

    error ConversionExceedsMax(uint256 cost, uint256 maxIn);
    error CreditExceeded(uint256 amount, uint256 available);
    error DebtBoundExceeded(uint256 amount, uint256 maxDebt);
    error InvalidAutopay();
    error InvalidLine();
    error InvalidStatement();
    error LineNotOpen();
    error NoConversion();
    error NotBorrower();
    error NotLender();
    error NotProgram();
    error NotUndercollateralized(uint256 owed, uint256 secured);
    error NothingToRedraw();
    error Reentrancy();
    error RepayExceedsOwed(uint256 amount, uint256 owed);
    error TermsMismatch();
    error UnknownLeg();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyProgram() {
        if (msg.sender != address(PROGRAM)) revert NotProgram();
        _;
    }

    constructor(ICardAuth program) {
        PROGRAM = program;
    }

    /// @notice Opens a line from the caller (the lender) to borrower in the program's settlement token, offering
    ///         simple interest of aprBps a year and a bound of maxDebt on what is owed and pending (zero: the limit
    ///         plus a year of interest on it). The borrower accepts before any draw. A zero collateralVault makes it
    ///         unsecured; otherwise the borrower enables locking before it draws.
    function openLine(
        address borrower,
        uint128 limit,
        uint64 dueDate,
        IEarnVault collateralVault,
        uint16 ltvBps,
        uint16 aprBps,
        uint128 maxDebt
    ) external returns (uint64 lineId) {
        address token = PROGRAM.settlementToken();
        // Due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (borrower == address(0) || dueDate <= block.timestamp || lineIdOf[msg.sender][borrower] != 0) {
            revert InvalidLine();
        }
        if (address(collateralVault) == address(0) ? ltvBps != 0 : ltvBps == 0 || ltvBps >= BPS) revert InvalidLine();
        // Collateral in another token is valued and sold through the program's conversion venue.
        if (
            address(collateralVault) != address(0) && collateralVault.asset() != token
                && address(ProgramVenue.venueOf(address(PROGRAM))) == address(0)
        ) revert InvalidLine();
        lineId = ++lineCount;
        lineIdOf[msg.sender][borrower] = lineId;
        Line storage l = _lines[lineId];
        (l.lender, l.dueDate, l.ltvBps, l.borrower, l.token, l.limit, l.collateralVault) =
        (msg.sender, dueDate, ltvBps, borrower, token, limit, collateralVault);
        emit LineOpened(lineId, msg.sender, borrower, token, limit, dueDate, address(collateralVault), ltvBps);
        _offer(lineId, l, aprBps, maxDebt);
    }

    /// @notice The lender offers new terms, which apply once the borrower accepts them.
    function offerTerms(uint64 lineId, uint16 aprBps, uint128 maxDebt) external {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender) revert NotLender();
        _offer(lineId, l, aprBps, maxDebt);
    }

    /// @notice The borrower accepts the offered terms, which must be aprBps and maxDebt. Interest so far accrues at the
    ///         earlier rate first.
    function acceptLine(uint64 lineId, uint16 aprBps, uint128 maxDebt) external nonReentrant {
        Line storage l = _lines[lineId];
        if (msg.sender != l.borrower) revert NotBorrower();
        Terms memory o = offerOf[lineId];
        if (aprBps != o.aprBps || maxDebt != o.maxDebt || maxDebt < l.limit) revert TermsMismatch();
        _accrue(lineId, false);
        // forge-lint: disable-next-line(unsafe-typecast)
        (l.accepted, l.aprBps, l.maxDebt, l.lastAccrued) = (true, aprBps, maxDebt, uint64(block.timestamp));
        emit LineAccepted(lineId, aprBps, maxDebt);
        _settle(lineId);
    }

    /// @notice The lender sets the limit, at most the debt bound accepted (or offered, before acceptance).
    function setLimit(uint64 lineId, uint128 limit) external nonReentrant {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender) revert NotLender();
        uint128 bound = l.accepted ? l.maxDebt : offerOf[lineId].maxDebt;
        if (limit > bound) revert DebtBoundExceeded(limit, bound);
        l.limit = limit;
        emit LimitSet(lineId, limit);
        _settle(lineId);
    }

    /// @notice The lender or the borrower stops new draws. What is owed stays owed.
    function closeLine(uint64 lineId) external nonReentrant {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender && msg.sender != l.borrower) revert NotLender();
        l.closed = true;
        if (lineIdOf[l.lender][l.borrower] == lineId) delete lineIdOf[l.lender][l.borrower];
        emit LineClosed(lineId);
        _settle(lineId);
    }

    /// @notice The borrower of a secured line locks shares as it borrows, after approving this contract as holder of
    ///         the vault's shares.
    function enableLocking(uint64 lineId) external nonReentrant {
        Line storage l = _lines[lineId];
        if (msg.sender != l.borrower) revert NotBorrower();
        if (address(l.collateralVault) == address(0)) revert InvalidLine();
        l.locking = true;
        emit LockingEnabled(lineId);
        _lock(lineId);
    }

    /// @notice Renews the line's commitment and share lock at today's balances and price. Anyone may call it.
    function relock(uint64 lineId) external nonReentrant {
        _settle(lineId);
    }

    /// @inheritdoc ISource
    function coverable(address owner, bytes32 position) external view returns (uint256) {
        uint64 lineId = _lineIdOf(position);
        Line storage l = _lines[lineId];
        if (owner != l.borrower || !_open(l) || l.token != PROGRAM.settlementToken()) return 0;
        return availableCredit(lineId);
    }

    /// @inheritdoc ISource
    function held(address owner, bytes32, bytes32 legId) external view returns (uint256) {
        bytes32 id = _holdId(owner, legId);
        uint64 lineId = _legs[id].lineId;
        if (lineId == 0) return 0;
        return CORE.getHold(_lines[lineId].lender, address(this), id).held;
    }

    /// @inheritdoc ISource
    /// @dev A line grants no capture tolerance: a capture past what was approved draws more credit only through
    ///      CAPTURE_FREE or CAPTURE_BEYOND, within the line's room.
    function toleranceBps(address, bytes32) external pure returns (uint16) {
        return 0;
    }

    /// @inheritdoc ISource
    /// @dev What a borrower owes a line is the line's, never core debt to this source.
    function owed(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc ISource
    function refundable(address owner, bytes32, bytes32 legId) external view returns (uint256) {
        return _legs[_holdId(owner, legId)].gross;
    }

    /// @inheritdoc ISource
    function hold(address owner, bytes32 position, bytes32 legId, uint256 units, uint64 expiresAt, bool standIn)
        external
        nonReentrant
        onlyProgram
        returns (uint256 heldUnits)
    {
        uint64 lineId = _lineIdOf(position);
        Line storage l = _lines[lineId];
        if (owner != l.borrower) revert NotBorrower();
        bytes32 id = _holdId(owner, legId);
        Leg storage g = _legs[id];
        uint256 now_ = g.lineId == 0 ? 0 : CORE.getHold(l.lender, address(this), id).held;
        if (g.lineId != 0 && g.lineId != lineId) revert UnknownLeg();
        heldUnits = units;
        if (units > now_) {
            if (!_open(l) || l.token != PROGRAM.settlementToken()) revert LineNotOpen();
            _accrue(lineId, false);
            uint256 credit = availableCredit(lineId);
            // A stand-in leg holds what the line can still give; captures may reach units later.
            if (standIn && units - now_ > credit) heldUnits = now_ + credit;
            if (heldUnits - now_ > credit) revert CreditExceeded(heldUnits - now_, credit);
        }
        if (heldUnits > type(uint64).max) revert CreditExceeded(heldUnits, type(uint64).max);
        // Bounded by the 64-bit check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        l.pending = l.pending + uint128(heldUnits) - g.held;
        // forge-lint: disable-next-line(unsafe-typecast)
        (g.lineId, g.held) = (lineId, uint64(heldUnits));
        // A growing leg comes out of the commitment first, which frees the lender's balance.
        if (heldUnits >= now_) _commit(lineId);
        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-start(reentrancy-no-eth)
        if (now_ == 0) {
            CORE.holdFrom(
                l.lender,
                IReservationCore.HoldRequest({
                    token: l.token,
                    id: id,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    amount: uint128(heldUnits),
                    expiresAt: expiresAt,
                    payee: PROGRAM.SETTLEMENT_ACCOUNT(),
                    standIn: false
                })
            );
        } else if (heldUnits != now_) {
            // forge-lint: disable-next-line(unsafe-typecast)
            CORE.adjust(l.lender, address(this), id, uint128(heldUnits));
        }
        // forge-lint: disable-end(reentrancy-no-eth)
        if (heldUnits < now_) _commit(lineId);
        _lock(lineId);
        emit Synced(lineId, id, l.owed, l.pending);
    }

    /// @inheritdoc ISource
    function capture(address owner, bytes32, bytes32 legId, uint256 units, uint8 flags)
        external
        nonReentrant
        onlyProgram
        returns (uint256, uint256)
    {
        bytes32 id = _holdId(owner, legId);
        Leg storage g = _legs[id];
        uint64 lineId = g.lineId;
        if (lineId == 0) revert UnknownLeg();
        Line storage l = _lines[lineId];
        IReservationCore.HoldRecord memory r = CORE.getHold(l.lender, address(this), id);
        // A settled leg covers nothing more.
        if (r.token == address(0)) return (0, 0);
        uint256 h = r.held;
        if (units > h && flags & (CAPTURE_BEYOND | CAPTURE_FREE) == 0) units = h;
        // forge-lint: disable-start(reentrancy-no-eth)
        if (units > h) {
            // Past what the leg holds: grow it within the line's credit first. CAPTURE_FREE takes what the credit
            // allows; CAPTURE_BEYOND reverts past it.
            _accrue(lineId, false);
            uint256 credit = availableCredit(lineId);
            if (units - h > credit && flags & CAPTURE_FREE != 0) units = h + credit;
            if (units - h > credit || units > type(uint64).max) revert CreditExceeded(units - h, credit);
            // Bounded by the 64-bit check above.
            // forge-lint: disable-start(unsafe-typecast)
            l.pending += uint128(units - h);
            g.held = uint64(units);
            // forge-lint: disable-end(unsafe-typecast)
            _commit(lineId);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (units > h) CORE.adjust(l.lender, address(this), id, uint128(units));
        }
        // A drained leg with no credit left covers nothing.
        if (units == 0 && flags & CAPTURE_FINAL == 0) return (0, 0);
        uint256 gross = uint256(g.gross) + units;
        // forge-lint: disable-next-line(unsafe-typecast)
        g.gross = uint64(gross);
        // forge-lint: disable-next-line(unsafe-typecast)
        CORE.capture(l.lender, address(this), id, uint128(units), flags & CAPTURE_FINAL != 0);
        // forge-lint: disable-end(reentrancy-no-eth)
        // forge-lint: disable-next-line(unsafe-typecast)
        _apply(lineId, id, uint64(gross));
        return (units, units);
    }

    /// @inheritdoc ISource
    /// @dev Credit never charges without a hold.
    function charge(address, bytes32, bytes32, uint256, bool) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc ISource
    function release(address owner, bytes32, bytes32 legId) external nonReentrant onlyProgram {
        bytes32 id = _holdId(owner, legId);
        Leg storage g = _legs[id];
        uint64 lineId = g.lineId;
        if (lineId == 0) return;
        Line storage l = _lines[lineId];
        IReservationCore.HoldRecord memory h = CORE.getHold(l.lender, address(this), id);
        if (h.token == address(0)) return;
        // Expiry is a timestamp by design; the transient lock covers the call.
        // forge-lint: disable-start(block-timestamp,reentrancy-no-eth)
        if (h.expiresAt <= block.timestamp) CORE.releaseExpired(l.lender, address(this), id);
        else CORE.release(l.lender, address(this), id);
        // forge-lint: disable-end(block-timestamp,reentrancy-no-eth)
        _apply(lineId, id, g.gross);
    }

    /// @inheritdoc ISource
    function refund(address owner, bytes32, bytes32 legId, uint256 units) external nonReentrant onlyProgram {
        bytes32 id = _holdId(owner, legId);
        Leg storage g = _legs[id];
        uint64 lineId = g.lineId;
        if (lineId == 0) revert UnknownLeg();
        Line storage l = _lines[lineId];
        uint64 gross = g.gross;
        uint256 taken = units < gross ? units : gross;
        // forge-lint: disable-next-line(unsafe-typecast)
        gross -= uint64(taken);
        g.gross = gross;
        // forge-lint: disable-start(reentrancy-no-eth)
        // forge-lint: disable-next-line(unsafe-typecast)
        if (taken != 0) CORE.refund(l.lender, l.token, address(this), id, uint128(taken));
        // The program sent units here first; what the leg did not take goes back to it.
        if (units > taken) SafeTransferLib.safeTransfer(l.token, msg.sender, units - taken);
        // forge-lint: disable-end(reentrancy-no-eth)
        _apply(lineId, id, gross);
    }

    /// @notice Repays amount of what the borrower owes, from the caller to the lender.
    function repay(uint64 lineId, uint128 amount) external nonReentrant {
        Line storage l = _lines[lineId];
        _repay(lineId, l, amount);
        SafeTransferLib.safeTransferFrom(l.token, msg.sender, l.lender, amount);
        _afterRepay(lineId, l, amount);
    }

    /// @notice Repays amount from the caller to the lender, as the program, one of its companions or a key holding its
    ///         treasury role, tied to ref (a purchase) so redraw may draw it again for that reference only.
    function repayFor(uint64 lineId, uint128 amount, bytes32 ref) external nonReentrant {
        _onlyTreasury();
        Line storage l = _lines[lineId];
        _repay(lineId, l, amount);
        repaymentOf[lineId][ref].repaid += amount;
        SafeTransferLib.safeTransferFrom(l.token, msg.sender, l.lender, amount);
        emit RepaidFor(lineId, ref, amount);
        _afterRepay(lineId, l, amount);
    }

    /// @notice Repays amount of the line's token from the caller's payToken, which the program's conversion venue
    ///         sells to the lender for exactly that amount, at a cost of at most maxIn. Returns what the caller paid.
    // Takes only from the caller, which approved this contract.
    // forge-lint: disable-next-item(arbitrary-send-erc20)
    function repayFrom(uint64 lineId, address payToken, uint128 amount, uint256 maxIn)
        external
        nonReentrant
        returns (uint256 spent)
    {
        Line storage l = _lines[lineId];
        _repay(lineId, l, amount);
        if (payToken == l.token) {
            spent = amount;
            SafeTransferLib.safeTransferFrom(l.token, msg.sender, l.lender, amount);
        } else {
            ILineVenue venue = _venue();
            spent = venue.quoteOut(payToken, l.token, amount);
            if (spent > maxIn) revert ConversionExceedsMax(spent, maxIn);
            SafeTransferLib.safeTransferFrom(payToken, msg.sender, address(this), spent);
            ProgramVenue.buy(venue, payToken, l.token, amount, spent, l.lender, msg.sender);
        }
        _afterRepay(lineId, l, amount);
    }

    /// @notice Draws up to amount on the line again for ref (a merchant's win on a purchase whose provisional credit
    ///         repaid the line), paying the program's settlement account from the lender's free balance, then its
    ///         commitment. At most what repayFor repaid for ref less what was drawn again for it, and the credit
    ///         still available. The program, its companions or its treasury role only. Returns what it drew.
    function redraw(uint64 lineId, uint128 amount, bytes32 ref) external nonReentrant returns (uint128 drawn) {
        _onlyTreasury();
        Line storage l = _lines[lineId];
        if (!_open(l)) revert LineNotOpen();
        RefRepayment storage r = repaymentOf[lineId][ref];
        uint256 left = r.repaid - r.redrawn;
        if (left == 0) revert NothingToRedraw();
        _accrue(lineId, false);
        uint256 credit = _min(availableCredit(lineId), left);
        // forge-lint: disable-next-line(unsafe-typecast)
        drawn = uint128(_min(amount, credit));
        if (drawn == 0) return 0;
        r.redrawn += drawn;
        address payee = PROGRAM.SETTLEMENT_ACCOUNT();
        uint256 free = CORE.available(l.lender, l.token);
        // availableCredit is bounded by the free balance plus the commitment, so the commitment covers the rest.
        // forge-lint: disable-start(reentrancy-no-eth)
        if (drawn > free) {
            uint256 keep = _heldNow(l.lender, commitmentOf[lineId]) - (drawn - free);
            bytes32 id = commitmentOf[lineId];
            // An amount the linter mistakes for a timestamp.
            // forge-lint: disable-next-line(block-timestamp)
            if (keep == 0) CORE.release(l.lender, address(this), id);
            // forge-lint: disable-next-line(unsafe-typecast)
            else CORE.adjust(l.lender, address(this), id, uint128(keep));
        }
        CORE.charge(l.lender, l.token, _chargeId(), drawn, payee, false);
        // forge-lint: disable-end(reentrancy-no-eth)
        l.owed += drawn;
        emit Redrawn(lineId, ref, payee, drawn, l.owed);
        _settle(lineId);
    }

    /// @notice Adds the interest the line has earned since it last did, up to the accepted debt bound. Anyone.
    function accrue(uint64 lineId) external nonReentrant {
        _accrue(lineId, true);
        _settle(lineId);
    }

    /// @notice Snapshots what the line owes as a statement due at dueAt, as its lender. Repayments pay open
    ///         statements oldest first.
    function closeStatement(uint64 lineId, uint64 dueAt) external returns (uint32 n) {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender) revert NotLender();
        // forge-lint: disable-next-line(block-timestamp)
        if (dueAt <= block.timestamp) revert InvalidStatement();
        _accrue(lineId, false);
        Statements storage s = statementsOf[lineId];
        n = ++s.count;
        if (s.collectFrom == 0) (s.collectFrom, s.payFrom) = (n, n);
        uint128 balance = l.owed;
        _statements[lineId][n] = Statement({
            dueAt: dueAt, status: balance == 0 ? StatementStatus.Paid : StatementStatus.Due, balance: balance, paid: 0
        });
        emit StatementClosed(lineId, n, balance, dueAt);
    }

    /// @notice The borrower names what statements falling due collect from, in order: the line's token, an Earn vault
    ///         over it (free shares), or another token the program's conversion venue sells for it.
    // At most MAX_AUTOPAY sources, each checked once.
    // forge-lint: disable-next-item(calls-loop)
    function setAutopay(uint64 lineId, address[] calldata sources) external {
        Line storage l = _lines[lineId];
        if (msg.sender != l.borrower) revert NotBorrower();
        if (sources.length > MAX_AUTOPAY) revert InvalidAutopay();
        for (uint256 i; i < sources.length; ++i) {
            if (sources[i] == l.token || _assetOf(sources[i]) == l.token) continue;
            if (address(ProgramVenue.venueOf(address(PROGRAM))) == address(0)) revert InvalidAutopay();
        }
        _autopay[lineId] = sources;
        emit AutopaySet(lineId, sources);
    }

    /// @notice Collects every statement that has fallen due through the borrower's autopay sources; one still short is
    ///         past due. Anyone may call it.
    function collect(uint64 lineId) external nonReentrant {
        Line storage l = _lines[lineId];
        _accrue(lineId, false);
        Statements storage s = statementsOf[lineId];
        uint32 count = s.count;
        uint32 n = s.collectFrom;
        if (n == 0) return;
        bool front = true;
        for (; n <= count; ++n) {
            Statement storage st = _statements[lineId][n];
            // forge-lint: disable-next-line(block-timestamp)
            if (st.status != StatementStatus.Due || st.dueAt > block.timestamp) {
                if (front && st.status != StatementStatus.Due) s.collectFrom = n + 1;
                else front = false;
                continue;
            }
            uint128 open = st.balance - st.paid;
            if (open > l.owed) open = l.owed;
            if (open != 0) {
                uint128 covered = _autopayFor(lineId, n, open);
                if (covered != 0) {
                    l.owed -= covered;
                    _payStatements(lineId, covered);
                    emit Repaid(lineId, l.borrower, covered, l.owed);
                }
            }
            st.status = st.paid >= st.balance || l.owed == 0 ? StatementStatus.Paid : StatementStatus.PastDue;
            emit StatementCollected(lineId, n, st.balance, st.paid, st.status);
            if (front) s.collectFrom = n + 1;
        }
        _settle(lineId);
    }

    /// @notice The lender sells just enough locked shares to bring a line past its loan-to-value back within it, at
    ///         today's price, and takes the proceeds toward what is owed.
    // Comparisons here are on share amounts the linter mistakes for timestamps.
    // forge-lint: disable-next-item(block-timestamp)
    function liquidate(uint64 lineId) external nonReentrant returns (uint128 shares, uint256 assets) {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender) revert NotLender();
        if (!l.locking) revert InvalidLine();
        _accrue(lineId, false);
        _lock(lineId);
        IEarnVault vault = l.collateralVault;
        uint256 locked = _heldNow(l.borrower, lockOf[lineId]);
        uint256 value = locked == 0 ? 0 : _inLine(l, vault.previewRedeem(locked));
        uint256 used = uint256(l.owed) + l.pending;
        uint256 ltv = l.ltvBps;
        if (used * BPS <= value * ltv) revert NotUndercollateralized(used, value * ltv / BPS);
        // Selling x restores used - x = ltv * (value - x).
        uint256 sell = _min((used * BPS - value * ltv + (BPS - ltv) - 1) / (BPS - ltv), l.owed);
        uint256 cover = _min(vault.previewWithdraw(_assetsFor(l, sell)), locked);
        // Rounding can leave the ratio a few units short; sell one more share at a time until it holds (bounded).
        for (uint256 i; i < 16 && cover < locked && !_sound(l, used, locked, cover); ++i) {
            ++cover;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        shares = uint128(cover);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        CORE.capture(l.borrower, address(this), lockOf[lineId], shares, false);
        ILineVenue venue = vault.asset() == l.token ? ILineVenue(address(0)) : _venue();
        assets = ProgramVenue.redeemTo(venue, vault, shares, l.token, l.lender);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 credited = assets < l.owed ? uint128(assets) : l.owed;
        l.owed -= credited;
        _payStatements(lineId, credited);
        emit Liquidated(lineId, shares, assets, l.owed);
        _settle(lineId);
    }

    /// @notice Credit the line can still draw: its limit (at most the debt bound), or for a secured line the lower of
    ///         that and its collateral's value times the loan-to-value, less what is owed and pending, within what the
    ///         lender's free balance and commitment back.
    function availableCredit(uint64 lineId) public view returns (uint256) {
        Line storage l = _lines[lineId];
        uint256 cap = _min(l.limit, l.maxDebt);
        if (address(l.collateralVault) != address(0)) cap = _min(cap, collateralValue(lineId) * l.ltvBps / BPS);
        uint256 used = uint256(l.owed) + l.pending;
        if (cap <= used) return 0;
        return _min(cap - used, CORE.available(l.lender, l.token) + _heldNow(l.lender, commitmentOf[lineId]));
    }

    /// @notice What a secured line's locked shares and the borrower's free shares are worth in its token; zero until
    ///         the borrower enables locking.
    function collateralValue(uint64 lineId) public view returns (uint256) {
        Line storage l = _lines[lineId];
        if (!l.locking) return 0;
        uint256 shares =
            _heldNow(l.borrower, lockOf[lineId]) + CORE.available(l.borrower, l.collateralVault.earnShare());
        // A share count the linter mistakes for a timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        return shares == 0 ? 0 : _inLine(l, l.collateralVault.previewRedeem(shares));
    }

    /// @notice What the line owes with the interest earned since it last accrued.
    function owedNow(uint64 lineId) external view returns (uint256 owed) {
        (owed,) = _interest(_lines[lineId]);
        owed += _lines[lineId].owed;
    }

    /// @notice What redraw may still draw on the line for ref; nothing on a line that is not open.
    function redrawable(uint64 lineId, bytes32 ref) external view returns (uint256) {
        if (!_open(_lines[lineId])) return 0;
        RefRepayment storage r = repaymentOf[lineId][ref];
        return r.repaid - r.redrawn;
    }

    /// @notice What the commitment hold reserves of the lender's balance now.
    function committed(uint64 lineId) external view returns (uint256) {
        Line storage l = _lines[lineId];
        return _heldNow(l.lender, commitmentOf[lineId]);
    }

    /// @notice The shares the line's lock holds now.
    function lockedShares(uint64 lineId) external view returns (uint256) {
        return _heldNow(_lines[lineId].borrower, lockOf[lineId]);
    }

    function lineOf(uint64 lineId) external view returns (Line memory) {
        return _lines[lineId];
    }

    /// @notice Leg legId of owner as the line last applied it: its line, what it held, what counted toward what the
    ///         borrower owes, and its captures less refunds.
    function legOf(address owner, bytes32 legId) external view returns (Leg memory) {
        return _legs[_holdId(owner, legId)];
    }

    function statementOf(uint64 lineId, uint32 n) external view returns (Statement memory) {
        return _statements[lineId][n];
    }

    function autopayOf(uint64 lineId) external view returns (address[] memory) {
        return _autopay[lineId];
    }

    /// @notice An accepted line in the program's settlement token that still has a limit, a balance owed or a live
    ///         leg keeps that token from changing (reason 7).
    function settlementTokenInUse(address) external view returns (uint8) {
        return _activeLines[PROGRAM.settlementToken()] != 0 ? IN_USE_LINES : 0;
    }

    function _onlyTreasury() private view {
        if (msg.sender == address(PROGRAM) || PROGRAM.isCompanion(msg.sender)) return;
        if (!PROGRAM.hasRoles(msg.sender, PROGRAM.ROLE_TREASURY())) revert NotProgram();
    }

    function _open(Line storage l) private view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return l.accepted && !l.closed && block.timestamp < l.dueDate;
    }

    function _lineIdOf(bytes32 position) private view returns (uint64 lineId) {
        // forge-lint: disable-next-line(unsafe-typecast)
        lineId = uint64(uint256(position));
        if (lineId == 0 || lineId > lineCount || uint256(position) > type(uint64).max) revert InvalidLine();
    }

    function _holdId(address owner, bytes32 legId) private pure returns (bytes32) {
        return keccak256(abi.encode(owner, legId));
    }

    function _chargeId() private returns (bytes32) {
        return keccak256(abi.encode("charge", ++_charges));
    }

    function _repay(uint64 lineId, Line storage l, uint128 amount) private {
        _accrue(lineId, false);
        if (amount == 0 || amount > l.owed) revert RepayExceedsOwed(amount, l.owed);
        l.owed -= amount;
        _payStatements(lineId, amount);
    }

    function _afterRepay(uint64 lineId, Line storage l, uint128 amount) private {
        emit Repaid(lineId, msg.sender, amount, l.owed);
        _settle(lineId);
    }

    /// @dev Applies a leg's hold and its captures less refunds (gross): captures add to what the borrower owes within
    ///      the accepted debt bound, refunds take from it, and captures, releases and expiry free pending credit. A
    ///      refund past what the borrower owes goes from the lender to the borrower.
    function _apply(uint64 lineId, bytes32 id, uint64 gross) private {
        Leg storage g = _legs[id];
        Line storage l = _lines[lineId];
        _accrue(lineId, false);
        uint128 h = CORE.getHold(l.lender, address(this), id).held;
        uint128 net = gross;
        l.pending = l.pending + h - g.held;
        uint128 excess;
        if (net >= g.net) {
            // A capture past the bound counts only within it; the rest counts on a later apply once there is room.
            uint256 more = net - g.net;
            uint256 used = uint256(l.owed) + l.pending;
            uint256 room = l.maxDebt > used ? l.maxDebt - used : 0;
            // forge-lint: disable-next-line(unsafe-typecast)
            if (more > room) (net, more) = (net - uint128(more - room), room);
            // forge-lint: disable-next-line(unsafe-typecast)
            l.owed += uint128(more);
        } else {
            uint128 back = g.net - net;
            if (back > l.owed) excess = back - l.owed;
            l.owed -= back - excess;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        (g.held, g.net) = (uint64(h), uint64(net));
        if (excess != 0) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            CORE.charge(l.lender, l.token, _chargeId(), excess, l.borrower, false);
            emit Overpaid(lineId, id, excess);
        }
        emit Synced(lineId, id, l.owed, l.pending);
        _settle(lineId);
    }

    function _settle(uint64 lineId) private {
        _commit(lineId);
        _lock(lineId);
    }

    function _offer(uint64 lineId, Line storage l, uint16 aprBps, uint128 maxDebt) private {
        uint256 limit = l.limit;
        if (maxDebt == 0) {
            uint256 bound = limit + limit * aprBps / BPS;
            // forge-lint: disable-next-line(unsafe-typecast)
            maxDebt = bound > type(uint128).max ? type(uint128).max : uint128(bound);
        }
        if (maxDebt < limit) revert InvalidLine();
        offerOf[lineId] = Terms(aprBps, maxDebt);
        emit TermsOffered(lineId, aprBps, maxDebt);
    }

    // forge-lint: disable-next-item(block-timestamp)
    function _interest(Line storage l) private view returns (uint256 interest, bool capped) {
        uint256 owed = l.owed;
        if (!l.accepted || owed == 0 || l.aprBps == 0 || block.timestamp <= l.lastAccrued) return (0, false);
        interest = owed * l.aprBps * (block.timestamp - l.lastAccrued) / (YEAR * BPS);
        uint256 used = owed + l.pending;
        uint256 room = l.maxDebt > used ? l.maxDebt - used : 0;
        if (interest >= room) (interest, capped) = (room, true);
    }

    /// @dev Adds interest since the last accrual. With carry, time too short to earn a whole unit carries over;
    ///      otherwise the clock restarts now, as what is owed is about to change.
    // forge-lint: disable-next-item(block-timestamp,unsafe-typecast)
    function _accrue(uint64 lineId, bool carry) private {
        Line storage l = _lines[lineId];
        if (!l.accepted) return;
        (uint256 interest, bool capped) = _interest(l);
        uint256 owed = l.owed;
        uint64 last = uint64(block.timestamp);
        if (carry && !capped && owed != 0 && l.aprBps != 0) {
            uint256 rate = owed * l.aprBps;
            last = uint64(l.lastAccrued + (interest * YEAR * BPS + rate - 1) / rate);
        }
        l.lastAccrued = last;
        if (interest == 0) return;
        l.owed = uint128(owed + interest);
        emit InterestAccrued(lineId, l.aprBps, uint128(interest), l.owed);
    }

    // _commit and _lock run only inside nonReentrant entry points against the fixed core; holds expire by timestamp
    // by design, and every amount they cast is bounded by a 128-bit line limit or a share balance.
    // forge-lint: disable-start(reentrancy-no-eth)
    // forge-lint: disable-start(block-timestamp)
    // forge-lint: disable-start(unsafe-typecast)

    /// @dev Moves the commitment hold to the undrawn limit, within what the lender's balance backs. Growing or placing
    ///      it is best effort: a lender who lowered its allowance keeps what is committed, and legs still settle.
    function _commit(uint64 lineId) private {
        _track(lineId);
        Line storage l = _lines[lineId];
        uint256 target;
        if (_open(l)) {
            uint256 used = uint256(l.owed) + l.pending;
            uint256 cap = _min(l.limit, l.maxDebt);
            target = cap > used ? cap - used : 0;
        }
        uint64 expiresAt = uint64(_min(block.timestamp + TERM, l.dueDate));
        (bytes32 id, bool ok) = _move(l.lender, l.token, commitmentOf[lineId], lineId, target, expiresAt, true);
        commitmentOf[lineId] = id;
        if (ok) emit Committed(lineId, id, uint128(_heldNow(l.lender, id)));
    }

    /// @dev Moves the share lock to the shares worth what is owed and pending over the loan-to-value, at most what the
    ///      borrower holds. Growth reverts if the borrower revoked this contract's allowance, so a leg it cannot secure
    ///      fails.
    function _lock(uint64 lineId) private {
        Line storage l = _lines[lineId];
        if (!l.locking) return;
        IEarnVault vault = l.collateralVault;
        uint256 used = _min(uint256(l.owed) + l.pending, l.maxDebt);
        uint256 target = used == 0 ? 0 : vault.previewWithdraw(_assetsFor(l, (used * BPS + l.ltvBps - 1) / l.ltvBps));
        uint64 expiresAt = uint64(block.timestamp + TERM);
        (bytes32 id,) = _move(l.borrower, vault.earnShare(), lockOf[lineId], lineId, target, expiresAt, false);
        lockOf[lineId] = id;
        emit Locked(lineId, id, uint128(_heldNow(l.borrower, id)));
    }

    /// @dev Moves this contract's hold id on owner's token to target (at most what the owner can back), renewing it
    ///      within a day of expiry. Returns the hold's id (zero when none) and whether anything changed.
    function _move(
        address owner,
        address token,
        bytes32 id,
        uint64 lineId,
        uint256 target,
        uint64 expiresAt,
        bool bestEffort
    ) private returns (bytes32, bool) {
        IReservationCore.HoldRecord memory h;
        bool live;
        if (id != bytes32(0)) {
            h = CORE.getHold(owner, address(this), id);
            live = h.token != address(0) && h.expiresAt > block.timestamp;
        }
        target = _min(target, CORE.available(owner, token) + (live ? h.held : 0));
        bool renew = live && h.expiresAt < block.timestamp + 1 days && expiresAt > h.expiresAt;
        if (live && !renew) {
            if (target == h.held) return (id, false);
            if (target == 0) {
                CORE.release(owner, address(this), id);
                return (bytes32(0), true);
            }
            if (target < h.held || !bestEffort) {
                CORE.adjust(owner, address(this), id, uint128(target));
            } else {
                try CORE.adjust(owner, address(this), id, uint128(target)) { }
                catch {
                    return (id, false);
                }
            }
            return (id, true);
        }
        if (live) CORE.release(owner, address(this), id);
        else if (h.token != address(0)) CORE.releaseExpired(owner, address(this), id);
        if (target == 0) return (bytes32(0), true);
        id = keccak256(abi.encode(lineId, ++_holds[lineId]));
        IReservationCore.HoldRequest memory req = IReservationCore.HoldRequest({
            token: token, id: id, amount: uint128(target), expiresAt: expiresAt, payee: address(this), standIn: false
        });
        if (!bestEffort) {
            CORE.holdFrom(owner, req);
            return (id, true);
        }
        try CORE.holdFrom(owner, req) { }
        catch {
            return (bytes32(0), true);
        }
        return (id, true);
    }

    // forge-lint: disable-end(unsafe-typecast)
    // forge-lint: disable-end(block-timestamp)
    // forge-lint: disable-end(reentrancy-no-eth)

    /// @dev Counts the line among active lines in its token while accepted, open and holding a limit, debt or a leg.
    function _track(uint64 lineId) private {
        Line storage l = _lines[lineId];
        bool active = l.accepted && !l.closed && (l.limit != 0 || l.owed != 0 || l.pending != 0);
        if (active == _active[lineId]) return;
        _active[lineId] = active;
        if (active) ++_activeLines[l.token];
        else --_activeLines[l.token];
    }

    /// @dev Takes up to amount for statement n from the borrower's autopay sources, in order, to the lender. A source
    ///      short of funds or approval gives what it can.
    // Runs inside collect's lock over at most MAX_AUTOPAY sources, taking only from the borrower that approved them.
    // forge-lint: disable-next-item(calls-loop,arbitrary-send-erc20)
    function _autopayFor(uint64 lineId, uint32 n, uint128 amount) private returns (uint128 covered) {
        Line storage l = _lines[lineId];
        (address borrower, address lender, address token) = (l.borrower, l.lender, l.token);
        address[] storage sources = _autopay[lineId];
        for (uint256 i; i < sources.length && covered < amount; ++i) {
            address source = sources[i];
            uint256 want = amount - covered;
            uint256 got;
            if (source == token) {
                got = _min(want, _free(token, borrower));
                if (got != 0) SafeTransferLib.safeTransferFrom(token, borrower, lender, got);
            } else if (_assetOf(source) == token) {
                got = _redeemFor(IEarnVault(source), borrower, lender, token, want);
            } else {
                got = _convertFor(l, source, borrower, want);
            }
            if (got == 0) continue;
            // forge-lint: disable-next-line(unsafe-typecast)
            covered += uint128(got);
            // forge-lint: disable-next-line(unsafe-typecast)
            emit Autopaid(lineId, n, source, uint128(got));
        }
    }

    /// @dev Sells the borrower's free shares for up to want of token, pays the lender, and returns surplus to the
    ///      borrower. Counts only tokens this contract received.
    // forge-lint: disable-next-item(calls-loop,arbitrary-send-erc20,reentrancy-no-eth)
    function _redeemFor(IEarnVault vault, address borrower, address lender, address token, uint256 want)
        private
        returns (uint256 got)
    {
        address share = vault.earnShare();
        uint256 free = _free(share, borrower);
        if (free == 0) return 0;
        uint256 need = vault.previewWithdraw(want);
        uint256 shares = _min(need, free);
        if (shares == 0) return 0;
        SafeTransferLib.safeTransferFrom(share, borrower, address(this), shares);
        SafeTransferLib.safeApprove(share, address(vault), shares);
        uint256 before = SafeTransferLib.balanceOf(token, address(this));
        if (need < free) vault.withdrawExact(want, address(this), shares);
        else vault.redeem(shares, address(this), 0);
        uint256 received = SafeTransferLib.balanceOf(token, address(this)) - before;
        SafeTransferLib.safeApprove(share, address(vault), 0);
        got = _min(received, want);
        if (got != 0) SafeTransferLib.safeTransfer(token, lender, got);
        if (received > got) SafeTransferLib.safeTransfer(token, borrower, received - got);
        uint256 left = SafeTransferLib.balanceOf(share, address(this));
        if (left != 0) SafeTransferLib.safeTransfer(share, borrower, left);
    }

    /// @dev Sells the borrower's free source tokens through the program's venue for up to want, to the lender.
    // forge-lint: disable-next-item(calls-loop,arbitrary-send-erc20)
    function _convertFor(Line storage l, address source, address borrower, uint256 want) private returns (uint256 got) {
        ILineVenue venue = ProgramVenue.venueOf(address(PROGRAM));
        if (address(venue) == address(0)) return 0;
        uint256 free = _free(source, borrower);
        if (free == 0) return 0;
        try venue.quoteOut(source, l.token, want) returns (uint256 need) {
            if (need <= free) {
                SafeTransferLib.safeTransferFrom(source, borrower, address(this), need);
                ProgramVenue.buy(venue, source, l.token, want, need, l.lender, borrower);
                return want;
            }
        } catch {
            return 0;
        }
        SafeTransferLib.safeTransferFrom(source, borrower, address(this), free);
        got = ProgramVenue.sell(venue, source, l.token, free, l.lender);
    }

    /// @dev Applies a repayment to the line's statements not yet paid, oldest first.
    function _payStatements(uint64 lineId, uint256 amount) private {
        Statements storage s = statementsOf[lineId];
        uint32 count = s.count;
        uint32 first = s.payFrom;
        if (first == 0) return;
        for (uint32 n = first; n <= count && amount != 0; ++n) {
            Statement storage st = _statements[lineId][n];
            if (st.status == StatementStatus.Paid) continue;
            uint256 part = _min(st.balance - st.paid, amount);
            // forge-lint: disable-next-line(unsafe-typecast)
            st.paid += uint128(part);
            amount -= part;
        }
        while (first <= count) {
            Statement storage st = _statements[lineId][first];
            if (st.status != StatementStatus.Paid && st.paid < st.balance) break;
            ++first;
        }
        s.payFrom = first;
    }

    // Called from the bounded liquidation loop.
    // forge-lint: disable-next-item(calls-loop)
    function _sound(Line storage l, uint256 used, uint256 locked, uint256 sold) private view returns (bool) {
        IEarnVault vault = l.collateralVault;
        uint256 proceeds = _min(_inLine(l, vault.previewRedeem(sold)), l.owed);
        return (used - proceeds) * BPS <= _inLine(l, vault.previewRedeem(locked - sold)) * l.ltvBps;
    }

    // forge-lint: disable-next-item(calls-loop)
    function _inLine(Line storage l, uint256 assets) private view returns (uint256) {
        address asset = l.collateralVault.asset();
        if (asset == l.token || assets == 0) return assets;
        return ProgramVenue.quoteIn(_venue(), asset, l.token, assets);
    }

    function _assetsFor(Line storage l, uint256 amount) private view returns (uint256) {
        address asset = l.collateralVault.asset();
        if (asset == l.token || amount == 0) return amount;
        return ProgramVenue.quoteOut(_venue(), asset, l.token, amount);
    }

    function _venue() private view returns (ILineVenue venue) {
        venue = ProgramVenue.venueOf(address(PROGRAM));
        if (address(venue) == address(0)) revert NoConversion();
    }

    /// @dev The asset of an Earn vault, zero for anything else.
    // forge-lint: disable-next-item(calls-loop)
    function _assetOf(address source) private view returns (address a) {
        if (source.code.length == 0) return address(0);
        (bool ok, bytes memory data) = source.staticcall(abi.encodeCall(IEarnVault.asset, ()));
        if (ok && data.length >= 32) a = abi.decode(data, (address));
    }

    /// @dev What of owner's token this contract may take now: free on the core and approved.
    // forge-lint: disable-next-item(calls-loop)
    function _free(address token, address owner) private view returns (uint256) {
        (bool ok, bytes memory data) =
            token.staticcall(abi.encodeWithSignature("allowance(address,address)", owner, address(this)));
        uint256 allowed = ok && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
        return _min(CORE.available(owner, token), allowed);
    }

    /// @dev What this contract's hold id on owner still holds, zero once gone or expired.
    // forge-lint: disable-next-item(block-timestamp)
    function _heldNow(address owner, bytes32 id) private view returns (uint256) {
        if (id == bytes32(0)) return 0;
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, address(this), id);
        return h.expiresAt <= block.timestamp ? 0 : h.held;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
