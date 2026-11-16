// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { CardProgram } from "./CardProgram.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";

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
contract IssuerDesk {
    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint256 private constant BPS = 10_000;

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

    CardProgram public immutable PROGRAM;
    address public immutable ISSUER;
    address public immutable TOKEN;
    address public immutable SETTLEMENT;

    Line[] internal _terms;
    Reward[] internal _rewards;
    mapping(bytes32 purchaseRef => Book) public books;
    mapping(bytes32 purchaseRef => Split[]) internal _splits;
    mapping(uint64 seq => Step) public steps;
    uint64 internal _nonce;
    bool internal _locked;

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
    event Corrected(bytes32 indexed purchaseRef, uint64 indexed target, int128 amount, string reason);

    error NotIssuer();
    error ZeroAddress();
    error InvalidTerms();
    error InvalidRewards();
    error NotCorrectable();
    error CorrectionTooLarge();
    error Reentrancy();

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
        _refund(purchaseRef, amount);
        _step(purchaseRef, REFUND, amount);
        _reverse(purchaseRef, amount);
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
            _refund(purchaseRef, size);
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

    function _step(bytes32 purchaseRef, uint8 kind, uint128 amount) private {
        (uint64 seq,,) = PROGRAM.ledger();
        steps[seq] = Step({ purchaseRef: purchaseRef, kind: kind, amount: amount, corrected: 0 });
    }

    // The settlement account is the program's own, fixed at deployment, and approved the desk for its splits and
    // refunds. The loops below call only the fixed core, once per split of one purchase.
    // forge-lint: disable-start(arbitrary-send-erc20)
    // forge-lint: disable-start(calls-loop)

    function _refund(bytes32 purchaseRef, uint128 amount) private {
        SafeTransferLib.safeTransferFrom(TOKEN, SETTLEMENT, address(this), amount);
        SafeTransferLib.safeApprove(TOKEN, address(PROGRAM), amount);
        PROGRAM.refund(purchaseRef, amount);
    }

    // Pays every terms line its share of amount, then each reward out of its funder's share, from the settlement
    // account: a funder gets its split less the rewards it funds, the owner the rewards.
    function _charged(bytes32 purchaseRef, uint128 amount) private {
        address owner = PROGRAM.purchaseOf(purchaseRef).owner;
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
            if (left[i] != 0) SafeTransferLib.safeTransferFrom(TOKEN, SETTLEMENT, _terms[i].payee, left[i]);
        }
        if (rewarded != 0) SafeTransferLib.safeTransferFrom(TOKEN, SETTLEMENT, owner, rewarded);
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
        Split[] storage splits = _splits[purchaseRef];
        for (uint256 i; i < splits.length; ++i) {
            Split storage s = splits[i];
            // At most s.amount, since refunded never passes captured.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128 due = uint128((uint256(s.amount) * refunded) / captured);
            if (due <= s.reversed) continue;
            uint128 share = due - s.reversed;
            s.reversed = due;
            uint128 available = CORE.available(s.payee, TOKEN);
            if (s.funder == address(0)) {
                CORE.charge(s.payee, TOKEN, _nextId(), share, SETTLEMENT, false);
                emit FeeReversed(purchaseRef, s.payee, s.kind, share, share > available ? share - available : 0);
                continue;
            }
            uint128 taken = share < available ? share : available;
            if (taken == 0) continue;
            CORE.charge(s.payee, TOKEN, _nextId(), taken, s.funder, false);
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
