// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { Conversion } from "../../../src/spend/programs/Conversion.sol";
import { CoreEnv } from "../core/harness/CoreEnv.sol";

/// @notice How far and how fast the Conversion's owner moves a reference rate, and how ownership changes hands.
contract ReferenceRateBoundsTest is CoreEnv {
    ITIP20Token internal eur;
    Conversion internal conv;

    function setUp() public {
        _deployCore();
        eur = _createToken("Euro", "EURX");
        conv = new Conversion(address(usd), address(this));
    }

    function test_setReferenceRate_firstRateWaitsForTheDelay() public {
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStepTooLarge.selector, address(eur), 1.1e18));
        conv.setReferenceRate(address(eur), 1.1e18);
        conv.scheduleReferenceRate(address(eur), 1.1e18);
        (uint128 rate, uint64 readyAt) = conv.scheduledRateOf(address(eur));
        assertEq(rate, 1.1e18);
        assertEq(readyAt, vm.getBlockTimestamp() + conv.RATE_DELAY());
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStepTooLarge.selector, address(eur), 1.1e18));
        conv.setReferenceRate(address(eur), 1.1e18);
        vm.warp(readyAt);
        conv.setReferenceRate(address(eur), 1.1e18);
        assertEq(conv.referenceRate(address(eur)), 1.1e18);
        // The schedule is spent.
        (rate, readyAt) = conv.scheduledRateOf(address(eur));
        assertEq(readyAt, 0);
    }

    function test_setReferenceRate_movesAtMostOneStepPerWindow() public {
        _first(1e18);
        // 2% from where the window opened, either way, at once.
        conv.setReferenceRate(address(eur), 1.02e18);
        conv.setReferenceRate(address(eur), 0.98e18);
        // Steps within a window add up from where it opened, never from the last rate.
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStepTooLarge.selector, address(eur), 0.9799e18));
        conv.setReferenceRate(address(eur), 0.9799e18);
        vm.warp(vm.getBlockTimestamp() + conv.RATE_STEP_WINDOW() - 1);
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStepTooLarge.selector, address(eur), 0.97e18));
        conv.setReferenceRate(address(eur), 0.97e18);
        // A new window opens from the rate it finds.
        vm.warp(vm.getBlockTimestamp() + 1);
        conv.setReferenceRate(address(eur), 0.97e18);
        (uint128 anchor,) = conv.rateWindowOf(address(eur));
        assertEq(anchor, 0.98e18);
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStepTooLarge.selector, address(eur), 0.95e18));
        conv.setReferenceRate(address(eur), 0.95e18);
    }

    function test_setReferenceRate_refreshingTheSameRateKeepsItCurrent() public {
        _first(1e18);
        vm.warp(vm.getBlockTimestamp() + conv.MAX_RATE_AGE() - 1);
        conv.setReferenceRate(address(eur), 1e18);
        vm.warp(vm.getBlockTimestamp() + conv.MAX_RATE_AGE() - 1);
        assertEq(conv.referenceRate(address(eur)), 1e18);
    }

    function test_scheduleReferenceRate_largeMoveWaitsAndZeroCancels() public {
        _first(1e18);
        conv.scheduleReferenceRate(address(eur), 2e18);
        vm.warp(vm.getBlockTimestamp() + conv.RATE_DELAY());
        // Only the rate scheduled may be set past the step.
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStepTooLarge.selector, address(eur), 1.9e18));
        conv.setReferenceRate(address(eur), 1.9e18);
        conv.scheduleReferenceRate(address(eur), 0);
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStepTooLarge.selector, address(eur), 2e18));
        conv.setReferenceRate(address(eur), 2e18);
        // Scheduling again restarts the delay.
        conv.scheduleReferenceRate(address(eur), 2e18);
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStepTooLarge.selector, address(eur), 2e18));
        conv.setReferenceRate(address(eur), 2e18);
        vm.warp(vm.getBlockTimestamp() + conv.RATE_DELAY());
        conv.setReferenceRate(address(eur), 2e18);
        assertEq(conv.referenceRate(address(eur)), 2e18);
    }

    function test_rates_areTheOwnersAlone() public {
        vm.startPrank(bob);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.scheduleReferenceRate(address(eur), 1e18);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.setReferenceRate(address(eur), 1e18);
        vm.stopPrank();
    }

    function test_setOwner_takesEffectOnceTheNewOwnerAccepts() public {
        conv.setOwner(bob);
        assertEq(conv.owner(), address(this));
        assertEq(conv.pendingOwner(), bob);
        vm.prank(alice);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.acceptOwner();
        // The current owner still acts, and may name someone else instead.
        conv.scheduleReferenceRate(address(eur), 1e18);
        conv.setOwner(alice);
        vm.prank(bob);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.acceptOwner();
        vm.prank(alice);
        conv.acceptOwner();
        assertEq(conv.owner(), alice);
        assertEq(conv.pendingOwner(), address(0));
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.scheduleReferenceRate(address(eur), 1e18);
    }

    function test_setOwner_zeroFixesTheConversionAtOnce() public {
        conv.setOwner(bob);
        conv.setOwner(address(0));
        assertEq(conv.owner(), address(0));
        assertEq(conv.pendingOwner(), address(0));
        vm.prank(bob);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.acceptOwner();
    }

    function _first(uint256 rate) internal {
        conv.scheduleReferenceRate(address(eur), rate);
        vm.warp(vm.getBlockTimestamp() + conv.RATE_DELAY());
        conv.setReferenceRate(address(eur), rate);
    }
}
