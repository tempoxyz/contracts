// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardAuth } from "../../src/programs/CardAuth.sol";
import { CardLegs } from "../../src/programs/CardLegs.sol";
import { CardLimits } from "../../src/programs/CardLimits.sol";
import { Conversion } from "../../src/programs/Conversion.sol";
import { ICardAuth } from "../../src/programs/interfaces/ICardAuth.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ISource } from "../../src/programs/interfaces/ISource.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";
import { Vm } from "forge-std/Vm.sol";

/// @notice Card authorization over its funding sources: cards, limits, mandates, and purchases held across cash,
///         savings and credit legs by the sources themselves, captured, released and refunded in one call each.
contract CardAuthTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");
    bytes32 internal constant P3 = bytes32("purchase-3");
    uint8 internal constant PARTIAL = 1;
    uint8 internal constant STAND_IN = 2;
    /// @dev Storage slot of CardAuth's _purchases mapping (forge inspect CardAuth storageLayout).
    uint256 internal constant PURCHASES_SLOT = 22;
    uint256 internal constant STATE_SLOT = 6;
    uint256 internal constant LEDGER_SLOT = 7;
    uint256 internal constant CARDS_SLOT = 14;
    uint256 internal constant USAGE_SLOT = 18;

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
    }

    // Cash leg.

    function test_authorize_cash_placesOneSourceHold() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);

        IReservationCore.HoldRecord memory h = _hold(alice, P1, CASH_LEG);
        assertEq(h.token, address(usd));
        assertEq(h.payee, address(cash));
        assertEq(h.held, 100e6);
        assertEq(h.captureLimit, 100e6);
        // The program itself places nothing on the core.
        assertEq(core.getHold(alice, address(cards), cards.legId(P1, CASH_LEG)).token, address(0));
        assertEq(core.reserved(alice, address(usd)), 100e6);
        assertEq(core.budget(alice, address(cash), address(usd)).outstanding, 100e6);
        ICardAuth.PurchaseView memory p = cards.purchaseOf(P1);
        assertEq(_legs(P1), 1 << CASH_LEG);
        assertTrue(p.open);
        assertEq(p.held, 100e6);
        _assertCoreBalanced();
    }

    function test_capture_cash_paysSettlementAccount() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.expectEmit(address(cards));
        emit CardAuth.PurchaseCaptured(P1, 100e6, 100e6, true, false, 2);
        _capture(P1, 100e6, true);

        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(usd.balanceOf(alice), 900e6);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertFalse(cards.purchaseOf(P1).open);
        _assertSourcesEmpty();
        _assertCoreBalanced();
    }

    function test_capture_partialThenFinal() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 40e6, false);
        assertEq(_hold(alice, P1, CASH_LEG).held, 60e6);
        _capture(P1, 30e6, true);
        assertEq(usd.balanceOf(settlement), 70e6);
        assertEq(usd.balanceOf(alice), 930e6);
        // The core deletes a hold once it settles.
        assertEq(_hold(alice, P1, CASH_LEG).token, address(0));
    }

    function test_capture_tipWithinTolerance() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardLegs.CaptureLimitExceeded.selector);
        cards.capture(P1, 110e6, true);
        vm.prank(issuer);
        cards.release(P1);

        // With a 20% tolerance on the cash source's payee terms, the tip fits.
        _setTolerance(alice, address(cash), address(usd), 2000);
        _authorize(P2, 100e6);
        _capture(P2, 110e6, true);
        assertEq(usd.balanceOf(settlement), 110e6);
        assertEq(usd.balanceOf(alice), 890e6);
        // The tip counts against the limits.
        assertEq(cards.cardOf(CARD).window.daySpent, 110e6);
    }

    function test_capture_twice_refused() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.PurchaseNotOpen.selector);
        cards.capture(P1, 100e6, true);
        // The core refuses a second capture of the settled leg too, even by the source that placed it.
        bytes32 id = cards.legId(P1, CASH_LEG);
        vm.prank(address(cash));
        vm.expectRevert(IReservationCore.HoldNotFound.selector);
        core.capture(alice, address(cash), id, 1, false);
    }

    function test_capture_afterExpiry_refused_andAnyoneReleases() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 400e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.PurchaseExpired.selector);
        cards.capture(P1, 400e6, true);
        // The core enforces hard expiry whoever captures.
        bytes32 id = cards.legId(P1, CASH_LEG);
        vm.prank(address(cash));
        vm.expectRevert(IReservationCore.HoldExpired.selector);
        core.capture(alice, address(cash), id, 1, false);

        vm.prank(bob);
        cards.release(P1);
        assertEq(usd.balanceOf(alice), 1000e6);
        assertFalse(cards.purchaseOf(P1).open);
        // Nothing was captured, so the day's window has its amount back.
        assertEq(cards.cardOf(CARD).window.daySpent, 0);
        _assertCoreBalanced();
    }

    function test_release_byAnyoneBeforeExpiry_refused() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(bob);
        vm.expectRevert(CardAuth.Unauthorized.selector);
        cards.release(P1);
    }

    function test_release_byAnyone_onlyOnceExpired() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        uint64 expiresAt = cards.purchaseOf(P1).expiresAt;
        vm.warp(expiresAt - 1);
        vm.prank(bob);
        vm.expectRevert(CardAuth.Unauthorized.selector);
        cards.release(P1);
        // An operator with only the settle role cannot release a live purchase either.
        address settler = makeAddr("settler");
        uint8 settleRole = cards.ROLE_SETTLE();
        vm.prank(issuer);
        cards.setOperator(settler, settleRole, 1e12);
        vm.prank(settler);
        vm.expectRevert(CardAuth.Unauthorized.selector);
        cards.release(P1);

        vm.warp(expiresAt);
        vm.expectEmit(address(cards));
        emit CardAuth.PurchaseReleased(P1, 100e6, 2);
        vm.prank(bob);
        cards.release(P1);
        assertEq(usd.balanceOf(alice), 1000e6);
        assertEq(_hold(alice, P1, CASH_LEG).token, address(0));
        // Once ended it cannot be released again.
        vm.prank(bob);
        vm.expectRevert(CardAuth.PurchaseNotOpen.selector);
        cards.release(P1);
        _assertCoreBalanced();
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

    function test_onlyIssuerOrOperator() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(CardAuth.Unauthorized.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
        _authorize(P1, 1e6);
        vm.prank(alice);
        vm.expectRevert(CardAuth.Unauthorized.selector);
        cards.capture(P1, 1e6, true);
    }

    function test_purchaseRef_isUnique() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 1e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.PurchaseExists.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
        // Nor after it ends.
        _capture(P1, 1e6, true);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.PurchaseExists.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    // Card controls.

    function test_frozenCard_refused() public {
        usd.mint(alice, 1000e6);
        vm.prank(bob);
        vm.expectRevert(CardAuth.NotCardOwner.selector);
        cards.setOwnStatus(CARD, 1);
        vm.prank(alice);
        cards.setOwnStatus(CARD, 1);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.CardNotActive.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.prank(alice);
        cards.setOwnStatus(CARD, 2);
        _authorize(P1, 1e6);
    }

    function test_closedCard_refused() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        cards.setOwnStatus(CARD, 3);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.CardNotActive.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), PARTIAL);
    }

    function test_expiredCard_refused() public {
        usd.mint(alice, 1000e6);
        vm.warp(vm.getBlockTimestamp() + 366 days);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.CardExpired.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_replaceCard_movesOwnerAndLimits() public {
        usd.mint(alice, 1000e6);
        bytes32 next = bytes32("card-2");
        vm.prank(issuer);
        cards.replaceCard(CARD, next, uint40(block.timestamp + 700 days));
        CardLimits.Card memory c = cards.cardOf(next);
        assertEq(c.owner, alice);
        assertEq(c.limits.perPurchase, 500e6);
        assertEq(uint8(cards.cardOf(CARD).status), uint8(CardLimits.Status.Closed));
        vm.prank(issuer);
        vm.expectRevert(CardLimits.CardNotActive.selector);
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
        assertEq(cards.purchaseOf(P1).card, next);

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
        bytes memory data = abi.encode(usage, ids, windows, merchants, spent);

        vm.expectRevert(CardAuth.NotIssuer.selector);
        cards.carryUsage(alice, data);
        vm.startPrank(issuer);
        cards.carryUsage(alice, data);
        // Carrying the same usage again changes nothing.
        cards.carryUsage(alice, data);
        vm.stopPrank();

        (bool revoked, uint96 limit,, uint96 counted) = cards.mandates(alice, merchant);
        assertFalse(revoked);
        assertEq(limit, 150e6);
        assertEq(counted, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.MerchantLimitExceeded.selector);
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
        bytes memory data = abi.encode(usage, ids, windows, new address[](0), new CardLimits.Mandate[](0));
        vm.prank(issuer);
        vm.expectRevert(CardLimits.InvalidCard.selector);
        cards.carryUsage(address(0xB0B), data);
    }

    function test_limits_ownerLowersAndIssuerRaisesOnlyWithinCeiling() public {
        vm.prank(issuer);
        vm.expectRevert(CardLimits.LimitAboveCeiling.selector);
        cards.setLimits(CARD, _limits(600e6, 1000e6, 5000e6), 0);

        vm.prank(alice);
        cards.setLimits(CARD, _limits(100e6, 200e6, 1000e6), 1);
        // The issuer cannot raise them back past what the owner lowered.
        vm.prank(issuer);
        vm.expectRevert(CardLimits.LimitAboveCeiling.selector);
        cards.setLimits(CARD, _limits(500e6, 1000e6, 5000e6), 0);
        vm.prank(alice);
        vm.expectRevert(CardLimits.LimitAboveCeiling.selector);
        cards.setLimits(CARD, _limits(200e6, 200e6, 1000e6), 1);
        // Nobody else sets them.
        vm.prank(bob);
        vm.expectRevert(CardAuth.NotCardOwner.selector);
        cards.setLimits(CARD, _limits(800e6, 2000e6, 8000e6), 2);
        vm.prank(alice);
        vm.expectRevert(CardAuth.NotIssuer.selector);
        cards.setLimits(CARD, _limits(100e6, 200e6, 1000e6), 0);

        vm.prank(alice);
        cards.setLimits(CARD, _limits(800e6, 2000e6, 8000e6), 2);
        vm.prank(issuer);
        cards.setLimits(CARD, _limits(800e6, 2000e6, 8000e6), 0);
        assertEq(cards.cardOf(CARD).limits.perPurchase, 800e6);
    }

    function test_overLimit_onPurchaseTotalAcrossLegs() public {
        // 60 cash and about 60 in savings: each leg is under 100, the purchase is not.
        usd.mint(alice, 60e6);
        _savings(alice, 60e6);
        vm.prank(alice);
        cards.setLimits(CARD, _limits(100e6, 1000e6, 5000e6), 1);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(0)));
        cards.authorize(CARD, P1, 110e6, merchant, uint64(block.timestamp + 1 days), 0);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
    }

    function test_dailyAndMonthlyWindows() public {
        usd.mint(alice, 5000e6);
        vm.prank(alice);
        cards.setLimits(CARD, _limits(500e6, 600e6, 900e6), 1);
        _authorize(P1, 400e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(1)));
        cards.authorize(CARD, P2, 300e6, merchant, uint64(block.timestamp + 1 days), 0);

        // A new day resets the daily window but not the month.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _authorize(P2, 400e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(2)));
        cards.authorize(CARD, P3, 200e6, merchant, uint64(vm.getBlockTimestamp() + 1 days), 0);
    }

    // Owner terms.

    function test_terms_requireGrant_andRevokeStopsNewPurchases() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(alice);
        cards.revoke();
        vm.prank(issuer);
        vm.expectRevert(CardLimits.NoTerms.selector);
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
        vm.expectRevert(CardLimits.NoTerms.selector);
        cards.adjust(P1, 150e6);
        vm.prank(issuer);
        cards.adjust(P1, 60e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 60e6);
        _capture(P1, 60e6, true);
        assertEq(usd.balanceOf(settlement), 60e6);
    }

    function test_adjust_frozenCardBeforeRevokedGrant() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(alice);
        cards.revoke();
        vm.prank(alice);
        cards.setOwnStatus(CARD, 1);
        // The card's status is checked first.
        vm.prank(issuer);
        vm.expectRevert(CardLimits.CardNotActive.selector);
        cards.adjust(P1, 150e6);
    }

    function test_revoke_refusesForcePost_butLateChargeOnAuthorizedPurchaseLands() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(alice);
        cards.revoke();
        // A force post opens a new purchase, which a revoked grant refuses.
        vm.prank(issuer);
        vm.expectRevert(CardLimits.NoTerms.selector);
        cards.charge(CARD, P2, 10e6, merchant);
        assertEq(cards.purchaseOf(P2).owner, address(0));
        // A late presentment of a purchase authorized under the grant still charges once its hold ended.
        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.PurchaseExists.selector);
        cards.charge(CARD, P1, 100e6, merchant);
        vm.prank(bob);
        cards.release(P1);
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
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(3)));
        cards.authorize(CARD, P2, 60e6, merchant, uint64(block.timestamp + 1 days), 0);
        // A final capture below the hold gives back the rest.
        _capture(P1, 80e6, true);
        (uint64 committed,,,,) = cards.usageOf(alice);
        assertEq(committed, 80e6);
        _authorize(P2, 70e6);
        // A refund gives its amount back.
        _refund(P1, 50e6);
        (committed,,,,) = cards.usageOf(alice);
        assertEq(committed, 100e6);
    }

    function test_terms_calendarMonth_atOffset() public {
        usd.mint(alice, 1000e6);
        // 2026-01-31 23:00 UTC is 2026-02-01 01:00 at UTC+2.
        vm.warp(1_769_900_400);
        _extendCard();
        _grant(0, 0, 0, 100e6, 2 hours);
        _authorize(P1, 100e6);
        // 2026-02-28 21:00 UTC is still February at UTC+2.
        vm.warp(1_772_312_400);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(2)));
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
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(0)));
        cards.authorize(CARD, P1, 60e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_cardCap() public {
        usd.mint(alice, 1000e6);
        vm.prank(issuer);
        cards.setCard(CARD, 0, 120e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(4)));
        cards.authorize(CARD, P2, 30e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_partialApproval_holdsWhatIsAvailable() public {
        usd.mint(alice, 40e6);
        vm.prank(alice);
        _setFunding(true, false, false);
        vm.prank(issuer);
        uint256 approved = cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 1 days), PARTIAL);
        assertEq(approved, 40e6);
        assertEq(cards.purchaseOf(P1).held, 40e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 40e6);
        // Only what was approved counts against the limits.
        assertEq(cards.cardOf(CARD).window.daySpent, 40e6);
        // Without PARTIAL the same request declines.
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InsufficientAvailable.selector);
        cards.authorize(CARD, P2, 100e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_partialApproval_wholeCents() public {
        usd.mint(alice, 40_005_000);
        vm.prank(alice);
        _setFunding(true, false, false);
        vm.prank(issuer);
        uint256 approved = cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 1 days), PARTIAL);
        assertEq(approved, 40e6);
        assertEq(cards.purchaseOf(P1).held, 40e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 40e6);
        // A request the sources cover in full keeps its fraction of a cent.
        vm.prank(issuer);
        assertEq(cards.authorize(CARD, P2, 5000, merchant, uint64(block.timestamp + 1 days), PARTIAL), 5000);
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
        vm.expectRevert(CardAuth.Unauthorized.selector);
        cards.capture(P1, 10e6, true);
    }

    function test_operator_capBoundsWhatItAuthorizes() public {
        usd.mint(alice, 1000e6);
        address key = makeAddr("key");
        uint8 authorizeRole = cards.ROLE_AUTHORIZE();
        uint8 settleRole = cards.ROLE_SETTLE();
        vm.prank(issuer);
        cards.setOperator(key, authorizeRole, 50e6);
        vm.prank(key);
        cards.authorize(CARD, P1, 30e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.prank(key);
        vm.expectRevert(CardAuth.OperatorCapExceeded.selector);
        cards.authorize(CARD, P2, 30e6, merchant, uint64(block.timestamp + 1 days), 0);
        // An increment uses the cap by what it adds.
        vm.prank(key);
        cards.adjust(P1, 50e6);
        vm.prank(key);
        vm.expectRevert(CardAuth.OperatorCapExceeded.selector);
        cards.adjust(P1, 50e6 + 1);
        assertEq(cards.operatorOf(key).used, 50e6);
        // A settle-only operator cannot authorize.
        vm.prank(issuer);
        cards.setOperator(key, settleRole, 50e6);
        vm.prank(key);
        vm.expectRevert(CardAuth.Unauthorized.selector);
        cards.authorize(CARD, P2, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    // Incremental authorization and late charges.

    function test_adjust_raisesAndLowersCashHold() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.adjust(P1, 150e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 150e6);
        assertEq(cards.cardOf(CARD).window.daySpent, 150e6);
        vm.prank(issuer);
        cards.adjust(P1, 120e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 120e6);
        assertEq(cards.cardOf(CARD).window.daySpent, 120e6);
        _capture(P1, 120e6, true);
        assertEq(usd.balanceOf(settlement), 120e6);
    }

    function test_adjust_overLimitOrFunds_refused() public {
        usd.mint(alice, 300e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(0)));
        cards.adjust(P1, 600e6);
        vm.prank(issuer);
        vm.expectRevert(CardLegs.InsufficientAvailable.selector);
        cards.adjust(P1, 350e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 100e6);
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
        cards.charge(CARD, P3, 100e6 + 1, merchant);
        vm.prank(issuer);
        cards.charge(CARD, P3, 100e6, merchant);
        // A refund of a force post gives its room back.
        _refund(P2, 50e6);
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
        cards.setCard(CARD, 0, 120e6);
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
        _setFunding(true, false, false);
        _authorize(P1, 50e6);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        _setDebtCap(alice, address(cash), address(usd), 30e6);
        vm.prank(bob);
        cards.release(P1);
        vm.prank(issuer);
        cards.charge(CARD, P1, 70e6, merchant);
        assertEq(usd.balanceOf(settlement), 50e6);
        assertEq(_owed(alice, address(usd), address(cash)), 20e6);
        ICardAuth.PurchaseView memory p = cards.purchaseOf(P1);
        assertFalse(p.open);
        assertTrue(p.charged);
        assertEq(p.captured, 70e6);
        assertEq(p.refunded, 0);
        // A refund repays the debt first; what repaid it is the source's to forward.
        _refund(P1, 30e6);
        assertEq(_owed(alice, address(usd), address(cash)), 0);
        assertEq(usd.balanceOf(alice), 10e6);
        cash.sweep(address(usd));
        assertEq(usd.balanceOf(settlement), 70e6);
        _assertSourcesEmpty();
        _assertCoreBalanced();
    }

    function test_charge_pastDebtCap_issuerAbsorbsTheRest() public {
        usd.mint(alice, 50e6);
        _setDebtCap(alice, address(cash), address(usd), 30e6);
        // 50 available plus 30 of debt: the issuer carries the other 20.
        vm.expectEmit(address(cards));
        emit CardAuth.PurchaseCaptured(P1, 100e6, 80e6, true, true, 1);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        assertEq(usd.balanceOf(settlement), 50e6);
        assertEq(_owed(alice, address(usd), address(cash)), 30e6);
        // The whole amount counts toward the limits, not just what the owner paid.
        assertEq(cards.cardOf(CARD).window.daySpent, 100e6);
        // What the issuer absorbed is booked as refunded, so it can never be refunded to the owner.
        assertEq(cards.purchaseOf(P1).refunded, 20e6);
        (,, int128 net,) = cards.ledger();
        assertEq(net, 80e6);
        _assertCoreBalanced();
    }

    function test_refund_pastDebtCap_repaysButNeverPaysWhatTheIssuerAbsorbed() public {
        usd.mint(alice, 50e6);
        _setDebtCap(alice, address(cash), address(usd), 30e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        _fundRefund(101e6);
        // The sources covered 80; the 20 the issuer absorbed is not refundable.
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.refund(P1, 81e6);
        // The refund repays the debt and restores the cash.
        vm.prank(issuer);
        cards.refund(P1, 80e6);
        assertEq(_owed(alice, address(usd), address(cash)), 0);
        assertEq(core.available(alice, address(usd)), 50e6);
        // Once the issuer recovers what it absorbed from a merchant reserve, that becomes refundable too.
        vm.prank(issuer);
        cards.reserveSettled(P1, 20e6);
        vm.prank(issuer);
        cards.refund(P1, 20e6);
        assertEq(core.available(alice, address(usd)), 70e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.refund(P1, 1);
        _assertCoreBalanced();
    }

    function test_charge_nothingToTake_absorbsAllAndHasNoLeg() public {
        vm.expectEmit(address(cards));
        emit CardAuth.PurchaseCaptured(P1, 40e6, 0, true, true, 1);
        vm.prank(issuer);
        cards.charge(CARD, P1, 40e6, merchant);
        // No leg paid: only the record that the reference was charged.
        assertEq(_legs(P1), 0);
        ICardAuth.PurchaseView memory p = cards.purchaseOf(P1);
        assertTrue(p.charged);
        assertEq(p.captured, 40e6);
        assertEq(p.refunded, 40e6);
        // Nothing was taken from the owner, so there is nothing to refund.
        _fundRefund(1e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.refund(P1, 1e6);
        // The same reference cannot be charged twice.
        usd.mint(alice, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.PurchaseExists.selector);
        cards.charge(CARD, P1, 40e6, merchant);
    }

    function test_charge_lateChargeTwice_refused() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.release(P1);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        // A replayed presentment of the same reference does not charge the owner again.
        vm.prank(issuer);
        vm.expectRevert(CardAuth.PurchaseExists.selector);
        cards.charge(CARD, P1, 100e6, merchant);
        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(usd.balanceOf(alice), 900e6);
    }

    function test_charge_debtToAnotherCreditor_keepsThisSourcesCap() public {
        address lender = makeAddr("lender");
        usd.mint(alice, 10e6);
        _setDebtCap(alice, address(cash), address(usd), 30e6);
        _setDebtCap(alice, lender, address(usd), 5e6);
        vm.prank(alice);
        core.approveHolder(lender, address(usd), 100e6, 0);
        vm.prank(lender);
        core.charge(alice, address(usd), bytes32("x"), 15e6, lender, false);
        // Another creditor's debt leaves this source's cap whole: the charge is owed to the source.
        vm.prank(issuer);
        cards.charge(CARD, P1, 20e6, merchant);
        assertEq(_owed(alice, address(usd), lender), 5e6);
        assertEq(_owed(alice, address(usd), address(cash)), 20e6);
        assertEq(usd.balanceOf(settlement), 0);
        assertEq(cards.purchaseOf(P1).refunded, 0);
        _assertCoreBalanced();
    }

    function test_charge_creditorsFull_takesNoDebt() public {
        _setDebtCap(alice, address(cash), address(usd), 30e6);
        // The owner owes as many other creditors as the core keeps: there is no slot for this source.
        for (uint256 i; i < 4; ++i) {
            address lender = address(uint160(0x1000 + i));
            _setDebtCap(alice, lender, address(usd), 5e6);
            vm.prank(alice);
            core.approveHolder(lender, address(usd), 100e6, 0);
            vm.prank(lender);
            core.charge(alice, address(usd), bytes32(i), 1e6, lender, false);
        }
        vm.prank(issuer);
        cards.charge(CARD, P1, 20e6, merchant);
        assertEq(_owed(alice, address(usd), address(cash)), 0);
        assertEq(cards.purchaseOf(P1).refunded, 20e6);
        assertEq(usd.balanceOf(settlement), 0);
        _assertCoreBalanced();
    }

    function test_charge_onOpenPurchase_refused() public {
        usd.mint(alice, 100e6);
        _authorize(P1, 50e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.PurchaseExists.selector);
        cards.charge(CARD, P1, 50e6, merchant);
    }

    function test_revokedMerchant_refused() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        cards.setMandate(merchant, true, 0);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.MerchantRevoked.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_merchantMonthlyLimit() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        cards.setMandate(merchant, false, 150e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.MerchantLimitExceeded.selector);
        cards.authorize(CARD, P2, 100e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _authorize(P2, 100e6);
    }

    // Holder allowance.

    function test_revokedHolder_liveHoldsStillSettle() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(alice);
        core.approveHolder(address(cash), address(usd), 0, 0);
        vm.prank(issuer);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        cards.authorize(CARD, P2, 100e6, merchant, uint64(block.timestamp + 1 days), 0);

        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
    }

    function test_holderAllowance_capsOutstanding() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        core.approveHolder(address(cash), address(usd), 150e6, 0);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(IReservationCore.BudgetExceeded.selector);
        cards.authorize(CARD, P2, 100e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    // Savings and credit legs.

    function test_authorize_spansCashAndSavings() public {
        usd.mint(alice, 30e6);
        uint256 shares = _savings(alice, 500e6);
        _authorize(P1, 100e6);

        assertEq(_legs(P1), 1 << CASH_LEG | 1 << SAVINGS_LEG);
        assertEq(_hold(alice, P1, CASH_LEG).held, 30e6);
        IReservationCore.HoldRecord memory s = _hold(alice, P1, SAVINGS_LEG);
        assertEq(s.token, address(earnShare));
        assertEq(s.payee, address(savings));
        assertEq(s.held, earnVault.previewWithdraw(70e6));
        assertEq(earnShare.balanceOf(alice), shares - s.held);

        _capture(P1, 100e6, true);
        assertApproxEqAbs(usd.balanceOf(settlement), 100e6, 2);
        assertEq(earnShare.balanceOf(address(savings)), 0);
        assertEq(usd.balanceOf(address(savings)), FLOAT);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        _assertCoreBalanced();
    }

    function test_capture_waterfall_cashFirst() public {
        usd.mint(alice, 30e6);
        uint256 shares = _savings(alice, 500e6);
        _authorize(P1, 100e6);
        // A partial capture takes cash before shares.
        _capture(P1, 50e6, false);
        assertEq(_hold(alice, P1, CASH_LEG).held, 0);
        assertApproxEqAbs(usd.balanceOf(settlement), 50e6, 2);
        _capture(P1, 0, true);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertGt(earnShare.balanceOf(alice), shares - earnVault.previewWithdraw(70e6));
    }

    function test_insufficientFunds_placesNothing() public {
        usd.mint(alice, 30e6);
        _savings(alice, 20e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InsufficientAvailable.selector);
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 1 days), 0);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
    }

    function test_stoppedSource_skippedForNewPurchases_butSettlesItsHolds() public {
        _savings(alice, 200e6);
        _authorize(P1, 50e6);
        assertEq(_legs(P1), 1 << SAVINGS_LEG);
        _setting(abi.encodeCall(cards.setSource, (address(savings), false)));
        assertEq(cards.sourceKind(address(savings)), 0);
        // The owner's order still lists it, but new purchases skip it.
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InsufficientAvailable.selector);
        cards.authorize(CARD, P2, 50e6, merchant, uint64(block.timestamp + 1 days), 0);
        // And no new order can list it.
        vm.expectRevert(CardLegs.InvalidOrder.selector);
        this.setFundingAs(true, true, false);
        // The purchase it holds still settles.
        _capture(P1, 50e6, true);
        assertApproxEqAbs(usd.balanceOf(settlement), 50e6, 2);
        assertEq(core.reserved(alice, address(earnShare)), 0);
    }

    function test_threeLegs_captureDrawsTheLine() public {
        usd.mint(alice, 30e6);
        _savings(alice, 20e6);
        _withLine(1000e6);
        _authorize(P1, 100e6);

        assertEq(_legs(P1), 1 << CASH_LEG | 1 << SAVINGS_LEG | 1 << CREDIT_LEG);
        bytes32 creditId = cards.legId(P1, CREDIT_LEG);
        // The line books its leg itself; nothing of it is on the core.
        uint256 drawn = line.held(alice, bytes32(0), creditId);
        assertApproxEqAbs(drawn, 50e6, 2);
        assertEq(line.usedOf(alice), drawn);
        assertEq(core.getHold(alice, address(line), creditId).token, address(0));

        _capture(P1, 100e6, true);
        assertApproxEqAbs(usd.balanceOf(settlement), 100e6, 2);
        (uint128 held, uint128 captured,) = line.legs(alice, creditId);
        assertEq(held, 0);
        assertEq(captured, drawn);
        assertEq(usd.balanceOf(address(line)), FLOAT - drawn);
        assertEq(line.usedOf(alice), drawn);
        _assertCoreBalanced();
    }

    function test_threeLegs_releaseFreesEveryLeg() public {
        usd.mint(alice, 30e6);
        _savings(alice, 20e6);
        _withLine(1000e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.release(P1);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertEq(line.usedOf(alice), 0);
        assertEq(line.held(alice, bytes32(0), cards.legId(P1, CREDIT_LEG)), 0);
        assertEq(usd.balanceOf(address(line)), FLOAT);
    }

    function test_refund_reverseOrder_creditThenSavingsThenCash() public {
        usd.mint(alice, 30e6);
        uint256 shares = _savings(alice, 20e6);
        _withLine(1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        uint256 sharesBefore = earnShare.balanceOf(alice);
        uint256 owed = line.usedOf(alice);
        uint256 cashBefore = usd.balanceOf(alice);
        assertLt(sharesBefore, shares);
        bytes32 savingsId = cards.legId(P1, SAVINGS_LEG);
        assertApproxEqAbs(savings.refundable(alice, bytes32(0), savingsId), 20e6, 2);

        // The legs take back in reverse order: the credit leg what it captured, then savings.
        _fundRefund(100e6);
        vm.prank(issuer);
        cards.refund(P1, uint128(owed + 10e6));
        assertEq(line.usedOf(alice), 0);
        assertEq(line.refundedTo(alice), owed);
        assertEq(usd.balanceOf(alice), cashBefore, "nothing back to cash yet");
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice) - sharesBefore), 10e6, 2);
        assertApproxEqAbs(savings.refundable(alice, bytes32(0), savingsId), 10e6, 2);

        vm.prank(issuer);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.refund(P1, 50e6);
        // The rest restores savings up to what it captured, then cash.
        vm.prank(issuer);
        cards.refund(P1, uint128(90e6 - owed));
        assertEq(savings.refundable(alice, bytes32(0), savingsId), 0);
        assertApproxEqAbs(usd.balanceOf(alice), cashBefore + 30e6, 2);
        _assertCoreBalanced();
    }

    function test_adjustDown_cashAndSavings_cashGivesBackFirst() public {
        usd.mint(alice, 30e6);
        _savings(alice, 500e6);
        _authorize(P1, 50e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 30e6);
        bytes32 savingsId = cards.legId(P1, SAVINGS_LEG);
        assertApproxEqAbs(savings.held(alice, bytes32(0), savingsId), 20e6, 2);

        // A partial reversal of 15 lowers cash, not savings.
        vm.prank(issuer);
        cards.adjust(P1, 35e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 15e6);
        assertApproxEqAbs(savings.held(alice, bytes32(0), savingsId), 20e6, 2);
        assertEq(usd.balanceOf(alice), 15e6);
        // Past what cash holds, savings gives back the rest.
        vm.prank(issuer);
        cards.adjust(P1, 10e6);
        assertEq(_hold(alice, P1, CASH_LEG).token, address(0));
        assertApproxEqAbs(savings.held(alice, bytes32(0), savingsId), 10e6, 2);
        assertEq(usd.balanceOf(alice), 30e6);
        assertEq(cards.purchaseOf(P1).held, 10e6);
        _assertCoreBalanced();
    }

    function test_refund_cashAndSavings_restoresSavingsFirst() public {
        usd.mint(alice, 30e6);
        _savings(alice, 500e6);
        _authorize(P1, 40e6);
        _capture(P1, 40e6, true);
        assertEq(usd.balanceOf(alice), 0);
        uint256 sharesBefore = earnShare.balanceOf(alice);

        // 15 back: savings takes the 10 it captured, cash the other 5.
        _refund(P1, 15e6);
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice) - sharesBefore), 10e6, 2);
        assertEq(usd.balanceOf(alice), 5e6);
        assertEq(savings.refundable(alice, bytes32(0), cards.legId(P1, SAVINGS_LEG)), 0);
        // The rest goes to cash.
        _refund(P1, 25e6);
        assertEq(usd.balanceOf(alice), 30e6);
        _assertCoreBalanced();
    }

    function test_savingsThenCash_adjustDownLowersCash_refundTakesCashFirst() public {
        usd.mint(alice, 100e6);
        _savings(alice, 20e6);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](2);
        order[0] = CardLegs.Funding(ISource(address(savings)), bytes32(0));
        order[1] = _cashEntry(address(usd), 0);
        vm.prank(alice);
        cards.setFunding(order);
        _authorize(P1, 50e6);
        bytes32 savingsId = cards.legId(P1, 0);
        bytes32 cashId = cards.legId(P1, 1);
        assertApproxEqAbs(savings.held(alice, bytes32(0), savingsId), 20e6, 2);
        assertApproxEqAbs(core.getHold(alice, address(cash), cashId).held, 30e6, 2);

        // Cash gives back first even though it is the last leg drawn.
        vm.prank(issuer);
        cards.adjust(P1, 40e6);
        assertApproxEqAbs(core.getHold(alice, address(cash), cashId).held, 20e6, 2);
        assertApproxEqAbs(savings.held(alice, bytes32(0), savingsId), 20e6, 2);

        _capture(P1, 40e6, true);
        uint256 sharesBefore = earnShare.balanceOf(alice);
        uint256 cashBefore = usd.balanceOf(alice);
        // In reverse order: cash takes back the 20 it netted, then savings 5.
        _refund(P1, 25e6);
        assertApproxEqAbs(usd.balanceOf(alice), cashBefore + 20e6, 2);
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice) - sharesBefore), 5e6, 3);
        assertApproxEqAbs(savings.refundable(alice, bytes32(0), savingsId), 15e6, 3);
        _assertCoreBalanced();
    }

    function test_refund_creditBoundedByRefundable_thenCashTakesTheRest() public {
        usd.mint(alice, 30e6);
        line.setLimit(alice, 1000e6);
        vm.prank(alice);
        _setFunding(true, false, true);
        _authorize(P1, 100e6);
        // Cash is order entry 0 and the line entry 1 in this order.
        assertEq(_legs(P1), 1 << 0 | 1 << 1);
        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(usd.balanceOf(address(line)), FLOAT - 70e6);
        (address[] memory sources,,) = cards.legsOf(P1);
        assertEq(sources[1], address(line));

        _fundRefund(100e6);
        vm.prank(issuer);
        cards.refund(P1, 90e6);
        // The line takes back exactly what its leg captured, cash the rest.
        assertEq(line.refundedTo(alice), 70e6);
        assertEq(line.refundable(alice, bytes32(0), cards.legId(P1, 1)), 0);
        assertEq(usd.balanceOf(address(line)), FLOAT);
        assertEq(usd.balanceOf(alice), 20e6);
        // With the line's room used up, a later refund goes to cash only.
        vm.prank(issuer);
        cards.refund(P1, 10e6);
        assertEq(line.refundedTo(alice), 70e6);
        assertEq(usd.balanceOf(alice), 30e6);
        assertEq(cards.purchaseOf(P1).refunded, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.refund(P1, 1);
        _assertSourcesEmpty();
        _assertCoreBalanced();
    }

    function test_refund_aboveCapture_refused() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 50e6, true);
        _fundRefund(100e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.refund(P1, 51e6);
        vm.prank(issuer);
        cards.refund(P1, 50e6);
        assertEq(usd.balanceOf(alice), 1000e6);
        (,, int128 net,) = cards.ledger();
        assertEq(net, 0);
    }

    // Stand-ins, conversion and the settlement cursor.

    function test_standIn_adjustDown_keepsWhatIsHeldUpToTheNewAmount() public {
        usd.mint(alice, 30e6);
        _setOfflineCap(alice, address(cash), address(usd), 50e6);
        vm.prank(issuer);
        cards.authorize(CARD, P1, 40e6, merchant, uint64(block.timestamp + 1 days), STAND_IN);
        assertEq(_hold(alice, P1, CASH_LEG).held, 30e6);
        // Down to 35: the 30 reserved still fits, so nothing moves on the core.
        vm.prank(issuer);
        cards.adjust(P1, 35e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 30e6);
        assertEq(cards.purchaseOf(P1).held, 35e6);
        assertEq(cards.cardOf(CARD).window.daySpent, 35e6);
        // Down to 20: the hold gives back 10.
        vm.prank(issuer);
        cards.adjust(P1, 20e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 20e6);
        assertEq(usd.balanceOf(alice), 10e6);
        assertEq(cards.cardOf(CARD).window.daySpent, 20e6);
        _assertCoreBalanced();
    }

    /// @dev A stand-in lowered below what then clears captures within the owner's tolerance, the rest as debt up to the
    ///      offline cap; past the tolerance it refuses.
    function test_standIn_captureWithinTolerance_afterAdjustDown() public {
        usd.mint(alice, 30e6);
        _setOfflineCap(alice, address(cash), address(usd), 50e6);
        _setTolerance(alice, address(cash), address(usd), 2000);
        vm.prank(issuer);
        cards.authorize(CARD, P1, 40e6, merchant, uint64(block.timestamp + 1 days), STAND_IN);
        vm.prank(issuer);
        cards.adjust(P1, 35e6);
        vm.prank(issuer);
        vm.expectRevert(CardLegs.CaptureLimitExceeded.selector);
        cards.capture(P1, 43e6, true);
        _capture(P1, 40e6, true);
        assertEq(usd.balanceOf(alice), 0);
        assertEq(core.debtOf(alice, address(usd))[0].amount, 10e6);
        _assertCoreBalanced();
    }

    function test_standIn_onFrozenCard_declinedWhenItLands() public {
        usd.mint(alice, 30e6);
        vm.prank(alice);
        cards.setOwnStatus(CARD, 1);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.CardNotActive.selector);
        cards.authorize(CARD, P1, 20e6, merchant, uint64(block.timestamp + 1 days), STAND_IN);
        assertEq(usd.balanceOf(alice), 30e6);
        assertEq(cards.purchaseOf(P1).owner, address(0));
    }

    function test_standIn_adjustUp_refused() public {
        usd.mint(alice, 100e6);
        vm.prank(issuer);
        cards.authorize(CARD, P1, 40e6, merchant, uint64(block.timestamp + 1 days), STAND_IN);
        vm.prank(issuer);
        cards.adjust(P1, 30e6);
        // Not past the offline approval, and not back up after coming down either.
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.adjust(P1, 41e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.adjust(P1, 35e6);
    }

    function test_standIn_reservesWhatIsThereAndForwardsRepaidDebt() public {
        usd.mint(alice, 50e6);
        vm.prank(issuer);
        cards.authorize(CARD, P1, 80e6, merchant, uint64(block.timestamp + 1 days), STAND_IN);
        IReservationCore.HoldRecord memory h = _hold(alice, P1, CASH_LEG);
        assertTrue(h.standIn);
        assertEq(h.held, 50e6);
        assertEq(h.captureLimit, 80e6);
        assertTrue(cards.purchaseOf(P1).standIn);
        (, uint256 standIn,) = cards.exposure();
        assertEq(standIn, 80e6);

        // Without an offline cap the source can't cover the gap with debt: the issuer absorbs it.
        _capture(P1, 80e6, true);
        assertEq(usd.balanceOf(settlement), 50e6);
        assertEq(_owed(alice, address(usd), address(cash)), 0);
        assertEq(cards.purchaseOf(P1).refunded, 30e6);

        // With one, the gap becomes debt to the cash source, forwarded once repaid.
        usd.mint(alice, 50e6);
        _setOfflineCap(alice, address(cash), address(usd), 30e6);
        vm.prank(issuer);
        cards.authorize(CARD, P2, 80e6, merchant, uint64(block.timestamp + 1 days), STAND_IN);
        _capture(P2, 80e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(_owed(alice, address(usd), address(cash)), 30e6);
        assertEq(cards.purchaseOf(P2).refunded, 0);

        usd.mint(alice, 40e6);
        _repay(alice, address(usd));
        cash.sweep(address(usd));
        assertEq(usd.balanceOf(settlement), 130e6);
        assertEq(_owed(alice, address(usd), address(cash)), 0);
        _assertSourcesEmpty();
    }

    function test_foreignCashToken_convertsAtLockedRate() public {
        ITIP20Token xusd = otherUsd;
        xusd.mint(alice, 1000e6);
        vm.startPrank(alice);
        core.approveHolder(address(cash), address(xusd), type(uint128).max, 0);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
        order[0] = _cashEntry(address(xusd), 0);
        cards.setFunding(order);
        vm.stopPrank();
        // Without a conversion the token covers nothing.
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InsufficientAvailable.selector);
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 1 days), 0);

        // One unit of the token is worth 1.25 settlement units.
        Conversion conv = new Conversion(address(usd), address(this));
        FixedPricePool pool = new FixedPricePool(address(xusd), address(usd), 1.25e18);
        usd.mint(address(pool), 1_000_000e6);
        conv.setVenue(address(xusd), address(usd), address(pool), true);
        conv.setReferenceRate(address(xusd), 1.25e18);
        _setting(abi.encodeCall(cards.setCompanions, (address(0), address(0), address(0), address(conv))));
        _authorize(P1, 100e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 80e6);
        assertEq(cash.lockedRate(cards.legId(P1, CASH_LEG)), 1.25e18);
        _capture(P1, 100e6, true);
        // The settlement account receives the settlement token, converted.
        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(xusd.balanceOf(alice), 920e6);
        assertEq(cash.lockedRate(cards.legId(P1, CASH_LEG)), 0);
        _assertSourcesEmpty();
    }

    function test_settlementCursor() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        (uint64 seq,, int128 net,) = cards.ledger();
        assertEq(seq, 2);
        assertEq(net, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardLegs.InvalidCursor.selector);
        cards.acknowledgeSettlement(3);
        vm.prank(issuer);
        cards.acknowledgeSettlement(2);
        (, uint64 settledThrough,, int128 settledNet) = cards.ledger();
        assertEq(settledThrough, 2);
        assertEq(settledNet, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardLegs.InvalidCursor.selector);
        cards.acknowledgeSettlement(2);
    }

    /// @dev Credit the cardholder already holds (provisional credit a won dispute keeps) settles as a refund, by what the
    ///      caller says the network charges back: negative adds back what a merchant reserve paid instead.
    function test_creditBack_countsAgainstSettlement() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        _refund(P1, 40e6);
        vm.expectEmit(address(cards));
        emit CardAuth.CreditedBack(P1, 50e6, 50e6, 4);
        vm.prank(issuer);
        cards.creditBack(P1, 50e6, 50e6);
        (uint64 seq,, int128 net,) = cards.ledger();
        assertEq(seq, 4);
        assertEq(net, 10e6);
        vm.expectEmit(address(cards));
        emit CardAuth.CreditedBack(P1, 10e6, -5e6, 5);
        vm.prank(issuer);
        cards.creditBack(P1, 10e6, -5e6);
        (,, net,) = cards.ledger();
        assertEq(net, 15e6);
        assertEq(cards.purchaseOf(P1).refunded, 100e6);
        // Nothing is left to refund or credit back.
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.creditBack(P1, 1, 1);
    }

    // Funding order versions, views and storage.

    function test_setFunding_openPurchaseKeepsItsLegs() public {
        usd.mint(alice, 30e6);
        _savings(alice, 500e6);
        _authorize(P1, 100e6);
        uint8 placedUnder = cards.fundingVersion(alice);

        // The owner moves to the line alone.
        line.setLimit(alice, 1000e6);
        vm.prank(alice);
        _setFunding(false, false, true);
        assertEq(cards.fundingVersion(alice), placedUnder + 1);
        (address[] memory sources,,) = cards.legsOf(P1);
        assertEq(sources.length, 2);
        assertEq(sources[0], address(cash));
        assertEq(sources[1], address(savings));

        // An increment grows the purchase across the order it was placed under, not the line.
        vm.prank(issuer);
        cards.adjust(P1, 120e6);
        (sources,,) = cards.legsOf(P1);
        assertEq(sources.length, 2);
        assertEq(line.usedOf(alice), 0);
        assertApproxEqAbs(savings.held(alice, bytes32(0), cards.legId(P1, SAVINGS_LEG)), 90e6, 2);

        // A new purchase draws on the new order.
        _authorize(P2, 10e6);
        bytes32[] memory ids;
        (sources,, ids) = cards.legsOf(P2);
        assertEq(sources.length, 1);
        assertEq(sources[0], address(line));
        assertEq(ids[0], cards.legId(P2, 0));
        assertEq(line.usedOf(alice), 10e6);

        // The old purchase still captures through its own legs.
        _capture(P1, 120e6, true);
        assertApproxEqAbs(usd.balanceOf(settlement), 120e6, 2);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertEq(line.usedOf(alice), 10e6);
        _assertCoreBalanced();
    }

    function test_purchaseOf_andLegsOf() public {
        // An unknown reference reads as empty.
        ICardAuth.PurchaseView memory none = cards.purchaseOf(P1);
        assertEq(none.owner, address(0));
        assertEq(none.card, bytes32(0));
        assertFalse(none.open);
        (address[] memory noSources,,) = cards.legsOf(P1);
        assertEq(noSources.length, 0);

        usd.mint(alice, 30e6);
        _savings(alice, 20e6);
        _withLine(1000e6);
        uint64 expiresAt = uint64(block.timestamp + 7 days);
        _authorize(P1, 100e6);
        ICardAuth.PurchaseView memory p = cards.purchaseOf(P1);
        assertEq(p.owner, alice);
        assertEq(p.card, CARD);
        assertEq(p.token, address(usd));
        assertEq(p.expiresAt, expiresAt);
        assertEq(p.held, 100e6);
        assertEq(p.captured, 0);
        assertEq(p.refunded, 0);
        assertTrue(p.open);
        assertFalse(p.standIn);
        assertFalse(p.charged);

        (address[] memory sources, bytes32[] memory positions, bytes32[] memory ids) = cards.legsOf(P1);
        assertEq(sources.length, 3);
        assertEq(sources[0], address(cash));
        assertEq(sources[1], address(savings));
        assertEq(sources[2], address(line));
        assertEq(positions[0], _position(address(usd), 0));
        assertEq(positions[1], bytes32(0));
        assertEq(positions[2], bytes32(0));
        for (uint256 i; i < 3; ++i) {
            assertEq(ids[i], cards.legId(P1, i));
            assertEq(ids[i], keccak256(abi.encodePacked(P1, uint8(i))));
        }

        _capture(P1, 60e6, false);
        p = cards.purchaseOf(P1);
        assertEq(p.held, 40e6);
        assertEq(p.captured, 60e6);
        assertTrue(p.open);
        _capture(P1, 0, true);
        p = cards.purchaseOf(P1);
        assertEq(p.held, 0);
        assertEq(p.captured, 60e6);
        assertFalse(p.open);
        // The legs stay readable after the purchase ends.
        (sources,,) = cards.legsOf(P1);
        assertEq(sources.length, 3);
    }

    /// @dev Measured with vm.record over CardAuth's own storage (linked library calls run in its context): a second
    ///      authorize writes _purchases[ref], usageOf[owner] (one slot), the card's window (one slot), _state (held)
    ///      and _ledger (seq), and _purchases[ref] is the only slot that goes from zero to non-zero. Capture
    ///      rewrites the same slots and no new one.
    function test_storage_oneSlotPerPurchase() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 10e6);

        bytes32 purchase = keccak256(abi.encode(P2, PURCHASES_SLOT));
        bytes32 cardBase = keccak256(abi.encode(CARD, CARDS_SLOT));
        bytes32[5] memory expected = [
            purchase,
            keccak256(abi.encode(alice, USAGE_SLOT)),
            bytes32(uint256(cardBase) + 3),
            bytes32(STATE_SLOT),
            bytes32(LEDGER_SLOT)
        ];
        // The card has no lifetime cap, so the slot after its window stays empty.
        assertEq(vm.load(address(cards), bytes32(uint256(cardBase) + 4)), 0);
        for (uint256 i = 1; i < 5; ++i) {
            assertTrue(vm.load(address(cards), expected[i]) != 0, "already non-zero");
        }
        assertEq(vm.load(address(cards), purchase), 0);

        vm.record();
        _authorize(P2, 20e6);
        (, bytes32[] memory writes) = vm.accesses(address(cards));
        assertEq(_outside(writes, expected), 0, "authorize writes only the expected slots");
        assertEq(_distinct(writes), 5, "authorize writes five distinct slots");
        uint256 word = uint256(vm.load(address(cards), purchase));
        // The slot packs the card number and the amount.
        assertEq(uint32(word), cards.cardOf(CARD).index);
        assertEq(uint48(word >> 32), 20e6);

        vm.record();
        _capture(P2, 20e6, true);
        (, writes) = vm.accesses(address(cards));
        assertEq(_outside(writes, expected), 0, "capture writes only the expected slots");
        // The legs live with the sources: nothing next to the purchase word.
        assertEq(vm.load(address(cards), bytes32(uint256(purchase) + 1)), 0);
    }

    // Helpers.

    /// @dev External so a test can expect the revert of a funding order alice sets.
    function setFundingAs(bool withCash, bool withSavings, bool withLine) external {
        vm.prank(alice);
        _setFunding(withCash, withSavings, withLine);
    }

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

    /// @dev Gives alice a credit line of limit on the stub source and orders cash, savings, then the line.
    function _withLine(uint256 limit) internal {
        line.setLimit(alice, limit);
        vm.prank(alice);
        _setFunding(true, true, true);
    }

    /// @dev Moves the card's expiry a year past now.
    function _extendCard() internal {
        vm.prank(issuer);
        cards.setCard(CARD, 1, block.timestamp + 365 days);
    }

    function _fundRefund(uint256 amount) internal {
        usd.mint(issuer, amount);
        vm.prank(issuer);
        usd.approve(address(cards), amount);
    }

    function _refund(bytes32 ref, uint128 amount) internal {
        _fundRefund(amount);
        vm.prank(issuer);
        cards.refund(ref, amount);
    }

    /// @dev Issuance starts a card's window and the grant starts the owner's usage, so a purchase, even a new card's
    ///      first, creates one slot in CardAuth: the purchase word.
    function test_storage_firstPurchaseOfCardCreatesOnlyThePurchase() public {
        bytes32 second = keccak256("second card");
        vm.prank(issuer);
        cards.issueCard(second, alice, uint40(block.timestamp + 365 days), _limits(500e6, 1000e6, 5000e6), 7);
        bytes32 window = bytes32(uint256(keccak256(abi.encode(second, CARDS_SLOT))) + 3);
        assertTrue(vm.load(address(cards), window) != 0, "issuance starts the window");
        assertEq(vm.load(address(cards), bytes32(uint256(window) + 1)), 0, "no cap, so no second window slot");
        assertTrue(vm.load(address(cards), keccak256(abi.encode(alice, USAGE_SLOT))) != 0, "the grant starts usage");
        usd.mint(alice, 1000e6);
        _authorize(P1, 10e6);

        vm.startStateDiffRecording();
        vm.prank(issuer);
        cards.authorize(second, P2, 20e6, merchant, uint64(block.timestamp + 7 days), 0);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        bytes32 purchase = keccak256(abi.encode(P2, PURCHASES_SLOT));
        uint256 created;
        for (uint256 i; i < accesses.length; ++i) {
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory a = accesses[i].storageAccesses[j];
                if (a.account != address(cards) || !a.isWrite || a.reverted) continue;
                if (a.previousValue != 0 || a.newValue == 0) continue;
                assertEq(a.slot, purchase, "only the purchase word is new");
                ++created;
            }
        }
        assertEq(created, 1);
        assertEq(cards.cardOf(second).window.daySpent, 20e6);
    }

    function _distinct(bytes32[] memory slots) internal pure returns (uint256 n) {
        for (uint256 i; i < slots.length; ++i) {
            bool seen;
            for (uint256 j; j < i && !seen; ++j) {
                seen = slots[j] == slots[i];
            }
            if (!seen) ++n;
        }
    }

    function _outside(bytes32[] memory slots, bytes32[5] memory allowed) internal pure returns (uint256 n) {
        for (uint256 i; i < slots.length; ++i) {
            bool ok;
            for (uint256 j; j < 5 && !ok; ++j) {
                ok = slots[i] == allowed[j];
            }
            if (!ok) ++n;
        }
    }
}
