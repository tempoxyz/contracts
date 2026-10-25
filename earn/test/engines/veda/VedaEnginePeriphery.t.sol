// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { VedaEngine } from "../../../src/engines/veda/VedaEngine.sol";
import { VedaPeripheryRegistry } from "../../../src/engines/veda/VedaPeripheryRegistry.sol";
import { IEarnEngineAsyncRedeem } from "../../../src/interfaces/engines/IEarnEngineAsyncRedeem.sol";
import { IAccountant } from "../../../src/interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringVault } from "../../../src/interfaces/external/veda/IBoringVault.sol";
import { ITeller } from "../../../src/interfaces/external/veda/ITeller.sol";
import { IVedaPeripheryRegistry } from "../../../src/interfaces/external/veda/IVedaPeripheryRegistry.sol";
import {
    MockAccountant,
    MockAsset,
    MockBoringVault,
    MockCore,
    MockQueue,
    MockTeller
} from "../../helpers/VedaEngineMocks.sol";
import { VedaEngineTestBase } from "../../helpers/VedaEngineTestBase.sol";

contract VedaEnginePeripheryTest is VedaEngineTestBase {
    function testRegistryBindsExactlyOneEngine() public {
        assertEq(registry.engine(), address(engine));
        VedaEngine secondEngine = new VedaEngine(
            IVedaPeripheryRegistry(address(registry)), address(this), MAX_RATE_AGE, "Second Wrapper", "vSECOND"
        );

        vm.expectRevert(abi.encodeWithSelector(VedaPeripheryRegistry.EngineAlreadyBound.selector, address(engine)));
        registry.bindEngine(address(secondEngine));
        assertEq(registry.engine(), address(engine));

        MockCore secondCore = new MockCore(asset);
        secondCore.setEngine(secondEngine);
        vm.expectRevert(
            abi.encodeWithSelector(VedaEngine.RegistryEngineMismatch.selector, address(secondEngine), address(engine))
        );
        secondEngine.initializeEarnVault(address(secondCore));
    }

    function testOnlyBoringVaultOwnerCanBindEngine() public {
        VedaPeripheryRegistry unboundRegistry = new VedaPeripheryRegistry(IBoringVault(address(vault)), address(asset));
        unboundRegistry.setVedaPeriphery(
            ITeller(address(teller)), IBoringQueue(address(queue)), IAccountant(address(accountant))
        );
        VedaEngine unboundEngine = new VedaEngine(
            IVedaPeripheryRegistry(address(unboundRegistry)), address(this), MAX_RATE_AGE, "Unbound Wrapper", "vUNBOUND"
        );

        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(VedaPeripheryRegistry.NotBoringVaultOwner.selector, address(0xDEAD), address(this))
        );
        unboundRegistry.bindEngine(address(unboundEngine));

        unboundRegistry.bindEngine(address(unboundEngine));
        assertEq(unboundRegistry.engine(), address(unboundEngine));
    }

    function testPeripheryActivationRejectsStaleAccountant() public {
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(2e6);
        registry.setVedaPeriphery(
            ITeller(address(newTeller)), IBoringQueue(address(newQueue)), IAccountant(address(newAccountant))
        );
        uint64 updatedAt = newAccountant.lastStrategistUpdateTimestamp();
        vm.warp(uint256(updatedAt) + MAX_RATE_AGE + 1);

        vm.expectRevert(
            abi.encodeWithSelector(VedaEngine.StaleAccountantRate.selector, updatedAt, block.timestamp, MAX_RATE_AGE)
        );
        engine.syncVedaPeriphery(1_900_000, 2_100_000);

        assertEq(address(engine.accountant()), address(accountant));
        assertEq(engine.peripheryVersion(), 1);
    }

    function testPeripheryActivationRejectsQueueWithoutTracking() public {
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(2e6);
        newQueue.setTrackWithdrawsOnChain(false);
        registry.setVedaPeriphery(
            ITeller(address(newTeller)), IBoringQueue(address(newQueue)), IAccountant(address(newAccountant))
        );

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.QueueTrackingDisabled.selector, address(newQueue)));
        engine.syncVedaPeriphery(1_900_000, 2_100_000);

        assertEq(address(engine.queue()), address(queue));
        assertEq(engine.peripheryVersion(), 1);
    }

    function testImmediateOnlyDeploymentCanActivateQueueLater() public {
        MockAsset immediateAsset = new MockAsset();
        MockBoringVault immediateVault = new MockBoringVault(address(immediateAsset), 6);
        MockAccountant immediateAccountant = new MockAccountant(immediateVault, address(immediateAsset));
        MockTeller immediateTeller = new MockTeller(immediateVault, immediateAccountant, address(immediateAsset));
        VedaPeripheryRegistry immediateRegistry =
            new VedaPeripheryRegistry(IBoringVault(address(immediateVault)), address(immediateAsset));
        immediateRegistry.setVedaPeriphery(
            ITeller(address(immediateTeller)), IBoringQueue(address(0)), IAccountant(address(immediateAccountant))
        );
        VedaEngine immediateEngine = new VedaEngine(
            IVedaPeripheryRegistry(address(immediateRegistry)),
            address(this),
            MAX_RATE_AGE,
            "Immediate Veda Vault",
            "ivVAULT"
        );
        immediateRegistry.bindEngine(address(immediateEngine));
        MockCore immediateCore = new MockCore(immediateAsset);
        immediateCore.setEngine(immediateEngine);
        immediateEngine.initializeEarnVault(address(immediateCore));
        immediateCore.setDepositsPaused(true);

        assertEq(address(immediateEngine.queue()), address(0));
        assertFalse(immediateEngine.supportsInterface(type(IEarnEngineAsyncRedeem).interfaceId));

        immediateAsset.mint(address(immediateCore), 10);
        assertEq(immediateCore.deposit(10), 10);
        assertEq(immediateCore.redeem(10, receiver, 10), 10);
        assertEq(immediateAsset.balanceOf(receiver), 10);

        immediateVault.mint(address(immediateEngine), 5);
        vm.expectRevert(VedaEngine.QueueUnavailable.selector);
        immediateCore.requestRedeem(5, address(immediateAsset), 0, 3600);
        assertEq(immediateVault.balanceOf(address(immediateEngine)), 5);

        MockQueue enabledQueue = new MockQueue(immediateVault, immediateAccountant);
        immediateRegistry.setVedaPeriphery(
            ITeller(address(immediateTeller)),
            IBoringQueue(address(enabledQueue)),
            IAccountant(address(immediateAccountant))
        );

        immediateCore.setDepositsPaused(false);
        vm.expectRevert(VedaEngine.DepositsNotPaused.selector);
        immediateEngine.syncVedaPeriphery(1e6, 1e6);
        assertEq(address(immediateEngine.queue()), address(0));

        immediateCore.setDepositsPaused(true);
        immediateEngine.syncVedaPeriphery(1e6, 1e6);
        assertEq(address(immediateEngine.queue()), address(enabledQueue));
        assertTrue(immediateEngine.supportsInterface(type(IEarnEngineAsyncRedeem).interfaceId));

        bytes32 id = immediateCore.requestRedeem(5, address(immediateAsset), 0, 3600);
        assertEq(immediateEngine.claimQueue(id), address(enabledQueue));
        assertEq(immediateEngine.openClaimsByQueue(address(enabledQueue)), 1);
    }

    function testQueueRotationPreservesOldClaimCancellationById() public {
        bytes32 id = _request(40);

        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(1e6);
        _rotate(newTeller, newQueue, newAccountant, 1e6, 1e6);

        assertEq(engine.claimQueue(id), address(queue));
        assertEq(engine.openClaimsByQueue(address(queue)), 1);
        assertEq(engine.openClaimsByQueue(address(newQueue)), 0);
        assertEq(core.cancelRedeem(id), 40);
        assertEq(vault.balanceOf(address(engine)), 40);
        assertEq(engine.openClaimsByQueue(address(queue)), 0);
        (VedaEngine.ClaimStatus status,) = engine.getClaim(id);
        assertEq(uint256(status), uint256(VedaEngine.ClaimStatus.Cancelled));
    }

    function testQueueRemovalDisablesNewRequestsButPreservesExistingCancellation() public {
        bytes32 id = _request(40);

        registry.setVedaPeriphery(ITeller(address(teller)), IBoringQueue(address(0)), IAccountant(address(accountant)));
        engine.syncVedaPeriphery(1e6, 1e6);

        assertEq(address(engine.queue()), address(0));
        assertFalse(engine.supportsInterface(type(IEarnEngineAsyncRedeem).interfaceId));
        assertEq(engine.claimQueue(id), address(queue));

        vault.mint(address(engine), 1);
        vm.expectRevert(VedaEngine.QueueUnavailable.selector);
        core.requestRedeem(1, address(asset), 0, 3600);

        assertEq(core.cancelRedeem(id), 40);
        assertEq(engine.openClaimsByQueue(address(queue)), 0);
        (VedaEngine.ClaimStatus status,) = engine.getClaim(id);
        assertEq(uint256(status), uint256(VedaEngine.ClaimStatus.Cancelled));
    }

    function testQueueRotationRejectsActiveCrossQueueRequestIdCollision() public {
        bytes32 id = _request(40);

        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(1e6);
        _rotate(newTeller, newQueue, newAccountant, 1e6, 1e6);

        // A fresh Queue starts its nonce at one. In the same block, identical request terms would
        // produce the same request ID, so the second request must roll back instead of overwriting.
        vault.mint(address(engine), 40);
        vm.expectRevert(abi.encodeWithSelector(VedaEngine.DuplicateRequest.selector, id));
        core.requestRedeem(40, address(asset), 0, 3600);
        assertEq(vault.balanceOf(address(engine)), 40);
        assertEq(engine.claimQueue(id), address(queue));
    }

    function testQueueRotationRejectsHistoricalCrossQueueRequestIdCollision() public {
        bytes32 id = _request(40);
        assertEq(core.cancelRedeem(id), 40);

        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(1e6);
        _rotate(newTeller, newQueue, newAccountant, 1e6, 1e6);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.DuplicateRequest.selector, id));
        core.requestRedeem(40, address(asset), 0, 3600);
        assertEq(vault.balanceOf(address(engine)), 40);
        assertEq(engine.claimQueue(id), address(queue));
    }

    function testOnlyBoringVaultOwnerCanPublishPeriphery() public {
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(1e6);

        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(VedaPeripheryRegistry.NotBoringVaultOwner.selector, address(0xDEAD), address(this))
        );
        registry.setVedaPeriphery(
            ITeller(address(newTeller)), IBoringQueue(address(newQueue)), IAccountant(address(newAccountant))
        );

        vault.transferOwnership(address(0xDEAD));
        vm.prank(address(0xDEAD));
        registry.setVedaPeriphery(
            ITeller(address(newTeller)), IBoringQueue(address(newQueue)), IAccountant(address(newAccountant))
        );
        assertEq(registry.version(), 2);
    }

    function testSyncVedaPeripheryRejectsRateOutsideOwnerBounds() public {
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(2e6);
        registry.setVedaPeriphery(
            ITeller(address(newTeller)), IBoringQueue(address(newQueue)), IAccountant(address(newAccountant))
        );

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.VedaRateOutOfBounds.selector, 2e6, 900_000, 1_100_000));
        engine.syncVedaPeriphery(900_000, 1_100_000);
    }

    function testRegistryRejectsMismatchedPeriphery() public {
        MockAsset otherAsset = new MockAsset();
        MockAccountant wrongAccountant = new MockAccountant(vault, address(otherAsset));
        MockTeller wrongTeller = new MockTeller(vault, wrongAccountant, address(asset));
        MockQueue wrongQueue = new MockQueue(vault, wrongAccountant);

        vm.expectRevert(
            abi.encodeWithSelector(
                VedaPeripheryRegistry.InvalidVedaPeripheryWiring.selector,
                address(wrongAccountant),
                address(asset),
                address(otherAsset)
            )
        );
        registry.setVedaPeriphery(
            ITeller(address(wrongTeller)), IBoringQueue(address(wrongQueue)), IAccountant(address(wrongAccountant))
        );
    }

    function testInitializeEarnVaultRequiresRegistryBinding() public {
        VedaPeripheryRegistry unboundRegistry = new VedaPeripheryRegistry(IBoringVault(address(vault)), address(asset));
        unboundRegistry.setVedaPeriphery(
            ITeller(address(teller)), IBoringQueue(address(queue)), IAccountant(address(accountant))
        );
        VedaEngine unboundEngine = new VedaEngine(
            IVedaPeripheryRegistry(address(unboundRegistry)), address(this), MAX_RATE_AGE, "Unbound Wrapper", "vUNBOUND"
        );
        MockCore unboundCore = new MockCore(asset);
        unboundCore.setEngine(unboundEngine);

        vm.expectRevert(
            abi.encodeWithSelector(VedaEngine.RegistryEngineMismatch.selector, address(unboundEngine), address(0))
        );
        unboundEngine.initializeEarnVault(address(unboundCore));

        unboundRegistry.bindEngine(address(unboundEngine));
        unboundEngine.initializeEarnVault(address(unboundCore));
        assertEq(unboundEngine.earnVault(), address(unboundCore));
    }

    function testSyncVedaPeripheryIsWrapperOwnerOnly() public {
        (MockAccountant newAccountant, MockTeller newTeller, MockQueue newQueue) = _newPeriphery(1e6);
        registry.setVedaPeriphery(
            ITeller(address(newTeller)), IBoringQueue(address(newQueue)), IAccountant(address(newAccountant))
        );

        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xDEAD)));
        engine.syncVedaPeriphery(1e6, 1e6);
    }
}
