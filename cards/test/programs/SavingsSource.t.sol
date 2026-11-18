// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CardAuth } from "../../src/programs/CardAuth.sol";
import { CardLimits } from "../../src/programs/CardLimits.sol";
import { SavingsSource } from "../../src/programs/SavingsSource.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { CAPTURE_BEYOND, CAPTURE_FINAL } from "../../src/programs/interfaces/ISource.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice The savings source over a real EarnVault and the core model, driven directly as its program: holds on
///         Earn shares, captures that redeem and pay the settlement account, deferred redemptions paid from the
///         float, refunds that deposit back into the vault, and the funder's float.
contract SavingsSourceTest is AuthEnv {
    bytes32 internal constant ID = bytes32("leg-1");
    bytes32 internal constant ID2 = bytes32("leg-2");
    uint256 internal shares;

    function setUp() public {
        _deployPrograms();
        usd.mint(alice, 1000e6);
        shares = _depositEarn(alice, 1000e6);
        vm.prank(alice);
        core.approveHolder(address(savings), address(earnShare), type(uint128).max, 0);
    }

    function test_constructor_standingApprovals() public view {
        assertEq(earnShare.allowance(address(savings), address(earnVault)), type(uint256).max);
        assertEq(usd.allowance(address(savings), address(earnVault)), type(uint256).max);
    }

    function test_hold_placesSharesWorthTheUnits() public {
        assertEq(_place(ID, 300e6), 300e6);
        uint256 leg = _leg(ID).held;
        assertEq(leg, earnVault.previewWithdraw(300e6));
        assertEq(_leg(ID).payee, address(savings));
        assertEq(savings.held(alice, bytes32(0), ID), earnVault.previewRedeem(leg));
        // More than the owner has holds everything free, worth what it redeems for.
        uint256 placed = _place(ID2, 5000e6);
        assertEq(placed, earnVault.previewRedeem(shares - leg));
        assertEq(core.available(alice, address(earnShare)), 0);
    }

    function test_capture_redeemsAndPaysSettlement() public {
        _place(ID, 300e6);
        uint256 leg = _leg(ID).held;
        uint256 value = earnVault.previewRedeem(leg);
        vm.prank(address(cards));
        uint256 paid = savings.capture(alice, bytes32(0), ID, 300e6, CAPTURE_FINAL);
        assertEq(paid, 300e6);
        // Rounding the shares up may redeem a little more than the capture; it goes with the capture.
        assertEq(usd.balanceOf(settlement), value);
        assertGe(value, 300e6);
        assertEq(earnShare.balanceOf(address(savings)), 0);
        assertEq(usd.balanceOf(address(savings)), FLOAT);
        assertEq(savings.heldShares(), 0);
        // The final capture ends the leg, so the core forgets it.
        assertEq(_leg(ID).token, address(0));
        _assertCoreBalanced();
    }

    function test_capture_writesNoStorageBeyondTheCore() public {
        _place(ID, 100e6);
        vm.record();
        vm.prank(address(cards));
        savings.capture(alice, bytes32(0), ID, 100e6, CAPTURE_FINAL);
        (, bytes32[] memory writes) = vm.accesses(address(savings));
        assertEq(writes.length, 0);
    }

    function test_capture_partial() public {
        _place(ID, 200e6);
        uint256 leg = _leg(ID).held;
        uint256 first = earnVault.previewWithdraw(50e6);
        vm.prank(address(cards));
        assertEq(savings.capture(alice, bytes32(0), ID, 50e6, 0), 50e6);
        assertEq(_leg(ID).held, leg - first);
        uint256 second = earnVault.previewWithdraw(50e6);
        vm.prank(address(cards));
        savings.capture(alice, bytes32(0), ID, 50e6, CAPTURE_FINAL);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertEq(earnShare.balanceOf(alice), shares - first - second);
        _assertCoreBalanced();
    }

    function test_onlyProgram() public {
        _place(ID, 100e6);
        vm.startPrank(bob);
        vm.expectRevert(SavingsSource.NotProgram.selector);
        savings.capture(alice, bytes32(0), ID, 1e6, 0);
        vm.expectRevert(SavingsSource.NotProgram.selector);
        savings.hold(alice, bytes32(0), ID2, 1e6, _expiry(), false);
        vm.expectRevert(SavingsSource.NotProgram.selector);
        savings.release(alice, bytes32(0), ID);
        vm.expectRevert(SavingsSource.NotProgram.selector);
        savings.refund(alice, bytes32(0), ID, 1e6);
        vm.expectRevert(SavingsSource.NotProgram.selector);
        savings.charge(alice, bytes32(0), ID, 1e6, false);
        vm.stopPrank();
    }

    function test_capture_onlyItsOwnLegs() public {
        // Another holder's share hold under the same id is not the source's to capture.
        vm.prank(alice);
        core.approveHolder(address(this), address(earnShare), type(uint128).max, 0);
        core.holdFrom(
            alice,
            IReservationCore.HoldRequest({
                token: address(earnShare), id: ID, amount: 100e6, expiresAt: _expiry(), payee: bob, standIn: false
            })
        );
        vm.prank(address(cards));
        assertEq(savings.capture(alice, bytes32(0), ID, 1e6, CAPTURE_FINAL), 0);
        assertEq(core.getHold(alice, address(this), ID).held, 100e6);
        assertEq(usd.balanceOf(settlement), 0);
    }

    function test_capture_notBeyondHeld() public {
        _place(ID, 100e6);
        uint256 leg = _leg(ID).held;
        uint256 value = earnVault.previewRedeem(leg);
        // Asked for more than it holds, the source takes only its hold.
        vm.prank(address(cards));
        assertEq(savings.capture(alice, bytes32(0), ID, 150e6, 0), value);
        assertEq(earnShare.balanceOf(alice), shares - leg);
        // Past the hold it reaches free shares only within the hold's capture limit: the hold itself, with no
        // tolerance.
        _place(ID2, 100e6);
        uint256 leg2 = _leg(ID2).held;
        vm.prank(address(cards));
        savings.capture(alice, bytes32(0), ID2, 150e6, CAPTURE_BEYOND | CAPTURE_FINAL);
        assertEq(earnShare.balanceOf(alice), shares - leg - leg2);
        _assertCoreBalanced();
    }

    function test_capture_beyondTheHold_withinTheOwnersTolerance() public {
        _setTolerance(alice, address(savings), address(earnShare), 5000);
        uint256 before = earnShare.balanceOf(alice);
        _place(ID, 100e6);
        vm.prank(address(cards));
        uint256 paid = savings.capture(alice, bytes32(0), ID, 140e6, CAPTURE_BEYOND | CAPTURE_FINAL);
        assertEq(paid, 140e6);
        assertEq(before - earnShare.balanceOf(alice), earnVault.previewWithdraw(140e6));
        _assertCoreBalanced();
    }

    function test_capture_deferredWhenVaultCannotRedeem() public {
        _place(ID, 100e6);
        uint256 leg = _leg(ID).held;
        uint256 value = earnVault.previewRedeem(leg);
        vm.mockCallRevert(
            address(earnVault),
            abi.encodeWithSignature("redeem(uint256,address,uint256)", leg, settlement, value),
            "illiquid"
        );
        vm.prank(address(cards));
        uint256 paid = savings.capture(alice, bytes32(0), ID, 100e6, CAPTURE_FINAL);
        assertEq(paid, 100e6);
        assertEq(usd.balanceOf(settlement), value);
        assertEq(savings.heldShares(), leg);
        assertEq(usd.balanceOf(address(savings)), FLOAT - value);

        vm.clearMockedCalls();
        vm.prank(funder);
        savings.redeemHeld(leg, value);
        assertEq(savings.heldShares(), 0);
        assertGe(usd.balanceOf(address(savings)), FLOAT - 1);
    }

    function test_capture_deferred_refusedPastTheFloat() public {
        vm.prank(funder);
        savings.withdraw(address(usd), funder, FLOAT);
        _place(ID, 100e6);
        uint256 leg = _leg(ID).held;
        uint256 value = earnVault.previewRedeem(leg);
        vm.mockCallRevert(
            address(earnVault),
            abi.encodeWithSignature("redeem(uint256,address,uint256)", leg, settlement, value),
            "illiquid"
        );
        vm.prank(address(cards));
        vm.expectRevert(abi.encodeWithSelector(SavingsSource.InsufficientFloat.selector, value, uint256(0)));
        savings.capture(alice, bytes32(0), ID, 100e6, CAPTURE_FINAL);
    }

    function test_capture_revertsWithoutQuote() public {
        _place(ID, 100e6);
        uint256 leg = _leg(ID).held;
        vm.mockCall(address(earnVault), abi.encodeWithSignature("previewRedeem(uint256)", leg), abi.encode(0));
        vm.prank(address(cards));
        vm.expectRevert(SavingsSource.NoQuote.selector);
        savings.capture(alice, bytes32(0), ID, 100e6, CAPTURE_FINAL);
        vm.clearMockedCalls();
        assertEq(_leg(ID).held, leg);
    }

    function test_refund_depositsCashAndRefundsShares() public {
        _place(ID, 300e6);
        uint256 leg = _leg(ID).held;
        vm.prank(address(cards));
        uint256 paid = savings.capture(alice, bytes32(0), ID, 300e6, CAPTURE_FINAL);
        // The program pays the source the refund before calling it.
        usd.mint(address(savings), paid);
        vm.prank(address(cards));
        savings.refund(alice, bytes32(0), ID, paid);
        uint256 minted = earnShare.balanceOf(alice) - (shares - leg);
        assertApproxEqAbs(earnVault.previewRedeem(minted), paid, 1, "the refund deposits its whole value");
        assertApproxEqAbs(earnShare.balanceOf(alice), shares, 1);
        assertEq(usd.balanceOf(address(savings)), FLOAT, "the float is untouched");
        assertEq(earnShare.balanceOf(address(savings)), 0);
    }

    function test_refund_boundedByTheProgramAtWhatItCovered() public {
        // Through the program: savings refunds take any amount, so the program stops them at what was covered.
        _issueSavingsOnly();
        vm.prank(issuer);
        cards.authorize(CARD, bytes32("p1"), 100e6, merchant, _expiry(), 0);
        vm.prank(issuer);
        cards.capture(bytes32("p1"), 100e6, true);
        uint256 before = earnShare.balanceOf(alice);
        usd.mint(issuer, 1000e6);
        vm.startPrank(issuer);
        usd.approve(address(cards), type(uint256).max);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.refund(bytes32("p1"), 100e6 + 1);
        cards.refund(bytes32("p1"), 100e6);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.refund(bytes32("p1"), 1);
        vm.stopPrank();
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice) - before), 100e6, 1);
        assertEq(usd.balanceOf(issuer), 900e6);
        assertEq(usd.balanceOf(address(savings)), FLOAT);
    }

    function test_funderOnly() public {
        vm.expectRevert(SavingsSource.NotFunder.selector);
        savings.withdraw(address(usd), address(this), 1);
        vm.expectRevert(SavingsSource.NotFunder.selector);
        savings.redeemHeld(1, 0);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(SavingsSource.ExceedsHeldShares.selector, uint256(1), uint256(0)));
        savings.withdraw(address(earnShare), funder, 1);
        vm.prank(funder);
        savings.withdraw(address(usd), funder, 1e6);
        assertEq(usd.balanceOf(funder), 1e6);
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(SavingsSource.ZeroAddress.selector);
        new SavingsSource(cards, IEarnVault(address(earnVault)), address(0));
        vm.expectRevert(SavingsSource.ZeroAddress.selector);
        new SavingsSource(cards, IEarnVault(address(0)), funder);
        vm.expectRevert(SavingsSource.ZeroAddress.selector);
        new SavingsSource(CardAuth(address(0)), IEarnVault(address(earnVault)), funder);
    }

    function _place(bytes32 id, uint256 units) internal returns (uint256) {
        vm.prank(address(cards));
        return savings.hold(alice, bytes32(0), id, units, _expiry(), false);
    }

    function _leg(bytes32 id) internal view returns (IReservationCore.HoldRecord memory) {
        return core.getHold(alice, address(savings), id);
    }

    function _expiry() internal view returns (uint64) {
        return uint64(block.timestamp + 1 days);
    }

    function _issueSavingsOnly() internal {
        vm.prank(issuer);
        cards.issueCard(CARD, alice, uint40(block.timestamp + 365 days), _limits(5000e6, 10_000e6, 50_000e6), 2);
        vm.startPrank(alice);
        _setFunding(false, true, false);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
        vm.stopPrank();
    }
}
