// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { VedaEngine } from "../../src/engines/veda/VedaEngine.sol";
import { VedaPeripheryRegistry } from "../../src/engines/veda/VedaPeripheryRegistry.sol";
import { IAccountant } from "../../src/interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringVault } from "../../src/interfaces/external/veda/IBoringVault.sol";
import { ITeller } from "../../src/interfaces/external/veda/ITeller.sol";
import { IVedaPeripheryRegistry } from "../../src/interfaces/external/veda/IVedaPeripheryRegistry.sol";
import { MockAccountant, MockAsset, MockBoringVault, MockCore, MockQueue, MockTeller } from "./VedaEngineMocks.sol";

abstract contract VedaEngineTestBase is Test {
    uint64 internal constant MAX_RATE_AGE = 1 days;

    MockAsset asset;
    MockBoringVault vault;
    MockAccountant accountant;
    MockTeller teller;
    MockQueue queue;
    VedaPeripheryRegistry registry;
    VedaEngine engine;
    MockCore core;
    address receiver = address(0xB0B);

    function setUp() public virtual {
        _deployVedaStack(6);
        core = new MockCore(asset);
        core.setEngine(engine);
        engine.initializeEarnVault(address(core));
        core.setDepositsPaused(true);
        engine.setAuthorizedForwarder(address(this), true);
    }

    /// @dev Deploys a fresh asset, a BoringVault with `decimals`-decimal shares, its full periphery, and an engine
    /// owned by this test and bound to the registry. The caller binds the engine to an EarnVault.
    function _deployVedaStack(uint8 decimals) internal {
        asset = new MockAsset();
        vault = new MockBoringVault(address(asset), decimals);
        accountant = new MockAccountant(vault, address(asset));
        teller = new MockTeller(vault, accountant, address(asset));
        queue = new MockQueue(vault, accountant);
        registry = new VedaPeripheryRegistry(IBoringVault(address(vault)), address(asset));
        registry.setVedaPeriphery(
            ITeller(address(teller)), IBoringQueue(address(queue)), IAccountant(address(accountant))
        );
        engine = new VedaEngine(
            IVedaPeripheryRegistry(address(registry)), address(this), MAX_RATE_AGE, "Veda Vault", "vVAULT"
        );
        registry.bindEngine(address(engine));
    }

    function _newPeriphery(uint256 rate_)
        internal
        returns (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue)
    {
        newAccountant = new MockAccountant(vault, address(asset));
        newAccountant.setRate(rate_);
        newTeller = new MockTeller(vault, newAccountant, address(asset));
        newQueue = new MockQueue(vault, newAccountant);
    }

    function _rotate(
        MockTeller newTeller,
        MockQueue newQueue,
        MockAccountant newAccountant,
        uint256 minRate,
        uint256 maxRate
    ) internal {
        registry.setVedaPeriphery(
            ITeller(address(newTeller)), IBoringQueue(address(newQueue)), IAccountant(address(newAccountant))
        );
        engine.syncVedaPeriphery(minRate, maxRate);
    }

    function _request(uint128 shares) internal returns (bytes32 id) {
        vault.mint(address(engine), shares);
        id = core.requestRedeem(shares, address(asset), 0, 3600);
    }

    function _ids(bytes32 id) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = id;
    }
}
