// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { FeeConfig, FixedFeeRecipient } from "../../src/interfaces/core/EarnFeeTypes.sol";
import { IEarnFees } from "../../src/interfaces/core/IEarnFees.sol";
import { IEarnEngine } from "../../src/interfaces/engines/IEarnEngine.sol";
import { IEarnEngineAsyncRedeem } from "../../src/interfaces/engines/IEarnEngineAsyncRedeem.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {
    CoreMockAsyncEngine,
    CoreMockToken,
    RecordingRedeemReceiver,
    earnVaultTestNoFees
} from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

contract CoarseAsyncEngine {
    uint256 internal constant ASSETS_PER_SHARE = 10_000;

    CoreMockToken public immutable assetToken;
    EarnVault public core;
    uint256 public heldShares;
    uint96 private _nonce;
    mapping(bytes32 requestId => uint256 shares) public requestShares;
    mapping(bytes32 requestId => bool open) public requestOpen;

    constructor(CoreMockToken asset_) {
        assetToken = asset_;
    }

    function setCore(EarnVault core_) external {
        core = core_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function shareScale() external pure returns (uint256) {
        return 1;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        require(assetToken.transferFrom(msg.sender, address(this), assets), "TRANSFER");
        shares = assets / ASSETS_PER_SHARE;
        require(shares != 0, "ZERO_SHARES");
        heldShares += shares;
    }

    function totalShares() external view returns (uint256) {
        return heldShares;
    }

    function totalAssets() external view returns (uint256) {
        return heldShares * ASSETS_PER_SHARE;
    }

    function valueOf(uint256 shares) external pure returns (uint256) {
        return shares * ASSETS_PER_SHARE;
    }

    function requestRedeem(uint256 shares, bytes calldata) external returns (bytes32 requestId) {
        require(msg.sender == address(core), "NOT_CORE");
        require(heldShares >= shares, "SHARES");
        heldShares -= shares;
        requestId = keccak256(abi.encode(address(this), _nonce++));
        requestShares[requestId] = shares;
        requestOpen[requestId] = true;
    }

    function cancelRedeem(bytes32 requestId) external returns (uint256 shares) {
        require(msg.sender == address(core), "NOT_CORE");
        require(requestOpen[requestId], "NOT_OPEN");
        requestOpen[requestId] = false;
        shares = requestShares[requestId];
        heldShares += shares;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IEarnEngine).interfaceId
            || interfaceId == type(IEarnEngineAsyncRedeem).interfaceId;
    }
}

