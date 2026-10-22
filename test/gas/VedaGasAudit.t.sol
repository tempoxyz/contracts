// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test, console2 } from "forge-std/Test.sol";

import { EarnVault } from "../../src/core/EarnVault.sol";
import { VedaEngine } from "../../src/engines/veda/VedaEngine.sol";
import { IForwardingEngine, VedaForwardingSolver } from "../../src/engines/veda/VedaForwardingSolver.sol";
import { VedaPeripheryRegistry } from "../../src/engines/veda/VedaPeripheryRegistry.sol";
import { IAccountant } from "../../src/interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../src/interfaces/external/veda/IBoringSolver.sol";
import { IBoringVault } from "../../src/interfaces/external/veda/IBoringVault.sol";
import { ITeller } from "../../src/interfaces/external/veda/ITeller.sol";
import { IVedaPeripheryRegistry } from "../../src/interfaces/external/veda/IVedaPeripheryRegistry.sol";
import { OnChainWithdraw, VedaRedeemRequest } from "../../src/interfaces/external/veda/VedaTypes.sol";
import { CoreMockToken, earnVaultTestNoFees } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";
import { MockAccountant, MockAsset, MockBoringVault, MockQueue, MockTeller } from "../helpers/VedaEngineMocks.sol";

contract AuditBoringSolver {
    MockAsset public immutable asset;

    constructor(MockAsset asset_) {
        asset = asset_;
    }

    function boringRedeemSolve(OnChainWithdraw[] calldata requests, address, bool) external {
        for (uint256 i = 0; i < requests.length; i++) {
            asset.mint(requests[i].user, requests[i].amountOfAssets);
        }
    }
}

abstract contract VedaAuditFixture is Test {
    uint64 internal constant MAX_RATE_AGE = 1 days;
    uint128 internal constant ACTION_AMOUNT = 1_000_000;

    MockAsset internal asset;
    MockBoringVault internal vault;
    MockAccountant internal accountant;
    MockTeller internal teller;
    MockQueue internal queue;
    VedaPeripheryRegistry internal registry;
    VedaEngine internal engine;
    AuditBoringSolver internal boringSolver;
    VedaForwardingSolver internal forwardingSolver;

    function _deployEngine(address earnVault_) internal {
        asset = new MockAsset();
        vault = new MockBoringVault(address(asset), 6);
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
        engine.initializeEarnVault(earnVault_);

        boringSolver = new AuditBoringSolver(asset);
        forwardingSolver = new VedaForwardingSolver(
            IBoringSolver(address(boringSolver)),
            IBoringQueue(address(queue)),
            address(teller),
            IForwardingEngine(address(engine)),
            address(this),
            address(this)
        );
        forwardingSolver.setAuthorizedSolver(address(this), true);
        engine.setAuthorizedForwarder(address(this), true);
        engine.setAuthorizedForwarder(address(forwardingSolver), true);
    }

    function _queueRequest(bytes32 requestId) internal view returns (OnChainWithdraw memory request) {
        return queue.getOnChainWithdraw(requestId);
    }

    function _requestData() internal view returns (bytes memory) {
        return abi.encode(
            VedaRedeemRequest({ assetOut: address(asset), discountBps: 0, secondsToDeadline: 3600, minQueuedAssets: 1 })
        );
    }

    function _ids(bytes32 requestId) internal pure returns (bytes32[] memory requestIds) {
        requestIds = new bytes32[](1);
        requestIds[0] = requestId;
    }

    function _startMeasure() internal returns (uint256 gasBefore) {
        vm.resumeGasMetering();
        gasBefore = gasleft();
    }

    function _stopMeasure(string memory label, uint256 gasBefore) internal {
        uint256 rawGas = gasBefore - gasleft();
        vm.pauseGasMetering();
        console2.log(label, rawGas);
    }
}

