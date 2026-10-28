// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice The ERC-20 allowance read a router or settler makes before topping up a standing approval.
interface IERC20Allowance {
    function allowance(address owner, address spender) external view returns (uint256);
}