contract EarnVaultAsyncTest is Test {
    CoreMockToken asset;
    CoreMockToken share;
    CoreMockAsyncEngine engine;
    EarnVault core;
    address user = address(0xA11CE);
    address receiver = address(0xB0B);
    address operator = address(0x0FF1CE);

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        share = new CoreMockToken("Share", "SH", 18);
        engine = new CoreMockAsyncEngine(asset);
        core = EarnVaultTestDeployer.deploy(address(engine), address(share), operator, earnVaultTestNoFees());
        engine.setCore(core);
        asset.mint(user, 100 ether);
    }

    function testAsyncBurnAtRequestInvariantAcrossRequestFinalizeCancel() public {
        _deposit(10 ether);

        vm.startPrank(user);
        share.approve(address(core), type(uint256).max);
        bytes32 finalizeId = core.requestRedeem(4 ether, "", receiver);
        vm.stopPrank();

        // The request burns EarnShare immediately and removes the queued backing from the active pool.
        assertEq(core.openRedeemRequestCount(), 1);
        assertEq(core.engineShares(), 6 ether);
        assertEq(core.totalEarnShares(), 6 ether);
        assertEq(share.balanceOf(address(core)), 0);
        assertTrue(core.isAccountingAligned());
        EarnVault.PendingRedeem memory pending = core.pendingRedeem(finalizeId);
        assertEq(pending.receiver, receiver);
        assertEq(pending.requester, user);
        assertEq(pending.burnedEarnShares, 4 ether);
        assertEq(pending.engineShares, 4 ether);
        assertTrue(pending.open);

        // Finalize pays the receiver and closes the already-burned pending claim.
        asset.mint(address(engine), 4 ether);
        engine.solve(finalizeId, 4 ether);
        assertEq(core.openRedeemRequestCount(), 0);
        assertEq(core.totalEarnShares(), 6 ether);
        assertEq(core.engineShares(), 6 ether);
        assertEq(asset.balanceOf(receiver), 4 ether);
        assertEq(share.balanceOf(address(core)), 0);
        assertTrue(core.isAccountingAligned());

        // A second request, then cancel: current-value shares mint to the receiver.
        vm.prank(user);
        bytes32 cancelId = core.requestRedeem(2 ether, "", receiver);
        assertEq(core.openRedeemRequestCount(), 1);
        assertEq(core.engineShares(), 4 ether);
        assertTrue(core.isAccountingAligned());

        vm.prank(user);
        core.cancelRedeem(cancelId, 2 ether);
        assertEq(core.openRedeemRequestCount(), 0);
        assertEq(core.engineShares(), 6 ether);
        assertEq(share.balanceOf(receiver), 2 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testFinalizeSucceedsEvenWhenReceiverCallbackReverts() public {
        RecordingRedeemReceiver recv = new RecordingRedeemReceiver();
        recv.setRevertInCallback(true);
        _deposit(10 ether);

        vm.startPrank(user);
        share.approve(address(core), type(uint256).max);
        bytes32 id = core.requestRedeem(5 ether, "", address(recv));
        vm.stopPrank();

        asset.mint(address(engine), 5 ether);
        engine.solve(id, 5 ether); // must not revert despite the receiver callback reverting
        assertEq(asset.balanceOf(address(recv)), 5 ether); // assets still delivered
        assertEq(core.totalEarnShares(), 5 ether); // request-time burn remains final
        assertEq(recv.lastFinalizedId(), bytes32(0)); // callback did revert
        assertTrue(core.isAccountingAligned());
    }

    function testCancelIsRequesterOrJanitorOnly() public {
        _deposit(10 ether);
        vm.startPrank(user);
        share.approve(address(core), type(uint256).max);
        bytes32 id = core.requestRedeem(4 ether, "", receiver);
        vm.stopPrank();

        vm.prank(address(0xDEAD));
        vm.expectRevert(EarnVault.NotRequesterOrJanitor.selector);
        core.cancelRedeem(id, 4 ether);

        // The default test helper assigns the operator as the async janitor.
        vm.prank(operator);
        core.cancelRedeem(id, 4 ether);
        assertEq(core.openRedeemRequestCount(), 0);
        assertEq(share.balanceOf(receiver), 4 ether);
    }

    function testCancellationRequiresAndEnforcesReceiverMinimum() public {
        _deposit(10 ether);
        vm.startPrank(user);
        share.approve(address(core), type(uint256).max);
        bytes32 id = core.requestRedeem(4 ether, "", receiver);

        vm.expectRevert(EarnVault.ZeroMinimumEarnShares.selector);
        core.cancelRedeem(id, 0);

        vm.expectRevert(abi.encodeWithSelector(EarnVault.MinimumEarnSharesNotMet.selector, 4 ether + 1, 4 ether));
        core.cancelRedeem(id, 4 ether + 1);
        vm.stopPrank();

        assertTrue(core.pendingRedeem(id).open);
        assertEq(core.openRedeemRequestCount(), 1);
        assertEq(core.engineShares(), 6 ether);
        assertEq(share.balanceOf(receiver), 0);
    }

    function testFinalizeOnlyEngineAndRejectsClosedRequests() public {
        _deposit(10 ether);
        vm.startPrank(user);
        share.approve(address(core), type(uint256).max);
        bytes32 id = core.requestRedeem(4 ether, "", receiver);
        vm.stopPrank();

        vm.expectRevert(EarnVault.NotEngine.selector);
        core.finalizeRedeem(id, address(asset), 4 ether);

        // Finalize once, then a second finalize / cancel must revert RequestNotOpen (idempotent).
        asset.mint(address(engine), 4 ether);
        engine.solve(id, 4 ether);
        vm.expectRevert(abi.encodeWithSelector(EarnVault.RequestNotOpen.selector, id));
        vm.prank(user);
        core.cancelRedeem(id, 1);
    }

    function testFinalizeRejectsUnexpectedAssetWithoutClosingRequest() public {
        _deposit(10 ether);
        vm.startPrank(user);
        share.approve(address(core), type(uint256).max);
        bytes32 id = core.requestRedeem(4 ether, "", receiver);
        vm.stopPrank();

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(EarnVault.FinalizedAssetMismatch.selector, address(share)));
        core.finalizeRedeem(id, address(share), 4 ether);

        assertTrue(core.pendingRedeem(id).open);
        assertEq(core.openRedeemRequestCount(), 1);
    }

    function testMigrateRevertsWhileAsyncRequestsPending() public {
        _deposit(10 ether);
        vm.startPrank(user);
        share.approve(address(core), type(uint256).max);
        core.requestRedeem(4 ether, "", receiver);
        vm.stopPrank();

        // An open async exit blocks migration: in-flight queued shares cannot be re-homed atomically.
        // The guard fires before the new engine is ever touched, so the arbitrary target is never called.
        vm.prank(operator);
        vm.expectRevert(EarnVault.PendingRedeemsOpen.selector);
        core.migrateEngine(address(0xBEEF), 1, 1);
    }

    function testContributionWhileAsyncRequestOpenBenefitsOnlyActivePool() public {
        _deposit(10 ether);
        vm.startPrank(user);
        share.approve(address(core), type(uint256).max);
        bytes32 requestId = core.requestRedeem(4 ether, "", receiver);
        asset.approve(address(core), type(uint256).max);
        core.contribute(1 ether);
        vm.stopPrank();

        assertEq(core.engineShares(), 7 ether);
        assertEq(core.totalEarnShares(), 6 ether);

        vm.prank(user);
        core.cancelRedeem(requestId, uint256(24 ether) / 7);
        assertEq(share.balanceOf(receiver), uint256(24 ether) / 7);
        assertEq(core.engineShares(), 11 ether - 1);
        assertEq(core.rawEngineShares(), 11 ether);
        assertEq(core.surplusEngineShares(), 1);
        assertTrue(core.isAccountingAligned());
    }

    function testFullCancellationDoesNotRatchetRewardRateBaseline() public {
        _deposit(1 ether);

        vm.startPrank(user);
        share.approve(address(core), type(uint256).max);
        core.contribute(99 ether);
        bytes32 firstRequest = core.requestRedeem(1 ether, "", user);
        core.cancelRedeem(firstRequest, 1 ether);
        bytes32 secondRequest = core.requestRedeem(1 ether, "", user);
        core.cancelRedeem(secondRequest, 1 ether);
        vm.stopPrank();

        assertEq(core.normalizedRewardRate(), 100 ether);
        assertEq(core.rewardRateBaseline(), 1 ether);

        address contributor = address(0xC0FFEE);
        asset.mint(contributor, 1);
        vm.startPrank(contributor);
        asset.approve(address(core), 1);
        vm.expectRevert(abi.encodeWithSelector(EarnVault.RewardRateLimitExceeded.selector, 100 ether + 1, 1 ether));
        core.contribute(1);
        vm.stopPrank();

        assertEq(core.engineShares(), 100 ether);
        assertEq(core.totalEarnShares(), 1 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testContributionCapPreventsCoarseCancellationReentry() public {
        address attacker = address(0xBAD);
        _deposit(10 ether);

        vm.startPrank(user);
        share.approve(address(core), type(uint256).max);
        bytes32 requestId = core.requestRedeem(10 ether, "", receiver);
        vm.stopPrank();
        assertEq(core.totalEarnShares(), 0);
        assertEq(core.engineShares(), 0);

        asset.mint(attacker, 9 ether + 1);
        vm.startPrank(attacker);
        asset.approve(address(core), type(uint256).max);
        core.deposit(1, attacker, 1);
        vm.expectRevert(
            abi.encodeWithSelector(EarnVault.RewardRateLimitExceeded.selector, (9 ether + 1) * 1 ether, 1 ether)
        );
        core.contribute(9 ether);
        vm.stopPrank();
        assertEq(core.totalEarnShares(), 1);
        assertEq(core.engineShares(), 1);

        vm.prank(user);
        core.cancelRedeem(requestId, 1);

        assertFalse(core.pendingRedeem(requestId).open);
        assertEq(core.openRedeemRequestCount(), 0);
        assertEq(core.engineShares(), 10 ether + 1);
        assertEq(share.balanceOf(receiver), 10 ether);
    }

    function testCancellationUsesSnapshottedFeeTermsAndCurrentReturnedValue() public {
        address feeRecipient = address(0xFEE);
        (CoreMockToken feeAsset, CoreMockToken feeShare, CoreMockAsyncEngine feeEngine, EarnVault feeCore) =
            _newFeeAsync(feeRecipient);

        vm.startPrank(user);
        feeAsset.approve(address(feeCore), type(uint256).max);
        feeShare.approve(address(feeCore), type(uint256).max);
        feeCore.deposit(10 ether, user, 10 ether);
        bytes32 requestId = feeCore.requestRedeem(4 ether, "", receiver);
        vm.stopPrank();

        IEarnFees feeModule = IEarnFees(feeCore.earnFees());
        IEarnFees.PendingFeeSnapshot memory pending = feeModule.pendingFeeSnapshot(requestId);
        assertEq(pending.requestValue, 4 ether);
        assertEq(pending.feeConfigId, 1);

        feeEngine.setRate(1.2 ether);
        FeeConfig memory noFees;
        vm.prank(operator);
        feeCore.setFeeConfig(noFees);
        uint256 activeFeeShares = feeModule.claimableEarnShares(feeRecipient);
        assertGt(activeFeeShares, 0);

        vm.prank(user);
        feeCore.cancelRedeem(requestId, 4 ether);

        assertGt(feeModule.claimableEarnShares(feeRecipient), activeFeeShares);
        assertEq(feeShare.balanceOf(receiver), 4 ether);
        assertFalse(feeCore.pendingRedeem(requestId).open);
        assertTrue(feeCore.isAccountingAligned());
    }

    function testMultipleCancellationsReopenAZeroSupplyPoolWithoutDilution() public {
        address feeRecipient = address(0xFEE);
        (CoreMockToken feeAsset, CoreMockToken feeShare, CoreMockAsyncEngine feeEngine, EarnVault feeCore) =
            _newFeeAsync(feeRecipient);

        vm.startPrank(user);
        feeAsset.approve(address(feeCore), type(uint256).max);
        feeShare.approve(address(feeCore), type(uint256).max);
        feeCore.deposit(10 ether, user, 10 ether);
        bytes32 first = feeCore.requestRedeem(4 ether, "", receiver);
        bytes32 second = feeCore.requestRedeem(6 ether, "", user);
        vm.stopPrank();
        assertEq(feeCore.totalEarnShares(), 0);
        assertEq(feeCore.engineShares(), 0);

        feeEngine.setRate(1.2 ether);
        vm.prank(user);
        feeCore.cancelRedeem(first, 1);
        assertEq(feeCore.engineShares(), 4 ether);
        assertEq(feeCore.totalEarnShares(), 4 ether);
        assertApproxEqAbs(feeShare.balanceOf(receiver), 3.933333333333333334 ether, 2);
        assertTrue(feeCore.isAccountingAligned());

        vm.prank(user);
        feeCore.cancelRedeem(second, 1);
        assertEq(feeCore.engineShares(), 10 ether);
        assertEq(feeCore.totalEarnShares(), 10 ether);
        assertApproxEqAbs(feeShare.balanceOf(user), 5.9 ether, 2);
        assertApproxEqAbs(
            IEarnFees(feeCore.earnFees()).claimableEarnShares(feeRecipient), 0.166666666666666666 ether, 2
        );
        assertTrue(feeCore.isAccountingAligned());
    }

    function testEmergencyDisableAllowsCancellationWhenValuationFails() public {
        address feeRecipient = address(0xFEE);
        (CoreMockToken feeAsset, CoreMockToken feeShare, CoreMockAsyncEngine feeEngine, EarnVault feeCore) =
            _newFeeAsync(feeRecipient);

        vm.startPrank(user);
        feeAsset.approve(address(feeCore), type(uint256).max);
        feeShare.approve(address(feeCore), type(uint256).max);
        feeCore.deposit(10 ether, user, 10 ether);
        bytes32 requestId = feeCore.requestRedeem(4 ether, "", receiver);
        vm.stopPrank();

        feeEngine.setValuationReverts(true);
        vm.prank(operator);
        feeCore.disableFees();

        vm.prank(user);
        feeCore.cancelRedeem(requestId, 4 ether);
        assertEq(feeShare.balanceOf(receiver), 4 ether);
        assertEq(IEarnFees(feeCore.earnFees()).claimableEarnShares(feeRecipient), 0);
        assertTrue(feeCore.isAccountingAligned());
    }

    function testFeeMintedSharesDoNotMakeCancellationUnderflow() public {
        address feeRecipient = address(0xFEE);
        (CoreMockToken feeAsset, CoreMockToken feeShare, CoreMockAsyncEngine feeEngine, EarnVault feeCore) =
            _newFeeAsync(feeRecipient);

        vm.startPrank(user);
        feeAsset.approve(address(feeCore), type(uint256).max);
        feeShare.approve(address(feeCore), type(uint256).max);
        feeCore.deposit(10 ether, user, 10 ether);
        vm.stopPrank();

        feeEngine.setRate(1.2 ether);
        feeCore.accrueFees();
        uint256 activeFeeShares = feeShare.balanceOf(address(feeCore.earnFees()));
        assertGt(activeFeeShares, 0);

        vm.prank(user);
        bytes32 requestId = feeCore.requestRedeem(10 ether, "", receiver);
        assertEq(feeCore.totalEarnShares(), activeFeeShares);

        vm.prank(user);
        feeCore.cancelRedeem(requestId, 9.9 ether);

        assertFalse(feeCore.pendingRedeem(requestId).open);
        assertEq(feeCore.openRedeemRequestCount(), 0);
        assertApproxEqAbs(feeShare.balanceOf(receiver), 10 ether, 100);
        assertTrue(feeCore.isAccountingAligned());
    }

    function testSnapshotlessCancellationRestoresFeeBaselines() public {
        address feeRecipient = address(0xFEE);
        _deposit(10 ether);

        vm.startPrank(user);
        share.approve(address(core), type(uint256).max);
        bytes32 requestId = core.requestRedeem(10 ether, "", receiver);
        vm.stopPrank();
        assertEq(core.totalEarnShares(), 0);

        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(feeRecipient, 1_000);
        vm.prank(operator);
        core.setFeeConfig(config);

        vm.prank(user);
        core.cancelRedeem(requestId, 10 ether);

        IEarnFees fees = IEarnFees(core.earnFees());
        assertEq(fees.highWaterMark(), 1 ether);
        (uint256 feeAssets, uint256 feeEarnShares) = core.accrueFees();
        assertEq(feeAssets, 0);
        assertEq(feeEarnShares, 0);
        assertEq(fees.claimableEarnShares(feeRecipient), 0);

        engine.setRate(1.1 ether);
        (feeAssets, feeEarnShares) = core.accrueFees();
        assertEq(feeAssets, 0.1 ether);
        assertGt(feeEarnShares, 0);
        assertEq(fees.claimableEarnShares(feeRecipient), feeEarnShares);
        assertTrue(core.isAccountingAligned());
    }

    function testFeeDisablementWaivesOpenRequestAcrossReactivation() public {
        address originalRecipient = address(0xFEE);
        address replacementRecipient = address(0xBEEF);
        (CoreMockToken feeAsset, CoreMockToken feeShare, CoreMockAsyncEngine feeEngine, EarnVault feeCore) =
            _newFeeAsync(originalRecipient);

        vm.startPrank(user);
        feeAsset.approve(address(feeCore), type(uint256).max);
        feeShare.approve(address(feeCore), type(uint256).max);
        feeCore.deposit(10 ether, user, 10 ether);
        bytes32 requestId = feeCore.requestRedeem(4 ether, "", receiver);
        vm.stopPrank();

        vm.prank(operator);
        feeCore.disableFees();
        feeEngine.setRate(1.2 ether);

        FeeConfig memory replacement;
        replacement.fixedFeeCount = 1;
        replacement.fixedFees[0] = FixedFeeRecipient(replacementRecipient, 1_000);
        vm.prank(operator);
        feeCore.setFeeConfig(replacement);

        vm.prank(user);
        feeCore.cancelRedeem(requestId, 4 ether);

        IEarnFees fees = IEarnFees(feeCore.earnFees());
        assertEq(fees.claimableEarnShares(originalRecipient), 0);
        assertEq(fees.claimableEarnShares(replacementRecipient), 0);
        assertEq(feeShare.balanceOf(receiver), 4 ether);
        assertFalse(feeCore.pendingRedeem(requestId).open);

        feeEngine.setRate(1.3 ether);
        feeCore.accrueFees();
        assertEq(fees.claimableEarnShares(originalRecipient), 0);
        assertGt(fees.claimableEarnShares(replacementRecipient), 0);
        assertTrue(feeCore.isAccountingAligned());
    }

    function testAsyncRequestRejectsExcessiveFloorLossBeforeBurning() public {
        CoreMockToken coarseAsset = new CoreMockToken("Coarse Asset", "CAST", 6);
        CoreMockToken coarseShare = new CoreMockToken("Coarse Earn Share", "CSH", 18);
        CoarseAsyncEngine coarseEngine = new CoarseAsyncEngine(coarseAsset);
        EarnVault coarseCore = EarnVaultTestDeployer.deploy(
            address(coarseEngine), address(coarseShare), operator, earnVaultTestNoFees()
        );
        coarseEngine.setCore(coarseCore);

        address remainingHolder = address(0xCAFE);
        coarseAsset.mint(user, 2_990_000);
        vm.startPrank(user);
        coarseAsset.approve(address(coarseCore), type(uint256).max);
        coarseShare.approve(address(coarseCore), type(uint256).max);
        assertEq(coarseCore.deposit(2_990_000, user, 299 ether), 299 ether);
        assertTrue(coarseShare.transfer(remainingHolder, 99.1 ether));

        vm.expectRevert(abi.encodeWithSelector(EarnVault.ExcessiveConversionLoss.selector, 199.9 ether, 199 ether));
        coarseCore.requestRedeem(199.9 ether, "", receiver);

        assertEq(coarseShare.balanceOf(user), 199.9 ether);
        assertEq(coarseCore.totalEarnShares(), 299 ether);
        assertEq(coarseCore.engineShares(), 299);

        bytes32 requestId = coarseCore.requestRedeem(199 ether, "", receiver);
        vm.stopPrank();

        EarnVault.PendingRedeem memory pending = coarseCore.pendingRedeem(requestId);
        assertEq(pending.burnedEarnShares, 199 ether);
        assertEq(pending.engineShares, 199);
        assertEq(coarseCore.totalEarnShares(), 100 ether);
        assertEq(coarseCore.engineShares(), 100);
        assertTrue(coarseCore.isAccountingAligned());
    }

    /// @dev A contribution moves the anchor to 200 EarnShare per 201 engine shares, so re-entering
    ///      100 returned engine shares floors to EarnShare that represents only 99 of them.
    function testNonemptyPoolCancellationRejectsExcessiveFloorLoss() public {
        CoreMockToken coarseAsset = new CoreMockToken("Coarse Asset", "CAST", 6);
        CoreMockToken coarseShare = new CoreMockToken("Coarse Earn Share", "CSH", 18);
        CoarseAsyncEngine coarseEngine = new CoarseAsyncEngine(coarseAsset);
        EarnVault coarseCore = EarnVaultTestDeployer.deploy(
            address(coarseEngine), address(coarseShare), operator, earnVaultTestNoFees()
        );
        coarseEngine.setCore(coarseCore);

        coarseAsset.mint(user, 3_010_000);
        vm.startPrank(user);
        coarseAsset.approve(address(coarseCore), type(uint256).max);
        coarseShare.approve(address(coarseCore), type(uint256).max);
        assertEq(coarseCore.deposit(3_000_000, user, 300 ether), 300 ether);
        bytes32 requestId = coarseCore.requestRedeem(100 ether, "", receiver);
        coarseCore.contribute(10_000);
        assertEq(coarseCore.totalEarnShares(), 200 ether);
        assertEq(coarseCore.engineShares(), 201);

        vm.expectRevert(abi.encodeWithSelector(EarnVault.ExcessiveConversionLoss.selector, 100, 99));
        coarseCore.cancelRedeem(requestId, 1);
        vm.stopPrank();

        assertTrue(coarseCore.pendingRedeem(requestId).open);
        assertEq(coarseCore.pendingRedeem(requestId).engineShares, 100);
        assertEq(coarseShare.balanceOf(receiver), 0);
        assertEq(coarseCore.totalEarnShares(), 200 ether);
        assertEq(coarseCore.engineShares(), 201);
        assertTrue(coarseCore.isAccountingAligned());
    }

    function testCoarseAsyncExitPreservesRemainingBackingAndLiveness() public {
        CoreMockToken coarseAsset = new CoreMockToken("Coarse Asset", "CAST", 6);
        CoreMockToken coarseShare = new CoreMockToken("Coarse Earn Share", "CSH", 18);
        CoarseAsyncEngine coarseEngine = new CoarseAsyncEngine(coarseAsset);
        EarnVault coarseCore = EarnVaultTestDeployer.deploy(
            address(coarseEngine), address(coarseShare), operator, earnVaultTestNoFees()
        );
        coarseEngine.setCore(coarseCore);

        coarseAsset.mint(user, 100_020_000);
        vm.startPrank(user);
        coarseAsset.approve(address(coarseCore), type(uint256).max);
        coarseShare.approve(address(coarseCore), type(uint256).max);
        assertEq(coarseCore.deposit(100_010_000, user, 10_001 ether), 10_001 ether);

        bytes32 firstRequest = coarseCore.requestRedeem(10_001 ether - 1, "", receiver);
        EarnVault.PendingRedeem memory pending = coarseCore.pendingRedeem(firstRequest);
        assertEq(pending.engineShares, 10_000);

        assertEq(coarseCore.totalEarnShares(), 1);
        assertEq(coarseCore.engineShares(), 1);
        assertEq(coarseCore.rawEngineShares(), 1);
        assertEq(coarseCore.surplusEngineShares(), 0);
        assertEq(coarseCore.convertToEngineShares(1), 1);
        assertTrue(coarseCore.isAccountingAligned());

        // A new principal entry and a second async exit remain usable above the reward ceiling.
        assertEq(coarseCore.deposit(10_000, user, 1), 1);
        bytes32 secondRequest = coarseCore.requestRedeem(2, "", receiver);
        vm.stopPrank();

        assertTrue(coarseCore.pendingRedeem(secondRequest).open);
        assertEq(coarseCore.totalEarnShares(), 0);
        assertEq(coarseCore.engineShares(), 0);
        assertEq(coarseCore.rewardRateBaseline(), 1);
    }

    function _deposit(uint256 assets) internal {
        vm.startPrank(user);
        asset.approve(address(core), type(uint256).max);
        core.deposit(assets, user, assets);
        vm.stopPrank();
    }

    function _newFeeAsync(address feeRecipient)
        internal
        returns (CoreMockToken feeAsset, CoreMockToken feeShare, CoreMockAsyncEngine feeEngine, EarnVault feeCore)
    {
        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(feeRecipient, 1_000);
        feeAsset = new CoreMockToken("Fee Asset", "FAST", 18);
        feeShare = new CoreMockToken("Fee Share", "FSH", 18);
        feeEngine = new CoreMockAsyncEngine(feeAsset);
        feeCore = EarnVaultTestDeployer.deploy(address(feeEngine), address(feeShare), operator, config);
        feeEngine.setCore(feeCore);
        feeAsset.mint(user, 100 ether);
    }
}
