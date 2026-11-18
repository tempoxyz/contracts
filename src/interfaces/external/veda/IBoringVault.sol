// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

interface IBoringVault {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
    function owner() external view returns (address);
}
