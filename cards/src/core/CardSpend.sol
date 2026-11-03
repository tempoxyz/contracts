// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice One card spend, whatever the card provider. The same struct settles public spend (paid by the
///         cardholder's account) and private spend (paid by the program's `CardSettler` from a Zone
///         withdrawal), so both encode `abi.encode(CardSpend)` identically.
/// @dev The provider-specific parts are the program, which decides what `destination` may be, and
///      `destinationHint`, the evidence that program reads (Rain: the collateral's index in its factory's
///      `collateralProxies`). Kept to static words so a private spend's callback fits the Zone outbox's
///      1,024 bytes.
struct CardSpend {
    /// @dev The provider's `ICardProgram` adapter. Must be the spender's own program.
    address program;
    /// @dev Stablecoin the destination receives.
    address token;
    uint256 amount;
    address destination;
    /// @dev Provider-specific evidence that `destination` belongs to the program, read only by the program.
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
