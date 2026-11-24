// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice The part of an Upshift (August) tokenized vault that {UpshiftEngine} uses.
/// @dev The vault is not ERC-4626: it issues a separate receipt token ({lpTokenAddress}), prices it from a
///      reported NAV, and pays lagged redemptions from a queue keyed by claim date and receiver.
interface IUpshiftVault {
    /// @notice The reference asset every redemption pays.
    function asset() external view returns (address);

    /// @notice The receipt token the vault mints on deposit and burns on redemption.
    function lpTokenAddress() external view returns (address);

    /// @notice When the vault's NAV report was last updated.
    function assetsUpdatedOn() external view returns (uint256);

    /// @notice Mints receipt tokens to `receiverAddr` for `amountIn` of `assetIn` pulled from the caller.
    function deposit(address assetIn, uint256 amountIn, address receiverAddr) external returns (uint256 shares);

    /// @notice Burns the caller's `shares` and pays `receiverAddr` now, net of the instant redemption fee.
    function instantRedeem(uint256 shares, address receiverAddr) external;

    /// @notice Queues the caller's `shares` for `receiverAddr`, claimable on the returned date.
    /// @dev The vault adds the shares to the receiver's total for that date and has no way to cancel them.
    function requestRedeem(uint256 shares, address receiverAddr)
        external
        returns (uint256 claimableEpoch, uint256 year, uint256 month, uint256 day);

    /// @notice Pays `receiverAddr` everything queued for it on a date, priced when called.
    function claim(uint256 year, uint256 month, uint256 day, address receiverAddr)
        external
        returns (uint256 shares, uint256 assetsAfterFee);

    /// @notice The redemption value of `shares` before and after the instant or the lagged fee.
    function previewRedemption(uint256 shares, bool isInstant)
        external
        view
        returns (uint256 assetsAmount, uint256 assetsAfterFee);

    /// @notice The shares queued for `receiverAddr` on a date and not yet paid.
    function getBurnableAmountByReceiver(uint256 year, uint256 month, uint256 day, address receiverAddr)
        external
        view
        returns (uint256 shares);
}
