// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice One card spend, for every provider. The same struct settles a public spend (`CardSpender.spend`,
///         paid by the cardholder's account) and a private one (`CardSpender.settle`, paid from a Zone
///         withdrawal), so both encode `abi.encode(CardSpend)` identically. Kept to static words so a
///         private spend's callback fits the Zone outbox's 1,024 bytes.
struct CardSpend {
    /// @dev The `CardSpender` this spend is for. A program refuses any other's spend.
    address program;
    /// @dev Stablecoin the destination receives.
    address token;
    uint256 amount;
    address destination;
    /// @dev Provider-specific evidence that `destination` belongs to the program, read only by its provider
    ///      (Rain: the collateral's index in its factory's `collateralProxies`).
    uint256 destinationHint;
    /// @dev Tempo Earn vault that funds `fromVault`, holding `token`. Zero when `fromVault` is zero.
    address vault;
    /// @dev Part of `amount` redeemed from `vault`. The rest is paid in `token`.
    uint256 fromVault;
    /// @dev Most EarnShares `fromVault` may burn. Zero accepts the live price.
    uint256 maxShares;
    /// @dev The provider's own reference for reconciliation. Emitted, never enforced.
    bytes32 ref;
}
