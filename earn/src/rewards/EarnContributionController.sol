// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20Like } from "../interfaces/external/IERC20Like.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Minimal EarnVault surface needed by the standalone contribution controller.
interface IContributionTarget {
    function accrueFees() external returns (uint256 feeAssets, uint256 feeEarnShares);
    function asset() external view returns (address);
    function contribute(uint256 assets) external returns (uint256 engineShares);
    function totalEarnShares() external view returns (uint256);
}

/// @title EarnContributionController
/// @notice Standalone orchestration for one-way Earn backing contributions.
/// @dev The owner chooses a funder and amount for each contribution. The funder keeps custody and
///      approves this contract; funds move atomically from that funder through the immutable EarnVault's
///      permissionless contribution path. No EarnShare is minted. Reward policy and provider identity
///      stay outside the EarnVault, so this controller can be paused or replaced independently.
/// Specs for solar-verify (docs/earn/modules/rewards.md):
/// Funding entry points are nonReentrant (`locked` is 1 when free, 2 while held).
/// @custom:reentrancy-guard locked != 1
/// The vault and its asset are fixed and nonzero.
/// @custom:invariant address(earnVault) != address(0) && asset != address(0)
/// Ghost record of the last token call (set in _safeTransferFrom and _safeApprove): whether it succeeded,
/// whether it returned data, and that data read as a bool.
/// @custom:ghost bool lastCallOk
/// @custom:ghost bool lastCallReturnedData
/// @custom:ghost bool lastCallReturnedTrue
/// Ghost record of the last amount pulled from a funder and the last approval given to the vault.
/// @custom:ghost uint256 lastPulled
/// @custom:ghost uint256 vaultApproval
/// Ghost record of the supply the last supply check accepted.
/// @custom:ghost uint256 checkedSupply
/// Solvency: the controller never holds what it contributes. Every successful leg pulls exactly the requested
/// assets and leaves no approval behind (see _contributeExact).
/// Not proved: that the controller's asset balance returns to its prior value after each leg; the vault's
/// contribute pull is not measured here.
contract EarnContributionController is Ownable2Step {
    IContributionTarget public immutable earnVault;
    address public immutable asset;

    bool public active = true;

    uint256 private locked = 1;

    event ActiveSet(bool active);
    event Funded(address indexed funder, uint256 requestedAssets, uint256 fundedAssets);

    error Inactive();
    error InvalidArrayLengths();
    error NotSelf();
    error ReentrantCall();
    error EarnShareSupplyOutOfBounds(uint256 earnShareSupply, uint256 maxEarnShareSupply);
    error TokenCallFailed();
    error TokenCallFalse();
    error ZeroAddress();
    error ZeroAmount();

    modifier nonReentrant() {
        if (locked != 1) revert ReentrantCall();
        locked = 2;
        _;
        locked = 1;
    }

    /// @custom:ensures earnVault == earnVault_ && active && owner() == owner_
    constructor(IContributionTarget earnVault_, address owner_) Ownable(owner_) {
        if (address(earnVault_) == address(0)) revert ZeroAddress();

        address asset_ = earnVault_.asset();
        if (asset_ == address(0)) revert ZeroAddress();

        earnVault = earnVault_;
        asset = asset_;
        emit ActiveSet(true);
    }

    /// @notice Pulls one best-effort contribution from `funder` through the EarnVault.
    /// @dev A supply above the owner's authorized maximum, failed provider transfer, or failed engine
    ///      deposit is recorded as zero funding. A lower nonzero supply remains eligible and receives
    ///      a larger contribution per EarnShare.
    /// @param maxEarnShareSupply Maximum fee-inclusive pre-contribution EarnShare supply authorized for
    ///        this funding attempt. Zero guarantees that the attempt records no funding even if the vault
    ///        is seeded first.
    /// Only the owner funds, only while active, never for the zero funder; the lock is released.
    /// @custom:ensures old(owner()) == msg.sender && old(active) && funder != address(0)
    /// @custom:ensures requestedAssets == 0 ==> fundedAssets == 0
    /// @custom:ensures locked == 1
    /// Liveness: the owner's call while active, unlocked and for a nonzero funder always returns; a failed
    /// pull, supply check or contribution records zero funding instead of reverting.
    /// @custom:succeeds-if msg.sender == owner() && active && locked == 1 && funder != address(0)
    function fund(address funder, uint256 requestedAssets, uint256 maxEarnShareSupply)
        external
        onlyOwner
        nonReentrant
        returns (uint256 fundedAssets)
    {
        if (!active) revert Inactive();
        if (funder == address(0)) revert ZeroAddress();
        if (requestedAssets == 0) {
            emit Funded(funder, 0, 0);
            return 0;
        }

        // Isolate the provider pull + underlying investment in one atomic subcall. A failed
        // provider or underlying vault records zero without retaining assets in this controller.
        try this.executeFunding(funder, requestedAssets, maxEarnShareSupply) returns (uint256 actualAssets) {
            fundedAssets = actualAssets;
        } catch { }

        emit Funded(funder, requestedAssets, fundedAssets);
    }

    /// @notice Pulls an all-or-nothing contribution batch from multiple funders.
    /// @dev The fee-inclusive supply bound is checked once before the first contribution. A provider
    ///      or venue failure reverts every leg, preventing partial multi-provider settlement.
    /// Only the owner funds, only while active, with at least two legs of equal-length arrays, every funder
    /// nonzero and every amount positive; the total covers every leg and no vault approval is left.
    /// @custom:ensures old(owner()) == msg.sender && old(active)
    /// @custom:ensures funders.length >= 2 && funders.length == requestedAssets.length
    /// @custom:ensures forall uint256 j :: j < funders.length ==> funders[j] != address(0) && requestedAssets[j] > 0
    /// @custom:ensures totalFundedAssets >= funders.length
    /// @custom:ensures locked == 1 && vaultApproval == 0
    /// Not proved: liveness. The batch is all-or-nothing by design, so it also needs every funder's pull, the
    /// vault's fee accrual and every contribution to succeed, which depend on calls outside this contract.
    function fundBatchExact(address[] calldata funders, uint256[] calldata requestedAssets, uint256 maxEarnShareSupply)
        external
        onlyOwner
        nonReentrant
        returns (uint256 totalFundedAssets)
    {
        if (!active) revert Inactive();
        uint256 length = funders.length;
        if (length < 2 || length != requestedAssets.length) revert InvalidArrayLengths();
        /// @custom:invariant i <= length && length == funders.length && length == requestedAssets.length
        /// @custom:invariant forall uint256 j :: j < i ==> funders[j] != address(0) && requestedAssets[j] > 0
        for (uint256 i; i < length; ++i) {
            if (funders[i] == address(0)) revert ZeroAddress();
            if (requestedAssets[i] == 0) revert ZeroAmount();
        }

        _checkEarnShareSupply(maxEarnShareSupply);
        /// @custom:invariant i <= length && length == funders.length && length == requestedAssets.length
        /// @custom:invariant totalFundedAssets >= i && (i > 0 ==> vaultApproval == 0)
        /// @custom:invariant forall uint256 j :: j < length ==> funders[j] != address(0) && requestedAssets[j] > 0
        for (uint256 i; i < length; ++i) {
            uint256 amount = requestedAssets[i];
            _contributeExact(funders[i], amount);
            totalFundedAssets += amount;
            emit Funded(funders[i], amount, amount);
        }
    }

    /// @notice Atomic provider pull, live-supply check, and contribution leg used only through `fund`.
    /// Only the controller itself calls it; it funds exactly the requested assets and leaves no approval.
    /// @custom:ensures msg.sender == address(this) && fundedAssets == requestedAssets && vaultApproval == 0
    function executeFunding(address funder, uint256 requestedAssets, uint256 maxEarnShareSupply)
        external
        returns (uint256 fundedAssets)
    {
        if (msg.sender != address(this)) revert NotSelf();

        _checkEarnShareSupply(maxEarnShareSupply);
        _contributeExact(funder, requestedAssets);
        fundedAssets = requestedAssets;
    }

    /// The contract invariants hold on entry (it is called from verified entry points only).
    /// @custom:requires address(earnVault) != address(0) && asset != address(0)
    /// The fee-inclusive supply read after accrueFees is nonzero and within the owner's maximum.
    /// @custom:ensures 0 < checkedSupply && checkedSupply <= maxEarnShareSupply
    function _checkEarnShareSupply(uint256 maxEarnShareSupply) private {
        earnVault.accrueFees();
        uint256 earnShareSupply = earnVault.totalEarnShares();
        /// @custom:ghost checkedSupply = earnShareSupply
        if (earnShareSupply == 0 || earnShareSupply > maxEarnShareSupply) {
            revert EarnShareSupplyOutOfBounds(earnShareSupply, maxEarnShareSupply);
        }
    }

    /// The contract invariants hold on entry (it is called from verified entry points only).
    /// @custom:requires address(earnVault) != address(0) && asset != address(0)
    /// A contribution pulls exactly the requested assets before approving the vault, and leaves no approval.
    /// @custom:ensures vaultApproval == 0
    function _contributeExact(address funder, uint256 requestedAssets) private {
        _safeTransferFrom(asset, funder, address(this), requestedAssets);
        /// @custom:assert lastPulled == requestedAssets
        _safeApprove(asset, address(earnVault), requestedAssets);
        earnVault.contribute(requestedAssets);
        _safeApprove(asset, address(earnVault), 0);
    }

    /// @notice Stops or restarts future funding calls without touching the vault or existing rewards.
    /// @custom:ensures old(owner()) == msg.sender && active == active_
    /// @custom:succeeds-if msg.sender == owner()
    function setActive(bool active_) external onlyOwner {
        if (active == active_) return;
        active = active_;
        emit ActiveSet(active_);
    }

    /// The contract invariants hold on entry (it is called from verified entry points only).
    /// @custom:requires address(earnVault) != address(0) && asset != address(0)
    /// A token call is accepted only if it succeeded and returned nothing or true.
    /// @custom:ensures lastCallOk && (lastCallReturnedData ==> lastCallReturnedTrue) && lastPulled == amount
    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory result) = token.call(abi.encodeCall(IERC20Like.transferFrom, (from, to, amount)));
        /// @custom:ghost lastPulled = amount
        /// @custom:ghost lastCallOk = ok
        /// @custom:ghost lastCallReturnedData = result.length != 0
        /// @custom:ghost lastCallReturnedTrue = result.length != 0 && abi.decode(result, (bool))
        if (!ok) revert TokenCallFailed();
        if (result.length != 0 && !abi.decode(result, (bool))) revert TokenCallFalse();
    }

    /// The contract invariants hold on entry (it is called from verified entry points only).
    /// @custom:requires address(earnVault) != address(0) && asset != address(0)
    /// A token call is accepted only if it succeeded and returned nothing or true.
    /// @custom:ensures lastCallOk && (lastCallReturnedData ==> lastCallReturnedTrue) && vaultApproval == amount
    function _safeApprove(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory result) = token.call(abi.encodeCall(IERC20Like.approve, (spender, amount)));
        /// @custom:ghost vaultApproval = amount
        /// @custom:ghost lastCallOk = ok
        /// @custom:ghost lastCallReturnedData = result.length != 0
        /// @custom:ghost lastCallReturnedTrue = result.length != 0 && abi.decode(result, (bool))
        if (!ok) revert TokenCallFailed();
        if (result.length != 0 && !abi.decode(result, (bool))) revert TokenCallFalse();
    }
}
