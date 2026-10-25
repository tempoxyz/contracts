// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

interface ITeller {
    function vault() external view returns (address);
    function accountant() external view returns (address);
    function bulkDeposit(address depositAsset, uint256 depositAmount, uint256 minimumMint, address to)
        external
        returns (uint256 shares);
    function bulkWithdraw(address withdrawAsset, uint256 shareAmount, uint256 minimumAssets, address to)
        external
        returns (uint256 assetsOut);
}
