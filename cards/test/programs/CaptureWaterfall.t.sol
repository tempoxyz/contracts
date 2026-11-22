// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CardLegs } from "../../src/programs/CardLegs.sol";
import { ISource } from "../../src/programs/interfaces/ISource.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice Captures walk the funding order, each source covering what it holds and can still cover from free funds
///         before the issuer absorbs anything; refunds go to the legs in reverse.
contract CaptureWaterfallTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(5000e6, 10_000e6, 50_000e6));
    }

    function test_savingsOverage_freeSavingsCoverIt() public {
        usd.mint(alice, 20e6);
        _savings(alice, 100e6);
        _setTolerance(alice, address(cash), address(usd), 10_000);
        _authorize(P1, 20e6);
        assertEq(_legs(P1), 1 << CASH_LEG);
        assertEq(_hold(alice, P1, CASH_LEG).held, 20e6);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        _capture(P1, 30e6, true);
        assertEq(usd.balanceOf(alice), 0);
        assertApproxEqAbs(_savingsValue(), 90e6, 2);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertApproxEqAbs(usd.balanceOf(settlement), 30e6, 2);
        assertEq(cards.purchaseOf(P1).refunded, 0);
        _assertCoreBalanced();
        _assertSourcesEmpty();
    }

    function test_savingsCashFirst_cashDepositedAfterTheHoldGoesFirst() public {
        _savings(alice, 100e6);
        _authorize(P1, 50e6);
        assertEq(_legs(P1), 1 << SAVINGS_LEG);
        usd.mint(alice, 30e6);
        _capture(P1, 50e6, true);
        assertEq(usd.balanceOf(alice), 0);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertApproxEqAbs(_savingsValue(), 80e6, 2);
        assertApproxEqAbs(usd.balanceOf(settlement), 50e6, 2);
        _assertCoreBalanced();
        _assertSourcesEmpty();
    }

    function test_savingsRefund_theLegsInReverse() public {
        usd.mint(alice, 20e6);
        // Two wei past 30 so the shares' rounding still covers the 30 the swipe needs from savings.
        _savings(alice, 30e6 + 2);
        _authorize(P1, 50e6);
        _capture(P1, 50e6, true);
        assertEq(usd.balanceOf(alice), 0);
        assertApproxEqAbs(_savingsValue(), 0, 2);
        // A force post with nothing left is the issuer's: the owner owes nothing for it.
        vm.prank(issuer);
        cards.charge(CARD, P2, 15e6, merchant);
        assertEq(cards.purchaseOf(P2).refunded, 15e6);

        _fundRefunds(51e6);
        // The last leg (savings) takes back what it covered first, then the cash leg.
        _refund(P1, 30e6);
        assertEq(usd.balanceOf(alice), 0);
        assertApproxEqAbs(_savingsValue(), 30e6, 2);

        _refund(P1, 20e6);
        assertEq(usd.balanceOf(alice), 20e6);
        assertApproxEqAbs(_savingsValue(), 30e6, 2);

        vm.prank(issuer);
        vm.expectRevert();
        cards.refund(P1, 1e6);
        _assertCoreBalanced();
    }

    function test_savingsThenCash_overagePlacesACashLegAtCapture() public {
        usd.mint(alice, 20e6);
        _savings(alice, 25e6);
        _setTolerance(alice, address(savings), address(earnShare), 10_000);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](2);
        order[0] = CardLegs.Funding(ISource(address(savings)), bytes32(0));
        order[1] = _cashEntry(address(usd), 0);
        vm.prank(alice);
        cards.setFunding(order);
        _authorize(P1, 20e6);
        assertEq(_legs(P1), 1 << 0);
        // Savings cover what they hold and their free shares; cash covers the rest from a leg placed at capture.
        _capture(P1, 30e6, true);
        assertEq(_legs(P1), 1 << 0 | 1 << 1);
        assertApproxEqAbs(_savingsValue(), 0, 2);
        assertApproxEqAbs(usd.balanceOf(alice), 15e6, 2);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertApproxEqAbs(usd.balanceOf(settlement), 30e6, 2);
        assertEq(cards.purchaseOf(P1).refunded, 0);
        _assertCoreBalanced();
        _assertSourcesEmpty();
    }

    function test_savingsThenCash_overageFromFreeSavingsLeavesCash() public {
        usd.mint(alice, 20e6);
        _savings(alice, 100e6);
        _setTolerance(alice, address(savings), address(earnShare), 10_000);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](2);
        order[0] = CardLegs.Funding(ISource(address(savings)), bytes32(0));
        order[1] = _cashEntry(address(usd), 0);
        vm.prank(alice);
        cards.setFunding(order);
        _authorize(P1, 20e6);
        _capture(P1, 30e6, true);
        assertEq(_legs(P1), 1 << 0);
        assertEq(usd.balanceOf(alice), 20e6);
        assertApproxEqAbs(_savingsValue(), 70e6, 2);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertApproxEqAbs(usd.balanceOf(settlement), 30e6, 2);
        _assertCoreBalanced();
    }

    /// @dev A purchase no cash leg funds still takes the owner's tolerance from its cash entry.
    function test_toleranceFromTheCashEntry_whenNoCashLegFunds() public {
        _savings(alice, 100e6);
        _setTolerance(alice, address(cash), address(usd), 2000);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](2);
        order[0] = CardLegs.Funding(ISource(address(savings)), bytes32(0));
        order[1] = _cashEntry(address(usd), 0);
        vm.prank(alice);
        cards.setFunding(order);
        _authorize(P1, 40e6);
        assertEq(_legs(P1), 1 << 0);
        vm.prank(issuer);
        vm.expectRevert(CardLegs.CaptureLimitExceeded.selector);
        cards.capture(P1, 49e6, true);
        _capture(P1, 45e6, true);
        assertApproxEqAbs(_savingsValue(), 55e6, 2);
        _assertCoreBalanced();
    }

    function _savings(address owner, uint256 assets) internal returns (uint256 shares) {
        usd.mint(owner, assets);
        shares = _depositEarn(owner, assets);
    }

    function _savingsValue() internal view returns (uint256) {
        return earnVault.previewRedeem(earnShare.balanceOf(alice));
    }

    function _fundRefunds(uint256 amount) internal {
        usd.mint(issuer, amount);
        vm.prank(issuer);
        usd.approve(address(cards), amount);
    }

    function _refund(bytes32 ref, uint128 amount) internal {
        vm.prank(issuer);
        cards.refund(ref, amount);
    }
}
