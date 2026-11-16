// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Simple4626Vault } from "tempo-earn/demo/Simple4626Vault.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

/// @title ImpairableVault
/// @notice A test yield venue whose curator can write its assets down, so localnet and tests can show what a loss in
///         the venue does to savings legs. Never deploy it outside tests.
contract ImpairableVault is Simple4626Vault {
    address public immutable CURATOR;

    event Impaired(uint256 assets, address to);

    error NotCurator();

    constructor(address asset_, string memory name_, string memory symbol_, uint8 decimals_)
        Simple4626Vault(asset_, name_, symbol_, decimals_)
    {
        CURATOR = msg.sender;
    }

    /// @notice Moves `assets` out of the venue to `to`, lowering what every share redeems for.
    function impair(uint256 assets, address to) external {
        if (msg.sender != CURATOR) revert NotCurator();
        if (!IERC20Like(asset).transfer(to, assets)) revert TokenCallFalse();
        emit Impaired(assets, to);
    }
}
