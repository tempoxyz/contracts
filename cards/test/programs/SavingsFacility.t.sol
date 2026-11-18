// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { SavingsFacility } from "../../src/programs/SavingsFacility.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice The savings facility over a real EarnVault and the core model, with this test as the holder that places
///         share legs and drives the facility as their placer.
contract SavingsFacilityTest is ProgramsEnv {
    bytes32 internal constant ID = bytes32("leg-1");
    uint256 internal shares;

    function setUp() public {
        _deployPrograms();
        usd.mint(alice, 1000e6);
        shares = _depositEarn(alice, 1000e6);
        vm.prank(alice);
        core.approveHolder(address(this), address(earnShare), type(uint128).max, 0);
    }

    function test_constructor_standingApprovals() public view {
        assertEq(earnShare.allowance(address(facility), address(earnVault)), type(uint256).max);
        assertEq(usd.allowance(address(facility), address(earnVault)), type(uint256).max);
    }

    function test_capture_redeemsAndPaysSettlement() public {
        uint128 leg = _place(address(facility), earnVault.previewWithdraw(300e6));
        uint256 value = earnVault.previewRedeem(leg);
        uint256 assets = facility.capture(alice, ID, leg, true);
        assertEq(assets, value);
        assertEq(usd.balanceOf(settlement), value);
        assertEq(earnShare.balanceOf(address(facility)), 0);
        assertEq(facility.float(), FLOAT);
        assertEq(facility.heldShares(), 0);
        // The final capture ends the leg, so the core forgets it.
        assertEq(core.getHold(alice, address(this), ID).token, address(0));
        _assertCoreBalanced();
    }

    function test_capture_writesNoStorage() public {
        uint128 leg = _place(address(facility), 100e6);
        vm.record();
        facility.capture(alice, ID, leg, true);
        (, bytes32[] memory writes) = vm.accesses(address(facility));
        assertEq(writes.length, 0);
    }

    function test_capture_partial() public {
        uint128 leg = _place(address(facility), 200e6);
        facility.capture(alice, ID, 50e6, false);
        assertEq(core.getHold(alice, address(this), ID).held, leg - 50e6);
        facility.capture(alice, ID, 50e6, true);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertEq(earnShare.balanceOf(alice), shares - 100e6);
    }

    function test_capture_onlyPlacer() public {
        _place(address(facility), 100e6);
        vm.prank(bob);
        vm.expectRevert(SavingsFacility.NotPlacer.selector);
        facility.capture(alice, ID, 1e6, false);
    }

    function test_capture_onlyItsOwnLegs() public {
        _place(bob, 100e6);
        vm.expectRevert(SavingsFacility.NotFacilityHold.selector);
        facility.capture(alice, ID, 1e6, false);
    }

    function test_capture_notBeyondHeld() public {
        uint128 leg = _place(address(facility), 100e6);
        vm.expectRevert(abi.encodeWithSelector(SavingsFacility.ExceedsHeld.selector, uint256(leg) + 1, uint256(leg)));
        facility.capture(alice, ID, leg + 1, false);
    }

    function test_capture_deferredWhenVaultCannotRedeem() public {
        uint128 leg = _place(address(facility), 100e6);
        uint256 value = earnVault.previewRedeem(leg);
        vm.mockCallRevert(
            address(earnVault),
            abi.encodeWithSignature("redeem(uint256,address,uint256)", uint256(leg), settlement, value),
            "illiquid"
        );
        uint256 assets = facility.capture(alice, ID, leg, true);
        assertEq(assets, value);
        assertEq(usd.balanceOf(settlement), value);
        assertEq(facility.heldShares(), leg);
        assertEq(facility.float(), FLOAT - value);

        vm.clearMockedCalls();
        vm.prank(funder);
        facility.redeemHeld(leg, value);
        assertEq(facility.heldShares(), 0);
        assertGe(facility.float(), FLOAT - 1);
    }

    function test_capture_revertsWithoutQuote() public {
        uint128 leg = _place(address(facility), 100e6);
        vm.mockCall(address(earnVault), abi.encodeWithSignature("previewRedeem(uint256)", uint256(leg)), abi.encode(0));
        vm.expectRevert(SavingsFacility.NoQuote.selector);
        facility.capture(alice, ID, leg, true);
        assertEq(core.getHold(alice, address(this), ID).held, leg);
    }

    function test_refund_depositsCashAndRefundsShares() public {
        uint128 leg = _place(address(facility), earnVault.previewWithdraw(300e6));
        uint256 value = facility.capture(alice, ID, leg, true);
        usd.mint(address(this), value);
        usd.approve(address(facility), value);
        uint256 refunded = facility.refund(alice, ID, value, leg);
        assertApproxEqAbs(refunded, leg, 1);
        assertApproxEqAbs(earnShare.balanceOf(alice), shares, 1);
    }

    function test_refund_cappedAtRefundable() public {
        uint128 leg = _place(address(facility), 100e6);
        facility.capture(alice, ID, leg, true);
        usd.mint(address(this), 1000e6);
        usd.approve(address(facility), 1000e6);
        // The placer bounds the refund by what it captured; the rest stays with the facility.
        uint256 refunded = facility.refund(alice, ID, 1000e6, leg);
        assertEq(refunded, leg);
        assertGt(facility.heldShares(), 0);
        vm.expectRevert(SavingsFacility.NothingToRefund.selector);
        facility.refund(alice, ID, 1e6, 0);
    }

    function test_refund_fromAnyCallerOnlyPaysTheOwner() public {
        uint128 leg = _place(address(facility), 100e6);
        facility.capture(alice, ID, leg, true);
        // The core keeps no record to check a refund against: whoever pays it only gives the owner shares.
        usd.mint(bob, 10e6);
        vm.startPrank(bob);
        usd.approve(address(facility), 10e6);
        uint256 refunded = facility.refund(alice, ID, 10e6, type(uint256).max);
        vm.stopPrank();
        assertEq(earnShare.balanceOf(alice), shares - leg + refunded);
    }

    function test_funderOnly() public {
        vm.expectRevert(SavingsFacility.NotFunder.selector);
        facility.withdraw(address(usd), address(this), 1);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(SavingsFacility.ExceedsHeldShares.selector, uint256(1), uint256(0)));
        facility.withdraw(address(earnShare), funder, 1);
        vm.prank(funder);
        facility.withdraw(address(usd), funder, 1e6);
        assertEq(usd.balanceOf(funder), 1e6);
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(SavingsFacility.ZeroAddress.selector);
        new SavingsFacility(IEarnVault(address(earnVault)), address(0), funder);
    }

    function _place(address payee, uint256 amount) internal returns (uint128 leg) {
        // forge-lint: disable-next-line(unsafe-typecast)
        leg = uint128(amount);
        core.holdFrom(
            alice,
            IReservationCore.HoldRequest({
                token: address(earnShare),
                id: ID,
                amount: leg,
                expiresAt: uint64(block.timestamp + 1 days),
                payee: payee,
                standIn: false
            })
        );
    }
}