contract VedaEngineGasAudit is VedaAuditFixture {
    bool public depositsPaused = true;
    bool internal revertFinalize;

    function setUp() public {
        _deployEngine(address(this));
        asset.mint(address(this), 100 * ACTION_AMOUNT);
        asset.approve(address(engine), type(uint256).max);
    }

    function finalizeRedeem(bytes32, address, uint256) external view {
        require(!revertFinalize, "FINALIZE");
    }

    function testGasEngineDeposit() public {
        vm.pauseGasMetering();
        uint256 gasBefore = _startMeasure();
        uint256 shares = engine.deposit(ACTION_AMOUNT);
        _stopMeasure("engine.deposit", gasBefore);
        assertEq(shares, ACTION_AMOUNT);
    }

    function testGasEngineRedeem() public {
        vm.pauseGasMetering();
        engine.deposit(ACTION_AMOUNT);
        uint256 gasBefore = _startMeasure();
        uint256 assets = engine.redeem(ACTION_AMOUNT, address(0xB0B), ACTION_AMOUNT);
        _stopMeasure("engine.redeem", gasBefore);
        assertEq(assets, ACTION_AMOUNT);
    }

    function testGasEngineWithdrawExact() public {
        vm.pauseGasMetering();
        engine.deposit(ACTION_AMOUNT);
        uint256 gasBefore = _startMeasure();
        uint256 shares = engine.withdraw(ACTION_AMOUNT / 2, address(0xB0B));
        _stopMeasure("engine.withdrawExact", gasBefore);
        assertEq(shares, ACTION_AMOUNT / 2);
    }

    function testGasEngineRequestRedeem() public {
        vm.pauseGasMetering();
        engine.deposit(ACTION_AMOUNT);
        uint256 gasBefore = _startMeasure();
        bytes32 requestId = engine.requestRedeem(ACTION_AMOUNT, _requestData());
        _stopMeasure("engine.requestRedeem", gasBefore);
        assertTrue(requestId != bytes32(0));
    }

    function testGasEngineCancelRedeem() public {
        vm.pauseGasMetering();
        engine.deposit(ACTION_AMOUNT);
        bytes32 requestId = engine.requestRedeem(ACTION_AMOUNT, _requestData());

        uint256 gasBefore = _startMeasure();
        uint256 shares = engine.cancelRedeem(requestId);
        _stopMeasure("engine.cancelRedeem", gasBefore);
        assertEq(shares, ACTION_AMOUNT);
    }

    function testGasEngineForwardSolvedOne() public {
        vm.pauseGasMetering();
        bytes32 requestId = _prepareClaims(1)[0];
        asset.mint(address(engine), ACTION_AMOUNT);

        uint256 gasBefore = _startMeasure();
        uint256 claimed = engine.forwardSolved(_ids(requestId), address(asset), ACTION_AMOUNT);
        _stopMeasure("engine.forwardSolved.1", gasBefore);
        assertEq(claimed, 1);
    }

    function testGasEngineForwardSolvedFive() public {
        vm.pauseGasMetering();
        bytes32[] memory requestIds = _prepareClaims(5);
        asset.mint(address(engine), 5 * ACTION_AMOUNT);

        uint256 gasBefore = _startMeasure();
        uint256 claimed = engine.forwardSolved(requestIds, address(asset), 5 * ACTION_AMOUNT);
        _stopMeasure("engine.forwardSolved.5", gasBefore);
        assertEq(claimed, 5);
    }

    function testGasEngineForwardSolvedTen() public {
        vm.pauseGasMetering();
        bytes32[] memory requestIds = _prepareClaims(10);
        asset.mint(address(engine), 10 * ACTION_AMOUNT);

        uint256 gasBefore = _startMeasure();
        uint256 claimed = engine.forwardSolved(requestIds, address(asset), 10 * ACTION_AMOUNT);
        _stopMeasure("engine.forwardSolved.10", gasBefore);
        assertEq(claimed, 10);
    }

    function testGasForwardingSolverOne() public {
        vm.pauseGasMetering();
        bytes32 requestId = _prepareClaims(1)[0];

        uint256 gasBefore = _startMeasure();
        uint256 claimed = forwardingSolver.solveAndForward(_ids(requestId), false);
        _stopMeasure("forwardingSolver.solveAndForward.1", gasBefore);
        assertEq(claimed, 1);
    }

    function testGasForwardingSolverFive() public {
        vm.pauseGasMetering();
        bytes32[] memory requestIds = _prepareClaims(5);

        uint256 gasBefore = _startMeasure();
        uint256 claimed = forwardingSolver.solveAndForward(requestIds, false);
        _stopMeasure("forwardingSolver.solveAndForward.5", gasBefore);
        assertEq(claimed, 5);
    }

    function testGasForwardingSolverTen() public {
        vm.pauseGasMetering();
        bytes32[] memory requestIds = _prepareClaims(10);

        uint256 gasBefore = _startMeasure();
        uint256 claimed = forwardingSolver.solveAndForward(requestIds, false);
        _stopMeasure("forwardingSolver.solveAndForward.10", gasBefore);
        assertEq(claimed, 10);
    }

    function testGasEngineClaimRedeemRecovery() public {
        vm.pauseGasMetering();
        bytes32 requestId = _prepareClaims(1)[0];
        asset.mint(address(engine), ACTION_AMOUNT);
        revertFinalize = true;
        engine.forwardSolved(_ids(requestId), address(asset), ACTION_AMOUNT);
        revertFinalize = false;

        uint256 gasBefore = _startMeasure();
        uint256 assets = engine.claimRedeem(requestId);
        _stopMeasure("engine.claimRedeem", gasBefore);
        assertEq(assets, ACTION_AMOUNT);
    }

    function _prepareClaims(uint256 count) internal returns (bytes32[] memory requestIds) {
        requestIds = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            vault.mint(address(engine), ACTION_AMOUNT);
            requestIds[i] = engine.requestRedeem(ACTION_AMOUNT, _requestData());
        }
    }
}

