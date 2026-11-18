// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { ILineVenue, ProgramVenue } from "./ProgramVenue.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { ISettlementTokenGuard } from "./interfaces/ISettlementTokenGuard.sol";

/// @dev The account a card program settles through, which a line's redraws pay.
interface IProgramRoles {
    function rolesOf(address key) external view returns (uint8);
}

interface IProgramSettlementAccount {
    // The program's own name for it.
    // forge-lint: disable-next-line(mixed-case-function)
    function SETTLEMENT_ACCOUNT() external view returns (address);
}

/// @dev The token a card program settles in.
interface IProgramSettlementToken {
    function settlementToken() external view returns (address);
}

/// @title CreditLine
/// @notice Lenders' credit lines that card programs draw on. Each draw is a hold on the lender's own balance, placed
///         here through `holdFrom` (the lender approves this contract as a holder of the line's token), so every
///         approved line part is backed by funds the lender has reserved. The line's program is the hold's payee
///         and captures it; the borrower owes what was captured, net of refunds, until repaid. A secured line also
///         caps credit at the value of Earn shares the borrower pledged to this contract on the core, times its
///         loan-to-value, and may seize the pledge for what is owed once the due date and notice period have passed.
///         Specified in docs/cards/design.md (Card programs).
/// @dev Owed and pending amounts follow the core's records: `sync` reads a draw's hold and applies what changed,
///      whoever captured, released or refunded it. What is owed earns simple interest at the yearly rate the borrower
///      accepted, and what is owed and pending never passes the debt bound it accepted. The lender closes statements;
///      a statement falling due is collected through the borrower's autopay sources. Fees and collection beyond the
///      pledge and autopay are the issuer's and lender's services, not this contract's.
/// @custom:reentrancy-guard _locked
contract CreditLine is ISettlementTokenGuard {
    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint256 private constant BPS = 10_000;
    /// @dev The program role whose keys may repay a line for a reference (CardProgram.ROLE_TREASURY).
    uint8 private constant ROLE_TREASURY = 4;
    /// @dev How long one commitment hold lasts; the core caps holds at 31 days.
    uint256 private constant COMMITMENT_TERM = 30 days;
    /// @dev The year interest rates are quoted over.
    uint256 private constant YEAR = 365 days;

    struct Line {
        address lender;
        /// @dev No draws from the due date on; the pledge may be seized from `dueDate + noticePeriod`.
        uint64 dueDate;
        bool accepted;
        bool closed;
        address borrower;
        uint32 noticePeriod;
        uint16 ltvBps;
        address token;
        /// @dev The only card program that may draw on the line, and the payee of its holds.
        address program;
        uint128 limit;
        /// @dev Captured, net of refunds, not yet repaid or seized.
        uint128 owed;
        /// @dev What the line's live holds still reserve on the lender.
        uint128 pending;
        /// @dev Zero for an unsecured line.
        IEarnVault collateralVault;
        bytes32 pledgeId;
        /// @dev The yearly interest rate the borrower accepted, in basis points: simple interest on what is owed.
        uint16 aprBps;
        /// @dev When interest was last added.
        uint64 lastAccrued;
        /// @dev The most the borrower agreed to owe and have pending, interest included.
        uint128 maxDebt;
    }

    /// @dev Terms the lender offers and the borrower accepts.
    struct Terms {
        uint16 aprBps;
        uint128 maxDebt;
    }

    /// @dev What the program, or a treasury key of it, repaid on a line for one reference, and what was drawn again
    ///      for that reference since.
    struct RefRepayment {
        uint128 repaid;
        uint128 redrawn;
    }

    /// @dev What `sync` last read from a draw's hold.
    struct Draw {
        uint64 lineId;
        uint96 held;
        uint96 net;
    }

    enum StatementStatus {
        None,
        Due,
        Paid,
        PastDue
    }

    /// @dev What was owed when the lender closed the statement, and what repayments have paid of it since.
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

    /// @dev At most this many autopay sources per line.
    uint256 private constant MAX_AUTOPAY = 4;

    uint64 public lineCount;
    mapping(uint64 lineId => Line) internal _lines;
    mapping(bytes32 holdId => Draw) public draws;
    /// @notice The open line each lender has for each borrower, if any.
    mapping(address lender => mapping(address borrower => uint64 lineId)) public lineIdOf;
    /// @notice The hold that commits a line's undrawn limit on the lender's balance, and how many it has had.
    mapping(uint64 lineId => bytes32 holdId) public commitmentOf;
    mapping(uint64 lineId => uint64) internal _commitments;
    /// @notice Secured lines whose borrower locks shares as it borrows, instead of a fixed pledge, and the hold on the
    ///         borrower's shares that locks them.
    mapping(uint64 lineId => bool) public locking;
    mapping(uint64 lineId => bytes32 holdId) public lockOf;
    mapping(uint64 lineId => uint64) internal _locks;
    /// @notice Each line's statements by number, from 1, and its counters.
    mapping(uint64 lineId => mapping(uint32 n => Statement)) internal _statements;
    mapping(uint64 lineId => Statements) public statementsOf;
    /// @dev What a statement falling due collects from, in order: the line's token for the borrower's cash, or an Earn
    ///      vault over that token for the borrower's free shares in it.
    mapping(uint64 lineId => address[]) internal _autopay;

    /// @dev Re-draws so far, which number their charges on the lender.
    uint64 internal _redraws;
    /// @notice The terms each line's lender offers, which the borrower accepts to apply them.
    mapping(uint64 lineId => Terms) public offerOf;
    /// @notice What each line received as repayment for each reference through `repayFor`, and what `redraw` drew
    ///         again for it.
    mapping(uint64 lineId => mapping(bytes32 ref => RefRepayment)) public repaymentOf;

    /// @dev Accepted, open lines each program draws on in each token that still have a limit, a balance owed or a live
    ///      hold, and whether each line is one of them.
    mapping(address program => mapping(address token => uint256)) internal _activeLines;
    mapping(uint64 lineId => bool) internal _active;

    bool private transient _locked;

    event LineOpened(
        uint64 indexed lineId,
        address indexed lender,
        address indexed borrower,
        address token,
        address program,
        uint128 limit,
        uint64 dueDate,
        uint32 noticePeriod,
        address collateralVault,
        uint16 ltvBps
    );
    event LineAccepted(uint64 indexed lineId, uint16 aprBps, uint128 maxDebt);
    event TermsOffered(uint64 indexed lineId, uint16 aprBps, uint128 maxDebt);
    event LineClosed(uint64 indexed lineId);
    event LimitSet(uint64 indexed lineId, uint128 limit);
    event Drawn(uint64 indexed lineId, bytes32 indexed holdId, bytes32 ref, uint128 amount, uint64 expiresAt);
    event Synced(uint64 indexed lineId, bytes32 indexed holdId, uint128 owed, uint128 pending);
    event Repaid(uint64 indexed lineId, address indexed payer, uint128 amount, uint128 owed);
    /// @notice A repayment from the program or its treasury key tied to `ref`, which `redraw` may draw again.
    event RepaidFor(uint64 indexed lineId, bytes32 indexed ref, uint128 amount);
    /// @notice A refund past what the line owed, passed from the lender to the borrower.
    event Overpaid(uint64 indexed lineId, bytes32 holdId, uint128 amount);
    /// @notice The lender paid `payee` `amount` on the borrower's behalf, which the borrower now owes.
    event Redrawn(uint64 indexed lineId, bytes32 indexed ref, address indexed payee, uint128 amount, uint128 owed);
    event Committed(uint64 indexed lineId, bytes32 holdId, uint128 amount);
    event PledgeAttached(uint64 indexed lineId, bytes32 pledgeId, uint128 shares, uint64 expiresAt);
    event PledgeReleased(uint64 indexed lineId, bytes32 pledgeId);
    event Seized(uint64 indexed lineId, bytes32 pledgeId, uint128 shares, uint256 assets, uint128 owed);
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

    error CreditExceeded(uint256 amount, uint256 available);
    error DebtBoundExceeded(uint256 amount, uint256 maxDebt);
    error ConversionExceedsMax(uint256 cost, uint256 maxIn);
    error NoConversion();
    error InvalidAutopay();
    error InvalidLine();
    error InvalidRate();
    error InvalidStatement();
    error InvalidPledge();
    error LineNotOpen();
    error NotBorrower();
    error NotLender();
    error NotPastDue();
    error NotProgram();
    error NothingOwed();
    error NothingToRedraw();
    error NotUndercollateralized(uint256 owed, uint256 secured);
    error PledgeInPlace();
    error Reentrancy();
    error RepayExceedsOwed(uint256 amount, uint256 owed);
    error StillOwed();
    error TermsMismatch();
    error UnknownDraw();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /// @notice Opens a line from the caller (the lender) to `borrower`, drawn on by `program` only, offering simple
    ///         interest of `aprBps` a year on what is owed and a bound of `maxDebt` on what is owed and pending, zero
    ///         meaning the limit plus a year of interest on it. The borrower must accept these terms before any draw.
    ///         `collateralVault` zero makes it unsecured.
    function openLine(
        address borrower,
        address token,
        address program,
        uint128 limit,
        uint64 dueDate,
        uint32 noticePeriod,
        IEarnVault collateralVault,
        uint16 ltvBps,
        uint16 aprBps,
        uint128 maxDebt
    ) external returns (uint64 lineId) {
        if (borrower == address(0) || token == address(0) || program == address(0)) {
            revert InvalidLine();
        }
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (dueDate <= block.timestamp) revert InvalidLine();
        if (address(collateralVault) == address(0)) {
            if (ltvBps != 0) revert InvalidLine();
        } else if (ltvBps == 0 || ltvBps > BPS) {
            revert InvalidLine();
        } else if (collateralVault.asset() != token && address(ProgramVenue.venueOf(program)) == address(0)) {
            // Collateral in another token is valued and sold through the program's conversion venue.
            revert InvalidLine();
        }
        if (lineIdOf[msg.sender][borrower] != 0) revert InvalidLine();
        lineId = ++lineCount;
        lineIdOf[msg.sender][borrower] = lineId;
        Line storage l = _lines[lineId];
        l.lender = msg.sender;
        l.dueDate = dueDate;
        l.borrower = borrower;
        l.noticePeriod = noticePeriod;
        l.ltvBps = ltvBps;
        l.token = token;
        l.program = program;
        l.limit = limit;
        l.collateralVault = collateralVault;
        emit LineOpened(
            lineId, msg.sender, borrower, token, program, limit, dueDate, noticePeriod, address(collateralVault), ltvBps
        );
        _offer(lineId, l, aprBps, maxDebt);
    }

    /// @notice The lender offers new terms for line `lineId`, which apply once the borrower accepts them; until then
    ///         the accepted terms stay. `maxDebt` zero means the limit plus a year of interest on it.
    function offerTerms(uint64 lineId, uint16 aprBps, uint128 maxDebt) external {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender) revert NotLender();
        _offer(lineId, l, aprBps, maxDebt);
    }

    /// @notice The borrower accepts the terms the lender offers, which must be `aprBps` and `maxDebt`, and agrees to
    ///         owe what the line's program draws within them. Interest so far accrues at the earlier rate first.
    function acceptLine(uint64 lineId, uint16 aprBps, uint128 maxDebt) external nonReentrant {
        Line storage l = _lines[lineId];
        if (msg.sender != l.borrower) revert NotBorrower();
        Terms memory o = offerOf[lineId];
        if (aprBps != o.aprBps || maxDebt != o.maxDebt || maxDebt < l.limit) revert TermsMismatch();
        _accrue(lineId, false);
        // forge-lint: disable-next-line(unsafe-typecast)
        (l.accepted, l.aprBps, l.maxDebt, l.lastAccrued) = (true, aprBps, maxDebt, uint64(block.timestamp));
        emit LineAccepted(lineId, aprBps, maxDebt);
        _commit(lineId);
        _lock(lineId);
    }

    /// @notice The lender sets the line's limit, at most the debt bound the borrower accepted (or, before it
    ///         accepts, the one offered); draws already placed stay.
    function setLimit(uint64 lineId, uint128 limit) external {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender) revert NotLender();
        uint128 bound = l.accepted ? l.maxDebt : offerOf[lineId].maxDebt;
        if (limit > bound) revert DebtBoundExceeded(limit, bound);
        l.limit = limit;
        emit LimitSet(lineId, limit);
        _commit(lineId);
    }

    /// @notice The lender or the borrower stops new draws. What is owed stays owed.
    function closeLine(uint64 lineId) external {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender && msg.sender != l.borrower) revert NotLender();
        l.closed = true;
        if (lineIdOf[l.lender][l.borrower] == lineId) delete lineIdOf[l.lender][l.borrower];
        emit LineClosed(lineId);
        _commit(lineId);
    }

    /// @notice Places a hold of `amount` on the lender's balance, payable to the calling program, for the
    ///         borrower's purchase `ref`. Only the line's program may call it, within the available credit.
    /// @return holdId The hold's id on the lender's account.
    /// @return lender Whose balance is held.
    /// @return token The line's token.
    function draw(uint64 lineId, address borrower, bytes32 ref, uint128 amount, uint64 expiresAt)
        external
        nonReentrant
        returns (bytes32 holdId, address lender, address token)
    {
        Line storage l = _lines[lineId];
        if (msg.sender != l.program) revert NotProgram();
        if (borrower != l.borrower) revert NotBorrower();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (!l.accepted || l.closed || block.timestamp >= l.dueDate) revert LineNotOpen();
        _accrue(lineId, false);
        uint256 credit = availableCredit(lineId);
        if (amount > credit) revert CreditExceeded(amount, credit);
        // Draws fit in a Draw record: credit is bounded by the limit, so this only guards an unusual limit.
        if (amount > type(uint96).max) revert CreditExceeded(amount, type(uint96).max);

        (lender, token) = (l.lender, l.token);
        holdId = holdIdOf(msg.sender, ref);
        // forge-lint: disable-next-line(unsafe-typecast)
        draws[holdId] = Draw({ lineId: lineId, held: uint96(amount), net: 0 });
        l.pending += amount;
        // The draw comes out of the commitment, so it frees the lender's balance first.
        _commit(lineId);
        _lock(lineId);
        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-start(reentrancy-no-eth)
        CORE.holdFrom(
            lender,
            IReservationCore.HoldRequest({
                token: token, id: holdId, amount: amount, expiresAt: expiresAt, payee: msg.sender, standIn: false
            })
        );
        // forge-lint: disable-end(reentrancy-no-eth)
        emit Drawn(lineId, holdId, ref, amount, expiresAt);
    }

    /// @notice Applies what changed on a draw's hold since the last sync: captures add to what the borrower owes,
    ///         refunds take from it, and captures, releases and expiry free pending credit. Anyone may call it.
    function sync(bytes32 holdId) public {
        Draw storage d = draws[holdId];
        uint64 lineId = d.lineId;
        if (lineId == 0) revert UnknownDraw();
        Line storage l = _lines[lineId];
        _accrue(lineId, false);
        IReservationCore.HoldRecord memory h = CORE.getHold(l.lender, holdId);
        uint128 held = h.held;
        uint128 net = h.captured - h.refunded;
        // Pending holds only shrink after placement: captures and releases free them.
        l.pending = l.pending + held - d.held;
        uint128 excess;
        if (net >= d.net) {
            l.owed += net - d.net;
        } else {
            uint128 back = d.net - net;
            if (back > l.owed) excess = back - l.owed;
            l.owed -= back - excess;
        }
        // Both are at most the draw's amount, which fits in 96 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        (d.held, d.net) = (uint96(held), uint96(net));
        // A refund past what the borrower owes (it repaid the purchase already) reached the lender; it is the
        // borrower's. The id is unique: each refund lowers the draw's net.
        if (excess != 0) {
            CORE.charge(
                l.lender,
                l.token,
                keccak256(abi.encode(address(this), "overpaid", holdId, net)),
                excess,
                l.borrower,
                false
            );
            emit Overpaid(lineId, holdId, excess);
        }
        emit Synced(lineId, holdId, l.owed, l.pending);
        _commit(lineId);
        _lock(lineId);
    }

    /// @notice Sets what draw `holdId` still reserves, as the program that drew it: an increase must fit the line's
    ///         available credit and moves out of the commitment; a decrease returns to it.
    function resize(bytes32 holdId, uint128 amount) external nonReentrant {
        Draw storage d = draws[holdId];
        uint64 lineId = d.lineId;
        if (lineId == 0) revert UnknownDraw();
        Line storage l = _lines[lineId];
        if (msg.sender != l.program) revert NotProgram();
        uint128 held = CORE.getHold(l.lender, holdId).held;
        if (amount > held) {
            _accrue(lineId, false);
            uint256 more = amount - held;
            uint256 credit = availableCredit(lineId);
            if (more > credit) revert CreditExceeded(more, credit);
            if (amount > type(uint96).max) revert CreditExceeded(amount, type(uint96).max);
            l.pending = l.pending + amount - d.held;
            // forge-lint: disable-next-line(unsafe-typecast)
            d.held = uint96(amount);
            _commit(lineId);
            // Every entry point holds the transient lock for this whole call.
            // forge-lint: disable-next-line(reentrancy-no-eth)
            CORE.adjust(l.lender, holdId, amount);
        } else {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            CORE.adjust(l.lender, holdId, amount);
            l.pending = l.pending + amount - d.held;
            // forge-lint: disable-next-line(unsafe-typecast)
            d.held = uint96(amount);
            _commit(lineId);
        }
        _lock(lineId);
        emit Synced(lineId, holdId, l.owed, l.pending);
    }

    /// @notice Draws up to `amount` on line `lineId` again for its program (a merchant's win on a purchase that
    ///         provisional credit repaid), paying the program's settlement account from what the lender can fund: its
    ///         free balance, then its commitment. Only the line's program may call it, on an accepted, open line before
    ///         its due date, and it draws at most the credit still available and what `repayFor` repaid for `ref` less
    ///         what was drawn again for it already. Returns what it drew.
    function redraw(uint64 lineId, uint128 amount, bytes32 ref) external nonReentrant returns (uint128 drawn) {
        Line storage l = _lines[lineId];
        if (msg.sender != l.program) revert NotProgram();
        // Due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (!l.accepted || l.closed || block.timestamp >= l.dueDate) revert LineNotOpen();
        RefRepayment storage r = repaymentOf[lineId][ref];
        uint256 left = r.repaid - r.redrawn;
        if (left == 0) revert NothingToRedraw();
        _accrue(lineId, false);
        uint256 credit = availableCredit(lineId);
        if (left < credit) credit = left;
        // At most amount, a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        drawn = uint128(amount < credit ? amount : credit);
        if (drawn == 0) return 0;
        r.redrawn += drawn;
        address payee = IProgramSettlementAccount(l.program).SETTLEMENT_ACCOUNT();
        uint256 free = CORE.available(l.lender, l.token);
        // availableCredit is bounded by the free balance plus the commitment, so the commitment covers the rest. The
        // call is nonReentrant and _commit rewrites the commitment afterwards.
        // The commitment's expiry only zeroes it in _committed; nothing here compares time.
        // forge-lint: disable-start(block-timestamp)
        // forge-lint: disable-start(reentrancy-no-eth)
        if (drawn > free) {
            uint256 keep = _committed(lineId) - (drawn - free);
            bytes32 id = commitmentOf[lineId];
            if (keep == 0) CORE.release(l.lender, id);
            // forge-lint: disable-next-line(unsafe-typecast)
            else CORE.adjust(l.lender, id, uint128(keep));
        }
        CORE.charge(l.lender, l.token, keccak256(abi.encode(address(this), "redraw", ++_redraws)), drawn, payee, false);
        // forge-lint: disable-end(reentrancy-no-eth)
        // forge-lint: disable-end(block-timestamp)
        l.owed += drawn;
        emit Redrawn(lineId, ref, payee, drawn, l.owed);
        _commit(lineId);
        _lock(lineId);
    }

    /// @notice Recommits line `lineId`'s undrawn limit on the lender's balance, renewing its hold before it expires.
    ///         Anyone may call it.
    function recommit(uint64 lineId) external nonReentrant {
        _commit(lineId);
    }

    /// @notice Repays `amount` of what the borrower owes, from the caller to the lender.
    function repay(uint64 lineId, uint128 amount) external nonReentrant {
        Line storage l = _lines[lineId];
        _repay(lineId, l, amount);
        SafeTransferLib.safeTransferFrom(l.token, msg.sender, l.lender, amount);
        _afterRepay(lineId, l, amount);
    }

    /// @notice Repays `amount` of what the borrower owes from the caller to the lender, as the line's program or a key
    ///         holding its treasury role, tied to `ref` (a purchase or recovery) so `redraw` may draw it again for
    ///         that reference.
    function repayFor(uint64 lineId, uint128 amount, bytes32 ref) external nonReentrant {
        Line storage l = _lines[lineId];
        address program = l.program;
        if (msg.sender != program && IProgramRoles(program).rolesOf(msg.sender) & ROLE_TREASURY == 0) {
            revert NotProgram();
        }
        _repay(lineId, l, amount);
        repaymentOf[lineId][ref].repaid += amount;
        SafeTransferLib.safeTransferFrom(l.token, msg.sender, l.lender, amount);
        emit RepaidFor(lineId, ref, amount);
        _afterRepay(lineId, l, amount);
    }

    /// @notice Repays `amount` of the line's token from the caller's `payToken`, which the program's conversion
    ///         venue sells to the lender for exactly that amount, at a cost of at most `maxIn`.
    /// @return spent What the caller paid in `payToken`.
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
            ILineVenue venue = _venue(l);
            spent = venue.quoteOut(payToken, l.token, amount);
            if (spent > maxIn) revert ConversionExceedsMax(spent, maxIn);
            SafeTransferLib.safeTransferFrom(payToken, msg.sender, address(this), spent);
            ProgramVenue.buy(venue, payToken, l.token, amount, spent, l.lender, msg.sender);
        }
        _afterRepay(lineId, l, amount);
    }

    function _repay(uint64 lineId, Line storage l, uint128 amount) private {
        _accrue(lineId, false);
        if (amount == 0 || amount > l.owed) revert RepayExceedsOwed(amount, l.owed);
        l.owed -= amount;
        _payStatements(lineId, amount);
    }

    function _afterRepay(uint64 lineId, Line storage l, uint128 amount) private {
        emit Repaid(lineId, msg.sender, amount, l.owed);
        _commit(lineId);
        _lock(lineId);
    }

    /// @notice Adds the interest line `lineId` has earned since it last did: simple interest on what it owes at the
    ///         yearly rate the borrower accepted, over the time elapsed, rounded down, up to the accepted debt bound.
    ///         Anyone may call it.
    function accrue(uint64 lineId) external nonReentrant {
        _accrue(lineId, true);
        _commit(lineId);
        _lock(lineId);
    }

    /// @notice What line `lineId` owes with the interest it has earned since it last accrued.
    function owedNow(uint64 lineId) external view returns (uint256 owed) {
        (owed,) = _interest(_lines[lineId]);
        owed += _lines[lineId].owed;
    }

    /// @notice What `redraw` may still draw on line `lineId` for `ref`: what `repayFor` repaid for it, less what was
    ///         drawn again.
    function redrawable(uint64 lineId, bytes32 ref) external view returns (uint256) {
        RefRepayment storage r = repaymentOf[lineId][ref];
        return r.repaid - r.redrawn;
    }

    /// @notice Snapshots what line `lineId` owes as a statement due at `dueAt`, as its lender. Repayments pay the
    ///         line's open statements oldest first; one owing nothing is paid at once.
    /// @return n The statement's number on the line.
    function closeStatement(uint64 lineId, uint64 dueAt) external returns (uint32 n) {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender) revert NotLender();
        // Due dates are timestamps by design; a few seconds of validator skew does not change them.
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

    /// @notice The borrower names what statements falling due collect from, in order: the line's token for its cash,
    ///         an Earn vault over that token for its free shares there, or another token the program's conversion
    ///         venue sells for the line's. It approves this contract to take them.
    // At most MAX_AUTOPAY sources, each checked once.
    // forge-lint: disable-next-item(calls-loop)
    function setAutopay(uint64 lineId, address[] calldata sources) external {
        Line storage l = _lines[lineId];
        if (msg.sender != l.borrower) revert NotBorrower();
        if (sources.length > MAX_AUTOPAY) revert InvalidAutopay();
        for (uint256 i; i < sources.length; ++i) {
            address source = sources[i];
            if (source == l.token || _assetOf(source) == l.token) continue;
            if (address(ProgramVenue.venueOf(l.program)) == address(0)) revert InvalidAutopay();
        }
        _autopay[lineId] = sources;
        emit AutopaySet(lineId, sources);
    }

    /// @notice Collects every statement of line `lineId` that has fallen due: autopay pays what the statement still
    ///         owes, at most what the line owes, from the borrower's sources in order, and a statement still short
    ///         is past due. Anyone may call it.
    function collect(uint64 lineId) external nonReentrant {
        Line storage l = _lines[lineId];
        _accrue(lineId, false);
        Statements storage s = statementsOf[lineId];
        uint32 count = s.count;
        uint32 n = s.collectFrom;
        if (n == 0) return;
        // The cursor moves only past a run of statements no longer due at the front.
        bool front = true;
        for (; n <= count; ++n) {
            Statement storage st = _statements[lineId][n];
            // Due dates are timestamps by design.
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
        _commit(lineId);
        _lock(lineId);
    }

    /// @notice Statement `n` of line `lineId`.
    function statementOf(uint64 lineId, uint32 n) external view returns (Statement memory) {
        return _statements[lineId][n];
    }

    /// @notice What line `lineId`'s statements collect from.
    function autopayOf(uint64 lineId) external view returns (address[] memory) {
        return _autopay[lineId];
    }

    /// @dev Takes up to `amount` for statement `n` from the borrower's autopay sources, in order, to the lender, and
    ///      returns what the lender received. A source short of funds or approval gives what it can; a vault counts only
    ///      the tokens it actually paid.
    // Runs inside `collect`'s lock, over at most MAX_AUTOPAY sources the borrower named, and takes only from the
    // borrower that approved this contract for its autopay.
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
                got = _min(want, _min(CORE.available(borrower, token), _allowance(token, borrower)));
                if (got != 0) SafeTransferLib.safeTransferFrom(token, borrower, lender, got);
            } else if (_assetOf(source) == token) {
                got = _redeemFor(IEarnVault(source), borrower, lender, token, want);
            } else {
                got = _convertFor(l, source, borrower, want);
            }
            if (got == 0) continue;
            // Each part is at most `amount`.
            // forge-lint: disable-next-line(unsafe-typecast)
            covered += uint128(got);
            // forge-lint: disable-next-line(unsafe-typecast)
            emit Autopaid(lineId, n, source, uint128(got));
        }
    }

    /// @dev Sells the borrower's free shares in `vault` for up to `want` of `token`, pays that to the lender and
    ///      returns surplus tokens and unspent shares to the borrower. Counts only tokens this contract received.
    // Runs inside `collect`'s lock, once per autopay source, taking only from the borrower that approved it.
    // forge-lint: disable-next-item(calls-loop,arbitrary-send-erc20,reentrancy-no-eth)
    function _redeemFor(IEarnVault vault, address borrower, address lender, address token, uint256 want)
        private
        returns (uint256 got)
    {
        address share = vault.earnShare();
        // Shares under a hold or a lien stay out of reach.
        uint256 free = _min(CORE.available(borrower, share), _allowance(share, borrower));
        if (free == 0) return 0;
        uint256 need = vault.previewWithdraw(want);
        uint256 shares = need < free ? need : free;
        if (shares == 0) return 0;
        SafeTransferLib.safeTransferFrom(share, borrower, address(this), shares);
        SafeTransferLib.safeApprove(share, address(vault), shares);
        uint256 before = _balanceOf(token, address(this));
        // Exactly what is due when the free shares cover it, else everything they are worth.
        if (need < free) vault.withdrawExact(want, address(this), shares);
        else vault.redeem(shares, address(this), 0);
        uint256 received = _balanceOf(token, address(this)) - before;
        SafeTransferLib.safeApprove(share, address(vault), 0);
        got = _min(received, want);
        if (got != 0) SafeTransferLib.safeTransfer(token, lender, got);
        if (received > got) SafeTransferLib.safeTransfer(token, borrower, received - got);
        uint256 left = _balanceOf(share, address(this));
        if (left != 0) SafeTransferLib.safeTransfer(share, borrower, left);
    }

    /// @dev Sells up to what buys `want` of the line's token from the borrower's free `source` tokens through the
    ///      program's venue, to the lender, and returns what the lender received. Gives what the free tokens buy when
    ///      they fall short, and nothing when the venue cannot quote.
    // Runs inside `collect`'s lock, once per autopay source, taking only from the borrower that approved it.
    // forge-lint: disable-next-item(calls-loop,arbitrary-send-erc20)
    function _convertFor(Line storage l, address source, address borrower, uint256 want) private returns (uint256 got) {
        ILineVenue venue = ProgramVenue.venueOf(l.program);
        if (address(venue) == address(0)) return 0;
        uint256 free = _min(CORE.available(borrower, source), _allowance(source, borrower));
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

    /// @dev Redeems `shares` of the line's collateral and pays the lender in the line's token, selling through the
    ///      venue when the vault's asset differs, and returns what the lender received.
    // forge-lint: disable-next-item(reentrancy-no-eth)
    function _redeemToLender(Line storage l, uint256 shares) private returns (uint256) {
        IEarnVault vault = l.collateralVault;
        ILineVenue venue = vault.asset() == l.token ? ILineVenue(address(0)) : _venue(l);
        return ProgramVenue.redeemTo(venue, vault, shares, l.token, l.lender);
    }

    /// @dev What the collateral's `assets` sell for in the line's token now.
    // Called from the bounded liquidation and autopay loops.
    // forge-lint: disable-next-item(calls-loop)
    function _inLine(Line storage l, uint256 assets) private view returns (uint256) {
        address asset = l.collateralVault.asset();
        if (asset == l.token || assets == 0) return assets;
        return ProgramVenue.quoteIn(_venue(l), asset, l.token, assets);
    }

    /// @dev The collateral assets that sell for `amount` of the line's token now.
    function _assetsFor(Line storage l, uint256 amount) private view returns (uint256) {
        address asset = l.collateralVault.asset();
        if (asset == l.token || amount == 0) return amount;
        return ProgramVenue.quoteOut(_venue(l), asset, l.token, amount);
    }

    function _venue(Line storage l) private view returns (ILineVenue venue) {
        venue = ProgramVenue.venueOf(l.program);
        if (address(venue) == address(0)) revert NoConversion();
    }

    /// @dev The asset of an Earn vault, zero for anything else, such as a token.
    // Called from the bounded liquidation and autopay loops.
    // forge-lint: disable-next-item(calls-loop)
    function _assetOf(address source) private view returns (address a) {
        if (source.code.length == 0) return address(0);
        (bool ok, bytes memory data) = source.staticcall(abi.encodeCall(IEarnVault.asset, ()));
        if (ok && data.length >= 32) a = abi.decode(data, (address));
    }

    /// @dev Applies a repayment of `amount` to line `lineId`'s statements not yet paid, oldest first.
    function _payStatements(uint64 lineId, uint256 amount) private {
        Statements storage s = statementsOf[lineId];
        uint32 count = s.count;
        uint32 first = s.payFrom;
        if (first == 0) return;
        for (uint32 n = first; n <= count && amount != 0; ++n) {
            Statement storage st = _statements[lineId][n];
            if (st.status == StatementStatus.Paid) continue;
            uint256 part = _min(st.balance - st.paid, amount);
            // At most the statement's 128-bit balance.
            // forge-lint: disable-next-line(unsafe-typecast)
            st.paid += uint128(part);
            amount -= part;
        }
        // Statements before the first one still short take no more.
        while (first <= count) {
            Statement storage st = _statements[lineId][first];
            if (st.status != StatementStatus.Paid && st.paid < st.balance) break;
            ++first;
        }
        s.payFrom = first;
    }

    function _balanceOf(address token, address account) private view returns (uint256) {
        return SafeTransferLib.balanceOf(token, account);
    }

    // Called once per autopay source.
    // forge-lint: disable-next-item(calls-loop)
    function _allowance(address token, address owner) private view returns (uint256 amount) {
        (bool ok, bytes memory data) =
            token.staticcall(abi.encodeWithSignature("allowance(address,address)", owner, address(this)));
        if (ok && data.length >= 32) amount = abi.decode(data, (uint256));
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice The borrower attaches a pledge it placed on the core with this contract as authority: the line's
    ///         collateral share, expiring after the due date and notice period. Replaces only a pledge that is gone.
    function attachPledge(uint64 lineId, bytes32 pledgeId) external {
        Line storage l = _lines[lineId];
        if (msg.sender != l.borrower) revert NotBorrower();
        IEarnVault vault = l.collateralVault;
        if (address(vault) == address(0) || locking[lineId]) revert InvalidPledge();
        if (l.pledgeId != bytes32(0)) {
            (,, uint128 current,,) = CORE.lienOf(address(this), l.pledgeId);
            if (current != 0) revert PledgeInPlace();
        }
        (address owner, address token, uint128 shares, uint64 expiresAt, bool pledged) =
            CORE.lienOf(address(this), pledgeId);
        if (
            owner != l.borrower || token != vault.earnShare() || !pledged || shares == 0
                || expiresAt <= uint256(l.dueDate) + l.noticePeriod
        ) revert InvalidPledge();
        l.pledgeId = pledgeId;
        emit PledgeAttached(lineId, pledgeId, shares, expiresAt);
    }

    /// @notice The borrower takes its pledge back once nothing is owed or pending.
    function releasePledge(uint64 lineId) external {
        Line storage l = _lines[lineId];
        if (msg.sender != l.borrower) revert NotBorrower();
        if (l.owed != 0 || l.pending != 0) revert StillOwed();
        bytes32 pledgeId = l.pledgeId;
        if (pledgeId == bytes32(0)) revert InvalidPledge();
        l.pledgeId = bytes32(0);
        (,, uint128 shares,,) = CORE.lienOf(address(this), pledgeId);
        if (shares != 0) CORE.releaseLien(pledgeId);
        emit PledgeReleased(lineId, pledgeId);
    }

    /// @notice The lender seizes pledged shares for what is owed, once the due date and notice period have passed,
    ///         and redeems them to itself. Seizes at most the shares that cover what is owed.
    /// @return shares The shares seized.
    /// @return assets What the lender received.
    function seize(uint64 lineId) external nonReentrant returns (uint128 shares, uint256 assets) {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender) revert NotLender();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < uint256(l.dueDate) + l.noticePeriod) revert NotPastDue();
        _accrue(lineId, false);
        uint128 owed = l.owed;
        if (owed == 0) revert NothingOwed();
        bytes32 pledgeId = l.pledgeId;
        if (pledgeId == bytes32(0)) revert InvalidPledge();
        (,, uint128 pledgedShares,,) = CORE.lienOf(address(this), pledgeId);
        uint256 cover = l.collateralVault.previewWithdraw(_assetsFor(l, owed));
        // forge-lint: disable-next-line(unsafe-typecast)
        shares = cover < pledgedShares ? uint128(cover) : pledgedShares;
        if (shares == 0) revert InvalidPledge();

        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        CORE.seizeLien(pledgeId, shares);
        assets = _redeemToLender(l, shares);
        // Rounding may return a little more than owed; the debt never goes below zero.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 credited = assets < owed ? uint128(assets) : owed;
        l.owed = owed - credited;
        _payStatements(lineId, credited);
        _track(lineId);
        emit Seized(lineId, pledgeId, shares, assets, l.owed);
    }

    /// @notice The borrower secures a line by locking shares as it borrows: each draw locks shares worth what is owed
    ///         and pending over the loan-to-value, from its free shares, which keep earning. The borrower first approves
    ///         this contract as holder of the vault's shares. Excludes a pledge.
    function enableLocking(uint64 lineId) external nonReentrant {
        Line storage l = _lines[lineId];
        if (msg.sender != l.borrower) revert NotBorrower();
        if (address(l.collateralVault) == address(0) || l.pledgeId != bytes32(0)) revert InvalidPledge();
        locking[lineId] = true;
        emit LockingEnabled(lineId);
        _lock(lineId);
    }

    /// @notice Moves line `lineId`'s share lock to what is owed and pending at today's share price, as far as the borrower's
    ///         shares go, renewing its hold before it expires. Anyone may call it, such as a keeper after a price move.
    function relock(uint64 lineId) external nonReentrant {
        _lock(lineId);
    }

    /// @notice The lender sells just enough locked shares to bring a line past its loan-to-value back within it, at
    ///         today's price, and takes the proceeds toward what is owed.
    /// @return shares The shares sold.
    /// @return assets What the lender received.
    // Comparisons here are on share amounts the linter mistakes for timestamps.
    // forge-lint: disable-next-item(block-timestamp)
    function liquidate(uint64 lineId) external nonReentrant returns (uint128 shares, uint256 assets) {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender) revert NotLender();
        if (!locking[lineId]) revert InvalidPledge();
        _accrue(lineId, false);
        _lock(lineId);
        IEarnVault vault = l.collateralVault;
        uint256 locked = _lockedShares(lineId);
        uint256 value = locked == 0 ? 0 : _inLine(l, vault.previewRedeem(locked));
        uint256 used = uint256(l.owed) + l.pending;
        uint256 ltv = l.ltvBps;
        if (used * BPS <= value * ltv) revert NotUndercollateralized(used, value * ltv / BPS);
        // Selling x restores used - x = ltv * (value - x).
        uint256 sell = (used * BPS - value * ltv + (BPS - ltv) - 1) / (BPS - ltv);
        if (sell > l.owed) sell = l.owed;
        uint256 cover = vault.previewWithdraw(_assetsFor(l, sell));
        if (cover > locked) cover = locked;
        // Rounding can leave the ratio a few units short; sell one more share at a time until it holds (bounded).
        for (uint256 i; i < 16 && cover < locked && !_sound(l, used, locked, cover); ++i) {
            ++cover;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        shares = uint128(cover);
        bytes32 id = lockOf[lineId];
        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        CORE.capture(l.borrower, id, shares, false);
        assets = _redeemToLender(l, shares);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 credited = assets < l.owed ? uint128(assets) : l.owed;
        l.owed -= credited;
        _payStatements(lineId, credited);
        emit Liquidated(lineId, shares, assets, l.owed);
        _commit(lineId);
        _lock(lineId);
    }

    /// @dev Whether selling `sold` of `locked` shares leaves what is owed and pending within the loan-to-value of the rest.
    // Called in a loop of at most 16 steps, reading only the line's vault.
    // forge-lint: disable-next-item(calls-loop)
    function _sound(Line storage l, uint256 used, uint256 locked, uint256 sold) private view returns (bool) {
        IEarnVault vault = l.collateralVault;
        uint256 proceeds = _inLine(l, vault.previewRedeem(sold));
        if (proceeds > l.owed) proceeds = l.owed;
        return (used - proceeds) * BPS <= _inLine(l, vault.previewRedeem(locked - sold)) * l.ltvBps;
    }

    /// @notice The shares line `lineId`'s lock holds now.
    function lockedShares(uint64 lineId) external view returns (uint256) {
        return _lockedShares(lineId);
    }

    /// @notice Credit the line can still draw: its limit (at most the accepted debt bound), or for a secured line the
    ///         lower of that and the pledge's value times its loan-to-value, less what is owed and pending.
    function availableCredit(uint64 lineId) public view returns (uint256) {
        Line storage l = _lines[lineId];
        uint256 cap = l.limit < l.maxDebt ? l.limit : l.maxDebt;
        if (address(l.collateralVault) != address(0)) {
            uint256 secured = collateralValue(lineId) * l.ltvBps / BPS;
            if (secured < cap) cap = secured;
        }
        uint256 used = uint256(l.owed) + l.pending;
        if (cap <= used) return 0;
        // A draw can only take what the lender's balance backs: its free cash plus the commitment.
        uint256 backed = CORE.available(l.lender, l.token) + _committed(lineId);
        uint256 credit = cap - used;
        // The commitment counts only until its hold expires, a timestamp by design.
        // forge-lint: disable-next-line(block-timestamp)
        return credit < backed ? credit : backed;
    }

    /// @notice What line `lineId`'s commitment hold reserves of the lender's balance now.
    function committed(uint64 lineId) external view returns (uint256) {
        return _committed(lineId);
    }

    /// @notice The lender and token of line `lineId`.
    function partiesOf(uint64 lineId) external view returns (address lender, address token) {
        Line storage l = _lines[lineId];
        return (l.lender, l.token);
    }

    /// @notice What the line's pledge is worth now in its token, zero when it is gone or would expire before the
    ///         line may seize it.
    // forge-lint: disable-next-item(block-timestamp)
    function collateralValue(uint64 lineId) public view returns (uint256) {
        Line storage l = _lines[lineId];
        if (locking[lineId]) {
            // The shares locked so far and the borrower's free shares, which the next draw can lock.
            uint256 shares = _lockedShares(lineId) + CORE.available(l.borrower, l.collateralVault.earnShare());
            return shares == 0 ? 0 : _inLine(l, l.collateralVault.previewRedeem(shares));
        }
        if (l.pledgeId == bytes32(0)) return 0;
        (address owner,, uint128 shares, uint64 expiresAt,) = CORE.lienOf(address(this), l.pledgeId);
        if (owner != l.borrower || shares == 0 || expiresAt <= uint256(l.dueDate) + l.noticePeriod) return 0;
        return _inLine(l, l.collateralVault.previewRedeem(shares));
    }

    /// @notice A line `program` draws on is open in its settlement token while its borrower has accepted it and it has
    ///         a limit, a balance owed or a live hold, so the program's token waits for it to close (reason 7, open
    ///         credit lines). A line its borrower never accepted does not count.
    function settlementTokenInUse(address program) external view returns (uint8) {
        return _activeLines[program][IProgramSettlementToken(program).settlementToken()] != 0 ? 7 : 0;
    }

    /// @notice A line's terms and state.
    function lineOf(uint64 lineId) external view returns (Line memory) {
        return _lines[lineId];
    }

    /// @notice The token a line lends.
    function tokenOf(uint64 lineId) external view returns (address) {
        return _lines[lineId].token;
    }

    /// @notice The lender whose balance a draw holds, and the token.
    function drawOf(bytes32 holdId) external view returns (address lender, address token) {
        Line storage l = _lines[draws[holdId].lineId];
        return (l.lender, l.token);
    }

    /// @notice The hold id of `program`'s draw for its purchase `ref`, on the lender's account.
    function holdIdOf(address program, bytes32 ref) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), program, ref));
    }

    /// @dev Records offered terms, defaulting the debt bound to the limit plus a year of interest on it.
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

    /// @dev Interest line `l` has earned since it last accrued, within its debt bound, and whether that bound capped it.
    // Interest runs on timestamps by design; a few seconds of validator skew changes it by a few seconds of interest.
    // forge-lint: disable-next-item(block-timestamp)
    function _interest(Line storage l) private view returns (uint256 interest, bool capped) {
        uint256 owed = l.owed;
        if (!l.accepted || owed == 0 || l.aprBps == 0 || block.timestamp <= l.lastAccrued) return (0, false);
        interest = owed * l.aprBps * (block.timestamp - l.lastAccrued) / (YEAR * BPS);
        uint256 used = owed + l.pending;
        uint256 room = l.maxDebt > used ? l.maxDebt - used : 0;
        if (interest >= room) (interest, capped) = (room, true);
    }

    /// @dev Adds the interest earned since the line last accrued. With `carry`, what is owed stays the same afterwards,
    ///      so time too short to earn a whole unit carries to the next accrual; otherwise the clock restarts now, as
    ///      what is owed is about to change.
    // forge-lint: disable-next-item(block-timestamp,unsafe-typecast)
    function _accrue(uint64 lineId, bool carry) private {
        Line storage l = _lines[lineId];
        if (!l.accepted) return;
        (uint256 interest, bool capped) = _interest(l);
        uint256 owed = l.owed;
        uint64 last = uint64(block.timestamp);
        if (carry && !capped && owed != 0 && l.aprBps != 0) {
            // The time the interest paid for, rounded up so the borrower never pays twice for the same second.
            uint256 rate = owed * l.aprBps;
            last = uint64(l.lastAccrued + (interest * YEAR * BPS + rate - 1) / rate);
        }
        l.lastAccrued = last;
        if (interest == 0) return;
        l.owed = uint128(owed + interest);
        emit InterestAccrued(lineId, l.aprBps, uint128(interest), l.owed);
    }

    // _commit runs only inside nonReentrant entry points, against the fixed core; holds expire by timestamp by design,
    // and every amount it casts is bounded by a 128-bit line limit.
    // forge-lint: disable-start(reentrancy-no-eth)
    // forge-lint: disable-start(block-timestamp)
    // forge-lint: disable-start(unsafe-typecast)
    /// @dev Moves the commitment hold to the line's undrawn limit (what is neither owed nor pending), within what the
    ///      lender's balance backs. A closed, unaccepted or past-due line commits nothing.
    function _commit(uint64 lineId) private {
        _track(lineId);
        Line storage l = _lines[lineId];
        bytes32 id = commitmentOf[lineId];
        IReservationCore.HoldRecord memory h;
        bool live;
        if (id != bytes32(0)) {
            h = CORE.getHold(l.lender, id);
            // Expiries are timestamps by design; a few seconds of validator skew does not change them.
            // forge-lint: disable-next-line(block-timestamp)
            live = !h.settled && h.token != address(0) && h.expiresAt > block.timestamp;
        }
        uint256 target;
        // forge-lint: disable-next-line(block-timestamp)
        if (l.accepted && !l.closed && block.timestamp < l.dueDate) {
            uint256 used = uint256(l.owed) + l.pending;
            uint256 cap = l.limit < l.maxDebt ? l.limit : l.maxDebt;
            target = cap > used ? cap - used : 0;
            uint256 backed = CORE.available(l.lender, l.token) + (live ? h.held : 0);
            if (target > backed) target = backed;
        }
        // forge-lint: disable-next-line(block-timestamp)
        uint64 expiresAt = uint64(block.timestamp + COMMITMENT_TERM);
        if (expiresAt > l.dueDate) expiresAt = l.dueDate;
        // Renew a live hold that would lapse within a day; otherwise adjust it in place.
        // forge-lint: disable-next-line(block-timestamp)
        bool renew = live && h.expiresAt < block.timestamp + 1 days && expiresAt > h.expiresAt;
        if (live && !renew) {
            if (target == h.held) return;
            if (target == 0) {
                CORE.release(l.lender, id);
            } else if (target < h.held) {
                // forge-lint: disable-next-line(unsafe-typecast)
                CORE.adjust(l.lender, id, uint128(target));
            } else {
                // Growing the commitment is best effort: a lender who lowered or revoked this contract's allowance
                // keeps what is committed, and draws and repayments still settle.
                // forge-lint: disable-next-line(unsafe-typecast)
                try CORE.adjust(l.lender, id, uint128(target)) { }
                catch {
                    return;
                }
            }
        } else {
            if (live) CORE.release(l.lender, id);
            else if (id != bytes32(0) && !h.settled && h.token != address(0)) CORE.releaseExpired(l.lender, id);
            if (target == 0) {
                if (id != bytes32(0)) commitmentOf[lineId] = bytes32(0);
                emit Committed(lineId, bytes32(0), 0);
                return;
            }
            id = keccak256(abi.encode(address(this), "commitment", lineId, ++_commitments[lineId]));
            // Placing a commitment is best effort too, for the same reason.
            try CORE.holdFrom(
                l.lender,
                IReservationCore.HoldRequest({
                    // forge-lint: disable-next-line(unsafe-typecast)
                    token: l.token,
                    id: id,
                    amount: uint128(target),
                    expiresAt: expiresAt,
                    payee: address(this),
                    standIn: false
                })
            ) {
                commitmentOf[lineId] = id;
            } catch {
                commitmentOf[lineId] = bytes32(0);
                emit Committed(lineId, bytes32(0), 0);
                return;
            }
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Committed(lineId, id, uint128(target));
    }

    /// @dev Counts line `lineId` among its program's active lines in its token while it is accepted, open and has a
    ///      limit, a balance owed or a live hold. Every change to those runs through here.
    function _track(uint64 lineId) private {
        Line storage l = _lines[lineId];
        bool active = l.accepted && !l.closed && (l.limit != 0 || l.owed != 0 || l.pending != 0);
        if (active == _active[lineId]) return;
        _active[lineId] = active;
        if (active) ++_activeLines[l.program][l.token];
        else --_activeLines[l.program][l.token];
    }

    /// @dev Moves the share lock to the shares worth what is owed and pending over the loan-to-value, at most what the
    ///      borrower holds. Growth reverts if the borrower revoked this contract's allowance, so a draw it cannot secure
    ///      fails.
    function _lock(uint64 lineId) private {
        if (!locking[lineId]) return;
        Line storage l = _lines[lineId];
        IEarnVault vault = l.collateralVault;
        address share = vault.earnShare();
        bytes32 id = lockOf[lineId];
        IReservationCore.HoldRecord memory h;
        bool live;
        if (id != bytes32(0)) {
            h = CORE.getHold(l.borrower, id);
            live = !h.settled && h.token != address(0) && h.expiresAt > block.timestamp;
        }
        uint256 used = uint256(l.owed) + l.pending;
        // Locks only for what the borrower agreed to owe, at the loan-to-value it accepted.
        if (used > l.maxDebt) used = l.maxDebt;
        uint256 target = used == 0 ? 0 : vault.previewWithdraw(_assetsFor(l, (used * BPS + l.ltvBps - 1) / l.ltvBps));
        uint256 have = CORE.available(l.borrower, share) + (live ? h.held : 0);
        if (target > have) target = have;
        uint64 expiresAt = uint64(block.timestamp + COMMITMENT_TERM);
        bool renew = live && h.expiresAt < block.timestamp + 1 days;
        if (live && !renew) {
            if (target == h.held) return;
            if (target == 0) CORE.release(l.borrower, id);
            else CORE.adjust(l.borrower, id, uint128(target));
        } else {
            if (live) CORE.release(l.borrower, id);
            else if (id != bytes32(0) && !h.settled && h.token != address(0)) CORE.releaseExpired(l.borrower, id);
            id = bytes32(0);
            if (target != 0) {
                id = keccak256(abi.encode(address(this), "lock", lineId, ++_locks[lineId]));
                CORE.holdFrom(
                    l.borrower,
                    IReservationCore.HoldRequest({
                        token: share,
                        id: id,
                        amount: uint128(target),
                        expiresAt: expiresAt,
                        payee: address(this),
                        standIn: false
                    })
                );
            }
            lockOf[lineId] = id;
        }
        emit Locked(lineId, id, uint128(target));
    }

    function _lockedShares(uint64 lineId) private view returns (uint256) {
        bytes32 id = lockOf[lineId];
        if (id == bytes32(0)) return 0;
        IReservationCore.HoldRecord memory h = CORE.getHold(_lines[lineId].borrower, id);
        return h.settled || h.expiresAt <= block.timestamp ? 0 : h.held;
    }

    function _committed(uint64 lineId) private view returns (uint256) {
        bytes32 id = commitmentOf[lineId];
        if (id == bytes32(0)) return 0;
        IReservationCore.HoldRecord memory h = CORE.getHold(_lines[lineId].lender, id);
        // forge-lint: disable-next-line(block-timestamp)
        return h.settled || h.expiresAt <= block.timestamp ? 0 : h.held;
    }
    // forge-lint: disable-end(unsafe-typecast)
    // forge-lint: disable-end(block-timestamp)
    // forge-lint: disable-end(reentrancy-no-eth)
}
