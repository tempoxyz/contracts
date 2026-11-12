// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { SavingsFacility } from "../../src/core/SavingsFacility.sol";
import { CARDS_ADDRESS } from "../../src/core/interfaces/ICards.sol";
import { IReservations, RESERVATIONS_ADDRESS } from "../../src/core/interfaces/IReservations.sol";
import { CoreEnv } from "./harness/CoreEnv.sol";
import { MockCards } from "./harness/MockCards.sol";
import { MockReservations } from "./harness/MockReservations.sol";

/// @notice `SavingsFacility` over a real EarnVault and TIP-20 precompiles, with reservations state written
///         directly: a share hold captured to the facility, settled by the issuer.
contract SavingsFacilityTest is CoreEnv {
    MockReservations internal reservations = MockReservations(RESERVATIONS_ADDRESS);
    MockCards internal cards = MockCards(CARDS_ADDRESS);
    SavingsFacility internal facility;

    address internal issuer = makeAddr("issuer");
    address internal settlement = makeAddr("issuer.settlement");
    address internal funder = makeAddr("funder");
    bytes32 internal constant ID = bytes32("auth-1");

    uint256 internal constant FLOAT = 10_000e6;

    function setUp() public {
        _deployCore();
        vm.etch(RESERVATIONS_ADDRESS, address(new MockReservations()).code);
        vm.etch(CARDS_ADDRESS, address(new MockCards()).code);
        facility = new SavingsFacility(IEarnVault(address(earnVault)), issuer, settlement, funder);
        usd.mint(address(facility), FLOAT);
        usd.mint(alice, 1000e6);
        _depositEarn(alice, 1000e6);
    }

    function test_settle_paysValueAndRefillsFloat() public {
        uint256 shares = _captureShares(alice, ID, earnVault.previewWithdraw(300e6));
        uint256 value = earnVault.previewRedeem(shares);

        vm.prank(issuer);
        (uint256 settledShares, uint256 assets) = facility.settle(alice, ID, value);

        assertEq(settledShares, shares);
        assertEq(assets, value);
        assertEq(usd.balanceOf(settlement), value);
        assertEq(earnShare.balanceOf(address(facility)), 0);
        // Redemption returns what the issuer was paid, so the float is whole again (to rounding).
        assertApproxEqAbs(facility.float(), FLOAT, 1);
        assertEq(facility.settled(alice, ID), shares);
    }

    function test_payOut_paysSweptSharesToTheRecipient() public {
        address state = makeAddr("state");
        uint256 shares = earnShare.balanceOf(alice);
        _sweepShares(alice, state, shares);
        uint256 value = earnVault.previewRedeem(shares);

        (uint256 paidShares, uint256 assets) = facility.payOut(alice);

        assertEq(paidShares, shares);
        assertEq(assets, value);
        assertEq(usd.balanceOf(state), value);
        assertEq(earnShare.balanceOf(address(facility)), 0);
        assertApproxEqAbs(facility.float(), FLOAT, 1);
        assertEq(facility.paidOut(alice), shares);
    }

    function test_payOut_onlyNewSweeps() public {
        address state = makeAddr("state");
        _sweepShares(alice, state, 100e6);
        facility.payOut(alice);
        vm.expectRevert(SavingsFacility.NothingToSettle.selector);
        facility.payOut(alice);
        // A later sweep pays only its own shares.
        _sweepShares(alice, state, 50e6);
        (uint256 paidShares,) = facility.payOut(alice);
        assertEq(paidShares, 50e6);
    }

    function test_payOut_needsARecipient() public {
        vm.expectRevert(SavingsFacility.ZeroAddress.selector);
        facility.payOut(alice);
    }

    function test_settle_onlyNewCaptures() public {
        _captureShares(alice, ID, 100e6);
        vm.startPrank(issuer);
        facility.settle(alice, ID, 0);
        vm.expectRevert(SavingsFacility.NothingToSettle.selector);
        facility.settle(alice, ID, 0);
        vm.stopPrank();
    }

    function test_settle_onlyIssuer() public {
        _captureShares(alice, ID, 100e6);
        vm.expectRevert(SavingsFacility.NotIssuer.selector);
        facility.settle(alice, ID, 0);
    }

    function test_settle_rejectsCashHold() public {
        reservations.setHold(alice, ID, IReservations.Hold(address(usd), address(facility), 0, 0));
        reservations.setCaptured(alice, ID, 100e6);
        vm.prank(issuer);
        vm.expectRevert(SavingsFacility.NotFacilityHold.selector);
        facility.settle(alice, ID, 0);
    }

    function test_settle_rejectsHoldForAnotherPayee() public {
        reservations.setHold(alice, ID, IReservations.Hold(address(earnShare), settlement, 0, 0));
        reservations.setCaptured(alice, ID, 100e6);
        vm.prank(issuer);
        vm.expectRevert(SavingsFacility.NotFacilityHold.selector);
        facility.settle(alice, ID, 0);
    }

    function test_settle_rejectsOwnerInDebtToFacility() public {
        _captureShares(alice, ID, 100e6);
        reservations.setDebt(alice, address(earnShare), address(facility), 5e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(SavingsFacility.OwnerOwesShares.selector, 5e6));
        facility.settle(alice, ID, 0);
    }

    function test_settle_ignoresDebtToOthers() public {
        _captureShares(alice, ID, 100e6);
        reservations.setDebt(alice, address(earnShare), bob, 5e6);
        vm.prank(issuer);
        facility.settle(alice, ID, 0);
    }

    function test_settle_enforcesMinAssets() public {
        uint256 shares = _captureShares(alice, ID, 100e6);
        uint256 value = earnVault.previewRedeem(shares);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(SavingsFacility.AssetsBelowMinimum.selector, value, value + 1));
        facility.settle(alice, ID, value + 1);
    }

    function test_settle_deferredRedemptionPaysFromFloat() public {
        uint256 shares = _captureShares(alice, ID, 200e6);
        uint256 value = earnVault.previewRedeem(shares);
        bytes memory redeemCall =
            abi.encodeWithSignature("redeem(uint256,address,uint256)", shares, address(facility), value);
        vm.mockCallRevert(address(earnVault), redeemCall, "illiquid");

        vm.prank(issuer);
        facility.settle(alice, ID, value);
        assertEq(usd.balanceOf(settlement), value);
        assertEq(earnShare.balanceOf(address(facility)), shares);
        assertEq(earnShare.allowance(address(facility), address(earnVault)), 0);
        assertEq(facility.float(), FLOAT - value);

        vm.clearMockedCalls();
        vm.prank(funder);
        facility.redeemHeld(shares, 1);
        assertEq(earnShare.balanceOf(address(facility)), 0);
        assertApproxEqAbs(facility.float(), FLOAT, 1);
    }

    function test_settle_revertsWithoutQuote() public {
        uint256 shares = _captureShares(alice, ID, 200e6);
        vm.mockCallRevert(address(earnVault), abi.encodeWithSignature("previewRedeem(uint256)", shares), "no quote");
        vm.prank(issuer);
        vm.expectRevert(bytes("no quote"));
        facility.settle(alice, ID, 0);
        assertEq(facility.settled(alice, ID), 0);
        assertEq(earnShare.balanceOf(address(facility)), shares);
        assertEq(facility.float(), FLOAT);
    }

    function test_settle_revertsWithoutFloatWhenDeferred() public {
        vm.prank(funder);
        facility.withdraw(address(usd), funder, FLOAT);
        uint256 shares = _captureShares(alice, ID, 200e6);
        vm.mockCallRevert(
            address(earnVault),
            abi.encodeWithSignature(
                "redeem(uint256,address,uint256)", shares, address(facility), earnVault.previewRedeem(shares)
            ),
            "illiquid"
        );
        vm.prank(issuer);
        vm.expectRevert();
        facility.settle(alice, ID, 0);
        assertEq(facility.settled(alice, ID), 0);
    }

    function test_funderOnly() public {
        vm.expectRevert(SavingsFacility.NotFunder.selector);
        facility.withdraw(address(usd), address(this), 1);
        vm.expectRevert(SavingsFacility.NotFunder.selector);
        facility.redeemHeld(1, 0);
    }

    function test_constructor_rejectsZeroAddress() public {
        vm.expectRevert(SavingsFacility.ZeroAddress.selector);
        new SavingsFacility(IEarnVault(address(earnVault)), address(0), settlement, funder);
    }

    /// @dev What a capture of `shares` on a share hold leaves: the hold, its captured total, the shares paid.
    function _captureShares(address owner, bytes32 id, uint256 shares) internal returns (uint256) {
        reservations.setHold(owner, id, IReservations.Hold(address(earnShare), address(facility), 0, 0));
        reservations.setCaptured(owner, id, uint128(shares));
        vm.prank(owner);
        earnShare.transfer(address(facility), shares);
        return shares;
    }

    /// @dev Moves `shares` of `owner`'s into the facility and adds them to the payout record, as a sweep does.
    function _sweepShares(address owner, address to, uint256 shares) internal {
        (, uint128 swept) = cards.payoutOf(owner, address(earnShare), address(facility));
        vm.prank(owner);
        earnShare.transfer(address(facility), shares);
        cards.setPayout(owner, address(earnShare), address(facility), to, swept + uint128(shares));
    }
}
