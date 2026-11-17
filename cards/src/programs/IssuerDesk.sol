// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Allowance } from "tempo-earn/interfaces/external/IERC20Allowance.sol";

import { CardFunding } from "./CardFunding.sol";
import { CardProgram } from "./CardProgram.sol";
import { Conversion } from "./Conversion.sol";
import { SavingsFacility } from "./SavingsFacility.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { ISettlementTokenGuard } from "./interfaces/ISettlementTokenGuard.sol";

/// @title IssuerDesk
/// @notice An issuer's services over its CardProgram, kept off the card program and the reservation core: the
///         program's split schedule (terms) paid to named parties out of every capture, rewards paid to cardholders
///         out of a party's split, refunds that take back each split and reward in proportion, and corrections of
///         processor errors linked to the step they fix. Every step emits one self-describing event, so the
///         issuer's books rebuild from logs.
/// @dev The issuer makes the desk an operator of its program, and the program's settlement account approves the
///      desk for the settlement token: captures land in the settlement account and the desk pays each split from
///      there in the same call. A split payee approves the desk as a holder on the core with a debt cap for the
///      settlement account, so a refund takes its share back from what it has available and leaves the rest as
///      capped debt. A cardholder approves the desk as a holder so a refund can take back a reward from money it
///      still has, never as debt. Amounts are in units of the program's settlement token.
contract IssuerDesk is ISettlementTokenGuard {
    using FixedPointMathLib for uint256;

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint256 private constant BPS = 10_000;
    uint256 private constant RATE_ONE = 1e18;
    /// @dev Converted legs each round what they take up by a unit, at most one per funding source.
    uint256 private constant LEG_ROUNDING = 8;

    /// @notice Dispute states, in the order a dispute moves through them; a dispute ends won or lost.
    uint8 public constant OPENED = 1;
    uint8 public constant PROVISIONAL_CREDIT = 2;
    uint8 public constant ARBITRATION = 5;
    uint8 public constant WON = 6;
    uint8 public constant LOST = 7;

    /// @notice Step kinds a correction can fix.
    uint8 public constant CAPTURE = 1;
    uint8 public constant REFUND = 2;

    /// @notice A terms line: bps of every capture paid to payee, labelled kind.
    struct Line {
        address payee;
        uint16 bps;
        bytes32 kind;
    }

    /// @notice A reward: bps of every capture paid to the cardholder out of funder's split, labelled kind.
    struct Reward {
        address funder;
        uint16 bps;
        bytes32 kind;
    }

    /// @notice What one purchase paid one party: a split (funder zero) or a reward paid to the owner by funder.
    struct Split {
        address payee;
        address funder;
        bytes32 kind;
        uint128 amount;
        uint128 reversed;
    }

    /// @notice What a purchase captured and refunded through the desk, the base of every split's reversal.
    struct Book {
        uint128 captured;
        uint128 refunded;
    }

    /// @notice A capture or refund the desk made, by the program's ledger sequence number.
    struct Step {
        bytes32 purchaseRef;
        uint8 kind;
        uint128 amount;
        uint128 corrected;
    }

    /// @notice A dispute on a purchase: the disputed amount and the provisional credit given so far.
    struct Dispute {
        address owner;
        uint8 state;
        uint128 amount;
        uint128 provisional;
    }

    CardProgram public immutable PROGRAM;
    address public immutable ISSUER;
    address public immutable TOKEN;
    address public immutable SETTLEMENT;

    Line[] internal _terms;
    Reward[] internal _rewards;
    mapping(bytes32 purchaseRef => Book) public books;
    mapping(bytes32 purchaseRef => Split[]) internal _splits;
    mapping(uint64 seq => Step) public steps;
    mapping(bytes32 purchaseRef => Dispute) public disputes;
    /// @notice What the issuer collected from merchant reserves toward an open dispute.
    mapping(bytes32 purchaseRef => uint128) public reserveCollected;
    /// @notice Disputes opened and not yet resolved, which keep the program on its settlement token.
    uint64 public openDisputes;
    uint64 internal _nonce;
    bool internal _locked;
    bytes32[] internal _disputed;
    address[] internal _debtors;
    mapping(address owner => bool) internal _isDebtor;

    event TermsSet(Line[] lines);
    event RewardsSet(Reward[] rewards);
    event FeePaid(bytes32 indexed purchaseRef, address indexed payee, bytes32 kind, uint128 amount);
    event FeeReversed(bytes32 indexed purchaseRef, address indexed payee, bytes32 kind, uint128 amount, uint128 debt);
    event RewardPaid(
        bytes32 indexed purchaseRef, address indexed account, address indexed funder, bytes32 kind, uint128 amount
    );
    event RewardReversed(
        bytes32 indexed purchaseRef, address indexed account, address indexed funder, bytes32 kind, uint128 amount
    );
    event DisputeOpened(bytes32 indexed purchaseRef, address indexed account, uint128 amount, bytes evidence);
    event ReserveCollectedFor(bytes32 indexed purchaseRef, uint128 amount);
    event DisputeStepped(
        bytes32 indexed purchaseRef,
        address indexed account,
        uint8 state,
        uint128 provisional,
        uint128 repaid,
        bytes evidence,
        bool byMerchant
    );
    event DisputeResolved(
        bytes32 indexed purchaseRef,
        address indexed account,
        bool won,
        int256 amount,
        uint128 debt,
        uint128 repaid,
        uint128 chargeback
    );
    event Corrected(bytes32 indexed purchaseRef, uint64 indexed target, int128 amount, string reason);
    /// @notice A refund or correction past what the purchase still nets settled `amount` of provisional credit, which
    ///         the cardholder already holds, instead of paying it again.
    event DisputeSettled(bytes32 indexed purchaseRef, address indexed account, uint128 amount);
    /// @notice A lost dispute took `amount` (settlement units) back from one funding source, in the funding order's
    ///         terms: kind 1 cash, 2 a savings facility, 4 a credit line re-drawn.
    event DisputeRecovered(
        bytes32 indexed purchaseRef, address indexed account, uint8 kind, address source, uint64 lineId, uint256 amount
    );

    error NotIssuer();
    error ZeroAddress();
    error InvalidTerms();
    error InvalidRewards();
    error NotCorrectable();
    error CorrectionTooLarge();
    error Reentrancy();
    error DisputeExists();
    error NoDispute();
    error InvalidDisputeStep();
    error DisputeTooLarge();
    error RefundTooLarge();

    modifier onlyIssuer() {
        _onlyIssuer();
        _;
    }

    modifier onlyOperator() {
        _onlyOperator();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(CardProgram program) {
        if (address(program) == address(0)) revert ZeroAddress();
        PROGRAM = program;
        ISSUER = program.ISSUER();
        TOKEN = program.SETTLEMENT_TOKEN();
        SETTLEMENT = program.SETTLEMENT_ACCOUNT();
    }

    // Every entry point that moves money holds the lock for its whole call; the program and the core it calls are
    // fixed.
    // forge-lint: disable-start(reentrancy-no-eth)

    /// @notice Replaces the split schedule. Splits never add up to the whole capture.
    function setTerms(Line[] calldata lines) external onlyIssuer {
        uint256 total;
        delete _terms;
        for (uint256 i; i < lines.length; ++i) {
            if (lines[i].payee == address(0) || lines[i].bps == 0) revert InvalidTerms();
            total += lines[i].bps;
            _terms.push(lines[i]);
        }
        if (total >= BPS) revert InvalidTerms();
        emit TermsSet(lines);
    }

    /// @notice Replaces the rewards. A funder pays rewards only out of its own split, so its rewards never add up to
    ///         more basis points than its terms lines.
    function setRewards(Reward[] calldata rewards_) external onlyIssuer {
        delete _rewards;
        for (uint256 i; i < rewards_.length; ++i) {
            address funder = rewards_[i].funder;
            uint256 asked;
            for (uint256 j; j < rewards_.length; ++j) {
                if (rewards_[j].funder == funder) asked += rewards_[j].bps;
            }
            if (funder == address(0) || rewards_[i].bps == 0 || asked > _shareOf(funder)) revert InvalidRewards();
            _rewards.push(rewards_[i]);
        }
        emit RewardsSet(rewards_);
    }

    /// @notice Captures through the program and pays each split and reward from the settlement account.
    function capture(bytes32 purchaseRef, uint128 amount, bool isFinal) external nonReentrant onlyOperator {
        PROGRAM.capture(purchaseRef, amount, isFinal);
        _step(purchaseRef, CAPTURE, amount);
        if (amount != 0) _charged(purchaseRef, amount);
    }

    /// @notice Refunds through the program from the settlement account, then takes back each split's and reward's
    ///         share of the refund.
    function refund(bytes32 purchaseRef, uint128 amount) external nonReentrant onlyOperator {
        Book storage b = books[purchaseRef];
        // A won dispute counts as a refund of the purchase, so nothing it credited refunds again.
        if (disputes[purchaseRef].state == WON && amount > b.captured - b.refunded) revert RefundTooLarge();
        _refundSettling(purchaseRef, amount);
        _step(purchaseRef, REFUND, amount);
        _reverse(purchaseRef, amount);
    }

    /// @notice An open dispute is sized in the program's settlement token, so the token waits for it to resolve.
    function settlementTokenInUse(address) external view returns (uint8) {
        return openDisputes != 0 ? 4 : 0;
    }

    /// @notice Opens a dispute on a captured purchase, for at most what it captured and has not refunded.
    function openDispute(bytes32 purchaseRef, uint128 amount, bytes calldata evidence)
        external
        nonReentrant
        onlyOperator
    {
        Book storage b = books[purchaseRef];
        if (disputes[purchaseRef].state != 0) revert DisputeExists();
        if (amount == 0 || amount > b.captured - b.refunded) revert DisputeTooLarge();
        address owner = PROGRAM.purchaseOf(purchaseRef).owner;
        disputes[purchaseRef] = Dispute({ owner: owner, state: OPENED, amount: amount, provisional: 0 });
        _disputed.push(purchaseRef);
        ++openDisputes;
        emit DisputeOpened(purchaseRef, owner, amount, evidence);
    }

    /// @notice Moves a dispute forward, attaching evidence and giving provisional credit from the settlement account.
    ///         Refunds and provisional credit together never return more than the purchase, nor provisional credit
    ///         more than the dispute. Credit the cardholder receives repays its debt first.
    function disputeStep(
        bytes32 purchaseRef,
        uint8 state,
        uint128 provisional,
        bytes calldata evidence,
        bool byMerchant
    ) external nonReentrant onlyOperator {
        Dispute storage d = disputes[purchaseRef];
        if (d.state == 0 || d.state >= WON) revert NoDispute();
        if (state <= d.state || state < PROVISIONAL_CREDIT || state > ARBITRATION) revert InvalidDisputeStep();
        Book storage b = books[purchaseRef];
        uint128 open = b.captured - b.refunded;
        uint128 cap = d.amount < open ? d.amount : open;
        if (provisional > 0 && d.provisional + provisional > cap) revert DisputeTooLarge();
        d.state = state;
        uint128 repaid;
        if (provisional > 0) {
            d.provisional += provisional;
            repaid = _credit(d.owner, provisional);
        }
        emit DisputeStepped(purchaseRef, d.owner, state, provisional, repaid, evidence, byMerchant);
    }

    /// @notice Ends a dispute. A merchant win takes the provisional credit back at once from what the cardholder has,
    ///         the rest as debt to the settlement account within its cap. A cardholder win counts as a refund of
    ///         what is still unrefunded: the program refunds what the provisional credit did not cover, every split
    ///         comes back in proportion, and the whole credited amount is charged back to the network.
    function resolveDispute(bytes32 purchaseRef, bool cardholderWins) external nonReentrant onlyOperator {
        Dispute storage d = disputes[purchaseRef];
        if (d.state == 0 || d.state >= WON) revert NoDispute();
        address owner = d.owner;
        uint128 provisional = d.provisional;
        --openDisputes;
        if (!cardholderWins) {
            d.state = LOST;
            uint256 debt = provisional > 0 ? _recover(purchaseRef, owner, provisional) : 0;
            // Below provisional, a uint128.
            // forge-lint: disable-next-line(unsafe-typecast)
            emit DisputeResolved(purchaseRef, owner, false, -int256(uint256(provisional)), uint128(debt), 0, 0);
            return;
        }
        d.state = WON;
        (uint128 credited, uint128 rest) = _won(purchaseRef);
        // What the issuer collected from merchant reserves is no longer the network's to charge back.
        uint128 collected = reserveCollected[purchaseRef];
        uint128 chargeback = credited > collected ? credited - collected : 0;
        uint128 repaid;
        if (rest > 0) {
            (, uint128 before) = CORE.debtOf(owner, TOKEN);
            _refund(purchaseRef, rest);
            (, uint128 later) = CORE.debtOf(owner, TOKEN);
            repaid = before > later ? before - later : 0;
        }
        // The provisional credit the cardholder keeps counts as refunded too: it frees the mandate's usage and leaves
        // the network's side of the chargeback the refund above did not already cover.
        uint128 kept = credited - rest;
        uint128 net = chargeback > rest ? chargeback - rest : 0;
        if (kept != 0 || net != 0) PROGRAM.creditBack(purchaseRef, kept, net);
        _reverse(purchaseRef, credited);
        emit DisputeResolved(purchaseRef, owner, true, int256(uint256(rest)), 0, repaid, chargeback);
    }

    /// @notice Records what the issuer collected from merchant reserves toward an open dispute, which a cardholder win
    ///         then leaves out of the chargeback.
    function collectedReserve(bytes32 purchaseRef, uint128 amount) external onlyOperator {
        Dispute storage d = disputes[purchaseRef];
        if (d.state == 0 || d.state >= WON) revert NoDispute();
        reserveCollected[purchaseRef] += amount;
        emit ReserveCollectedFor(purchaseRef, amount);
    }

    /// @notice Corrects a processor error on the capture or refund the program logged as target, by an amount
    ///         signed toward the cardholder. Toward the cardholder it comes back like a refund; against it, it is
    ///         charged like a capture, splits and rewards included. Corrections to one step never add up to more
    ///         than the step moved.
    function correct(bytes32 purchaseRef, uint64 target, int128 amount, string calldata reason)
        external
        nonReentrant
        onlyOperator
    {
        Step storage s = steps[target];
        if (s.kind == 0 || s.purchaseRef != purchaseRef) revert NotCorrectable();
        // A negated int128 fits in uint128 for every value but the minimum, which no step can move.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 size = amount < 0 ? uint128(-amount) : uint128(amount);
        if (size == 0 || s.corrected + size > s.amount) revert CorrectionTooLarge();
        s.corrected += size;
        if (amount > 0) {
            Book storage b = books[purchaseRef];
            if (size > b.captured - b.refunded) revert CorrectionTooLarge();
            _refundSettling(purchaseRef, size);
            _reverse(purchaseRef, size);
        } else {
            PROGRAM.charge(PROGRAM.purchaseOf(purchaseRef).card, purchaseRef, size, address(0));
            _charged(purchaseRef, size);
        }
        emit Corrected(purchaseRef, target, amount, reason);
    }

    /// @notice The split schedule.
    function terms() external view returns (Line[] memory) {
        return _terms;
    }

    /// @notice The rewards.
    function rewards() external view returns (Reward[] memory) {
        return _rewards;
    }

    /// @notice What one purchase paid each party, and how much of it was taken back.
    function splitsOf(bytes32 purchaseRef) external view returns (Split[] memory) {
        return _splits[purchaseRef];
    }

    /// @notice What a cardholder win would refund from the settlement account now: the credited amount past what
    ///         provisional credit already paid.
    function winRefund(bytes32 purchaseRef) external view returns (uint128 rest) {
        (, rest) = _won(purchaseRef);
    }

    /// @notice What open disputes risk (each at most what its purchase still nets) and the capped debt lost disputes
    ///         left owed to the settlement account, in settlement units.
    function exposure() external view returns (uint256 disputed, uint256 debt) {
        for (uint256 i; i < _disputed.length; ++i) {
            bytes32 ref = _disputed[i];
            Dispute storage d = disputes[ref];
            if (d.state >= WON) continue;
            Book storage b = books[ref];
            uint128 open = b.captured - b.refunded;
            disputed += d.amount < open ? d.amount : open;
        }
        for (uint256 i; i < _debtors.length; ++i) {
            // A view over the core's debt records, one read per owner a lost dispute left in debt.
            // forge-lint: disable-next-line(calls-loop)
            (address creditor, uint128 owed) = CORE.debtOf(_debtors[i], TOKEN);
            if (creditor == SETTLEMENT) debt += owed;
        }
    }

    function _onlyIssuer() private view {
        if (msg.sender != ISSUER) revert NotIssuer();
    }

    function _onlyOperator() private view {
        if (msg.sender != ISSUER && !PROGRAM.operators(msg.sender)) revert NotIssuer();
    }

    function _shareOf(address payee) private view returns (uint256 share) {
        for (uint256 i; i < _terms.length; ++i) {
            if (_terms[i].payee == payee) share += _terms[i].bps;
        }
    }

    // Pays the owner from the settlement account, which approved the desk; incoming credit repays its debt first.
    // forge-lint: disable-next-item(arbitrary-send-erc20)
    function _credit(address owner, uint128 amount) private returns (uint128 repaid) {
        (, uint128 before) = CORE.debtOf(owner, TOKEN);
        SafeTransferLib.safeTransferFrom(TOKEN, SETTLEMENT, owner, amount);
        (, uint128 later) = CORE.debtOf(owner, TOKEN);
        repaid = before > later ? before - later : 0;
    }

    function _step(bytes32 purchaseRef, uint8 kind, uint128 amount) private {
        (uint64 seq,,,) = PROGRAM.ledger();
        steps[seq] = Step({ purchaseRef: purchaseRef, kind: kind, amount: amount, corrected: 0 });
    }

    // The settlement account is the program's own, fixed at deployment, and approved the desk for its splits and
    // refunds. The loops below call only the fixed core, once per split of one purchase.
    // forge-lint: disable-start(arbitrary-send-erc20)
    // forge-lint: disable-start(calls-loop)

    // A win credits the disputed amount, at most what the purchase still nets; rest is what provisional credit left.
    function _won(bytes32 purchaseRef) private view returns (uint128 credited, uint128 rest) {
        Dispute storage d = disputes[purchaseRef];
        Book storage b = books[purchaseRef];
        uint128 open = b.captured - b.refunded;
        credited = d.amount < open ? d.amount : open;
        rest = credited > d.provisional ? credited - d.provisional : 0;
    }

    function _refund(bytes32 purchaseRef, uint128 amount) private {
        address token = PROGRAM.settlementToken();
        address booked = PROGRAM.purchaseToken(purchaseRef);
        if (booked == token) {
            SafeTransferLib.safeTransferFrom(token, SETTLEMENT, address(this), amount);
            _allowProgram(token, amount);
            PROGRAM.refund(purchaseRef, amount);
            return;
        }
        // A purchase booked in an earlier settlement token refunds in its units, which the program takes in today's
        // token at the reference rate; what the desk pulled beyond that goes back to the settlement account.
        uint256 paying =
            uint256(amount).mulDivUp(Conversion(PROGRAM.conversion()).mid(booked, token), RATE_ONE) + LEG_ROUNDING;
        // What the desk already holds (a one-unit seed, sent by anyone) stays, so a refund never creates its balance.
        uint256 baseline = SafeTransferLib.balanceOf(token, address(this));
        SafeTransferLib.safeTransferFrom(token, SETTLEMENT, address(this), paying);
        _allowProgram(token, paying);
        PROGRAM.refund(purchaseRef, amount);
        uint256 left = SafeTransferLib.balanceOf(token, address(this)) - baseline;
        if (left != 0) SafeTransferLib.safeTransfer(token, SETTLEMENT, left);
    }

    /// @dev A standing maximum allowance for the immutable program: Tempo charges every zero-to-nonzero allowance as a
    ///      new storage slot. The program takes only what each refund pulls from the desk, which holds nothing between
    ///      calls but a seed.
    function _allowProgram(address token, uint256 amount) private {
        if (IERC20Allowance(token).allowance(address(this), address(PROGRAM)) < amount) {
            SafeTransferLib.safeApproveWithRetry(token, address(PROGRAM), type(uint256).max);
        }
    }

    // Refunds amount of a purchase. The part past what it still nets once its open dispute's provisional credit counts
    // settles that credit, which the cardholder already holds: it moves no money, the program still counts it.
    function _refundSettling(bytes32 purchaseRef, uint128 amount) private {
        uint128 settled;
        Dispute storage d = disputes[purchaseRef];
        if (d.state != 0 && d.state < WON && d.provisional != 0) {
            Book storage b = books[purchaseRef];
            uint256 over = uint256(b.refunded) + amount + d.provisional;
            if (over > b.captured) {
                // At most amount + provisional, both uint128; capped at provisional below.
                // forge-lint: disable-next-line(unsafe-typecast)
                settled = uint128(over - b.captured);
                if (settled > d.provisional) settled = d.provisional;
                if (settled > amount) settled = amount;
                d.provisional -= settled;
                emit DisputeSettled(purchaseRef, d.owner, settled);
            }
        }
        if (amount > settled) _refund(purchaseRef, amount - settled);
        if (settled != 0) PROGRAM.creditBack(purchaseRef, settled, settled);
    }

    // Takes amount back after a lost dispute: the owner's free settlement token first, then its savings positions in
    // its funding order, never a credit line; the rest becomes capped debt to the settlement account, without a fee.
    function _recover(bytes32 purchaseRef, address owner, uint256 amount) private returns (uint256 debt) {
        uint256 free = CORE.available(owner, TOKEN);
        uint256 cash = free < amount ? free : amount;
        if (cash != 0) emit DisputeRecovered(purchaseRef, owner, 1, TOKEN, 0, cash);
        debt = amount - cash;
        if (debt != 0) {
            (, CardFunding.Source[] memory order) = PROGRAM.fundingOrderOf(owner);
            for (uint256 i; i < order.length && debt != 0; ++i) {
                if (order[i].kind != 2) continue;
                uint256 taken = _takeShares(purchaseRef, owner, SavingsFacility(order[i].source), debt);
                debt -= taken;
            }
        }
        if (cash + debt != 0) {
            // Bounded by the uint128 provisional credit.
            // forge-lint: disable-next-line(unsafe-typecast)
            CORE.charge(owner, TOKEN, _nextId(), uint128(cash + debt), SETTLEMENT, false);
        }
        if (debt != 0 && !_isDebtor[owner]) {
            _isDebtor[owner] = true;
            _debtors.push(owner);
        }
    }

    // Takes up to need (settlement units) of the owner's free shares in one savings facility's vault, redeems them to
    // the settlement account and returns what they were worth. A vault that cannot redeem now gets the shares sent as
    // they are.
    function _takeShares(bytes32 purchaseRef, address owner, SavingsFacility facility, uint256 need)
        private
        returns (uint256 taken)
    {
        address share = facility.SHARE();
        uint256 shares = CORE.available(owner, share);
        if (shares == 0) return 0;
        uint256 value = facility.VAULT().previewRedeem(shares);
        if (value > need) {
            uint256 wanted = facility.VAULT().previewWithdraw(need);
            if (wanted < shares) {
                shares = wanted;
                value = facility.VAULT().previewRedeem(shares);
            }
        }
        if (shares == 0 || value == 0) return 0;
        // Shares come from 128-bit core balances.
        // forge-lint: disable-next-line(unsafe-typecast)
        CORE.charge(owner, share, _nextId(), uint128(shares), address(this), false);
        SafeTransferLib.safeApprove(share, address(facility.VAULT()), shares);
        try facility.VAULT().redeem(shares, SETTLEMENT, value) returns (uint256 assets) {
            value = assets;
        } catch {
            SafeTransferLib.safeApprove(share, address(facility.VAULT()), 0);
            SafeTransferLib.safeTransfer(share, SETTLEMENT, shares);
        }
        taken = value < need ? value : need;
        emit DisputeRecovered(purchaseRef, owner, 2, address(facility), 0, taken);
    }

    // Pays every terms line its share of amount, then each reward out of its funder's share, from the settlement
    // account: a funder gets its split less the rewards it funds, the owner the rewards.
    function _charged(bytes32 purchaseRef, uint128 amount) private {
        address owner = PROGRAM.purchaseOf(purchaseRef).owner;
        address token = PROGRAM.purchaseToken(purchaseRef);
        books[purchaseRef].captured += amount;
        uint256 count = _terms.length;
        uint128[] memory left = new uint128[](count);
        for (uint256 i; i < count; ++i) {
            Line memory line = _terms[i];
            // Below amount, since terms add up to less than the whole.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128 fee = uint128((uint256(amount) * line.bps) / BPS);
            left[i] = fee;
            if (fee == 0) continue;
            _addSplit(purchaseRef, line.payee, address(0), line.kind, fee);
            emit FeePaid(purchaseRef, line.payee, line.kind, fee);
        }
        uint128 rewarded;
        for (uint256 r; r < _rewards.length; ++r) {
            Reward memory reward = _rewards[r];
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128 due = uint128((uint256(amount) * reward.bps) / BPS);
            uint128 paid;
            for (uint256 i; i < count && due != 0; ++i) {
                if (_terms[i].payee != reward.funder) continue;
                uint128 part = due < left[i] ? due : left[i];
                left[i] -= part;
                due -= part;
                paid += part;
            }
            if (paid == 0) continue;
            rewarded += paid;
            _addSplit(purchaseRef, owner, reward.funder, reward.kind, paid);
            emit RewardPaid(purchaseRef, owner, reward.funder, reward.kind, paid);
        }
        for (uint256 i; i < count; ++i) {
            if (left[i] != 0) SafeTransferLib.safeTransferFrom(token, SETTLEMENT, _terms[i].payee, left[i]);
        }
        if (rewarded != 0) SafeTransferLib.safeTransferFrom(token, SETTLEMENT, owner, rewarded);
    }

    function _addSplit(bytes32 purchaseRef, address payee, address funder, bytes32 kind, uint128 amount) private {
        Split[] storage splits = _splits[purchaseRef];
        for (uint256 i; i < splits.length; ++i) {
            Split storage s = splits[i];
            if (s.payee == payee && s.funder == funder && s.kind == kind) {
                s.amount += amount;
                return;
            }
        }
        splits.push(Split({ payee: payee, funder: funder, kind: kind, amount: amount, reversed: 0 }));
    }

    // Takes back the refunded share of every split: a payee returns its part from what it has available and owes the
    // settlement account the rest, within its debt cap; an owner returns a reward only from money it still has, to
    // the funder, which writes off the rest.
    function _reverse(bytes32 purchaseRef, uint128 amount) private {
        Book storage b = books[purchaseRef];
        uint128 captured = b.captured;
        if (captured == 0) return;
        uint128 refunded = b.refunded + amount;
        if (refunded > captured) refunded = captured;
        b.refunded = refunded;
        // Splits were paid, and come back, in the token the purchase was booked in.
        address token = PROGRAM.purchaseToken(purchaseRef);
        Split[] storage splits = _splits[purchaseRef];
        for (uint256 i; i < splits.length; ++i) {
            Split storage s = splits[i];
            // At most s.amount, since refunded never passes captured.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128 due = uint128((uint256(s.amount) * refunded) / captured);
            if (due <= s.reversed) continue;
            uint128 share = due - s.reversed;
            s.reversed = due;
            uint128 available = CORE.available(s.payee, token);
            if (s.funder == address(0)) {
                CORE.charge(s.payee, token, _nextId(), share, SETTLEMENT, false);
                emit FeeReversed(purchaseRef, s.payee, s.kind, share, share > available ? share - available : 0);
                continue;
            }
            uint128 taken = share < available ? share : available;
            if (taken == 0) continue;
            CORE.charge(s.payee, token, _nextId(), taken, s.funder, false);
            emit RewardReversed(purchaseRef, s.payee, s.funder, s.kind, taken);
        }
    }

    // forge-lint: disable-end(calls-loop)
    // forge-lint: disable-end(arbitrary-send-erc20)
    // forge-lint: disable-end(reentrancy-no-eth)

    function _nextId() private returns (bytes32) {
        return keccak256(abi.encode(address(this), ++_nonce));
    }
}
