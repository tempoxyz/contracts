// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";

import { EarnVault } from "../../../../src/earn/core/EarnVault.sol";
import { VedaEngine } from "../../../../src/earn/engines/veda/VedaEngine.sol";
import { VedaPeripheryRegistry } from "../../../../src/earn/engines/veda/VedaPeripheryRegistry.sol";
import { IAccountant } from "../../../../src/interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringVault } from "../../../../src/interfaces/external/veda/IBoringVault.sol";
import { ITeller } from "../../../../src/interfaces/external/veda/ITeller.sol";
import { IVedaPeripheryRegistry } from "../../../../src/interfaces/external/veda/IVedaPeripheryRegistry.sol";
import { VedaRedeemRequest } from "../../../../src/interfaces/external/veda/VedaTypes.sol";
import { CoreMockToken, earnVaultTestNoFees } from "../../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../../helpers/EarnVaultTestDeployer.sol";
import { MockAccountant, MockAsset, MockBoringVault, MockQueue, MockTeller } from "../../helpers/VedaEngineMocks.sol";

/// @dev An async receiver whose finalize hook uses all the gas it is given.
contract GasBurningReceiver {
    uint256 public calls;

    function onRedeemFinalized(bytes32, address, uint256) external {
        while (true) {
            calls++;
        }
    }
}

/// @dev A solved batch over a real EarnVault, whose finalize calls each contract receiver's hook.
contract VedaEngineReceiverHookTest is Test {
    uint64 internal constant MAX_RATE_AGE = 1 days;
    uint128 internal constant AMOUNT = 1_000_000;

    MockAsset internal asset;
    MockBoringVault internal vault;
    MockAccountant internal accountant;
    MockQueue internal queue;
    VedaEngine internal engine;
    EarnVault internal earnVault;
    address internal user = address(0xA11CE);
    address internal receiver = address(0xB0B);

    function setUp() public {
        asset = new MockAsset();
        vault = new MockBoringVault(address(asset), 6);
        accountant = new MockAccountant(vault, address(asset));
        MockTeller teller = new MockTeller(vault, accountant, address(asset));
        queue = new MockQueue(vault, accountant);
        VedaPeripheryRegistry registry = new VedaPeripheryRegistry(IBoringVault(address(vault)), address(asset));
        registry.setVedaPeriphery(
            ITeller(address(teller)), IBoringQueue(address(queue)), IAccountant(address(accountant))
        );
        engine = new VedaEngine(
            IVedaPeripheryRegistry(address(registry)), address(this), MAX_RATE_AGE, "Veda Vault", "vVAULT"
        );
        registry.bindEngine(address(engine));
        CoreMockToken earnShare = new CoreMockToken("Earn Share", "EARN", 6);
        earnVault =
            EarnVaultTestDeployer.deploy(address(engine), address(earnShare), address(this), earnVaultTestNoFees());
        engine.initializeEarnVault(address(earnVault));
        engine.setAuthorizedForwarder(address(this), true);

        asset.mint(user, 10 * AMOUNT);
        vm.startPrank(user);
        asset.approve(address(earnVault), type(uint256).max);
        earnShare.approve(address(earnVault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Each payout in a batch runs with capped gas, so a receiver whose hook burns everything it gets costs
    ///      the batch at most that cap: both claims are paid and the solve stays far below the gas it was given.
    function testGasBurningReceiverCannotTakeTheBatchGas() public {
        GasBurningReceiver burner = new GasBurningReceiver();
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = _request(address(burner));
        ids[1] = _request(receiver);
        asset.mint(address(engine), 2 * AMOUNT);

        uint256 gasBefore = gasleft();
        uint256 claimed = engine.forwardSolved{ gas: 30_000_000 }(ids, address(asset), 2 * AMOUNT);
        uint256 used = gasBefore - gasleft();

        assertEq(claimed, 2);
        assertLt(used, 2_500_000, "one payout's gas is capped");
        assertEq(asset.balanceOf(address(burner)), AMOUNT);
        assertEq(asset.balanceOf(receiver), AMOUNT);
        assertEq(earnVault.openRedeemRequestCount(), 0);
        assertEq(engine.unresolvedClaimCount(), 0);
        for (uint256 i = 0; i < ids.length; i++) {
            (VedaEngine.ClaimStatus status,) = engine.getClaim(ids[i]);
            assertEq(uint256(status), uint256(VedaEngine.ClaimStatus.Paid));
        }
    }

    function _request(address receiver_) internal returns (bytes32 requestId) {
        vm.startPrank(user);
        uint256 shares = earnVault.deposit(AMOUNT, user, 1);
        requestId = earnVault.requestRedeem(
            shares,
            abi.encode(
                VedaRedeemRequest({
                    assetOut: address(asset), discountBps: 0, secondsToDeadline: 3600, minQueuedAssets: 1
                })
            ),
            receiver_
        );
        vm.stopPrank();
    }
}
