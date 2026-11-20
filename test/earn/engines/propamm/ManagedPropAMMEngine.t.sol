// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { PropAMMTestToken, PropAMMTestOracle } from "../../helpers/PropAMMEngineMocks.sol";
import { ManagedPropAMMTestVenue, ManagedPropAMMTestEarnVault } from "../../helpers/ManagedPropAMMEngineMocks.sol";
import { ManagedPropAMMEngine } from "../../../../src/earn/engines/propamm/ManagedPropAMMEngine.sol";
import { IManagedPropAMMVenue } from "../../../../src/interfaces/external/propamm/IManagedPropAMMVenue.sol";

contract ManagedPropAMMEngineTest is Test {
    uint64 constant SPONSOR = 7;
    bytes32 constant ROUTE = bytes32(uint256(1));

    PropAMMTestToken usdc;
    PropAMMTestToken baseToken;
    PropAMMTestToken otherBase;
    PropAMMTestOracle oracle;
    ManagedPropAMMTestVenue pool;
    ManagedPropAMMEngine engine;
    ManagedPropAMMTestEarnVault vault;
    uint16 decoyPair;
    uint16 pairIndex;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new PropAMMTestToken("USDC.e");
        baseToken = new PropAMMTestToken("BASE");
        otherBase = new PropAMMTestToken("OTHER");
        oracle = new PropAMMTestOracle();
        pool = new ManagedPropAMMTestVenue();
        // The engine's pair is not the pool's first: a swap that named pair 0 would trade other tokens.
        decoyPair = pool.addPair(otherBase, usdc, new PropAMMTestOracle());
        pairIndex = pool.addPair(baseToken, usdc, oracle);
        pool.setPairAccess(decoyPair, IManagedPropAMMVenue.AccessMode.Open);
        pool.setPairAccess(pairIndex, IManagedPropAMMVenue.AccessMode.Listed);
        engine = _newEngine(pairIndex, 0, ROUTE);
        pool.setMember(pairIndex, 0, address(engine), true);
        vault = new ManagedPropAMMTestEarnVault(engine, usdc);
        engine.initializeEarnVault(address(vault));
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 1000e6);
        baseToken.mint(address(pool), 10000e6);
        otherBase.mint(address(pool), 10000e6);
        usdc.mint(address(pool), 10000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _newEngine(uint16 index, uint64 sponsor, bytes32 route) internal returns (ManagedPropAMMEngine) {
        return new ManagedPropAMMEngine(
            address(pool), index, sponsor, address(usdc), address(baseToken), address(this), 1 days, route
        );
    }

    function _expectInvalidConstruction(
        address pool_,
        uint16 index,
        address asset_,
        address base_,
        uint256 maxAge,
        bytes32 route
    ) internal {
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        new ManagedPropAMMEngine(pool_, index, 0, asset_, base_, address(this), maxAge, route);
    }

    function buy(address who, uint256 assets) internal returns (uint256) {
        vm.prank(who);
        return vault.deposit(assets);
    }

    /// @dev Every engine fund flow reverts with `reason` and moves nothing.
    function _assertEveryFlowReverts(uint256 held, bytes4 reason) internal {
        uint256 aliceCash = usdc.balanceOf(alice);
        uint256 poolCash = usdc.balanceOf(address(pool));
        uint256 poolBase = baseToken.balanceOf(address(pool));
        vm.prank(alice);
        vm.expectRevert(reason);
        vault.deposit(105e6);
        vm.expectRevert(reason);
        vault.redeem(held, alice, 1);
        vm.expectRevert(reason);
        vault.withdraw(1e6, alice);
        assertEq(engine.totalShares(), held);
        assertEq(usdc.balanceOf(alice), aliceCash);
        assertEq(usdc.balanceOf(address(pool)), poolCash);
        assertEq(baseToken.balanceOf(address(pool)), poolBase);
        assertEq(usdc.balanceOf(address(engine)), 0);
        assertEq(usdc.allowance(address(engine), address(pool)), 1);
        assertEq(baseToken.allowance(address(engine), address(pool)), 1);
    }

    function testConstructorBindsThePairItsTokensAndTheSponsor() public {
        pool.addSponsor(SPONSOR);
        ManagedPropAMMEngine candidate = _newEngine(pairIndex, SPONSOR, bytes32(uint256(2)));
        assertEq(address(candidate.pool()), address(pool));
        assertEq(candidate.pairIndex(), pairIndex);
        assertEq(candidate.sponsorId(), SPONSOR);
        assertEq(candidate.asset(), address(usdc));
        assertEq(candidate.baseToken(), address(baseToken));
        assertEq(address(candidate.priceOracle()), address(oracle));
        assertEq(candidate.oracleDecimals(), 8);
        assertEq(candidate.priceScale(), 1e8);
        assertEq(candidate.shareScale(), 1e6);
        assertEq(candidate.maxOracleAge(), 1 days);
        assertEq(candidate.customerId(), bytes32(uint256(2)));
        assertEq(candidate.earnVault(), address(0));
        assertEq(candidate.owner(), address(this));
        assertEq(usdc.allowance(address(candidate), address(pool)), 1);
        assertEq(baseToken.allowance(address(candidate), address(pool)), 1);
    }

    function testConstructorRejectsAnUnknownOrRemovedPair() public {
        _expectInvalidConstruction(address(pool), pool.pairCount(), address(usdc), address(baseToken), 1 days, ROUTE);
        _expectInvalidConstruction(address(pool), type(uint16).max, address(usdc), address(baseToken), 1 days, ROUTE);
        pool.removePair(pairIndex);
        _expectInvalidConstruction(address(pool), pairIndex, address(usdc), address(baseToken), 1 days, ROUTE);
    }

    function testConstructorRejectsAPairWithOtherTokens() public {
        // Another live pair of the same pool: same quote, another base.
        _expectInvalidConstruction(address(pool), decoyPair, address(usdc), address(baseToken), 1 days, ROUTE);
        // The right pair, with a token that is not its base or not its quote.
        _expectInvalidConstruction(address(pool), pairIndex, address(usdc), address(otherBase), 1 days, ROUTE);
        _expectInvalidConstruction(address(pool), pairIndex, address(otherBase), address(baseToken), 1 days, ROUTE);
        // The pair's tokens the wrong way round: the asset must be the quote.
        _expectInvalidConstruction(address(pool), pairIndex, address(baseToken), address(usdc), 1 days, ROUTE);
        _expectInvalidConstruction(address(pool), pairIndex, address(usdc), address(usdc), 1 days, ROUTE);
        _expectInvalidConstruction(address(pool), pairIndex, address(0), address(baseToken), 1 days, ROUTE);
        _expectInvalidConstruction(address(pool), pairIndex, address(usdc), address(0), 1 days, ROUTE);
    }

    function testConstructorRejectsInvalidPoolWindowRouteAndHook() public {
        _expectInvalidConstruction(address(0xdead), pairIndex, address(usdc), address(baseToken), 1 days, ROUTE);
        _expectInvalidConstruction(address(pool), pairIndex, address(usdc), address(baseToken), 0, ROUTE);
        _expectInvalidConstruction(address(pool), pairIndex, address(usdc), address(baseToken), 1 days, bytes32(0));
        pool.setPairHook(pairIndex, address(this));
        _expectInvalidConstruction(address(pool), pairIndex, address(usdc), address(baseToken), 1 days, ROUTE);
    }

    function testConstructorRejectsPairDecimalsThatDifferFromTheTokens() public {
        vm.mockCall(address(baseToken), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        _expectInvalidConstruction(address(pool), pairIndex, address(usdc), address(baseToken), 1 days, ROUTE);
        vm.clearMockedCalls();
        vm.mockCall(address(oracle), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        _expectInvalidConstruction(address(pool), pairIndex, address(usdc), address(baseToken), 1 days, ROUTE);
    }

    function testSwapsNameThePairAndSponsorAndPayTheEngine() public {
        pool.addSponsor(SPONSOR);
        pool.setPairSponsor(pairIndex, SPONSOR, true);
        ManagedPropAMMEngine sponsored = _newEngine(pairIndex, SPONSOR, ROUTE);
        pool.setMember(pairIndex, SPONSOR, address(sponsored), true);
        ManagedPropAMMTestEarnVault sponsoredVault = new ManagedPropAMMTestEarnVault(sponsored, usdc);
        sponsored.initializeEarnVault(address(sponsoredVault));
        vm.prank(alice);
        usdc.approve(address(sponsoredVault), type(uint256).max);

        uint256 otherBefore = otherBase.balanceOf(address(pool));
        vm.prank(alice);
        uint256 shares = sponsoredVault.deposit(105e6);
        assertEq(shares, 100e6);
        assertEq(pool.lastPairIndex(), pairIndex);
        assertEq(pool.lastSponsorId(), SPONSOR);
        assertEq(baseToken.balanceOf(address(sponsored)), 100e6);
        assertEq(otherBase.balanceOf(address(pool)), otherBefore);

        assertEq(sponsoredVault.withdraw(21e6, alice), 20e6);
        assertEq(sponsoredVault.redeem(80e6, alice, 84e6), 84e6);
        assertEq(pool.lastSponsorId(), SPONSOR);
        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(sponsored.totalShares(), 0);
        assertEq(usdc.balanceOf(address(sponsored)), 0);
        assertEq(usdc.allowance(address(sponsored), address(pool)), 1);
        assertEq(baseToken.allowance(address(sponsored), address(pool)), 1);
        // The home-list engine, on the same pair, was not touched.
        assertEq(engine.totalShares(), 0);
    }

    function testEnginesOnOnePoolKeepSeparateRoundingRoutes() public {
        ManagedPropAMMEngine second = _newEngine(pairIndex, 0, ROUTE);
        pool.setMember(pairIndex, 0, address(second), true);
        ManagedPropAMMTestEarnVault secondVault = new ManagedPropAMMTestEarnVault(second, usdc);
        second.initializeEarnVault(address(secondVault));
        vm.prank(bob);
        usdc.approve(address(secondVault), type(uint256).max);

        uint256 first = buy(alice, 1e6 + 1);
        vm.prank(bob);
        uint256 other = secondVault.deposit(1e6 + 1);
        assertEq(first, other);
        assertGt(pool.roundingCredit(pool.roundingRouteKey(pairIndex, address(engine), ROUTE)), 0);
        assertEq(
            pool.roundingCredit(pool.roundingRouteKey(pairIndex, address(engine), ROUTE)),
            pool.roundingCredit(pool.roundingRouteKey(pairIndex, address(second), ROUTE))
        );
        assertEq(engine.totalShares(), first);
        assertEq(second.totalShares(), other);
    }

    function testClosedPairRevertsEveryFlow() public {
        uint256 held = buy(alice, 105e6);
        pool.setPairAccess(pairIndex, IManagedPropAMMVenue.AccessMode.Closed);
        _assertEveryFlowReverts(held, ManagedPropAMMEngine.InvalidConfiguration.selector);
        (, bool admitted,,,) = engine.liquidityStatus();
        assertFalse(admitted);
        // Valuation does not depend on access.
        assertEq(engine.totalAssets(), 105e6);

        pool.setPairAccess(pairIndex, IManagedPropAMMVenue.AccessMode.Listed);
        assertEq(vault.redeem(held, alice, 105e6), 105e6);
    }

    function testUnlistedTakerRevertsEveryFlow() public {
        uint256 held = buy(alice, 105e6);
        pool.setMember(pairIndex, 0, address(engine), false);
        _assertEveryFlowReverts(held, ManagedPropAMMEngine.InvalidConfiguration.selector);

        // A listing on another list or another pair does not admit the engine on its own.
        pool.addSponsor(SPONSOR);
        pool.setPairSponsor(pairIndex, SPONSOR, true);
        pool.setMember(pairIndex, SPONSOR, address(engine), true);
        pool.setMember(decoyPair, 0, address(engine), true);
        _assertEveryFlowReverts(held, ManagedPropAMMEngine.InvalidConfiguration.selector);

        pool.setMember(pairIndex, 0, address(engine), true);
        assertEq(vault.redeem(held, alice, 105e6), 105e6);
    }

    function testPausedPoolRevertsEveryFlow() public {
        uint256 held = buy(alice, 105e6);
        pool.setPaused(true);
        _assertEveryFlowReverts(held, ManagedPropAMMEngine.InvalidConfiguration.selector);
        (bool paused, bool admitted,,,) = engine.liquidityStatus();
        assertTrue(paused);
        assertTrue(admitted);

        pool.setPaused(false);
        assertEq(vault.redeem(held, alice, 105e6), 105e6);
    }

    function testDeniedTakerRevertsEveryFlowEvenOnAnOpenPair() public {
        uint256 held = buy(alice, 105e6);
        pool.setDenied(address(engine), true);
        _assertEveryFlowReverts(held, ManagedPropAMMEngine.InvalidConfiguration.selector);
        pool.setPairAccess(pairIndex, IManagedPropAMMVenue.AccessMode.Open);
        _assertEveryFlowReverts(held, ManagedPropAMMEngine.InvalidConfiguration.selector);

        pool.setDenied(address(engine), false);
        pool.setMember(pairIndex, 0, address(engine), false);
        // An Open pair admits every taker it does not deny, whatever the list.
        assertEq(vault.redeem(held, alice, 105e6), 105e6);
    }

    function testSponsorRefusalsRevertEveryFlow() public {
        // An engine whose sponsor id the pool never registered.
        ManagedPropAMMEngine sponsored = _newEngine(pairIndex, SPONSOR, ROUTE);
        ManagedPropAMMTestEarnVault sponsoredVault = new ManagedPropAMMTestEarnVault(sponsored, usdc);
        sponsored.initializeEarnVault(address(sponsoredVault));
        vm.prank(alice);
        usdc.approve(address(sponsoredVault), type(uint256).max);
        pool.setMember(pairIndex, SPONSOR, address(sponsored), true);

        vm.prank(alice);
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        sponsoredVault.deposit(105e6);

        pool.addSponsor(SPONSOR);
        vm.prank(alice);
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        sponsoredVault.deposit(105e6);

        pool.setPairSponsor(pairIndex, SPONSOR, true);
        vm.prank(alice);
        uint256 held = sponsoredVault.deposit(105e6);

        pool.setSponsorEnabled(SPONSOR, false);
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        sponsoredVault.redeem(held, alice, 1);
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        sponsoredVault.withdraw(1e6, alice);
        assertEq(sponsored.totalShares(), held);
        assertEq(usdc.balanceOf(alice), 895e6);

        pool.setSponsorEnabled(SPONSOR, true);
        assertEq(sponsoredVault.redeem(held, alice, 105e6), 105e6);
    }

    function testRemovedPairFailsClosed() public {
        uint256 held = buy(alice, 105e6);
        pool.removePair(pairIndex);
        vm.expectRevert(ManagedPropAMMEngine.InvalidOracle.selector);
        engine.totalAssets();
        assertFalse(engine.isFeeValuationFresh());
        vm.prank(alice);
        vm.expectRevert(ManagedPropAMMEngine.InvalidOracle.selector);
        vault.deposit(105e6);
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        vault.redeem(held, alice, 1);
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        vault.withdraw(1e6, alice);
        assertEq(engine.totalShares(), held);
        assertEq(usdc.balanceOf(alice), 895e6);
        (, bool admitted,,,) = engine.liquidityStatus();
        assertFalse(admitted);
    }

    function testHookInstalledAfterDeploymentBlocksDepositsNotExits() public {
        uint256 held = buy(alice, 105e6);
        uint256 aliceCash = usdc.balanceOf(alice);
        pool.setPairHook(pairIndex, address(this));

        vm.prank(alice);
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        vault.deposit(105e6);
        (, bool admitted,,,) = engine.liquidityStatus();
        assertFalse(admitted);
        assertEq(engine.totalShares(), held);
        assertEq(engine.totalAssets(), 105e6);

        // The hook rule is a deposit admission check: holders still leave both ways.
        vault.withdraw(21e6, alice);
        assertEq(engine.totalShares(), held - 20e6);
        assertEq(vault.redeem(held - 20e6, alice, 84e6), 84e6);
        assertEq(engine.totalShares(), 0);
        assertEq(usdc.balanceOf(alice), aliceCash + 105e6);
        assertEq(usdc.allowance(address(engine), address(pool)), 1);
        assertEq(baseToken.allowance(address(engine), address(pool)), 1);
    }

    function testOutputPaidToAnotherAccountRevertsAtomically() public {
        uint256 held = buy(alice, 105e6);
        pool.setPayee(address(0xbad));

        vm.prank(bob);
        vm.expectRevert(ManagedPropAMMEngine.InexactTransfer.selector);
        vault.deposit(105e6);
        vm.expectRevert(ManagedPropAMMEngine.InsufficientBacking.selector);
        vault.redeem(held, alice, 1);
        vm.expectRevert(ManagedPropAMMEngine.InexactTransfer.selector);
        vault.withdraw(1e6, alice);

        assertEq(engine.totalShares(), held);
        assertEq(usdc.balanceOf(bob), 1000e6);
        assertEq(usdc.balanceOf(alice), 895e6);
        assertEq(usdc.balanceOf(address(0xbad)), 0);
        assertEq(baseToken.balanceOf(address(0xbad)), 0);
        assertEq(usdc.allowance(address(engine), address(pool)), 1);
        assertEq(baseToken.allowance(address(engine), address(pool)), 1);
    }

    function testLiquidityStatusReadsThePoolAndTheEnginesAdmission() public {
        usdc.mint(address(engine), 3e6);
        (bool paused, bool admitted, uint256 idleCash, uint256 venueCash, uint256 venueBase) = engine.liquidityStatus();
        assertFalse(paused);
        assertTrue(admitted);
        assertEq(idleCash, 3e6);
        assertEq(venueCash, 10000e6);
        assertEq(venueBase, 10000e6);
    }

    function testFutureAndZeroPricesFail() public {
        oracle.set(105_000_000, block.timestamp + 1);
        vm.expectRevert();
        engine.totalAssets();
        oracle.set(0, block.timestamp);
        vm.expectRevert();
        engine.totalAssets();
    }

    function testOnlyBoundVaultCanMoveFunds() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.deposit(1e6);
        vm.prank(alice);
        vm.expectRevert();
        engine.redeem(1, alice, 0);
        vm.prank(alice);
        vm.expectRevert();
        engine.withdraw(1, alice);
    }

    function testOracleReplacementFailsClosed() public {
        buy(alice, 105e6);
        pool.replaceOracle(pairIndex, new PropAMMTestOracle());
        vm.expectRevert();
        engine.totalAssets();
        assertFalse(engine.isFeeValuationFresh());
    }

    function testFeeOnInputTokenRevertsAtomically() public {
        usdc.setChargeFee(true);
        uint256 balance = usdc.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(105e6);
        assertEq(usdc.balanceOf(alice), balance);
        assertEq(engine.totalShares(), 0);
    }

    function testFeeOnBaseTokenRevertsAtomically() public {
        baseToken.setChargeFee(true);
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(105e6);
        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(baseToken.balanceOf(address(engine)), 0);
    }

    function testReentrancyAndTransientValuationAreRejected() public {
        buy(alice, 105e6);
        pool.setCallback(address(vault));
        buy(bob, 105e6);
        assertTrue(pool.callbackAttempted());
        assertFalse(pool.reentrySucceeded());
        assertFalse(pool.readSucceeded());
        assertEq(engine.totalAssets(), 210e6);
    }

    function testExactWithdrawalRoundsSharesUp() public {
        uint256 shares = buy(alice, 105e6);
        oracle.set(110_000_000, block.timestamp);
        uint256 expected = engine.previewWithdraw(1);
        assertEq(vault.withdraw(1, alice), expected);
        assertEq(engine.totalShares(), shares - expected);
    }

    function testBindingIsOwnerOnlyOnceAndAssetChecked() public {
        vm.expectRevert();
        engine.initializeEarnVault(address(vault));

        ManagedPropAMMEngine candidate = _newEngine(pairIndex, 0, bytes32(uint256(2)));
        vm.prank(alice);
        vm.expectRevert();
        candidate.initializeEarnVault(address(vault));
        ManagedPropAMMTestEarnVault wrongAssetVault = new ManagedPropAMMTestEarnVault(candidate, baseToken);
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        candidate.initializeEarnVault(address(wrongAssetVault));
        assertEq(candidate.earnVault(), address(0));
    }

    function testFeeOnPayoutRevertsWithoutConsumingBase() public {
        uint256 shares = buy(alice, 105e6);
        usdc.setChargeFee(true);
        vm.expectRevert();
        vault.redeem(shares, alice, 1);
        assertEq(engine.totalShares(), shares);
        assertEq(usdc.balanceOf(alice), 895e6);
    }
}
