// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The subset of Tempo Earn's `EarnVault` used to fund card spend.
interface ITempoEarnVault {
    function asset() external view returns (address);

    function earnShare() external view returns (address);

    function previewWithdraw(uint256 assets) external view returns (uint256 earnShares);

    function previewRedeem(uint256 earnShares) external view returns (uint256 assets);

    function deposit(uint256 assets, address receiver, uint256 minEarnShares) external returns (uint256 earnShares);

    /// @notice Burns at most `maxEarnShares` from the caller and sends exactly `assets` to
    ///         `receiver`.
    function withdrawExact(uint256 assets, address receiver, uint256 maxEarnShares)
        external
        returns (uint256 earnSharesBurned);
}