contract VedaFullStackGasAudit is VedaAuditFixture {
    CoreMockToken internal earnShare;
    EarnVault internal earnVault;
    address internal user = address(0xA11CE);
    address internal receiver = address(0xB0B);

    function setUp() public {
        // The engine must exist before the EarnVault and is bound after the proxy is initialized.
        asset = new MockAsset();
        vault = new MockBoringVault(address(asset), 6);
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
        earnShare = new CoreMockToken("Earn Share", "EARN", 6);
        earnVault =
            EarnVaultTestDeployer.deploy(address(engine), address(earnShare), address(this), earnVaultTestNoFees());
        engine.initializeEarnVault(address(earnVault));

        boringSolver = new AuditBoringSolver(asset);
        forwardingSolver = new VedaForwardingSolver(
            IBoringSolver(address(boringSolver)),
            IBoringQueue(address(queue)),
            address(teller),
            IForwardingEngine(address(engine)),
            address(this),
            address(this)
        );
        forwardingSolver.setAuthorizedSolver(address(this), true);
        engine.setAuthorizedForwarder(address(forwardingSolver), true);

        asset.mint(user, 100 * ACTION_AMOUNT);
        vm.startPrank(user);
        asset.approve(address(earnVault), type(uint256).max);
        earnShare.approve(address(earnVault), type(uint256).max);
        vm.stopPrank();
    }

    function testGasFullFirstDeposit() public {
        vm.pauseGasMetering();
        vm.prank(user);
        uint256 gasBefore = _startMeasure();
        uint256 shares = earnVault.deposit(ACTION_AMOUNT, user, 1);
        _stopMeasure("full.deposit.first", gasBefore);
        assertEq(shares, ACTION_AMOUNT);
    }

    function testGasFullSteadyDeposit() public {
        vm.pauseGasMetering();
        _depositForUser(ACTION_AMOUNT);
        vm.prank(user);
        uint256 gasBefore = _startMeasure();
        uint256 shares = earnVault.deposit(ACTION_AMOUNT, user, 1);
        _stopMeasure("full.deposit.steady", gasBefore);
        assertEq(shares, ACTION_AMOUNT);
    }

    function testGasFullRedeem() public {
        vm.pauseGasMetering();
        _depositForUser(ACTION_AMOUNT);
        vm.prank(user);
        uint256 gasBefore = _startMeasure();
        uint256 assets = earnVault.redeem(ACTION_AMOUNT, receiver, ACTION_AMOUNT);
        _stopMeasure("full.redeem", gasBefore);
        assertEq(assets, ACTION_AMOUNT);
    }

    function testGasFullWithdrawExact() public {
        vm.pauseGasMetering();
        _depositForUser(ACTION_AMOUNT);
        vm.prank(user);
        uint256 gasBefore = _startMeasure();
        uint256 shares = earnVault.withdrawExact(ACTION_AMOUNT / 2, receiver, ACTION_AMOUNT);
        _stopMeasure("full.withdrawExact", gasBefore);
        assertEq(shares, ACTION_AMOUNT / 2);
    }

    function testGasFullRequestRedeem() public {
        vm.pauseGasMetering();
        _depositForUser(ACTION_AMOUNT);
        vm.prank(user);
        uint256 gasBefore = _startMeasure();
        bytes32 requestId = earnVault.requestRedeem(ACTION_AMOUNT, _requestData(), receiver);
        _stopMeasure("full.requestRedeem", gasBefore);
        assertTrue(requestId != bytes32(0));
    }

    function testGasFullCancelRedeem() public {
        vm.pauseGasMetering();
        bytes32 requestId = _fullRequest(ACTION_AMOUNT);
        vm.prank(user);
        uint256 gasBefore = _startMeasure();
        earnVault.cancelRedeem(requestId, 1);
        _stopMeasure("full.cancelRedeem", gasBefore);
        assertEq(earnShare.balanceOf(receiver), ACTION_AMOUNT);
    }

    function testGasFullSolveAndForwardOne() public {
        vm.pauseGasMetering();
        bytes32 requestId = _fullRequest(ACTION_AMOUNT);

        uint256 gasBefore = _startMeasure();
        uint256 claimed = forwardingSolver.solveAndForward(_ids(requestId), false);
        _stopMeasure("full.solveAndForward.1", gasBefore);
        assertEq(claimed, 1);
    }

    function testGasFullSolveAndForwardFive() public {
        vm.pauseGasMetering();
        bytes32[] memory requestIds = new bytes32[](5);
        for (uint256 i = 0; i < requestIds.length; i++) {
            requestIds[i] = _fullRequest(ACTION_AMOUNT);
        }

        uint256 gasBefore = _startMeasure();
        uint256 claimed = forwardingSolver.solveAndForward(requestIds, false);
        _stopMeasure("full.solveAndForward.5", gasBefore);
        assertEq(claimed, 5);
    }

    function _depositForUser(uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = earnVault.deposit(assets, user, 1);
    }

    function _fullRequest(uint128 earnShares) internal returns (bytes32 requestId) {
        _depositForUser(earnShares);
        vm.prank(user);
        requestId = earnVault.requestRedeem(earnShares, _requestData(), receiver);
    }
}
