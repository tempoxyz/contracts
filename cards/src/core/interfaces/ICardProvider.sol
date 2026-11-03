// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { CardSpend } from "../CardSpend.sol";

/// @title ICardProvider
/// @notice A card provider's engine for one or more `CardSpender`s: what the provider decides about a
///         spend. Every provider implements this; what it pays through is an optional capability
///         (`ICardProviderPayout`), discovered with ERC-165 when the program is deployed, as Earn
///         discovers an engine's exit capabilities. Provider contracts hold no funds and read the provider's own
///         contracts as they are.
interface ICardProvider is IERC165 {
    /// @notice Whether a spend of `token` from `payer` may pay `destination`.
    /// @param payer The cardholder's account (public) or whoever settles a Zone withdrawal (private).
    /// @param hint Provider-specific evidence that `destination` belongs to the program.
    /// @param isPrivate True for a private spend, which must not name the cardholder: the provider authorizes
    ///        only destinations the program shares across cardholders for it.
    function isAuthorizedDestination(address payer, address destination, address token, uint256 hint, bool isPrivate)
        external
        view
        returns (bool);

    /// @notice Whether spends may redeem Tempo Earn shares from `vault`. A vault's `withdrawExact` decides
    ///         where redeemed value goes, so allowing one is as strong as adding a destination.
    function isAllowedVault(address vault) external view returns (bool);

    /// @notice Whether the provider's own contracts have stopped spends (false when they have no pause).
    function paused() external view returns (bool);
}

/// @title ICardProviderPayout
/// @notice Optional capability: the provider's own contracts pay the spend. The program approves
///         `payoutTarget` for the spend's input and calls it with `payoutData(spend)` as the payer, then
///         checks the destination got exactly the amount and takes back what was not used. `BridgeProvider`
///         names the program's spender clone, so Bridge's factory still governs every spend.
interface ICardProviderPayout {
    /// @notice The contract the program pays through. Fixed for the provider's life.
    function payoutTarget() external view returns (address);

    /// @notice The call that pays `spend` from the program's balance.
    function payoutData(CardSpend calldata spend) external view returns (bytes memory);
}
