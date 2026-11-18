// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Optional engine capability for depositing base assets the EarnVault already sent to the engine.
/// @dev The paired EarnVault transfers `assets` from its caller straight to the engine and then calls
///      {depositHeld}, saving the hop through the vault. The engine deposits exactly `assets` and returns its
///      engine-share increase, which the vault measures. Only the bound EarnVault may call it.
interface IEarnEngineHeldDeposit {
    function depositHeld(uint256 assets) external returns (uint256 engineShares);
}
