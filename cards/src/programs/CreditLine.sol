// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";

/// @title CreditLine
/// @notice Lenders' credit lines that card programs draw on. Each draw is a hold on the lender's own balance, placed
///         here through `holdFrom` (the lender approves this contract as a holder of the line's token), so every
///         approved line part is backed by funds the lender has reserved. The line's program is the hold's payee
///         and captures it; the borrower owes what was captured, net of refunds, until repaid. A secured line also
///         caps credit at the value of Earn shares the borrower pledged to this contract on the core, times its
///         loan-to-value, and may seize the pledge for what is owed once the due date and notice period have passed.
///         Specified in docs/cards/design.md (Card programs).
/// @dev Owed and pending amounts follow the core's records: `sync` reads a draw's hold and applies what changed,
///      whoever captured, released or refunded it. Interest, fees and collection beyond the pledge are the issuer's
///      and lender's services, not this contract's.
contract CreditLine {
    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint256 private constant BPS = 10_000;
    /// @dev How long one commitment hold lasts; the core caps holds at 31 days.
    uint256 private constant COMMITMENT_TERM = 30 days;

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
    }

    /// @dev What `sync` last read from a draw's hold.
    struct Draw {
        uint64 lineId;
        uint96 held;
        uint96 net;
    }

    uint64 public lineCount;
    mapping(uint64 lineId => Line) internal _lines;
    mapping(bytes32 holdId => Draw) public draws;
    /// @notice The open line each lender has for each borrower, if any.
    mapping(address lender => mapping(address borrower => uint64 lineId)) public lineIdOf;
    /// @notice The hold that commits a line's undrawn limit on the lender's balance, and how many it has had.
    mapping(uint64 lineId => bytes32 holdId) public commitmentOf;
    mapping(uint64 lineId => uint64) internal _commitments;

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
    event LineAccepted(uint64 indexed lineId);
    event LineClosed(uint64 indexed lineId);
    event LimitSet(uint64 indexed lineId, uint128 limit);
    event Drawn(uint64 indexed lineId, bytes32 indexed holdId, bytes32 ref, uint128 amount, uint64 expiresAt);
    event Synced(uint64 indexed lineId, bytes32 indexed holdId, uint128 owed, uint128 pending);
    event Repaid(uint64 indexed lineId, address indexed payer, uint128 amount, uint128 owed);
    event Charged(uint64 indexed lineId, uint128 amount, uint128 owed);
    event Committed(uint64 indexed lineId, bytes32 holdId, uint128 amount);
    event PledgeAttached(uint64 indexed lineId, bytes32 pledgeId, uint128 shares, uint64 expiresAt);
    event PledgeReleased(uint64 indexed lineId, bytes32 pledgeId);
    event Seized(uint64 indexed lineId, bytes32 pledgeId, uint128 shares, uint256 assets, uint128 owed);

    error CreditExceeded(uint256 amount, uint256 available);
    error InvalidLine();
    error InvalidPledge();
    error LineNotOpen();
    error NotBorrower();
    error NotLender();
    error NotPastDue();
    error NotProgram();
    error NothingOwed();
    error PledgeInPlace();
    error Reentrancy();
    error RepayExceedsOwed(uint256 amount, uint256 owed);
    error StillOwed();
    error UnknownDraw();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /// @notice Opens a line from the caller (the lender) to `borrower`, drawn on by `program` only. The
    ///         borrower must accept it before any draw. `collateralVault` zero makes it unsecured.
    function openLine(
        address borrower,
        address token,
        address program,
        uint128 limit,
        uint64 dueDate,
        uint32 noticePeriod,
        IEarnVault collateralVault,
        uint16 ltvBps
    ) external returns (uint64 lineId) {
        if (borrower == address(0) || token == address(0) || program == address(0)) revert InvalidLine();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (dueDate <= block.timestamp) revert InvalidLine();
        if (address(collateralVault) == address(0)) {
            if (ltvBps != 0) revert InvalidLine();
        } else if (ltvBps == 0 || ltvBps > BPS || collateralVault.asset() != token) {
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
    }

    /// @notice The borrower agrees to owe what the line's program draws.
    function acceptLine(uint64 lineId) external {
        Line storage l = _lines[lineId];
        if (msg.sender != l.borrower) revert NotBorrower();
        l.accepted = true;
        emit LineAccepted(lineId);
        _commit(lineId);
    }

    /// @notice The lender sets the line's limit; draws already placed stay.
    function setLimit(uint64 lineId, uint128 limit) external {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender) revert NotLender();
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
        IReservationCore.HoldRecord memory h = CORE.getHold(l.lender, holdId);
        uint128 held = h.held;
        uint128 net = h.captured - h.refunded;
        // Pending holds only shrink after placement: captures and releases free them.
        l.pending = l.pending + held - d.held;
        if (net >= d.net) {
            l.owed += net - d.net;
        } else {
            uint128 back = d.net - net;
            l.owed = back < l.owed ? l.owed - back : 0;
        }
        // Both are at most the draw's amount, which fits in 96 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        (d.held, d.net) = (uint96(held), uint96(net));
        emit Synced(lineId, holdId, l.owed, l.pending);
        _commit(lineId);
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
        emit Synced(lineId, holdId, l.owed, l.pending);
    }

    /// @notice Adds `amount` to what the borrower owes, as the lender (interest, or a re-drawn disputed purchase). It
    ///         comes out of the line's undrawn limit like a draw.
    function charge(uint64 lineId, uint128 amount) external nonReentrant {
        Line storage l = _lines[lineId];
        if (msg.sender != l.lender) revert NotLender();
        l.owed += amount;
        emit Charged(lineId, amount, l.owed);
        _commit(lineId);
    }

    /// @notice Recommits line `lineId`'s undrawn limit on the lender's balance, renewing its hold before it expires.
    ///         Anyone may call it.
    function recommit(uint64 lineId) external nonReentrant {
        _commit(lineId);
    }

    /// @notice Repays `amount` of what the borrower owes, from the caller to the lender.
    function repay(uint64 lineId, uint128 amount) external nonReentrant {
        Line storage l = _lines[lineId];
        if (amount == 0 || amount > l.owed) revert RepayExceedsOwed(amount, l.owed);
        l.owed -= amount;
        SafeTransferLib.safeTransferFrom(l.token, msg.sender, l.lender, amount);
        emit Repaid(lineId, msg.sender, amount, l.owed);
        _commit(lineId);
    }

    /// @notice The borrower attaches a pledge it placed on the core with this contract as authority: the line's
    ///         collateral share, expiring after the due date and notice period. Replaces only a pledge that is gone.
    function attachPledge(uint64 lineId, bytes32 pledgeId) external {
        Line storage l = _lines[lineId];
        if (msg.sender != l.borrower) revert NotBorrower();
        IEarnVault vault = l.collateralVault;
        if (address(vault) == address(0)) revert InvalidPledge();
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
        uint128 owed = l.owed;
        if (owed == 0) revert NothingOwed();
        bytes32 pledgeId = l.pledgeId;
        if (pledgeId == bytes32(0)) revert InvalidPledge();
        (,, uint128 pledgedShares,,) = CORE.lienOf(address(this), pledgeId);
        IEarnVault vault = l.collateralVault;
        uint256 cover = vault.previewWithdraw(owed);
        // forge-lint: disable-next-line(unsafe-typecast)
        shares = cover < pledgedShares ? uint128(cover) : pledgedShares;
        if (shares == 0) revert InvalidPledge();

        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        CORE.seizeLien(pledgeId, shares);
        address share = vault.earnShare();
        SafeTransferLib.safeApprove(share, address(vault), shares);
        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        assets = vault.redeem(shares, l.lender, vault.previewRedeem(shares));
        // Rounding may return a little more than owed; the debt never goes below zero.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 credited = assets < owed ? uint128(assets) : owed;
        l.owed = owed - credited;
        emit Seized(lineId, pledgeId, shares, assets, l.owed);
    }

    /// @notice Credit the line can still draw: its limit, or for a secured line the lower of the limit and the
    ///         pledge's value times its loan-to-value, less what is owed and pending.
    function availableCredit(uint64 lineId) public view returns (uint256) {
        Line storage l = _lines[lineId];
        uint256 cap = l.limit;
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
    function collateralValue(uint64 lineId) public view returns (uint256) {
        Line storage l = _lines[lineId];
        if (l.pledgeId == bytes32(0)) return 0;
        (address owner,, uint128 shares, uint64 expiresAt,) = CORE.lienOf(address(this), l.pledgeId);
        if (owner != l.borrower || shares == 0 || expiresAt <= uint256(l.dueDate) + l.noticePeriod) return 0;
        return l.collateralVault.previewRedeem(shares);
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

    // _commit runs only inside nonReentrant entry points, against the fixed core; holds expire by timestamp by design,
    // and every amount it casts is bounded by a 128-bit line limit.
    // forge-lint: disable-start(reentrancy-no-eth)
    // forge-lint: disable-start(block-timestamp)
    // forge-lint: disable-start(unsafe-typecast)
    /// @dev Moves the commitment hold to the line's undrawn limit (what is neither owed nor pending), within what the
    ///      lender's balance backs. A closed, unaccepted or past-due line commits nothing.
    function _commit(uint64 lineId) private {
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
            target = l.limit > used ? l.limit - used : 0;
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
