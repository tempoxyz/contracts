// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice One card spend through Bridge's "TS" handler, `SpenderTempoSpend`. The program's `CardSpender`
///         pays every spend, public and private, with this struct, which `BridgeProvider.payoutData` builds
///         from the `CardSpend`. This is its only definition: the handler and the provider import it from
///         here, so both encode `abi.encode(Spend)` identically.
struct Spend {
    bytes32 spenderId;
    /// @dev Stablecoin the destination receives.
    address token;
    uint256 amount;
    address destination;
    /// @dev Tempo Earn vault that funds `fromVault`, holding `token`. Zero when `fromVault` is zero.
    address vault;
    /// @dev Part of `amount` redeemed from `vault`. The rest is paid in `token`.
    uint256 fromVault;
    /// @dev Most EarnShares `fromVault` may burn. Zero accepts the live price.
    uint256 maxShares;
    /// @dev Bridge's own reference for reconciliation. Emitted, never enforced.
    bytes32 ref;
}

/// @notice The subset of Bridge's `SpenderFactory` that names a program's spender clone.
interface IBridgeSpenderFactory {
    function getSpenderAddress(bytes32 spenderId) external view returns (address);
}

/// @notice The subset of a Bridge spender clone (`SpenderDelegator`) a program pays through:
///         `publicCall`, routed to a handler by the payload's 2-byte prefix.
interface IBridgeSpenderClone {
    function publicCall(bytes calldata data) external;
}
