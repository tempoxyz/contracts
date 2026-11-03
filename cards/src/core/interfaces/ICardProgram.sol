// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ICardProgram
/// @notice What a card provider decides about one card program, read by the provider-agnostic
///         `CardSpender` on every spend. One adapter per provider program: Rain's is
///         `RainCardProgram`. Adapters read the provider's own contracts as they are; they never
///         require the provider to change them.
interface ICardProgram {
    /// @notice Whether a spend of `token` from `payer` may pay `destination`.
    /// @param payer Who funds the spend: the cardholder's account (public) or the program's settler (private).
    /// @param hint Provider-specific evidence that `destination` belongs to the program.
    /// @param isPrivate True for a private spend, which `CardSpender` accepts only from its own settler. A
    ///        private spend must not name the cardholder, so an adapter authorizes only destinations the
    ///        program shares across cardholders for it.
    function isAuthorizedDestination(address payer, address destination, address token, uint256 hint, bool isPrivate)
        external
        view
        returns (bool);

    /// @notice Whether spends may redeem Tempo Earn shares from `vault`. A vault's `withdrawExact`
    ///         decides where redeemed value goes, so allowing one is as strong as adding a destination.
    function isAllowedVault(address vault) external view returns (bool);

    /// @notice Whether the provider has stopped every spend of this program. An adapter with no pause
    ///         returns false; one with a pause lets only the provider's pause key set it.
    function paused() external view returns (bool);
}
