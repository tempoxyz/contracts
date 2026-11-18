// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title IExposureGuard
/// @notice Bounds what a card authorization contract may owe: CardAuth asks its registered guard after every step that
///         raises its exposure (authorize, an increase, a charge), and the guard reverts to refuse the step.
interface IExposureGuard {
    /// @notice Reverts when the program's exposure is past what the guard allows.
    function checkExposure() external view;
}
