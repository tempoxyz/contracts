// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Called by an EarnVault inside {IEarnVaultWithdrawCallback-withdrawExactWithCallback} once it knows the
///         EarnShare cost.
/// @dev The callee must transfer exactly `earnShares` of EarnShare to the calling vault before returning, from any
///      account it may spend from. The vault checks its balance rose by that amount and burns it.
interface IEarnWithdrawCallback {
    function earnWithdrawCallback(uint256 earnShares) external;
}

/// @notice The EarnVault entrypoint that collects EarnShare through {IEarnWithdrawCallback}. An EarnVault reports
///         it through ERC-165, so a caller can tell a vault that has it from one deployed before it.
interface IEarnVaultWithdrawCallback {
    function withdrawExactWithCallback(uint256 assets, address receiver, uint256 maxEarnShares)
        external
        returns (uint256 earnSharesBurned);
}
