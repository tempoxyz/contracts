// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { DemoPropAMMParOracle, DemoPropAMMRecipientRegistry } from "../../src/demo/DemoPropAMMPeriphery.sol";
import { DemoStablecoinFunder } from "../../src/demo/DemoStablecoinFunder.sol";
import { Simple4626Vault } from "../../src/demo/Simple4626Vault.sol";
import { FixtureScript, IDirectPropAMMAdmin } from "./FixtureScript.sol";

/// @notice The engine-independent fixtures: stablecoins, the router pool, and the same-asset venue.
///         Each engine's venue fixtures live in its own script; the shared factory releases come
///         from `script/deploy/` (`DeployFactoryRelease.s.sol` and each engine factory's own script).
/// @dev Each external function is one transaction-sized step the localnet orchestrator calls with
///      typed calldata (`Foundry.script`).
contract DeployLocalEarnScript is FixtureScript {
    /// @dev `nonce` is zero on a fresh chain and fresh per bootstrap on a persistent one.
    function stablecoinFunder(uint256 nonce) external broadcast {
        _deployStablecoinFunder(nonce);
    }

    function stablecoins(DemoStablecoinFunder funder, uint256 nonce) external broadcast {
        _createStablecoins(funder, nonce);
    }

    function routerPoolOracle() external broadcast {
        new DemoPropAMMParOracle();
    }

    function routerPoolRegistry() external broadcast {
        new DemoPropAMMRecipientRegistry();
    }

    /// @dev The private asset is the pool base and the vault asset its quote; the par oracle makes
    ///      both directions an exact 1:1 conversion for these equal-decimal fixture tokens.
    function routerPool(address privateAsset, address vaultAsset, address oracle, address registry) external broadcast {
        _deployDirectPropAMM(privateAsset, vaultAsset, oracle, registry);
    }

    /// @dev Unpausing admits no taker; only the router the lifecycle admits can trade.
    function routerPoolUnpause(IDirectPropAMMAdmin pool) external broadcast {
        pool.unpause();
    }

    /// @dev Venue for the optional same-asset route, whose router private asset is PATHUSD itself.
    function pathUsdVault() external broadcast {
        new Simple4626Vault(PATH_USD, "Local PATHUSD Vault", "tePATH", 6);
    }
}
