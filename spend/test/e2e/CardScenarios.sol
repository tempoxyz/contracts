// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { console } from "forge-std/console.sol";
import { IAllowanceTransfer } from "permit2/interfaces/IAllowanceTransfer.sol";
import { Simple4626Vault } from "tempo-earn/demo/Simple4626Vault.sol";

import { CardProgram } from "../harness/CardProgram.sol";
import { Decline, Funding, PullOutcome, RailCaps } from "../harness/SpendRail.sol";

/// @notice Every card product scenario Stripe and Bridge must handle, written once against the
///         rail hooks so it runs unchanged on every contract setup.
/// @dev Where a setup lacks a capability, the scenario pins what the setup actually does (marked
///      "Gap") instead of failing, so the suite stays green while documenting the difference.
abstract contract CardScenarios is CardProgram {
    uint256 internal constant START = 1000e6;

    address internal alice = makeAddr("alice");

    uint256 private _settlementBefore;
    uint256 private _programBefore;
    uint256 private _reserveBefore;

    function setUp() public virtual {
        _deployTempo();
        _railSetUp();
        _railEnroll(alice, START);
        _settlementBefore = usd.balanceOf(settlement);
        _programBefore = usd.balanceOf(programWallet);
        _reserveBefore = usd.balanceOf(reserveWallet);
    }

    // ==================================================================
    // Purchases
    // ==================================================================

    function test_purchase_captureSettlesExactAmount() public {
        uint256 v0 = _railValue(alice);
        (uint256 id, bool ok) = _authorize(alice, 42.5e6, MCC_GROCERY);
        assertTrue(ok, "approved");
        _capture(id, 42.5e6, true);

        _assertSpent(v0, 42.5e6);
        _assertSettled(42.5e6);
        _assertLedger();
    }

    function test_purchase_reversalReturnsHold() public {
        uint256 v0 = _railValue(alice);
        (uint256 id, bool ok) = _authorize(alice, 100e6, MCC_GROCERY);
        assertTrue(ok, "approved");
        _assertSpent(v0, 100e6);
        _reverse(id);

        _assertSpent(v0, 0);
        assertEq(auths[id].returned, 100e6, "hold returned");
        _assertLedger();
    }

    function test_purchase_expiryReleasesHold() public {
        uint256 v0 = _railValue(alice);
        (uint256 id,) = _authorize(alice, 30e6, MCC_GROCERY);
        vm.expectRevert("authorization not expired");
        this.expireExternal(id);

        vm.warp(block.timestamp + 7 days);
        _expire(id);
        _assertSpent(v0, 0);
        _assertLedger();
    }

    function test_purchase_partialCaptureReturnsRemainder() public {
        uint256 v0 = _railValue(alice);
        (uint256 id,) = _authorize(alice, 100e6, MCC_GROCERY);
        _capture(id, 60e6, true);

        _assertSpent(v0, 60e6);
        assertEq(auths[id].returned, 40e6, "remainder returned");
        _assertLedger();
    }

    function test_purchase_multipleCaptures() public {
        uint256 v0 = _railValue(alice);
        (uint256 id,) = _authorize(alice, 100e6, MCC_GROCERY);
        _capture(id, 30e6, false);
        _capture(id, 50e6, true);

        _assertSpent(v0, 80e6);
        _assertSettled(100e6);
        _assertLedger();
    }

    function test_restaurant_tipWithinHold() public {
        uint256 v0 = _railValue(alice);
        (uint256 id, bool ok) = _authorize(alice, 50e6, MCC_RESTAURANT);
        assertTrue(ok, "approved");
        assertEq(auths[id].held, 60e6, "20% tip buffer");
        _capture(id, 58e6, true);

        _assertSpent(v0, 58e6);
        assertEq(auths[id].returned, 2e6, "unused buffer returned");
        _assertLedger();
    }

    function test_restaurant_tipBeyondHoldPullsDifference() public {
        uint256 v0 = _railValue(alice);
        (uint256 id,) = _authorize(alice, 50e6, MCC_RESTAURANT);
        _capture(id, 65e6, true);

        _assertSpent(v0, 65e6);
        _assertSettled(65e6);
        assertEq(reserveDrawn, 0, "no reserve needed");
        _assertLedger();
    }

    function test_overcapture_withoutFunds_reserveCovers() public {
        uint256 v0 = _railValue(alice);
        (uint256 id,) = _authorize(alice, 800e6, MCC_GROCERY);
        _capture(id, 1100e6, true);

        _assertSpent(v0, 800e6);
        assertEq(reserveDrawn, 300e6, "reserve covered the shortfall");
        assertEq(cardholderDebt[alice], 300e6, "cardholder owes the shortfall");
        assertEq(usd.balanceOf(settlement) - _settlementBefore, 1100e6, "network paid in full");
        _assertLedger();
    }

    function test_hotel_incrementalAuthorization() public {
        uint256 v0 = _railValue(alice);
        (uint256 id,) = _authorize(alice, 200e6, MCC_HOTEL);
        assertEq(auths[id].expiresAt, block.timestamp + 31 days, "lodging stays open 31 days");
        assertTrue(_incrementAuthorization(id, 150e6), "increment approved");
        _capture(id, 320e6, true);

        _assertSpent(v0, 320e6);
        _assertLedger();
    }

    function test_fuelPump_preauthorizationThenActual() public {
        uint256 v0 = _railValue(alice);
        (uint256 id,) = _authorize(alice, 1e6, MCC_FUEL_PUMP);
        assertEq(auths[id].held, 100e6, "pump preauthorization hold");
        _capture(id, 47.23e6, true);

        _assertSpent(v0, 47.23e6);
        _assertLedger();
    }

    function test_crossBorder_feePulledWithPrincipal() public {
        uint256 v0 = _railValue(alice);
        (uint256 id,) = _authorizeWithFee(alice, 110e6, MCC_GROCERY, 150);
        assertEq(auths[id].held, 111.65e6, "principal plus 1.5% fee");
        _capture(id, 110e6, true);

        _assertSpent(v0, 111.65e6);
        _assertLedger();
    }

    function test_atm_withdrawalWithFee() public {
        uint256 v0 = _railValue(alice);
        (, bool ok) = _atmWithdrawal(alice, 200e6, 3e6);
        assertTrue(ok, "approved");

        _assertSpent(v0, 203e6);
        _assertLedger();
    }

    function test_forceCapture_withoutAuthorization() public {
        uint256 v0 = _railValue(alice);
        _forceCapture(alice, 33e6, MCC_GROCERY);

        _assertSpent(v0, 33e6);
        assertEq(reserveDrawn, 0, "funded by the cardholder");
        _assertLedger();
    }

    function test_forceCapture_withoutFunds_reserveCovers() public {
        _railDrain(alice);
        _forceCapture(alice, 33e6, MCC_GROCERY);

        assertEq(reserveDrawn, 33e6, "reserve paid the network");
        assertEq(cardholderDebt[alice], 33e6, "cardholder owes it");
        _assertLedger();
    }

    // ==================================================================
    // Refunds and disputes
    // ==================================================================

    function test_refund_full() public {
        uint256 v0 = _railValue(alice);
        uint256 id = _purchase(75e6);
        _refundCapture(id, 75e6);

        _assertSpent(v0, 0);
        _assertLedger();
    }

    function test_refund_partial() public {
        uint256 v0 = _railValue(alice);
        uint256 id = _purchase(75e6);
        _refundCapture(id, 25e6);

        _assertSpent(v0, 50e6);
        _assertLedger();
    }

    function test_refund_afterFundsMovedAway() public {
        uint256 id = _purchase(100e6);
        _railDrain(alice);
        _refundCapture(id, 40e6);

        assertApproxEqAbs(_railValue(alice), 40e6, _tolerance(), "refund lands in funding source");
        _assertLedger();
    }

    function test_refund_landsInFundingSource() public {
        _requireEarn();
        uint256 id = _purchase(100e6);
        uint256 sharesBefore = _railShares(alice);
        _refundCapture(id, 100e6);

        if (_railCaps().refundsEarn) {
            assertGt(_railShares(alice), sharesBefore, "refund re-entered Earn");
        } else {
            // Gap: the refund arrives as idle stablecoin, outside Earn.
            _gap("the refund arrives as idle stablecoin, outside Earn");
            assertEq(_railShares(alice), sharesBefore, "refund did not re-enter Earn");
        }
        _assertLedger();
    }

    function test_dispute_wonCreditsCardholder() public {
        uint256 v0 = _railValue(alice);
        uint256 id = _purchase(120e6);
        _resolveDispute(id, 120e6, true);

        _assertSpent(v0, 0);
        _assertLedger();
    }

    function test_dispute_lostKeepsCharge() public {
        uint256 v0 = _railValue(alice);
        uint256 id = _purchase(120e6);
        _resolveDispute(id, 120e6, false);

        _assertSpent(v0, 120e6);
        _assertLedger();
    }

    // ==================================================================
    // Declines and controls
    // ==================================================================

    function test_decline_insufficientFunds() public {
        uint256 v0 = _railValue(alice);
        (uint256 id, bool ok) = _authorize(alice, 1500e6, MCC_GROCERY);

        assertFalse(ok, "declined");
        _assertDeclinedFor(Decline.InsufficientFunds);
        assertEq(uint8(auths[id].status), uint8(AuthStatus.Declined));
        _assertSpent(v0, 0);
        _assertSettled(0);
    }

    function test_decline_afterCardholderRevokes() public {
        uint256 v0 = _railValue(alice);
        _railRevoke(alice);
        (, bool ok) = _authorize(alice, 10e6, MCC_GROCERY);

        assertFalse(ok, "declined");
        _assertDeclinedFor(Decline.Revoked);
        _assertSpent(v0, 0);
    }

    function test_decline_whenProgramPaused() public {
        uint256 v0 = _railValue(alice);
        vm.prank(bridgePauser);
        bridgeFactory.pause();
        (, bool ok) = _authorize(alice, 10e6, MCC_GROCERY);

        if (_railCaps().privateBalances) {
            // The Zone accepts the request before Tempo sees the pause; the callback reverts,
            // the input bounces back, and the reserve settles the approved authorization.
            assertTrue(ok, "approved at request time");
            assertEq(reserveDrawn, 10e6, "reserve covers the bounced pull");
        } else {
            assertFalse(ok, "declined");
        }
        _assertDeclinedFor(Decline.Paused);
        _assertSpent(v0, 0);
    }

    function test_spendLimit_capsSpend() public {
        _railSetSpendLimit(alice, 100e6);
        (, bool first) = _authorize(alice, 60e6, MCC_GROCERY);
        (, bool second) = _authorize(alice, 60e6, MCC_GROCERY);

        assertTrue(first, "within limit");
        assertFalse(second, "over limit");
        _assertDeclinedFor(Decline.SpendLimit);
    }

    function test_spendLimit_resetsEachPeriod() public {
        _railSetSpendLimit(alice, 100e6);
        (, bool first) = _authorize(alice, 80e6, MCC_GROCERY);
        assertTrue(first, "within limit");

        vm.warp(block.timestamp + LIMIT_PERIOD);
        (, bool nextPeriod) = _authorize(alice, 80e6, MCC_GROCERY);
        if (_railCaps().periodicSpendLimit) {
            assertTrue(nextPeriod, "limit refreshed");
        } else {
            // Gap: an allowance is a lifetime cap, so the cardholder must re-approve.
            _gap("an allowance is a lifetime cap, so the cardholder must re-approve");
            assertFalse(nextPeriod, "allowance never refreshes");
        }
    }

    function test_standingAllowance_betweenPulls() public {
        _purchase(10e6);
        if (_railCaps().noStandingAllowance) {
            assertEq(usd.allowance(alice, address(spender)), 0, "nothing approved to Bridge");
            assertEq(earnShare.allowance(alice, address(spender)), 0, "no share approval");
        } else {
            // Gap: the card program can pull up to the remaining allowance at any time.
            _gap("the card program can pull up to the remaining allowance at any time");
            (uint160 viaPermit2,,) =
                IAllowanceTransfer(permit2).allowance(alice, address(usd), address(spender));
            uint256 standing = usd.allowance(alice, address(spender))
                + earnShare.allowance(alice, address(spender))
                + venue.allowance(alice, address(spender)) + viaPermit2;
            assertGt(standing, 0, "allowance remains standing");
        }
    }

    // ==================================================================
    // Concurrency and failure handling
    // ==================================================================

    function test_concurrentAuthorizations_noOverspend() public {
        uint256 v0 = _railValue(alice);
        (, bool first) = _authorize(alice, 700e6, MCC_GROCERY);
        (, bool second) = _authorize(alice, 400e6, MCC_GROCERY);

        assertTrue(first, "first approved");
        assertFalse(second, "second declined");
        _assertDeclinedFor(Decline.InsufficientFunds);
        _assertSpent(v0, 700e6);
    }

    function test_fundsMovedAfterApproval_reserveCovers() public {
        frontRunNextPull[alice] = true;
        (uint256 id, bool ok) = _authorize(alice, 100e6, MCC_GROCERY);
        assertTrue(ok, "approved on preflight");
        _capture(id, 100e6, true);

        assertEq(reserveDrawn, 100e6, "reserve settled the purchase");
        assertEq(cardholderDebt[alice], 100e6, "cardholder carries a negative balance");
        _assertLedger();
    }

    function test_retrySameAction_neverDoubleCharges() public {
        uint256 v0 = _railValue(alice);
        retryNextPull = true;
        (uint256 id,) = _authorize(alice, 50e6, MCC_GROCERY);
        _capture(id, 50e6, true);

        if (_railCaps().idempotentActions) {
            assertEq(lastRetrySettled, 0, "retry rejected on chain");
            _assertSpent(v0, 50e6);
        } else {
            // Gap: idempotency is offchain only, so a retried submission pulls again.
            _gap("idempotency is offchain only, so a retried submission pulls again");
            assertEq(lastRetrySettled, 50e6, "retry pulled a second time");
            _assertSpent(v0, 100e6);
        }
    }

    // ==================================================================
    // Earn
    // ==================================================================

    function test_earn_yieldAccruesUntilSpent() public {
        _requireEarn();
        uint256 sharesForSpend = _previewShares(100e6);
        _accrueYield(100); // 1%
        uint256 v1 = _railValue(alice);
        uint256 s1 = _railShares(alice);
        _purchase(100e6);

        _assertSpent(v1, 100e6);
        assertLt(s1 - _railShares(alice), sharesForSpend, "yield lowered the share cost");
    }

    function test_earn_priceDropAfterQuote_boundsShareCost() public {
        _requireEarn();
        uint256 quoted = _previewShares(100e6);
        uint256 s0 = _railShares(alice);

        if (!_railCaps().boundedShareCost) {
            // Gap: the pull prices shares at execution with no cap.
            _gap("the pull prices shares at execution with no cap");
            _venueLoss(200);
            (, bool approved) = _authorize(alice, 100e6, MCC_GROCERY);
            assertTrue(approved, "approved");
            assertGt(s0 - _railShares(alice), quoted * 10_100 / 10_000, "burned beyond quote");
            return;
        }
        lossAfterQuoteBps = 200;
        (, bool ok) = _authorize(alice, 100e6, MCC_GROCERY);
        if (_railCaps().privateBalances) {
            assertTrue(ok, "approved at request time");
            assertEq(reserveDrawn, 100e6, "bounced pull covered by reserve");
        } else {
            assertFalse(ok, "declined");
        }
        _assertDeclinedFor(Decline.ShareCost);
        assertEq(_railShares(alice), s0, "no shares burned beyond the quote");
    }

    function test_earn_illiquidVenue() public {
        _requireEarn();
        uint256 v0 = _railValue(alice);
        vm.mockCallRevert(
            address(venue),
            abi.encodeWithSelector(Simple4626Vault.withdraw.selector),
            abi.encodeWithSignature("Error(string)", "illiquid")
        );
        (, bool ok) = _authorize(alice, 100e6, MCC_GROCERY);

        if (_railCaps().privateBalances) {
            assertTrue(ok, "approved at request time");
            assertEq(reserveDrawn, 100e6, "bounced pull covered by reserve");
        } else {
            assertFalse(ok, "declined");
        }
        _assertDeclinedFor(Decline.Illiquid);
        _assertSpent(v0, 0);
    }

    function test_split_stablecoinFirstThenEarn() public {
        _requireEarn();
        if (!_railCaps().splitFunding) {
            vm.skip(true, "rail cannot combine balances in one pull");
        }
        _giveStablecoin(alice, 30e6);
        uint256 v0 = _railValue(alice);
        PullOutcome outcome = _railPullSplit(alice, 50e6, 30e6, keccak256("split"));

        assertEq(uint8(outcome), uint8(PullOutcome.Settled), "settled");
        assertEq(usd.balanceOf(alice), 0, "stablecoin spent first");
        _assertSpent(v0, 50e6);
        assertEq(usd.balanceOf(settlement) - _settlementBefore, 50e6, "one settlement");
    }

    // ==================================================================
    // Privacy
    // ==================================================================

    function test_private_cardholderNeverAppearsOnTempo() public {
        if (!_railCaps().privateBalances) vm.skip(true, "public rail");
        (uint256 id,) = _authorize(alice, 60e6, MCC_RESTAURANT);
        // Control: the scan does find addresses that are on Tempo.
        assertTrue(_containsAddress(lastSettlementLogBlob, settlement), "scan sees destination");
        assertFalse(_containsAddress(lastSettlementLogBlob, alice), "pull logs");
        _capture(id, 55e6, true);
        assertFalse(_containsAddress(lastSettlementLogBlob, alice), "return logs");
        _refundCapture(id, 20e6);
        assertFalse(_containsAddress(lastSettlementLogBlob, alice), "refund logs");
    }

    /// @notice A leaked Bridge Zone key must not move the cardholder's private balance outside
    ///         the card program: neither to an unknown address nor to another account the Zone
    ///         admitted.
    function test_private_leakedZoneKeyStaysInProgram() public {
        if (!_railCaps().privateBalances) vm.skip(true, "public rail");
        address outsider = makeAddr("outsider");
        if (!zoneClosedLoop) {
            // Accepted risk (decision 7): a key scoped to the outbox can name any withdrawal recipient.
            assertTrue(_railZoneKeyWithdrawTo(alice, outsider, 1e6), "open Zone accepts it");
            assertEq(_received(outsider), 1e6, "outsider paid");
            _gap("accepted risk: a leaked Zone key can withdraw to any Tempo address");
            return;
        }
        assertFalse(_railZoneKeyWithdrawTo(alice, outsider, 1e6), "closed loop refuses outsider");
        assertEq(_received(outsider), 0, "outsider not paid");

        // Accepted risk (decision 7): a closed-loop Zone still pays any account it admitted.
        address admitted = makeAddr("other.admitted-account");
        _zoneAllowAccount(admitted);
        assertTrue(_railZoneKeyWithdrawTo(alice, admitted, 1e6), "closed loop accepts admitted");
        assertEq(_received(admitted), 1e6, "admitted account paid");
        _gap("accepted risk: a leaked Zone key can withdraw to any admitted account");
    }

    /// @dev Stablecoin plus EarnShare `account` holds on Tempo.
    function _received(address account) private view returns (uint256) {
        return usd.balanceOf(account) + earnShare.balanceOf(account);
    }

    // ==================================================================
    // External entrypoints and helpers
    // ==================================================================

    function expireExternal(uint256 id) external {
        _expire(id);
    }

    function _purchase(uint256 amount) internal returns (uint256 id) {
        bool ok;
        (id, ok) = _authorize(alice, amount, MCC_GROCERY);
        assertTrue(ok, "purchase approved");
        _capture(id, amount, true);
    }

    /// @dev The last pull failed for `reason`, where the rail pins the error it fails with.
    function _assertDeclinedFor(Decline reason) internal view {
        bytes4 expected = _railDeclineError(reason);
        if (expected == bytes4(0)) return;
        assertEq(bytes4(lastPullError), expected, "decline reason");
    }

    function _requireEarn() internal {
        if (_funding() != Funding.Earn) vm.skip(true, "stablecoin-funded rail");
    }

    function _tolerance() internal view returns (uint256) {
        return _funding() == Funding.Earn ? 50 : 0;
    }

    /// @dev The cardholder's value fell by exactly `spent` (Earn rounding aside).
    function _assertSpent(uint256 before, uint256 spent) internal view {
        assertApproxEqAbs(before - _railValue(alice), spent, _tolerance(), "cardholder charged");
    }

    function _assertSettled(uint256 amount) internal view {
        assertEq(usd.balanceOf(settlement) - _settlementBefore, amount, "settlement received");
    }

    /// @dev Money conservation across the program: settlement received every settled pull plus
    ///      reserve draws; Bridge liquidity paid every credit; each closed authorization pulled
    ///      exactly what it captured, minus what it returned.
    function _assertLedger() internal view {
        assertEq(
            usd.balanceOf(settlement) - _settlementBefore,
            settledPulls + reserveDrawn,
            "settlement = pulls + reserve"
        );
        assertEq(
            _programBefore - usd.balanceOf(programWallet),
            creditedToCardholders,
            "program liquidity = credits"
        );
        assertEq(_reserveBefore - usd.balanceOf(reserveWallet), reserveDrawn, "reserve draws");
        for (uint256 id = 1; id <= authCount; ++id) {
            Authorization storage a = auths[id];
            if (a.status != AuthStatus.Closed) continue;
            // Unused hold the reserve covered offsets the cardholder's debt instead of returning.
            if (a.reserveCovered == 0) {
                assertEq(a.held - a.returned, a.captured + a.fees, "hold reconciles to capture");
            } else {
                assertGe(a.held - a.returned, a.captured + a.fees, "hold covers capture");
            }
        }
    }

    /// @dev Records that the rail falls short of the product behavior here. `script/matrix.py`
    ///      collects these into the capability matrix.
    function _gap(string memory reason) internal pure {
        console.log(string.concat("GAP: ", reason));
    }

    function _containsAddress(bytes memory blob, address account) internal pure returns (bool) {
        bytes20 needle = bytes20(account);
        if (blob.length < 20) return false;
        for (uint256 i; i <= blob.length - 20; ++i) {
            bytes20 window;
            assembly {
                window := mload(add(add(blob, 0x20), i))
            }
            if (window == needle) return true;
        }
        return false;
    }
}
