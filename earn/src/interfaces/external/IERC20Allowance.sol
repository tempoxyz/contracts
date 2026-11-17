// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice The ERC-20 allowance read, kept apart from {IERC20Like} so contracts that never read allowances
///         keep their reviewed bytecode.
interface IERC20Allowance {
    function allowance(address owner, address spender) external view returns (uint256);
}
