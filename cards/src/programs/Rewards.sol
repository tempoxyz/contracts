// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @title Rewards
/// @notice Card rewards and their claw-back: the issuer pays a purchase's cardholder a reward (cashback) in one fixed
///         token from its funder, and when the purchase is refunded or written off takes it back from what the
///         cardholder still holds, never past what that purchase's rewards paid and never into debt.
/// @dev A companion of one CardAuth: the settle role pays and claws back, and an operator's payments count against
///      its cap. A cardholder approves this contract as a holder of the reward token so claw-backs can charge it.
///      Claw-backs pay the funder. One slot per rewarded purchase. Not upgradeable.
/// @custom:reentrancy-guard none: it calls only the fixed core, its program and its fixed token.
contract Rewards {
    using SafeCastLib for uint256;

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);

    /// @notice What a purchase's rewards paid and what was clawed back of it.
    struct Reward {
        uint128 paid;
        uint128 clawed;
    }

    ICardAuth public immutable PROGRAM;
    /// @notice The token rewards are paid in.
    address public immutable TOKEN;
    /// @notice Pays rewards (approving this contract) and receives what is clawed back.
    address public immutable FUNDER;

    mapping(bytes32 ref => Reward) public rewardOf;

    event RewardPaid(bytes32 indexed ref, address indexed owner, uint256 amount);
    event RewardClawedBack(bytes32 indexed ref, address indexed owner, uint256 amount);

    error InvalidAmount();
    error Unauthorized();
    error UnknownPurchase();
    error ZeroAddress();

    constructor(ICardAuth program, address token, address funder) {
        if (address(program) == address(0) || token == address(0) || funder == address(0)) revert ZeroAddress();
        (PROGRAM, TOKEN, FUNDER) = (program, token, funder);
    }

    /// @notice Pays purchase `ref`'s cardholder a reward of `amount` from the funder. Settle role.
    function pay(bytes32 ref, uint256 amount) external {
        address owner = _settle(ref, amount);
        if (amount == 0) revert InvalidAmount();
        Reward storage r = rewardOf[ref];
        r.paid = (r.paid + amount).toUint128();
        // The funder is fixed at deployment and approves this contract for rewards only.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        SafeTransferLib.safeTransferFrom(TOKEN, FUNDER, owner, amount);
        emit RewardPaid(ref, owner, amount);
    }

    /// @notice Takes back up to `amount` of purchase `ref`'s rewards from what its cardholder still holds of the
    ///         reward token, for the funder. Never past what the purchase's rewards paid less what was clawed back,
    ///         nor past the cardholder's free balance or the budget they gave this contract. Settle role. Returns what
    ///         it took.
    function clawBack(bytes32 ref, uint256 amount) external returns (uint256 taken) {
        address owner = _settle(ref, 0);
        Reward memory r = rewardOf[ref];
        taken = _min(amount, r.paid - r.clawed);
        taken = _min(taken, CORE.available(owner, TOKEN));
        IReservationCore.Budget memory b = CORE.budget(owner, address(this), TOKEN);
        uint256 used = uint256(b.spent) + b.outstanding;
        taken = _min(taken, b.limit > used ? b.limit - used : 0);
        if (taken == 0) return 0;
        rewardOf[ref].clawed = r.clawed + taken.toUint128();
        CORE.charge(owner, TOKEN, keccak256(abi.encode(ref, r.clawed)), taken.toUint128(), address(this), false);
        SafeTransferLib.safeTransfer(TOKEN, FUNDER, taken);
        emit RewardClawedBack(ref, owner, taken);
    }

    /// @dev Requires the settle role (counting `value` against an operator's cap) and returns the purchase's owner.
    function _settle(bytes32 ref, uint256 value) private returns (address owner) {
        if (!PROGRAM.hasRoles(msg.sender, PROGRAM.ROLE_SETTLE())) revert Unauthorized();
        if (value != 0) PROGRAM.useOperatorCap(msg.sender, value);
        owner = PROGRAM.purchaseOf(ref).owner;
        if (owner == address(0)) revert UnknownPurchase();
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
