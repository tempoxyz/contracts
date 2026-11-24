// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { UpshiftEngine } from "../../../../src/earn/engines/upshift/UpshiftEngine.sol";
import { UpshiftRedeemReceiver } from "../../../../src/earn/engines/upshift/UpshiftRedeemReceiver.sol";
import { EarnVault } from "../../../../src/earn/core/EarnVault.sol";
import { FeeConfig } from "../../../../src/interfaces/earn/EarnFeeTypes.sol";
import { IEarnEngine } from "../../../../src/interfaces/earn/engines/IEarnEngine.sol";
import { IEarnEngineAsyncRedeem } from "../../../../src/interfaces/earn/engines/IEarnEngineAsyncRedeem.sol";
import { IEarnEngineExactWithdraw } from "../../../../src/interfaces/earn/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineFeeValuation } from "../../../../src/interfaces/earn/engines/IEarnEngineFeeValuation.sol";
import { IEarnEngineHeldDeposit } from "../../../../src/interfaces/earn/engines/IEarnEngineHeldDeposit.sol";
import { IEarnEngineInKindDeposit } from "../../../../src/interfaces/earn/engines/IEarnEngineInKindDeposit.sol";
import { IEarnEngineRedeem } from "../../../../src/interfaces/earn/engines/IEarnEngineRedeem.sol";
import { IUpshiftVault } from "../../../../src/interfaces/external/upshift/IUpshiftVault.sol";
import { EarnVaultTestDeployer } from "../../helpers/EarnVaultTestDeployer.sol";
import { CoreMockToken, FaultyMockToken } from "../../helpers/EarnVaultMocks.sol";
import { MockUpshiftShareToken, MockUpshiftVault } from "../../helpers/UpshiftEngineMocks.sol";

