// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Always-fresh par oracle for a disposable DirectPropAMM router conversion pool.
/// @dev Test scaffolding only. With equal-decimal pair tokens, `10 ** decimals()` is an exact 1:1
///      conversion price, which is the price the scoped router requires.
contract DemoPropAMMParOracle {
    uint8 private constant DECIMALS = 8;

    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
        return (10 ** DECIMALS, block.timestamp);
    }
}

/// @notice Identity recipient registry for a disposable DirectPropAMM pool: no recipient redirects.
contract DemoPropAMMRecipientRegistry {
    function resolveRecipient(address recipient) external pure returns (address) {
        return recipient;
    }
}
