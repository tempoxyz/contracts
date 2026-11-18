// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { Conversion } from "../../src/programs/Conversion.sol";
import { CoreEnv } from "../core/harness/CoreEnv.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";

/// @notice Conversion on its own: reference rates and their age, quotes and swaps through the hub, the reference
///         floor and ceiling every swap stays within, conversion cost, owners' rate tolerances per program, and who
///         configures it. Purchases that convert are in CashSourceConversion.t.sol.
contract ConversionTest is CoreEnv {
    // EUR at $1.10 with a 30 bps conversion cost each way.
    uint256 internal constant BID = 1.0967e18;
    uint256 internal constant ASK = 1_103_310_000_000_000_000; // ~1.1 / 0.997

    ITIP20Token internal eur;
    Conversion internal conv;
    FixedPricePool internal bid;
    FixedPricePool internal ask;
    address internal trustedProgram = makeAddr("program");

    function setUp() public {
        _deployCore();
        eur = _createToken("Euro", "EURX");
        conv = new Conversion(address(usd), address(this));
        bid = new FixedPricePool(address(eur), address(usd), BID);
        ask = new FixedPricePool(address(eur), address(usd), ASK);
        usd.mint(address(bid), 1_000_000e6);
        eur.mint(address(ask), 1_000_000e6);
        conv.setVenue(address(eur), address(usd), address(bid), true);
        conv.setVenue(address(usd), address(eur), address(ask), false);
        conv.setReferenceRate(address(eur), 1.1e18);
        conv.setTrusted(trustedProgram, true);
        usd.mint(address(conv), 100_000e6);
        eur.mint(address(conv), 100_000e6);
    }

    // Conversion on its own.

    function test_referenceRate_staleAfterMaxAge() public {
        assertEq(conv.mid(address(eur), address(usd)), 1.1e18);
        vm.warp(vm.getBlockTimestamp() + conv.MAX_RATE_AGE() + 1);
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStale.selector, address(eur)));
        conv.mid(address(eur), address(usd));
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStale.selector, address(eur)));
        conv.referenceRate(address(eur));
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStale.selector, address(eur)));
        conv.costBps(address(eur), address(usd), 1e18);
        // The hub never goes stale, and setting the rate again makes it current.
        assertEq(conv.referenceRate(address(usd)), 1e18);
        conv.setReferenceRate(address(eur), 1.2e18);
        assertEq(conv.mid(address(eur), address(usd)), 1.2e18);
        assertEq(conv.rateUpdatedAt(address(eur)), vm.getBlockTimestamp());
    }

    function test_quotes_routeThroughTheHub() public {
        FixedPricePool gbpAsk = new FixedPricePool(address(otherUsd), address(usd), 1.25e18);
        otherUsd.mint(address(gbpAsk), 1_000_000e6);
        conv.setVenue(address(usd), address(otherUsd), address(gbpAsk), false);
        conv.setReferenceRate(address(otherUsd), 1.25e18);
        assertTrue(conv.converts(address(eur), address(otherUsd)));
        assertFalse(conv.converts(address(otherUsd), address(eur)));
        uint256 out = conv.quoteIn(address(eur), address(otherUsd), 100e6);
        assertEq(out, uint256(100e6) * BID / 1e18 * 1e18 / 1.25e18);
        eur.mint(bob, 100e6);
        vm.startPrank(bob);
        eur.approve(address(conv), 100e6);
        assertEq(conv.swapExactIn(address(eur), address(otherUsd), 100e6, out, bob), out);
        vm.stopPrank();
        assertEq(otherUsd.balanceOf(bob), out);
        assertEq(eur.balanceOf(address(conv)), 100_000e6, "no float used");
    }

    function test_swapExactOut_paysExactlyAndPullsOnlyWhatItSpends() public {
        uint256 cost = conv.quoteOut(address(eur), address(usd), 50e6);
        eur.mint(bob, 100e6);
        vm.startPrank(bob);
        eur.approve(address(conv), type(uint256).max);
        assertEq(conv.swapExactOut(address(eur), address(usd), 50e6, cost, bob), cost);
        vm.stopPrank();
        assertEq(usd.balanceOf(bob), 50e6);
        assertEq(eur.balanceOf(bob), 100e6 - cost);
    }

    function test_swapExactOut_revertsPastTheBound() public {
        uint256 cost = conv.quoteOut(address(eur), address(usd), 50e6);
        eur.mint(bob, 100e6);
        vm.startPrank(bob);
        eur.approve(address(conv), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Conversion.Slippage.selector, cost, cost - 1));
        conv.swapExactOut(address(eur), address(usd), 50e6, cost - 1, bob);
        vm.stopPrank();
    }

    function test_swapExactIn_zeroMinOutTakesTheReferenceFloor() public {
        // The venue pays half the reference rate: a sale with no bound is refused.
        bid.setPrice(0.55e18);
        eur.mint(bob, 100e6);
        vm.startPrank(bob);
        eur.approve(address(conv), 100e6);
        uint256 floor = conv.minOutFor(address(eur), address(usd), 100e6);
        assertEq(floor, 108.9e6, "the reference value less MAX_SLIPPAGE_BPS");
        vm.expectRevert(abi.encodeWithSelector(Conversion.Slippage.selector, 55e6, floor));
        conv.swapExactIn(address(eur), address(usd), 100e6, 0, bob);
        vm.stopPrank();
        assertEq(eur.balanceOf(bob), 100e6);
    }

    function test_swapExactIn_refusesABoundBelowTheReferenceFloor() public {
        bid.setPrice(0.55e18);
        eur.mint(bob, 100e6);
        vm.startPrank(bob);
        eur.approve(address(conv), 100e6);
        vm.expectRevert(abi.encodeWithSelector(Conversion.MinOutTooLow.selector, 1, 108.9e6));
        conv.swapExactIn(address(eur), address(usd), 100e6, 1, bob);
        vm.stopPrank();
        // Within the floor the venue's price stands.
        bid.setPrice(BID);
        vm.startPrank(bob);
        assertEq(conv.swapExactIn(address(eur), address(usd), 100e6, 0, bob), 109.67e6);
        vm.stopPrank();
    }

    function test_swapExactOut_refusesPayingPastTheReferenceCeiling() public {
        ask.setPrice(2.2e18);
        usd.mint(bob, 1000e6);
        vm.startPrank(bob);
        usd.approve(address(conv), 1000e6);
        uint256 ceiling = conv.maxInFor(address(usd), address(eur), 100e6);
        assertEq(ceiling, 111.1e6, "the reference cost plus MAX_SLIPPAGE_BPS");
        vm.expectRevert(abi.encodeWithSelector(Conversion.Slippage.selector, 220e6, ceiling));
        conv.swapExactOut(address(usd), address(eur), 100e6, 1000e6, bob);
        vm.stopPrank();
    }

    function test_quotes_boundedByTheReferenceRateAndStale() public {
        // A venue quoting above the reference rate values nothing above it.
        bid.setPrice(2e18);
        assertEq(conv.quoteIn(address(eur), address(usd), 100e6), 110e6);
        ask.setPrice(0.5e18);
        assertEq(conv.quoteOut(address(usd), address(eur), 100e6), 110e6);
        vm.warp(vm.getBlockTimestamp() + conv.MAX_RATE_AGE() + 1);
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStale.selector, address(eur)));
        conv.quoteIn(address(eur), address(usd), 100e6);
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStale.selector, address(eur)));
        conv.quoteOut(address(usd), address(eur), 100e6);
    }

    function test_costBps_measuresAgainstTheReferenceRate() public view {
        assertEq(conv.costBps(address(eur), address(usd), conv.rate(address(eur), address(usd))), 30);
        assertEq(conv.costBps(address(eur), address(usd), 1.2e18), 0);
    }

    function test_lapsed_followsTheOwnersToleranceForTheCallingProgram() public {
        vm.prank(alice);
        conv.setRateTolerance(trustedProgram, 200);
        vm.startPrank(trustedProgram);
        assertFalse(conv.lapsed(alice, 1e18, 1.02e18));
        assertTrue(conv.lapsed(alice, 1e18, 1.0201e18));
        vm.stopPrank();
        // Another program sees no tolerance, so its locks never lapse.
        assertFalse(conv.lapsed(alice, 1e18, 2e18));
    }

    function test_configuration_isTheOwnersAlone() public {
        vm.startPrank(bob);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.setVenue(address(eur), address(usd), address(bid), true);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.setReferenceRate(address(eur), 2e18);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.setTrusted(bob, true);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.sweep(address(eur), bob, 1);
        vm.expectRevert(Conversion.InvalidAmount.selector);
        conv.setRateTolerance(trustedProgram, 10_001);
        vm.stopPrank();
    }

    function test_convertAtMid_onlyForTrustedPrograms() public {
        usd.mint(bob, 10e6);
        vm.startPrank(bob);
        usd.approve(address(conv), 10e6);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.convertAtMid(address(usd), address(eur), 10e6, bob);
        vm.stopPrank();
    }

    function test_convertAtMid_paysAtTheReferenceRateFromTheFloat() public {
        usd.mint(trustedProgram, 22e6);
        vm.startPrank(trustedProgram);
        usd.approve(address(conv), 22e6);
        assertEq(conv.convertAtMid(address(usd), address(eur), 22e6, bob), 20e6);
        vm.stopPrank();
        assertEq(eur.balanceOf(bob), 20e6);
        assertEq(eur.balanceOf(address(conv)), 100_000e6 - 20e6);
    }
}