contract UpshiftEngineTest is Test {
    uint64 constant MAX_NAV_AGE = 2 days;

    FaultyMockToken asset;
    CoreMockToken share;
    MockUpshiftShareToken receipt;
    MockUpshiftVault upshift;
    UpshiftEngine engine;
    EarnVault vault;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event RedeemRequested(bytes32 indexed requestId, uint256 engineShares, uint256 claimableEpoch);
    event RedeemSettled(bytes32 indexed requestId, uint256 engineShares, uint256 assets);

    function setUp() public {
        vm.warp(1_800_000_000);
        asset = new FaultyMockToken("USD", "USD", 6);
        share = new CoreMockToken("Earn USD", "eUSD", 6);
        receipt = new MockUpshiftShareToken("Upshift USD", "upUSD", 6);
        upshift = new MockUpshiftVault(address(asset), address(receipt));
        receipt.setVault(address(upshift));
        engine = new UpshiftEngine(upshift, address(this), MAX_NAV_AGE, "Upshift USD", "upUSD");
        FeeConfig memory noFees;
        vault = EarnVaultTestDeployer.deploy(address(engine), address(share), address(this), noFees);
        engine.initializeEarnVault(address(vault));
        _fund(alice);
        _fund(bob);
    }

    function _fund(address account) internal {
        asset.mint(account, 1_000_000e6);
        vm.startPrank(account);
        asset.approve(address(vault), type(uint256).max);
        share.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(address account, uint256 assets) internal returns (uint256 shares) {
        vm.prank(account);
        shares = vault.deposit(assets, account, 1);
    }

    function _request(address account, uint256 earnShares) internal returns (bytes32 requestId) {
        vm.prank(account);
        requestId = vault.requestRedeem(earnShares, bytes(""));
    }

    function _receiverOf(bytes32 requestId) internal pure returns (address) {
        return address(uint160(uint256(requestId)));
    }

    function _queued(bytes32 requestId) internal view returns (uint256) {
        (,,, uint256 year, uint256 month, uint256 day) = engine.getClaim(requestId);
        return upshift.getBurnableAmountByReceiver(year, month, day, _receiverOf(requestId));
    }

    function _passClaimDate() internal {
        vm.warp(block.timestamp + 2 days);
    }

    // --- setup ---

    function testMetadataAndCapabilities() public view {
        assertEq(engine.asset(), address(asset));
        assertEq(engine.shareToken(), address(receipt));
        assertEq(address(engine.vault()), address(upshift));
        assertEq(engine.shareScale(), 1e6);
        assertEq(engine.earnVault(), address(vault));
        assertEq(engine.name(), "Upshift USD");
        assertEq(engine.symbol(), "upUSD");
        assertEq(engine.maxNavAge(), MAX_NAV_AGE);
        assertEq(UpshiftRedeemReceiver(engine.receiverImplementation()).engine(), address(engine));
        assertTrue(engine.supportsInterface(type(IEarnEngine).interfaceId));
        assertTrue(engine.supportsInterface(type(IEarnEngineRedeem).interfaceId));
        assertTrue(engine.supportsInterface(type(IEarnEngineAsyncRedeem).interfaceId));
        assertTrue(engine.supportsInterface(type(IEarnEngineFeeValuation).interfaceId));
        assertTrue(engine.supportsInterface(type(IEarnEngineHeldDeposit).interfaceId));
        assertFalse(engine.supportsInterface(type(IEarnEngineExactWithdraw).interfaceId));
        assertFalse(engine.supportsInterface(type(IEarnEngineInKindDeposit).interfaceId));
    }

    function testConstructorRejectsBadConfiguration() public {
        vm.expectRevert(UpshiftEngine.InvalidMaxNavAge.selector);
        new UpshiftEngine(upshift, address(this), 0, "Upshift", "up");
        vm.expectRevert(UpshiftEngine.EmptyMetadata.selector);
        new UpshiftEngine(upshift, address(this), MAX_NAV_AGE, "", "up");
        vm.expectRevert(UpshiftEngine.EmptyMetadata.selector);
        new UpshiftEngine(upshift, address(this), MAX_NAV_AGE, "Upshift", "");
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.InvalidUpshiftVault.selector, address(0xdead)));
        new UpshiftEngine(IUpshiftVault(address(0xdead)), address(this), MAX_NAV_AGE, "Upshift", "up");

        vm.mockCall(address(upshift), abi.encodeCall(IUpshiftVault.asset, ()), abi.encode(address(0xbeef)));
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.InvalidUpshiftVault.selector, address(0xbeef)));
        new UpshiftEngine(upshift, address(this), MAX_NAV_AGE, "Upshift", "up");
        vm.clearMockedCalls();

        vm.mockCall(address(upshift), abi.encodeCall(IUpshiftVault.lpTokenAddress, ()), abi.encode(address(0xbeef)));
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.InvalidUpshiftVault.selector, address(0xbeef)));
        new UpshiftEngine(upshift, address(this), MAX_NAV_AGE, "Upshift", "up");
        vm.clearMockedCalls();

        vm.mockCall(address(receipt), abi.encodeCall(receipt.decimals, ()), abi.encode(uint8(78)));
        vm.expectRevert(UpshiftEngine.InvalidVenueShareDecimals.selector);
        new UpshiftEngine(upshift, address(this), MAX_NAV_AGE, "Upshift", "up");
    }

    function testBindsOnceToMatchingVault() public {
        vm.expectRevert(UpshiftEngine.AlreadyInitialized.selector);
        engine.initializeEarnVault(address(vault));

        MockUpshiftShareToken otherReceipt = new MockUpshiftShareToken("Other", "o", 6);
        MockUpshiftVault otherUpshift = new MockUpshiftVault(address(share), address(otherReceipt));
        UpshiftEngine other = new UpshiftEngine(otherUpshift, address(this), MAX_NAV_AGE, "Other", "o");
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.InvalidAsset.selector, address(share), address(asset)));
        other.initializeEarnVault(address(vault));
        vm.expectRevert(UpshiftEngine.ZeroAddress.selector);
        other.initializeEarnVault(address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        other.initializeEarnVault(address(vault));
    }

    function testBindCanHandOwnershipToFinalOwner() public {
        UpshiftEngine fresh = new UpshiftEngine(upshift, address(this), MAX_NAV_AGE, "Upshift USD", "upUSD");
        vm.expectRevert(UpshiftEngine.ZeroAddress.selector);
        fresh.initializeEarnVault(address(vault), address(0));
        fresh.initializeEarnVault(address(vault), bob);
        assertEq(fresh.owner(), bob);
        assertEq(fresh.earnVault(), address(vault));
    }

    function testOnlyBoundVaultMovesFunds() public {
        _deposit(alice, 100e6);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.NotEarnVault.selector, alice));
        engine.deposit(1e6);
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.NotEarnVault.selector, alice));
        engine.depositHeld(1e6);
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.NotEarnVault.selector, alice));
        engine.redeem(1e6, alice, 0);
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.NotEarnVault.selector, alice));
        engine.requestRedeem(1e6, bytes(""));
        vm.stopPrank();

        UpshiftEngine unbound = new UpshiftEngine(upshift, address(this), MAX_NAV_AGE, "Upshift USD", "upUSD");
        vm.expectRevert(UpshiftEngine.EarnVaultNotSet.selector);
        unbound.deposit(1e6);
    }

    // --- deposits and valuation ---

    function testDepositHoldsReceiptTokensOnTheEngine() public {
        assertEq(_deposit(alice, 100e6), 100e6);
        assertEq(receipt.balanceOf(address(engine)), 100e6);
        assertEq(engine.totalShares(), 100e6);
        assertEq(engine.totalAssets(), 100e6);
        assertEq(vault.totalAssets(), 100e6);
        assertEq(asset.balanceOf(address(upshift)), 100e6);
        // Nothing rests on the engine or stays approved.
        assertEq(asset.balanceOf(address(engine)), 0);
        assertEq(asset.allowance(address(engine), address(upshift)), 0);
    }

    function testValueFollowsVaultNavNetOfWithdrawalFee() public {
        _deposit(alice, 100e6);
        asset.mint(address(upshift), 10e6);
        assertEq(engine.totalAssets(), 110e6);
        assertEq(engine.valueOf(50e6), 55e6);

        upshift.setFees(100, 250);
        assertEq(engine.valueOf(50e6), 54.45e6);
        assertEq(engine.totalAssets(), 108.9e6);
        // An instant exit is quoted with the vault's instant fee instead.
        assertEq(engine.previewRedeem(50e6), 53.625e6);
    }

    function testDepositNeedsFreshNavButExitsDoNot() public {
        _deposit(alice, 100e6);
        assertTrue(engine.isFeeValuationFresh());

        uint256 updatedAt = upshift.assetsUpdatedOn();
        vm.warp(updatedAt + MAX_NAV_AGE + 1);
        assertFalse(engine.isFeeValuationFresh());
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(UpshiftEngine.StaleNav.selector, updatedAt, block.timestamp, uint256(MAX_NAV_AGE))
        );
        vault.deposit(10e6, bob, 1);

        vm.prank(alice);
        assertEq(vault.redeem(10e6, alice, 10e6), 10e6);
        _request(alice, 10e6);

        upshift.updateTotalAssets(0);
        assertTrue(engine.isFeeValuationFresh());
        assertEq(_deposit(bob, 10e6), 10e6);
    }

    function testFutureNavTimestampIsNotFresh() public {
        uint256 updatedAt = upshift.assetsUpdatedOn();
        vm.warp(updatedAt - 1);
        assertFalse(engine.isFeeValuationFresh());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.InvalidNavTimestamp.selector, updatedAt, block.timestamp));
        vault.deposit(10e6, alice, 1);
    }

    function testMaxNavAgeChangesOnlyWhileDepositsPaused() public {
        vm.expectRevert(UpshiftEngine.DepositsNotPaused.selector);
        engine.setMaxNavAge(1 days);

        vault.setDepositsPaused(true);
        vm.expectRevert(UpshiftEngine.InvalidMaxNavAge.selector);
        engine.setMaxNavAge(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        engine.setMaxNavAge(1 days);
        engine.setMaxNavAge(1 days);
        assertEq(engine.maxNavAge(), 1 days);
    }

    function testDepositRevertsWhenVaultMintsNothing() public {
        upshift.setShortfalls(5e6, 0);
        vm.prank(alice);
        vm.expectRevert(UpshiftEngine.NoVenueSharesReceived.selector);
        vault.deposit(5e6, alice, 1);
    }

    function testDepositPullsFromTheEarnVault() public {
        asset.mint(address(vault), 5e6);
        vm.startPrank(address(vault));
        asset.approve(address(engine), 5e6);
        assertEq(engine.deposit(5e6), 5e6);
        vm.stopPrank();
        assertEq(engine.totalShares(), 5e6);
        assertEq(asset.balanceOf(address(engine)), 0);
        assertEq(asset.allowance(address(engine), address(upshift)), 0);
    }

    function testDepositRevertsWhenVaultLeavesAllowance() public {
        vm.mockCall(
            address(asset), abi.encodeCall(asset.allowance, (address(engine), address(upshift))), abi.encode(uint256(1))
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.UnexpectedAllowance.selector, address(upshift), 1));
        vault.deposit(5e6, alice, 1);
    }

    function testFundFlowsCannotBeReentered() public {
        ReenteringUpshiftVault reentering = new ReenteringUpshiftVault(address(asset), address(receipt));
        UpshiftEngine other =
            new UpshiftEngine(IUpshiftVault(address(reentering)), address(this), MAX_NAV_AGE, "Upshift", "up");
        other.initializeEarnVault(address(vault));
        reentering.setEngine(other);

        vm.prank(address(vault));
        vm.expectRevert(UpshiftEngine.ReentrantCall.selector);
        other.depositHeld(1e6);
    }

    function testVaultWhitelistGatesTheEngine() public {
        upshift.setWhitelist(true, address(engine), false);
        vm.prank(alice);
        vm.expectRevert(MockUpshiftVault.SenderNotWhitelisted.selector);
        vault.deposit(100e6, alice, 1);

        upshift.setWhitelist(true, address(engine), true);
        _deposit(alice, 100e6);
        bytes32 id = _request(alice, 40e6);
        _passClaimDate();
        assertEq(engine.settleRedeem(id), 40e6);
    }

    // --- instant redemption ---

    function testInstantRedeemPaysReceiverNetOfInstantFee() public {
        _deposit(alice, 100e6);
        upshift.setFees(0, 100);
        uint256 before = asset.balanceOf(bob);

        vm.prank(alice);
        assertEq(vault.redeem(40e6, bob, 39.6e6), 39.6e6);
        assertEq(asset.balanceOf(bob) - before, 39.6e6);
        assertEq(engine.totalShares(), 60e6);
        assertEq(receipt.totalSupply(), 60e6);
    }

    function testInstantRedeemRejectsZeroReceiver() public {
        _deposit(alice, 100e6);
        vm.prank(address(vault));
        vm.expectRevert(UpshiftEngine.ZeroAddress.selector);
        engine.redeem(40e6, address(0), 0);
    }

    function testInstantRedeemRevertsWhenEngineSharesGrow() public {
        _deposit(alice, 100e6);
        bytes[] memory balances = new bytes[](2);
        balances[0] = abi.encode(uint256(100e6));
        balances[1] = abi.encode(uint256(101e6));
        vm.mockCalls(address(receipt), abi.encodeCall(receipt.balanceOf, (address(engine))), balances);
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.UnexpectedVenueSharesBurned.selector, 40e6, 0));
        engine.redeem(40e6, alice, 0);
    }

    function testInstantRedeemEnforcesMinimum() public {
        _deposit(alice, 100e6);
        upshift.setFees(0, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.InsufficientAssetsReceived.selector, 40e6, 39.6e6));
        vault.redeem(40e6, alice, 40e6);
        assertEq(engine.totalShares(), 100e6);
    }

    function testInstantRedeemRevertsWhenVaultHasNoIdleCash() public {
        _deposit(alice, 100e6);
        upshift.deployCapital(90e6);
        vm.prank(alice);
        vm.expectRevert(bytes("BALANCE"));
        vault.redeem(40e6, alice, 1);
        // The queue still takes the exit.
        _request(alice, 40e6);
    }

    // --- queued redemption ---

    function testRequestQueuesSharesForItsOwnReceiver() public {
        _deposit(alice, 100e6);
        _deposit(bob, 50e6);

        bytes32 aliceId = _request(alice, 40e6);
        bytes32 bobId = _request(bob, 10e6);
        assertTrue(aliceId != bobId);

        (UpshiftEngine.ClaimStatus status, address receiver, uint256 engineShares,,,) = engine.getClaim(aliceId);
        assertEq(uint8(status), uint8(UpshiftEngine.ClaimStatus.Open));
        assertEq(receiver, _receiverOf(aliceId));
        assertEq(engineShares, 40e6);
        assertEq(UpshiftRedeemReceiver(receiver).engine(), address(engine));

        // Each receiver's queue entry is exactly its request, though both land on the same claim date.
        assertEq(_queued(aliceId), 40e6);
        assertEq(_queued(bobId), 10e6);
        assertEq(upshift.globalLiabilityShares(), 50e6);
        assertEq(engine.totalShares(), 100e6);
        assertEq(receipt.balanceOf(address(upshift)), 50e6);
        assertEq(receipt.allowance(address(engine), address(upshift)), 0);
        assertEq(vault.openRedeemRequestCount(), 2);
        assertEq(share.balanceOf(alice), 60e6);
    }

    function testRequestEmitsClaimableEpoch() public {
        _deposit(alice, 100e6);
        uint256 claimableEpoch = ((block.timestamp + 5 minutes + 1 days) / 1 days) * 1 days;
        vm.expectEmit(false, false, false, true, address(engine));
        emit RedeemRequested(bytes32(0), 40e6, claimableEpoch);
        _request(alice, 40e6);
    }

    function testRequestRejectsRequestData() public {
        _deposit(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(UpshiftEngine.UnexpectedRequestData.selector);
        vault.requestRedeem(40e6, abi.encode(uint256(1)));
    }

    function testRequestRejectsZeroAndOversizedShares() public {
        uint256 oversized = uint256(type(uint128).max) + 1;
        vm.startPrank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.InvalidEngineShares.selector, 0));
        engine.requestRedeem(0, bytes(""));
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.InvalidEngineShares.selector, oversized));
        engine.requestRedeem(oversized, bytes(""));
        vm.stopPrank();
    }

    function testRequestRevertsWhenVaultQueuesFewerShares() public {
        _deposit(alice, 100e6);
        vm.mockCall(
            address(upshift),
            abi.encodeWithSelector(IUpshiftVault.getBurnableAmountByReceiver.selector),
            abi.encode(40e6 - 1)
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.UnexpectedQueuedShares.selector, 40e6, 40e6 - 1));
        vault.requestRedeem(40e6, bytes(""));
    }

    function testRequestRejectsAClaimDateThatDoesNotFit() public {
        _deposit(alice, 100e6);
        // The vault call is replaced, so the share movement it would have made is replayed on the reads.
        vm.mockCall(
            address(upshift),
            abi.encodeWithSelector(IUpshiftVault.requestRedeem.selector),
            abi.encode(uint256(0), uint256(70_000), uint256(1), uint256(1))
        );
        bytes[] memory balances = new bytes[](2);
        balances[0] = abi.encode(uint256(100e6));
        balances[1] = abi.encode(uint256(60e6));
        vm.mockCalls(address(receipt), abi.encodeCall(receipt.balanceOf, (address(engine))), balances);
        vm.mockCall(
            address(receipt), abi.encodeCall(receipt.allowance, (address(engine), address(upshift))), abi.encode(0)
        );
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.UnexpectedClaimDate.selector, 70_000, 1, 1));
        engine.requestRedeem(40e6, bytes(""));
    }

    /// A receiver's address is predictable, so shares queued for it first must not block the request.
    function testSharesQueuedForAReceiverBeforeItsRequestDoNotBlockIt() public {
        _deposit(alice, 100e6);
        address next = vm.computeCreateAddress(address(engine), vm.getNonce(address(engine)));
        vm.startPrank(bob);
        asset.approve(address(upshift), 10e6);
        upshift.deposit(address(asset), 10e6, bob);
        receipt.approve(address(upshift), 10e6);
        upshift.requestRedeem(10e6, next);
        vm.stopPrank();

        bytes32 id = _request(alice, 40e6);
        assertEq(_receiverOf(id), next);
        (,, uint256 engineShares,,,) = engine.getClaim(id);
        assertEq(engineShares, 40e6);
        assertEq(_queued(id), 50e6);
        _passClaimDate();

        uint256 before = asset.balanceOf(alice);
        assertEq(engine.settleRedeem(id), 50e6);
        assertEq(asset.balanceOf(alice) - before, 50e6);
        assertEq(engine.totalShares(), 60e6);
    }

    function testRequestRevertsAtomicallyWhenVaultUnderpullsShares() public {
        _deposit(alice, 100e6);
        upshift.setShortfalls(0, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.UnexpectedVenueSharesBurned.selector, 40e6, 40e6 - 1));
        vault.requestRedeem(40e6, bytes(""));
        assertEq(engine.totalShares(), 100e6);
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(vault.openRedeemRequestCount(), 0);
    }

    function testSettleBeforeClaimDateRevertsAndKeepsRequestOpen() public {
        _deposit(alice, 100e6);
        bytes32 id = _request(alice, 40e6);

        vm.expectRevert(MockUpshiftVault.TooEarly.selector);
        engine.settleRedeem(id);
        assertEq(_queued(id), 40e6);
        assertEq(vault.openRedeemRequestCount(), 1);
    }

    function testSettlePaysStoredReceiverAtClaimTimePrice() public {
        _deposit(alice, 100e6);
        vm.prank(alice);
        bytes32 id = vault.requestRedeem(40e6, bob, bytes(""));

        // The vault earns 10% while the request waits; a queued redemption is priced when claimed.
        asset.mint(address(upshift), 10e6);
        _passClaimDate();
        uint256 before = asset.balanceOf(bob);

        vm.expectEmit(true, false, false, true, address(engine));
        emit RedeemSettled(id, 40e6, 44e6);
        vm.prank(makeAddr("anyone"));
        assertEq(engine.settleRedeem(id), 44e6);

        assertEq(asset.balanceOf(bob) - before, 44e6);
        assertEq(asset.balanceOf(_receiverOf(id)), 0);
        assertEq(asset.balanceOf(address(engine)), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(_queued(id), 0);
        assertEq(receipt.totalSupply(), 60e6);
        assertEq(vault.openRedeemRequestCount(), 0);
        (UpshiftEngine.ClaimStatus status,,,,,) = engine.getClaim(id);
        assertEq(uint8(status), uint8(UpshiftEngine.ClaimStatus.Settled));
        // The remaining holder keeps the rest of the gain.
        assertEq(vault.totalAssets(), 66e6);
    }

    function testSettlePassesOnALossAndTheWithdrawalFee() public {
        _deposit(alice, 100e6);
        bytes32 id = _request(alice, 40e6);
        vm.prank(address(upshift));
        asset.burn(10e6);
        upshift.setFees(100, 0);
        _passClaimDate();

        uint256 before = asset.balanceOf(alice);
        // 40 shares of a 90 NAV over 100 shares is 36, less the 1% withdrawal fee.
        assertEq(engine.settleRedeem(id), 35.64e6);
        assertEq(asset.balanceOf(alice) - before, 35.64e6);
    }

    function testSettleForwardsAPayoutTheVaultOperatorAlreadyMade() public {
        _deposit(alice, 100e6);
        bytes32 id = _request(alice, 40e6);
        (,,, uint256 year, uint256 month, uint256 day) = engine.getClaim(id);

        upshift.processAllClaimsByDate(year, month, day, 10);
        assertEq(asset.balanceOf(_receiverOf(id)), 40e6);
        assertEq(_queued(id), 0);
        assertEq(vault.openRedeemRequestCount(), 1);

        uint256 before = asset.balanceOf(alice);
        assertEq(engine.settleRedeem(id), 40e6);
        assertEq(asset.balanceOf(alice) - before, 40e6);
        assertEq(asset.balanceOf(_receiverOf(id)), 0);
        assertEq(vault.openRedeemRequestCount(), 0);
    }

    function testSettleRejectsUnknownAndSettledRequests() public {
        _deposit(alice, 100e6);
        bytes32 id = _request(alice, 40e6);
        _passClaimDate();
        engine.settleRedeem(id);

        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.ClaimNotOpen.selector, id));
        engine.settleRedeem(id);
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.ClaimNotOpen.selector, bytes32(uint256(1))));
        engine.settleRedeem(bytes32(uint256(1)));

        (UpshiftEngine.ClaimStatus status, address receiver, uint256 engineShares, uint256 year,,) =
            engine.getClaim(bytes32(uint256(1)));
        assertEq(uint8(status), uint8(UpshiftEngine.ClaimStatus.None));
        assertEq(receiver, address(0));
        assertEq(engineShares, 0);
        assertEq(year, 0);
    }

    function testSettleRevertsWhenAClaimLeavesSharesQueued() public {
        _deposit(alice, 100e6);
        bytes32 id = _request(alice, 40e6);
        _passClaimDate();
        vm.mockCall(
            address(upshift), abi.encodeWithSelector(IUpshiftVault.getBurnableAmountByReceiver.selector), abi.encode(5)
        );
        vm.expectRevert(abi.encodeWithSelector(UpshiftEngine.UnexpectedQueuedShares.selector, 0, 5));
        engine.settleRedeem(id);

        vm.clearMockedCalls();
        assertEq(engine.settleRedeem(id), 40e6);
    }

    function testSettleStaysOpenWhileTheReceiverCannotBePaid() public {
        _deposit(alice, 100e6);
        bytes32 id = _request(alice, 40e6);
        _passClaimDate();
        asset.setBlockedRecipient(alice, true);

        vm.expectRevert();
        engine.settleRedeem(id);
        // Nothing moved: the vault still owes the request and the EarnVault still tracks it.
        assertEq(_queued(id), 40e6);
        assertEq(vault.openRedeemRequestCount(), 1);

        asset.setBlockedRecipient(alice, false);
        uint256 before = asset.balanceOf(alice);
        assertEq(engine.settleRedeem(id), 40e6);
        assertEq(asset.balanceOf(alice) - before, 40e6);
    }

    function testSettleWaitsWhileVaultWithdrawalsArePaused() public {
        _deposit(alice, 100e6);
        bytes32 id = _request(alice, 40e6);
        _passClaimDate();
        upshift.setPaused(false, true);
        vm.expectRevert(MockUpshiftVault.WithdrawalsPaused.selector);
        engine.settleRedeem(id);

        upshift.setPaused(false, false);
        assertEq(engine.settleRedeem(id), 40e6);
    }

    function testSharesAThirdPartyQueuesForAReceiverArePaidToItsRequest() public {
        _deposit(alice, 100e6);
        bytes32 id = _request(alice, 40e6);

        // Bob holds receipt tokens directly and queues them for Alice's receiver on the same date.
        vm.startPrank(bob);
        asset.approve(address(upshift), 10e6);
        upshift.deposit(address(asset), 10e6, bob);
        receipt.approve(address(upshift), 10e6);
        upshift.requestRedeem(10e6, _receiverOf(id));
        vm.stopPrank();
        _passClaimDate();

        uint256 before = asset.balanceOf(alice);
        assertEq(engine.settleRedeem(id), 50e6);
        assertEq(asset.balanceOf(alice) - before, 50e6);
        assertEq(engine.totalShares(), 60e6);
    }

    function testCancelIsUnsupportedAndLeavesRequestOpen() public {
        _deposit(alice, 100e6);
        bytes32 id = _request(alice, 40e6);

        vm.prank(alice);
        vm.expectRevert(UpshiftEngine.CancelUnsupported.selector);
        vault.cancelRedeem(id, 1);
        // The janitor cannot cancel either.
        vm.expectRevert(UpshiftEngine.CancelUnsupported.selector);
        vault.cancelRedeem(id, 1);

        assertEq(vault.openRedeemRequestCount(), 1);
        assertEq(_queued(id), 40e6);
        _passClaimDate();
        assertEq(engine.settleRedeem(id), 40e6);
    }

    function testOnlyTheEngineSweepsAReceiver() public {
        _deposit(alice, 100e6);
        bytes32 id = _request(alice, 40e6);
        (,,, uint256 year, uint256 month, uint256 day) = engine.getClaim(id);
        upshift.processAllClaimsByDate(year, month, day, 10);
        UpshiftRedeemReceiver implementation = UpshiftRedeemReceiver(engine.receiverImplementation());

        vm.prank(alice);
        vm.expectRevert(UpshiftRedeemReceiver.NotEngine.selector);
        UpshiftRedeemReceiver(_receiverOf(id)).sweep(address(asset), alice);
        vm.expectRevert(UpshiftRedeemReceiver.NotEngine.selector);
        implementation.sweep(address(asset), alice);
        assertEq(asset.balanceOf(_receiverOf(id)), 40e6);
    }

    /// A queued exit pays exactly what the vault quotes at claim time, burns exactly the queued receipt
    /// tokens, and leaves the remaining holders' backing on the engine untouched.
    function testFuzzQueuedExitConservesCustody(uint256 deposited, uint256 requested, uint256 gain, uint16 feeBps)
        public
    {
        deposited = bound(deposited, 1e6, 500_000e6);
        requested = bound(requested, 1e3, deposited);
        gain = bound(gain, 0, deposited);
        feeBps = uint16(bound(feeBps, 0, 500));

        _deposit(alice, deposited);
        _deposit(bob, 1e6);
        bytes32 id = _request(alice, requested);
        (,, uint256 queuedShares,,,) = engine.getClaim(id);
        uint256 engineSharesAfterRequest = engine.totalShares();
        uint256 supplyBefore = receipt.totalSupply();

        asset.mint(address(upshift), gain);
        upshift.setFees(feeBps, 0);
        _passClaimDate();
        (, uint256 quoted) = upshift.previewRedemption(queuedShares, false);
        uint256 before = asset.balanceOf(alice);

        assertEq(engine.settleRedeem(id), quoted);
        assertEq(asset.balanceOf(alice) - before, quoted);
        assertEq(receipt.totalSupply(), supplyBefore - queuedShares);
        assertEq(engine.totalShares(), engineSharesAfterRequest);
        assertEq(asset.balanceOf(address(engine)), 0);
        assertEq(asset.balanceOf(_receiverOf(id)), 0);
        assertEq(vault.openRedeemRequestCount(), 0);
    }
}

/// @dev A vault whose deposit calls back into the engine.
contract ReenteringUpshiftVault {
    address public immutable asset;
    address public immutable lpTokenAddress;
    UpshiftEngine engine;

    constructor(address asset_, address lpToken_) {
        asset = asset_;
        lpTokenAddress = lpToken_;
    }

    function setEngine(UpshiftEngine engine_) external {
        engine = engine_;
    }

    function assetsUpdatedOn() external view returns (uint256) {
        return block.timestamp;
    }

    function deposit(address, uint256, address) external returns (uint256) {
        return engine.settleRedeem(bytes32(0));
    }
}
