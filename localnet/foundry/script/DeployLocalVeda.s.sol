// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { VedaEngine } from "../../../src/engines/veda/VedaEngine.sol";
import { VedaForwardingSolver, IForwardingEngine } from "../../../src/engines/veda/VedaForwardingSolver.sol";
import { VedaPeripheryRegistry } from "../../../src/engines/veda/VedaPeripheryRegistry.sol";
import { IAccountant } from "../../../src/interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../src/interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../../src/interfaces/external/veda/IBoringVault.sol";
import { ITeller } from "../../../src/interfaces/external/veda/ITeller.sol";
import { FixtureScript } from "./FixtureScript.sol";
import {
    LocalVedaAccountant,
    LocalVedaQueue,
    LocalVedaSolver,
    LocalVedaTeller,
    LocalVedaVault
} from "../src/LocalVeda.sol";

/// @notice The Veda engine's local venue: a BoringVault with its periphery and a replacement
///         periphery, the engine bound to the periphery registry, and its forwarding solver.
contract DeployLocalVedaScript is FixtureScript {
    uint64 private constant VEDA_SHARE_LOCK_PERIOD = 1 hours;

    function vault(address asset) external broadcast {
        new LocalVedaVault(asset, _owner());
    }

    function accountant(address vault_, address asset) external broadcast {
        new LocalVedaAccountant(vault_, asset, _owner());
    }

    function teller(LocalVedaVault vault_, LocalVedaAccountant accountant_, address asset) external broadcast {
        new LocalVedaTeller(vault_, accountant_, asset, _owner());
    }

    function queue(LocalVedaVault vault_, LocalVedaAccountant accountant_) external broadcast {
        new LocalVedaQueue(vault_, accountant_);
    }

    function stockSolver(LocalVedaQueue queue_) external broadcast {
        new LocalVedaSolver(queue_);
    }

    function registry(IBoringVault vault_, address asset) external broadcast {
        new VedaPeripheryRegistry(vault_, asset);
    }

    function publish(VedaPeripheryRegistry registry_, ITeller teller_, IBoringQueue queue_, IAccountant accountant_)
        external
        broadcast
    {
        registry_.setVedaPeriphery(teller_, queue_, accountant_);
    }

    function configure(LocalVedaTeller teller_, LocalVedaTeller nextTeller) external broadcast {
        teller_.setShareLockPeriod(VEDA_SHARE_LOCK_PERIOD);
        nextTeller.setShareLockPeriod(VEDA_SHARE_LOCK_PERIOD);
    }

    function engine(VedaPeripheryRegistry registry_, uint64 maxRateAge) external broadcast {
        new VedaEngine(registry_, _owner(), maxRateAge, "Local Veda Vault", "teVEDA");
    }

    function bindEngine(VedaPeripheryRegistry registry_, address engine_) external broadcast {
        registry_.bindEngine(engine_);
    }

    function forwarder(IBoringSolver stockSolver_, IBoringQueue queue_, address teller_, IForwardingEngine engine_)
        external
        broadcast
    {
        address owner = _owner();
        new VedaForwardingSolver(stockSolver_, queue_, teller_, engine_, owner, owner);
    }

    function authorize(VedaEngine engine_, VedaForwardingSolver forwardingSolver) external broadcast {
        engine_.setAuthorizedForwarder(address(forwardingSolver), true);
        forwardingSolver.setAuthorizedSolver(_owner(), true);
    }
}
