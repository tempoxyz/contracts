// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CardLimits } from "../../src/programs/CardLimits.sol";
import { CardProgram } from "../../src/programs/CardProgram.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice A card program over the core model: cards, limits, mandates, and purchases across cash, savings and
///         credit legs, placed, captured, released and refunded in one call each.
contract CardProgramTest is ProgramsEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");
    uint8 internal constant CASH = 1;
    uint8 internal constant SAVINGS = 2;
    uint8 internal constant CREDIT = 4;

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
    }

    // Cash leg.

    function test_authorize_cash_placesOneHold() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);

        IReservationCore.HoldRecord memory h = _hold(alice, P1, CASH);
        assertEq(h.token, address(usd));
        assertEq(h.placer, address(cards));
        assertEq(h.payee, address(cards));
        assertEq(h.held, 100e6);
        assertEq(core.reserved(alice, address(usd)), 100e6);
        (, uint128 outstanding) = core.allowance(alice, address(cards), address(usd));
        assertEq(outstanding, 100e6);
        CardProgram.Purchase memory p = cards.purchaseOf(P1);
        assertEq(p.legs, CASH);
        assertTrue(p.open);
        _assertCoreBalanced();
    }

    function test_capture_cash_paysSettlementAccount() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.expectEmit(address(cards));
        emit CardProgram.PurchaseCaptured(P1, CARD, 100e6, 100e6, 0, 0, 0, true, 2, 100e6);
        _capture(P1, 100e6, true);

        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(usd.balanceOf(address(cards)), 0);
        assertEq(usd.balanceOf(alice), 900e6);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertFalse(cards.purchaseOf(P1).open);
        _assertCoreBalanced();
    }

    function test_capture_partialThenFinal() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 40e6, false);
        assertEq(_hold(alice, P1, CASH).held, 60e6);
        _capture(P1, 30e6, true);
        assertEq(usd.balanceOf(settlement), 70e6);
        assertEq(usd.balanceOf(alice), 930e6);
        assertTrue(_hold(alice, P1, CASH).settled);
    }

    function test_capture_tipWithinTolerance() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(IReservationCore.ToleranceExceeded.selector);
        cards.capture(P1, 110e6, true);

        vm.prank(alice);
        core.setCaptureTolerance(address(cards), address(usd), 2000);
        _capture(P1, 110e6, true);
        assertEq(usd.balanceOf(settlement), 110e6);
        assertEq(usd.balanceOf(alice), 890e6);
    }

    function test_doubleCapture_refused() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.PurchaseNotOpen.selector);
        cards.capture(P1, 100e6, true);
        // The core refuses a second capture of the settled leg too.
        bytes32 id = cards.legId(P1, CASH);
        vm.prank(address(cards));
        vm.expectRevert(IReservationCore.HoldSettled.selector);
        core.capture(alice, id, 1, false);
    }

    function test_captureAfterExpiry_refused_andAnyoneExpires() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 400e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.PurchaseExpired.selector);
        cards.capture(P1, 400e6, true);
        // The core enforces hard expiry whoever captures.
        bytes32 id = cards.legId(P1, CASH);
        vm.prank(address(cards));
        vm.expectRevert(IReservationCore.HoldExpired.selector);
        core.capture(alice, id, 1, false);

        vm.prank(bob);
        cards.expire(P1);
        assertEq(usd.balanceOf(alice), 1000e6);
        assertFalse(cards.purchaseOf(P1).open);
        // Nothing was captured, so the day's window has its amount back.
        assertEq(cards.cardOf(CARD).window.daySpent, 0);
        _assertCoreBalanced();
    }

    function test_expire_beforeExpiry_refused() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.expectRevert(CardProgram.PurchaseNotExpired.selector);
        cards.expire(P1);
    }

    function test_release_returnsFundsAndWindow() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        assertEq(cards.cardOf(CARD).window.daySpent, 100e6);
        vm.prank(issuer);
        cards.release(P1);
        assertEq(usd.balanceOf(alice), 1000e6);
        assertEq(cards.cardOf(CARD).window.daySpent, 0);
        assertEq(cards.cardOf(CARD).window.monthSpent, 0);
    }

    function test_onlyIssuer() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
        _authorize(P1, 1e6);
        vm.prank(alice);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.capture(P1, 1e6, true);
    }

    function test_purchaseRef_isUnique() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 1e6);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.PurchaseExists.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    // Card controls.

    function test_frozenCard_refused() public {
        usd.mint(alice, 1000e6);
        vm.prank(bob);
        vm.expectRevert(CardProgram.NotCardOwner.selector);
        cards.freeze(CARD);
        vm.prank(alice);
        cards.freeze(CARD);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardNotActive.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.prank(alice);
        cards.unfreeze(CARD);
        _authorize(P1, 1e6);
    }

    function test_closedCard_refused() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        cards.close(CARD);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardNotActive.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 1);
    }

    function test_expiredCard_refused() public {
        usd.mint(alice, 1000e6);
        vm.warp(vm.getBlockTimestamp() + 366 days);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardExpired.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_replaceCard_movesOwnerAndLimits() public {
        usd.mint(alice, 1000e6);
        bytes32 next = bytes32("card-2");
        vm.prank(issuer);
        cards.replaceCard(CARD, next, uint40(block.timestamp + 700 days));
        CardProgram.Card memory c = cards.cardOf(next);
        assertEq(c.owner, alice);
        assertEq(c.limits.perPurchase, 500e6);
        assertEq(uint8(cards.cardOf(CARD).status), uint8(CardProgram.Status.Closed));
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardNotActive.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.prank(issuer);
        cards.authorize(next, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_replaceCard_openPurchaseFollowsReplacement() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 50e6);
        bytes32 next = bytes32("card-2");
        vm.prank(issuer);
        cards.replaceCard(CARD, next, uint40(block.timestamp + 700 days));
        assertEq(cards.replacedBy(CARD), next);

        // The increment counts against the replacement, which carried the old card's windows.
        vm.prank(issuer);
        cards.adjust(P1, 80e6);
        assertEq(cards.purchaseOf(P1).card, next);
        assertEq(cards.cardOf(next).window.daySpent, 80e6);
        _capture(P1, 80e6, true);
        assertEq(usd.balanceOf(settlement), 80e6);
    }

    function test_carryUsage_countsSpendFromAnotherInstance() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        cards.setMandate(merchant, false, 150e6);
        (uint32 day, uint32 month) = CardLimits.calendar(0);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = CARD;
        CardLimits.Window[] memory windows = new CardLimits.Window[](1);
        windows[0] = CardLimits.Window({ day: day, month: month, daySpent: 0, monthSpent: 0, cap: 0, committed: 0 });
        address[] memory merchants = new address[](1);
        merchants[0] = merchant;
        CardLimits.Mandate[] memory spent = new CardLimits.Mandate[](1);
        spent[0] = CardLimits.Mandate({ revoked: false, monthlyLimit: 0, month: month, spent: 100e6 });
        CardLimits.Usage memory usage =
            CardLimits.Usage({ committed: 100e6, day: day, month: month, daySpent: 100e6, monthSpent: 100e6 });

        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.carryUsage(alice, usage, ids, windows, merchants, spent);
        vm.startPrank(issuer);
        cards.carryUsage(alice, usage, ids, windows, merchants, spent);
        // Carrying the same usage again changes nothing.
        cards.carryUsage(alice, usage, ids, windows, merchants, spent);
        vm.stopPrank();

        (bool revoked, uint96 limit,, uint96 counted) = cards.mandates(alice, merchant);
        assertFalse(revoked);
        assertEq(limit, 150e6);
        assertEq(counted, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.MerchantLimitExceeded.selector);
        cards.authorize(CARD, P1, 60e6, merchant, uint64(block.timestamp + 1 days), 0);
        _authorize(P1, 50e6);
        (uint64 committed,,,,) = cards.usageOf(alice);
        assertEq(committed, 150e6);
    }

    function test_carryUsage_refusesAnotherOwnersCard() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = CARD;
        CardLimits.Window[] memory windows = new CardLimits.Window[](1);
        CardLimits.Usage memory usage;
        vm.prank(issuer);
        vm.expectRevert(CardProgram.InvalidCard.selector);
        cards.carryUsage(address(0xB0B), usage, ids, windows, new address[](0), new CardLimits.Mandate[](0));
    }

    function test_limits_ownerLowersAndIssuerRaisesOnlyWithinCeiling() public {
        vm.prank(issuer);
        vm.expectRevert(CardProgram.LimitAboveCeiling.selector);
        cards.raiseLimits(CARD, _limits(600e6, 1000e6, 5000e6));

        vm.prank(alice);
        cards.lowerLimits(CARD, _limits(100e6, 200e6, 1000e6));
        // The issuer cannot raise them back past what the owner lowered.
        vm.prank(issuer);
        vm.expectRevert(CardProgram.LimitAboveCeiling.selector);
        cards.raiseLimits(CARD, _limits(500e6, 1000e6, 5000e6));
        vm.prank(alice);
        vm.expectRevert(CardProgram.LimitAboveCeiling.selector);
        cards.lowerLimits(CARD, _limits(200e6, 200e6, 1000e6));

        vm.prank(alice);
        cards.allowLimits(CARD, _limits(800e6, 2000e6, 8000e6));
        vm.prank(issuer);
        cards.raiseLimits(CARD, _limits(800e6, 2000e6, 8000e6));
        assertEq(cards.cardOf(CARD).limits.perPurchase, 800e6);
    }

    function test_overLimit_onPurchaseTotalAcrossLegs() public {
        // 60 cash and about 60 in savings: each leg is under 100, the purchase is not.
        usd.mint(alice, 60e6);
        _savings(alice, 60e6);
        vm.prank(alice);
        cards.lowerLimits(CARD, _limits(100e6, 1000e6, 5000e6));
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.LimitExceeded.selector, uint8(0)));
        cards.authorize(CARD, P1, 110e6, merchant, uint64(block.timestamp + 1 days), 0);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
    }

    function test_dailyAndMonthlyWindows() public {
        usd.mint(alice, 5000e6);
        vm.prank(alice);
        cards.lowerLimits(CARD, _limits(500e6, 600e6, 900e6));
        _authorize(P1, 400e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.LimitExceeded.selector, uint8(1)));
        cards.authorize(CARD, P2, 300e6, merchant, uint64(block.timestamp + 1 days), 0);

        // A new day resets the daily window but not the month.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _authorize(P2, 400e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.LimitExceeded.selector, uint8(2)));
        cards.authorize(CARD, bytes32("purchase-3"), 200e6, merchant, uint64(vm.getBlockTimestamp() + 1 days), 0);
    }

    // Owner terms.

    function test_terms_requireGrant_andRevokeStopsNewPurchases() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(alice);
        cards.revoke();
        vm.prank(issuer);
        vm.expectRevert(CardProgram.NoTerms.selector);
        cards.authorize(CARD, P2, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
        // Open purchases still settle.
        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
    }

    function test_revoke_stopsIncrementsWithNoTerms_butDecreasesStillRun() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(alice);
        cards.revoke();
        // The card is still active, so the decline names the revoked grant, not the card.
        vm.prank(issuer);
        vm.expectRevert(CardProgram.NoTerms.selector);
        cards.adjust(P1, 150e6);
        vm.prank(issuer);
        cards.adjust(P1, 60e6);
        assertEq(_hold(alice, P1, CASH).held, 60e6);
        _capture(P1, 60e6, true);
        assertEq(usd.balanceOf(settlement), 60e6);
    }

    function test_adjust_frozenCardBeforeRevokedGrant() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(alice);
        cards.revoke();
        vm.prank(alice);
        cards.freeze(CARD);
        // The card's status is checked first.
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardNotActive.selector);
        cards.adjust(P1, 150e6);
    }

    function test_revoke_refusesForcePost_butLateChargeOnAuthorizedPurchaseLands() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(alice);
        cards.revoke();
        // A force post opens a new purchase, which a revoked grant refuses.
        vm.prank(issuer);
        vm.expectRevert(CardProgram.NoTerms.selector);
        cards.charge(CARD, P2, 10e6, merchant);
        assertEq(cards.purchaseOf(P2).owner, address(0));
        // A late presentment of a purchase authorized under the grant still charges.
        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        assertEq(usd.balanceOf(settlement), 100e6);
        // Granting again restores force posts.
        _grant(0, 0, 0, 0, 0);
        vm.prank(issuer);
        cards.charge(CARD, P2, 10e6, merchant);
        assertEq(usd.balanceOf(settlement), 110e6);
    }

    function test_terms_lifetimeLimit_countsHoldsCapturesAndRefunds() public {
        usd.mint(alice, 1000e6);
        _grant(150e6, 0, 0, 0, 0);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.LimitExceeded.selector, uint8(3)));
        cards.authorize(CARD, P2, 60e6, merchant, uint64(block.timestamp + 1 days), 0);
        // A final capture below the hold gives back the rest.
        _capture(P1, 80e6, true);
        (uint64 committed,,,,) = cards.usageOf(alice);
        assertEq(committed, 80e6);
        _authorize(P2, 70e6);
        // A refund gives its amount back.
        usd.mint(issuer, 50e6);
        vm.prank(issuer);
        usd.approve(address(cards), 50e6);
        vm.prank(issuer);
        cards.refund(P1, 50e6);
        (committed,,,,) = cards.usageOf(alice);
        assertEq(committed, 100e6);
    }

    function test_terms_calendarMonth_atOffset() public {
        usd.mint(alice, 1000e6);
        // 2026-01-31 23:00 UTC is 2026-02-01 01:00 at UTC+2.
        vm.warp(1_769_900_400);
        _grant(0, 0, 0, 100e6, 2 hours);
        _authorize(P1, 100e6);
        // 2026-02-28 21:00 UTC is still February at UTC+2.
        vm.warp(1_772_312_400);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.LimitExceeded.selector, uint8(2)));
        cards.authorize(CARD, P2, 1e6, merchant, uint64(vm.getBlockTimestamp() + 1 days), 0);
        // 2026-02-28 23:00 UTC is March at UTC+2.
        vm.warp(1_772_319_600);
        vm.prank(issuer);
        cards.authorize(CARD, P2, 100e6, merchant, uint64(vm.getBlockTimestamp() + 1 days), 0);
    }

    function test_terms_perPurchase() public {
        usd.mint(alice, 1000e6);
        _grant(0, 50e6, 0, 0, 0);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.LimitExceeded.selector, uint8(0)));
        cards.authorize(CARD, P1, 60e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_cardCap() public {
        usd.mint(alice, 1000e6);
        vm.prank(issuer);
        cards.setCardCap(CARD, 120e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.LimitExceeded.selector, uint8(4)));
        cards.authorize(CARD, P2, 30e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_partialApproval_holdsWhatIsAvailable() public {
        usd.mint(alice, 40e6);
        vm.prank(alice);
        _setFunding(address(usd), address(0), address(0), 0);
        vm.prank(issuer);
        uint256 approved = cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 1 days), 2);
        assertEq(approved, 40e6);
        assertEq(cards.purchaseOf(P1).amount, 40e6);
        assertEq(_hold(alice, P1, CASH).held, 40e6);
    }

    function test_operator() public {
        usd.mint(alice, 1000e6);
        address key = makeAddr("key");
        vm.prank(issuer);
        cards.setOperator(key, 7, 1e30);
        vm.prank(key);
        cards.authorize(CARD, P1, 10e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.prank(issuer);
        cards.setOperator(key, 0, 0);
        vm.prank(key);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.capture(P1, 10e6, true);
    }

    // Incremental authorization and late charges.

    function test_adjust_raisesAndLowersCashHold() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.adjust(P1, 150e6);
        assertEq(_hold(alice, P1, CASH).held, 150e6);
        assertEq(cards.cardOf(CARD).window.daySpent, 150e6);
        vm.prank(issuer);
        cards.adjust(P1, 120e6);
        assertEq(_hold(alice, P1, CASH).held, 120e6);
        assertEq(cards.cardOf(CARD).window.daySpent, 120e6);
        _capture(P1, 120e6, true);
        assertEq(usd.balanceOf(settlement), 120e6);
    }

    function test_adjust_overLimitOrFunds_refused() public {
        usd.mint(alice, 300e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.LimitExceeded.selector, uint8(0)));
        cards.adjust(P1, 600e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.InsufficientFunds.selector, uint256(250e6)));
        cards.adjust(P1, 350e6);
    }

    function test_charge_forcePostCountsAgainstTheCardsLimits() public {
        usd.mint(alice, 10_000e6);
        // Per purchase: the card allows 500 dollars.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(0)));
        cards.charge(CARD, P1, 500e6 + 1, merchant);
        // Daily: 1,000 dollars across authorizations and force posts.
        _authorize(P1, 500e6);
        vm.prank(issuer);
        cards.charge(CARD, P2, 400e6, merchant);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(1)));
        cards.charge(CARD, bytes32("purchase-3"), 100e6 + 1, merchant);
        vm.prank(issuer);
        cards.charge(CARD, bytes32("purchase-3"), 100e6, merchant);
        // A refund of a force post gives its room back.
        usd.mint(issuer, 50e6);
        vm.prank(issuer);
        usd.approve(address(cards), 50e6);
        vm.prank(issuer);
        cards.refund(P2, 50e6);
        vm.prank(issuer);
        cards.charge(CARD, bytes32("purchase-4"), 50e6, merchant);
    }

    function test_charge_forcePostCountsAgainstTermsCapAndMandate() public {
        usd.mint(alice, 10_000e6);
        _grant(150e6, 100e6, 0, 0, 0);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(0)));
        cards.charge(CARD, P1, 100e6 + 1, merchant);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(3)));
        cards.charge(CARD, P2, 50e6 + 1, merchant);
        _grant(0, 0, 0, 0, 0);
        vm.prank(issuer);
        cards.setCardCap(CARD, 120e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(4)));
        cards.charge(CARD, P2, 20e6 + 1, merchant);
        vm.prank(alice);
        cards.setMandate(merchant, true, 0);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.MerchantRevoked.selector);
        cards.charge(CARD, P2, 1e6, merchant);
    }

    function test_charge_afterExpiry_paysAndTakesDebtWithinCap() public {
        usd.mint(alice, 50e6);
        vm.prank(alice);
        _setFunding(address(usd), address(0), address(0), 0);
        _authorize(P1, 50e6);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.prank(alice);
        core.setDebtCap(address(cards), address(usd), 30e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 70e6, merchant);
        assertEq(usd.balanceOf(settlement), 50e6);
        (, uint128 debt) = core.debtOf(alice, address(usd));
        assertEq(debt, 20e6);
        assertFalse(cards.purchaseOf(P1).open);
        // A refund repays the debt first.
        usd.mint(issuer, 30e6);
        vm.prank(issuer);
        usd.approve(address(cards), 30e6);
        vm.prank(issuer);
        cards.refund(P1, 30e6);
        (, debt) = core.debtOf(alice, address(usd));
        assertEq(debt, 0);
        assertEq(usd.balanceOf(alice), 10e6);
        assertEq(usd.balanceOf(settlement), 70e6);
    }

    function test_charge_pastDebtCap_issuerAbsorbsTheRest() public {
        usd.mint(alice, 50e6);
        vm.prank(alice);
        core.setDebtCap(address(cards), address(usd), 30e6);
        // 50 available plus 30 of debt: the issuer carries the other 20.
        vm.expectEmit(address(cards));
        emit CardProgram.PurchaseCharged(P1, CARD, merchant, 100e6, 80e6, 20e6, 1, 100e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        assertEq(usd.balanceOf(settlement), 50e6);
        (, uint128 debt) = core.debtOf(alice, address(usd));
        assertEq(debt, 30e6);
        // The whole amount counts toward the limits, not just what the owner paid.
        assertEq(cards.cardOf(CARD).window.daySpent, 100e6);
        _assertCoreBalanced();
    }

    function test_refund_pastDebtCap_repaysThenPaysWhatTheIssuerAbsorbed() public {
        usd.mint(alice, 50e6);
        vm.prank(alice);
        core.setDebtCap(address(cards), address(usd), 30e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        usd.mint(issuer, 101e6);
        vm.prank(issuer);
        usd.approve(address(cards), 101e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.RefundExceedsCapture.selector, uint256(1e6)));
        cards.refund(P1, 101e6);
        // The refund repays the debt, restores the cash and lands what the issuer carried with the owner.
        vm.prank(issuer);
        cards.refund(P1, 100e6);
        (, uint128 debt) = core.debtOf(alice, address(usd));
        assertEq(debt, 0);
        assertEq(core.available(alice, address(usd)), 70e6);
        _assertCoreBalanced();
    }

    function test_charge_nothingToTake_absorbsAllAndPlacesNoCharge() public {
        vm.expectEmit(address(cards));
        emit CardProgram.PurchaseCharged(P1, CARD, merchant, 40e6, 0, 40e6, 1, 40e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 40e6, merchant);
        // No charge leg: only the marker that the reference was charged.
        assertEq(cards.purchaseOf(P1).legs, 16);
        assertTrue(cards.purchaseOf(P1).captured);
        // Nothing was taken from the owner, so there is nothing to refund.
        vm.prank(issuer);
        vm.expectRevert();
        cards.refund(P1, 1e6);
        // The same reference cannot be charged twice.
        usd.mint(alice, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.PurchaseExists.selector);
        cards.charge(CARD, P1, 40e6, merchant);
    }

    function test_charge_debtToAnotherCreditor_leavesNoDebtRoom() public {
        address lender = makeAddr("lender");
        usd.mint(alice, 10e6);
        vm.startPrank(alice);
        core.setDebtCap(address(cards), address(usd), 30e6);
        core.setDebtCap(lender, address(usd), 5e6);
        core.approveHolder(lender, address(usd), 100e6);
        vm.stopPrank();
        // Another creditor's debt holds the owner's debt slot; this program can't add to it.
        vm.prank(lender);
        core.charge(alice, address(usd), bytes32("x"), 15e6, lender, false);
        vm.prank(issuer);
        cards.charge(CARD, P1, 20e6, merchant);
        (address creditor, uint128 debt) = core.debtOf(alice, address(usd));
        assertEq(creditor, lender);
        assertEq(debt, 5e6);
        assertEq(usd.balanceOf(settlement), 0);
        _assertCoreBalanced();
    }

    function test_charge_onOpenPurchase_refused() public {
        usd.mint(alice, 100e6);
        _authorize(P1, 50e6);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.PurchaseOpen.selector);
        cards.charge(CARD, P1, 50e6, merchant);
    }

    function test_revokedMerchant_refused() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        cards.setMandate(merchant, true, 0);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.MerchantRevoked.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_merchantMonthlyLimit() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        cards.setMandate(merchant, false, 150e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.MerchantLimitExceeded.selector);
        cards.authorize(CARD, P2, 100e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _authorize(P2, 100e6);
    }

    // Holder allowance.

    function test_revokedHolder_liveHoldsStillSettle() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(alice);
        core.approveHolder(address(cards), address(usd), 0);
        vm.prank(issuer);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        cards.authorize(CARD, P2, 100e6, merchant, uint64(block.timestamp + 1 days), 0);

        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
    }

    function test_holderAllowance_capsOutstanding() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        core.approveHolder(address(cards), address(usd), 150e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(IReservationCore.AllowanceExceeded.selector);
        cards.authorize(CARD, P2, 100e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    // Savings and credit legs.

    function test_authorize_spansCashAndSavings() public {
        usd.mint(alice, 30e6);
        uint256 shares = _savings(alice, 500e6);
        _authorize(P1, 100e6);

        CardProgram.Purchase memory p = cards.purchaseOf(P1);
        assertEq(p.legs, CASH | SAVINGS);
        assertEq(_hold(alice, P1, CASH).held, 30e6);
        IReservationCore.HoldRecord memory s = _hold(alice, P1, SAVINGS);
        assertEq(s.token, address(earnShare));
        assertEq(s.payee, address(facility));
        assertEq(s.held, earnVault.previewWithdraw(70e6));
        assertEq(earnShare.balanceOf(alice), shares - s.held);

        _capture(P1, 100e6, true);
        assertApproxEqAbs(usd.balanceOf(settlement), 100e6, 2);
        assertEq(earnShare.balanceOf(address(facility)), 0);
        assertEq(facility.float(), FLOAT);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        _assertCoreBalanced();
    }

    function test_capture_waterfall_cashFirst() public {
        usd.mint(alice, 30e6);
        uint256 shares = _savings(alice, 500e6);
        _authorize(P1, 100e6);
        // A partial capture takes cash before shares.
        _capture(P1, 50e6, false);
        assertTrue(_hold(alice, P1, CASH).held == 0);
        assertEq(usd.balanceOf(settlement) >= 50e6 && usd.balanceOf(settlement) <= 50e6 + 2, true);
        _capture(P1, 0, true);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertGt(earnShare.balanceOf(alice), shares - earnVault.previewWithdraw(70e6));
    }

    function test_insufficientFunds_placesNothing() public {
        usd.mint(alice, 30e6);
        _savings(alice, 20e6);
        vm.prank(issuer);
        vm.expectPartialRevert(CardProgram.InsufficientFunds.selector);
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 1 days), 0);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
    }

    function test_unapprovedFacility_refused() public {
        _savings(alice, 100e6);
        _setting(abi.encodeCall(cards.setSource, (address(facility), false)));
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SourceNotApproved.selector, address(facility)));
        cards.authorize(CARD, P1, 50e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_threeLegs_captureAndRepay() public {
        usd.mint(alice, 30e6);
        _savings(alice, 20e6);
        uint64 lineId = _withLine(1000e6);
        uint256 lenderBefore = usd.balanceOf(lender);
        _authorize(P1, 100e6);

        CardProgram.Purchase memory p = cards.purchaseOf(P1);
        assertEq(p.legs, CASH | SAVINGS | CREDIT);
        bytes32 creditId = credit.holdIdOf(address(cards), P1);
        IReservationCore.HoldRecord memory c = core.getHold(lender, creditId);
        assertEq(c.placer, address(credit));
        assertEq(c.payee, address(cards));
        uint256 drawn = c.held;
        assertApproxEqAbs(drawn, 50e6, 2);
        // The line commits its whole limit on the lender's balance; the draw comes out of that commitment.
        assertEq(core.reserved(lender, address(usd)), 1000e6);

        _capture(P1, 100e6, true);
        assertApproxEqAbs(usd.balanceOf(settlement), 100e6, 2);
        assertEq(usd.balanceOf(lender) + core.reserved(lender, address(usd)), lenderBefore + 1000e6 - drawn);
        assertEq(credit.lineOf(lineId).owed, drawn);
        assertEq(credit.lineOf(lineId).pending, 0);

        // The borrower repays the lender through the line.
        usd.mint(alice, drawn);
        vm.prank(alice);
        usd.approve(address(credit), drawn);
        vm.prank(alice);
        // forge-lint: disable-next-line(unsafe-typecast)
        credit.repay(lineId, uint128(drawn));
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(usd.balanceOf(lender) + core.reserved(lender, address(usd)), lenderBefore + 1000e6);
        _assertCoreBalanced();
    }

    function test_threeLegs_releaseFreesEveryLeg() public {
        usd.mint(alice, 30e6);
        _savings(alice, 20e6);
        uint64 lineId = _withLine(1000e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.release(P1);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertEq(credit.committed(lineId), 1000e6);
        assertEq(credit.lineOf(lineId).pending, 0);
        assertEq(credit.lineOf(lineId).owed, 0);
    }

    function test_refund_reverseOrder() public {
        usd.mint(alice, 30e6);
        _savings(alice, 20e6);
        uint64 lineId = _withLine(1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        uint256 sharesBefore = earnShare.balanceOf(alice);
        uint256 owed = credit.lineOf(lineId).owed;

        // The issuer funds the refund; credit unwinds first, then savings.
        usd.mint(issuer, 100e6);
        vm.prank(issuer);
        usd.approve(address(cards), 100e6);
        vm.prank(issuer);
        cards.refund(P1, uint128(owed + 10e6));
        assertEq(credit.lineOf(lineId).owed, 0);
        assertGt(earnShare.balanceOf(alice), sharesBefore);
        assertEq(core.getHold(alice, cards.legId(P1, CASH)).refunded, 0);

        vm.prank(issuer);
        vm.expectPartialRevert(CardProgram.RefundExceedsCapture.selector);
        cards.refund(P1, 50e6);
    }

    function test_refund_aboveCapture_refused() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 50e6, true);
        usd.mint(issuer, 100e6);
        vm.prank(issuer);
        usd.approve(address(cards), 100e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.RefundExceedsCapture.selector, uint256(1e6)));
        cards.refund(P1, 51e6);
        vm.prank(issuer);
        cards.refund(P1, 50e6);
        assertEq(usd.balanceOf(alice), 1000e6);
        (,, uint128 net,) = cards.ledger();
        assertEq(net, 0);
    }

    // Stand-ins, rates and the settlement cursor.

    function test_standIn_adjustDown_keepsWhatIsHeldUpToTheNewAmount() public {
        usd.mint(alice, 30e6);
        vm.prank(alice);
        core.setOfflineCap(address(cards), address(usd), 50e6);
        vm.prank(issuer);
        cards.authorize(CARD, P1, 40e6, merchant, uint64(block.timestamp + 1 days), 1);
        assertEq(_hold(alice, P1, CASH).held, 30e6);
        // Down to 35: the 30 reserved still fits, so nothing moves on the core.
        vm.prank(issuer);
        cards.adjust(P1, 35e6);
        assertEq(_hold(alice, P1, CASH).held, 30e6);
        assertEq(cards.purchaseOf(P1).amount, 35e6);
        assertEq(cards.cardOf(CARD).window.daySpent, 35e6);
        // Down to 20: the hold gives back 10.
        vm.prank(issuer);
        cards.adjust(P1, 20e6);
        assertEq(_hold(alice, P1, CASH).held, 20e6);
        assertEq(usd.balanceOf(alice), 10e6);
        assertEq(cards.cardOf(CARD).window.daySpent, 20e6);
        _assertCoreBalanced();
    }

    function test_standIn_onFrozenCard_declinedWhenItLands() public {
        usd.mint(alice, 30e6);
        vm.prank(alice);
        cards.freeze(CARD);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardNotActive.selector);
        cards.authorize(CARD, P1, 20e6, merchant, uint64(block.timestamp + 1 days), 1);
        assertEq(usd.balanceOf(alice), 30e6);
        assertEq(cards.purchaseOf(P1).owner, address(0));
    }

    function test_standIn_adjustUp_refused() public {
        usd.mint(alice, 100e6);
        vm.prank(issuer);
        cards.authorize(CARD, P1, 40e6, merchant, uint64(block.timestamp + 1 days), 1);
        vm.prank(issuer);
        cards.adjust(P1, 30e6);
        // Not past the offline approval, and not back up after coming down either.
        vm.prank(issuer);
        vm.expectRevert(CardProgram.InvalidAmount.selector);
        cards.adjust(P1, 41e6);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.InvalidAmount.selector);
        cards.adjust(P1, 35e6);
    }

    function test_standIn_reservesWhatIsThereAndForwardsRepaidDebt() public {
        usd.mint(alice, 50e6);
        vm.prank(issuer);
        cards.authorize(CARD, P1, 80e6, merchant, uint64(block.timestamp + 1 days), 1);
        IReservationCore.HoldRecord memory h = _hold(alice, P1, CASH);
        assertTrue(h.standIn);
        assertEq(h.held, 50e6);
        assertEq(h.approved, 80e6);

        vm.prank(issuer);
        vm.expectRevert(IReservationCore.DebtCapExceeded.selector);
        cards.capture(P1, 80e6, true);
        vm.prank(alice);
        core.setOfflineCap(address(cards), address(usd), 30e6);
        _capture(P1, 80e6, true);
        assertEq(usd.balanceOf(settlement), 50e6);
        (address creditor, uint128 debt) = core.debtOf(alice, address(usd));
        assertEq(creditor, address(cards));
        assertEq(debt, 30e6);

        usd.mint(alice, 40e6);
        core.repay(alice, address(usd));
        cards.forward(address(usd));
        assertEq(usd.balanceOf(settlement), 80e6);
    }

    function test_foreignCashToken_convertsAtRecordedRate() public {
        otherUsd.mint(alice, 1000e6);
        vm.startPrank(alice);
        core.approveHolder(address(cards), address(otherUsd), type(uint128).max);
        _setFunding(address(otherUsd), address(0), address(0), 0);
        vm.stopPrank();
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.TokenNotAccepted.selector, address(otherUsd)));
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 1 days), 0);

        // One unit of the token is worth 1.25 settlement units.
        _setting(abi.encodeCall(cards.setRate, (address(otherUsd), 1.25e18)));
        _authorize(P1, 100e6);
        assertEq(_hold(alice, P1, CASH).held, 80e6);
        _capture(P1, 100e6, true);
        assertEq(otherUsd.balanceOf(settlement), 80e6);
    }

    function test_settlementCursor() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        (uint64 seq,, uint128 net,) = cards.ledger();
        assertEq(seq, 2);
        assertEq(net, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.InvalidCursor.selector);
        cards.acknowledgeSettlement(3);
        vm.prank(issuer);
        cards.acknowledgeSettlement(2);
        (, uint64 settledThrough,,) = cards.ledger();
        assertEq(settledThrough, 2);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.InvalidCursor.selector);
        cards.acknowledgeSettlement(2);
    }

    // Helpers.

    function _savings(address owner, uint256 assets) internal returns (uint256 shares) {
        usd.mint(owner, assets);
        shares = _depositEarn(owner, assets);
    }

    function _grant(uint64 limit, uint64 perPurchase, uint64 daily, uint64 monthly, int32 utcOffset) internal {
        vm.prank(alice);
        cards.grant(
            CardLimits.Terms({
                limit: limit, perPurchase: perPurchase, daily: daily, monthly: monthly, utcOffset: utcOffset
            })
        );
    }

    function _withLine(uint128 limit) internal returns (uint64 lineId) {
        lineId = _openLine(alice, limit, IEarnVault(address(0)), 0);
        vm.prank(alice);
        _setFunding(address(usd), address(facility), address(credit), lineId);
    }
}
