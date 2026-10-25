// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ISeedFunder, SeededSimple4626Vault } from "../../src/demo/SeededSimple4626Vault.sol";
import { Simple4626Vault } from "../../src/demo/Simple4626Vault.sol";
import { FixtureScript } from "./FixtureScript.sol";
import { ILocalMorphoVault, LocalMorphoFeeWrapper } from "./contracts/LocalMorphoFeeWrapper.sol";

/// @notice The ERC-4626 engine's venue: locally a Simple ERC-4626 vault behind the Morpho fee-wrapper
///         fixture, and on a persistent chain a vault with locked seed liquidity. The shared lifecycle
///         deploys the engine.
contract DeployLocalERC4626Script is FixtureScript {
    uint256 private constant SEED_ASSETS = 1_000e6;

    function vault(address asset) external broadcast {
        new Simple4626Vault(asset, "Tempo Earn Local Vault", "teLOCAL", 6);
    }

    function seededVault(address asset, ISeedFunder funder) external broadcast {
        new SeededSimple4626Vault(asset, "Tempo Earn Test Vault", "teTEST", 6, funder, SEED_ASSETS);
    }

    function morphoFeeWrapper(ILocalMorphoVault venue) external broadcast {
        new LocalMorphoFeeWrapper(venue);
    }
}
