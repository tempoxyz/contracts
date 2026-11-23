// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IssuerTreasury } from "../../../../src/spend/programs/IssuerTreasury.sol";
import { FundingBase } from "./FundingBase.sol";

/// @notice Weekend funding outage: the issuer stops refilling its treasury funds from Friday 18:00 until funding lands
///         again, the network settles on business days only, and cardholders keep swiping on a daily curve. The
///         unacknowledged net piles up behind the sponsor collateral until the exposure guard declines, and drains once
///         the issuer pays the network and the sponsor acknowledges. Every step checks conservation, custody, each
///         holder's bound and that an approval never leaves exposure above collateral.
contract FundingWeekendStressTest is FundingBase {
    address internal network = makeAddr("network");
    address internal bank = makeAddr("issuer.bank");

    struct Buy {
        bytes32 ref;
        uint32 holder;
        uint32 dueHour;
        uint8 fate;
        uint128 amount;
    }

    struct Stats {
        uint256 auths;
        uint256 approved;
        uint256 declinedGuard;
        uint256 declinedOther;
        uint256 outageAuths;
        uint256 outageGuard;
        uint256 firstTrip;
        uint256 lastTrip;
        uint256 tripHours;
        uint256 maxExposure;
        uint256 maxExposureBps;
        uint256 maxUnsettled;
        uint256 maxIssuerDebt;
        uint256 advanced;
        uint256 standIns;
        uint256 standInsRefused;
        uint256 standInsAbsorbed;
        uint256 shortfalls;
        uint256 maxShortfall;
        uint256 seized;
        uint256 settlements;
        uint256 captureFailures;
        uint256 authGas;
        uint256 authGasMax;
        uint256 captures;
        uint256 captureGas;
        uint256 captureGasMax;
        uint256 authSampled;
        uint256 captureSampled;
        uint256 volume;
        uint256 resumeHour;
        uint256 refilled;
        uint256 swept;
    }

    Buy[] internal buys;
    uint256[] internal pending;
    Stats internal s;

    uint256 internal n;
    uint256 internal fundsTarget;
    uint256 internal outageStart;
    uint256 internal fundingAt;
    uint256 internal holiday;
    bool internal sponsorCovers;
    /// @dev The network settles the net through its 00:00 cut-off, and the sponsor acknowledges through that cut-off.
    bool internal cutoffMode;
    uint64 internal cutoffSeq;
    int128 internal cutoffNet;
    int128 internal paidNet;
    uint256 internal cutoffAcks;
    uint256 internal cutoffCleared;
    uint256 internal partialAcks;
    uint256 internal partialCleared;
    uint256 internal paidStillCountedMax;
    uint256 internal unpaidAcknowledgedMax;
    uint256 internal lastTripHour;

    /// @dev Collateral in tenths of a day of expected volume (about 1.55 swipes a day per holder at $79.5 average).
    function _setUp(uint256 collateralTenths) internal {
        _setUp(collateralTenths, 30e6);
    }

    /// @dev "buffer" per holder is what the issuer keeps both as treasury funds and in the settlement account.
    function _setUp(uint256 collateralTenths, uint256 buffer) internal {
        vm.pauseGasMetering();
        n = 60 * _scale();
        rng = 0x5eed;
        tolBps = 2000;
        _world(uint128(n * 1232e5 * collateralTenths / 10));
        fundsTarget = n * buffer;
        parties.push(network);
        parties.push(bank);
        vm.prank(issuer);
        usd.approve(address(treasury), type(uint256).max);
        for (uint256 i; i < n; ++i) {
            uint256 balance = _rand(4) == 0 ? 20e6 + _rand(180e6) : 300e6 + _rand(2700e6);
            address h = _holder(i, balance, _cashOnly());
            _setTolerance(h, address(cash), address(usd), uint16(tolBps));
        }
        _mint(bank, n * 10_000e6);
        _topUp();
        _seal();
        outageStart = START + 4 days + 18 hours;
    }

    /// @dev Collateral for four days of volume rides out a regular weekend without a decline.
    function test_stress_weekendOutage_regularAmpleCollateral() public {
        _setUp(40);
        tag = "weekend_regular_ample";
        _run(10, type(uint256).max, START + 7 days + 9 hours, false);
    }

    /// @dev Collateral for three days of volume; funding lands Monday 09:00 and the network settles Monday 10:00.
    function test_stress_weekendOutage_regular() public {
        _setUp(30);
        tag = "weekend_regular";
        _run(10, type(uint256).max, START + 7 days + 9 hours, false);
    }

    /// @dev Monday is a holiday: no settlement until Tuesday 10:00, funding lands Tuesday 09:00.
    function test_stress_weekendOutage_holidayMonday() public {
        _setUp(30);
        tag = "weekend_holiday";
        _run(10, 7, START + 8 days + 9 hours, false);
    }

    /// @dev Holiday weekend, a thin buffer ($8 per holder) and funding lands only Wednesday 09:00: Tuesday's settlement
    ///      falls short and the sponsor seizes collateral to pay the network the rest.
    function test_stress_weekendOutage_lateFundingSponsorPays() public {
        _setUp(30, 8e6);
        tag = "weekend_late_funding";
        _run(10, 7, START + 9 days + 9 hours, true);
    }

    /// @dev The sponsor checkpoints the program at each 00:00 cut-off; the network pays what was captured through it
    ///      at 10:00 and the sponsor acknowledges through that cut-off while captures continue past it. Each
    ///      acknowledgement clears exactly the net through the cut-off and leaves the later net open, so the guard
    ///      counts nothing the network was paid for, and nothing it was not paid for is cleared.
    function test_stress_weekendOutage_cutoffAcknowledgement() public {
        _setUp(40);
        tag = "weekend_cutoff_ack";
        cutoffMode = true;
        _run(10, type(uint256).max, START + 7 days + 9 hours, false);
        assertGt(partialAcks, 0, "no partial acknowledgement");
        assertGt(partialCleared, 0, "partial acknowledgements cleared nothing");
        assertEq(paidStillCountedMax, 0, "the guard counted net the network was paid for");
    }

    // Simulation.

    function _run(uint256 days_, uint256 holidayDay, uint256 fundingAt_, bool sponsorCovers_) internal {
        vm.pauseGasMetering();
        (holiday, fundingAt, sponsorCovers) = (holidayDay, fundingAt_, sponsorCovers_);
        for (uint256 hr; hr < days_ * 24; ++hr) {
            _hour(hr);
        }
        _drain(days_ * 24);
        _report();
    }

    function _hour(uint256 hr) internal {
        uint256 t = START + hr * HOUR;
        vm.warp(t);
        uint256 hour = hr % 24;
        uint256 wd = _weekday(t);
        bool weekend = wd == 0 || wd == 6;
        bool business = !weekend && hr / 24 != holiday;
        bool outage = t >= outageStart && t < fundingAt;
        if (hour == 0) {
            if (cutoffMode) {
                // The network's cut-off: the sponsor records the net through it for the acknowledgement at 10:00.
                vm.prank(sponsor);
                cutoffSeq = treasury.checkpointSettlement();
                int128 recorded;
                (, recorded) = cards.settlementCheckpoint(0);
                (,, cutoffNet,) = cards.ledger();
                if (cutoffSeq > _settledThrough()) assertEq(recorded, cutoffNet, "checkpoint records the live net");
            } else {
                (cutoffSeq,, cutoffNet,) = cards.ledger();
            }
        }
        if (hour == 6 && wd == 5) _paydays();
        if (hour == 9 && business && !outage) {
            _topUp();
            _refill();
        }
        if (hour == 17 && business) _sweep();
        if (hour == 10 && business) _settleNetwork();
        _captureDue(hr);
        uint256 rate = _curve(hour, weekend) * n;
        uint256 count = rate / 100 + (_rand(100) < rate % 100 ? 1 : 0);
        uint256 guardBefore = s.declinedGuard;
        for (uint256 k; k < count; ++k) {
            vm.warp(t + (k + 1) * HOUR / (count + 1));
            _swipe(hr, outage);
        }
        if (s.declinedGuard > guardBefore) {
            ++s.tripHours;
            lastTripHour = hr;
        }
        _observe();
    }

    function _swipe(uint256 hr, bool outage) internal {
        uint256 i = _rand(n);
        address h = holders[i];
        uint128 amount = _ticket();
        bytes32 ref = keccak256(abi.encode("buy", buys.length));
        // 2% the network approves without asking (a stand-in): the issuer books it with bookStandIn when it clears.
        if (_rand(100) < 2) {
            (, uint256 clears) = _fate();
            buys.push(Buy(ref, uint32(i), uint32(hr + clears), 5, amount));
            pending.push(buys.length - 1);
            ++s.standIns;
            return;
        }
        (uint256 approved, bytes4 err, uint256 gasUsed) = _try(h, cardIds[i], ref, amount, 0);
        ++s.auths;
        if (outage) ++s.outageAuths;
        if (approved == 0) {
            if (err == IssuerTreasury.ExposureAboveCollateral.selector) {
                ++s.declinedGuard;
                if (outage) ++s.outageGuard;
                if (s.firstTrip == 0) s.firstTrip = block.timestamp;
                s.lastTrip = block.timestamp;
            } else {
                ++s.declinedOther;
            }
            return;
        }
        ++s.approved;
        if (gasUsed != 0) {
            ++s.authSampled;
            s.authGas += gasUsed;
            if (gasUsed > s.authGasMax) s.authGasMax = gasUsed;
        }
        // An approval never takes exposure past the collateral.
        assertLe(treasury.exposure(), treasury.valueOf(), "approval past collateral");
        (uint8 fate, uint256 delay) = _fate();
        buys.push(Buy(ref, uint32(i), uint32(hr + delay), fate, uint128(approved)));
        pending.push(buys.length - 1);
        _checkLedger();
        _checkHolder(h);
    }

    /// @dev 78% capture as authorized, 10% add a tip of up to 20%, 4% capture less, 6% are released and 2% are left
    ///      to expire. Most capture within hours, a quarter within two days, a few after three to five days.
    function _fate() internal returns (uint8 fate, uint256 delay) {
        uint256 r = _rand(100);
        fate = r < 78 ? 0 : r < 88 ? 1 : r < 92 ? 2 : r < 98 ? 3 : 4;
        r = _rand(100);
        delay = r < 70 ? 1 + _rand(6) : r < 95 ? 12 + _rand(36) : 72 + _rand(48);
    }

    /// @dev 60% $5-40, 30% $40-150, 10% $150-600.
    function _ticket() internal returns (uint128) {
        uint256 r = _rand(100);
        if (r < 60) return uint128(5e6 + _rand(35e6));
        if (r < 90) return uint128(40e6 + _rand(110e6));
        return uint128(150e6 + _rand(450e6));
    }

    function _captureDue(uint256 hr) internal {
        for (uint256 j; j < pending.length;) {
            Buy memory b = buys[pending[j]];
            if (b.dueHour > hr || b.fate == 4) {
                ++j;
                continue;
            }
            _resolve(b);
            pending[j] = pending[pending.length - 1];
            pending.pop();
        }
    }

    function _resolve(Buy memory b) internal {
        address h = holders[b.holder];
        if (b.fate == 5) {
            (bool posted, uint256 paid) = _bookStandIn(h, cardIds[b.holder], b.ref, b.amount);
            if (!posted) {
                ++s.standInsRefused;
            } else {
                s.volume += paid;
                s.standInsAbsorbed += b.amount - paid;
            }
        } else if (b.fate == 3) {
            _releaseBuy(h, b.ref);
        } else {
            uint128 amount = b.fate == 1
                ? uint128(b.amount + b.amount * _rand(tolBps + 1) / 10_000)
                : b.fate == 2 ? uint128(b.amount * (50 + _rand(46)) / 100) : b.amount;
            (bool ok, uint256 covered, uint256 gasUsed) = _book(h, b.ref, amount);
            if (!ok) {
                ++s.captureFailures;
                _releaseBuy(h, b.ref);
            } else {
                ++s.captures;
                s.volume += covered;
                if (gasUsed != 0) {
                    ++s.captureSampled;
                    s.captureGas += gasUsed;
                    if (gasUsed > s.captureGasMax) s.captureGasMax = gasUsed;
                }
            }
        }
        _checkLedger();
        _checkHolder(h);
    }

    /// @dev Wages land; the settlement account repays what it owes the treasury from what it holds.
    function _paydays() internal {
        for (uint256 i; i < n; ++i) {
            _payday(holders[i], 300e6 + _rand(700e6));
        }
        _repayAdvance();
        _checkLedger();
    }

    /// @dev The issuer refills its treasury funds to the target.
    function _topUp() internal {
        uint256 have = treasury.issuerFunds(address(usd));
        if (have >= fundsTarget) return;
        uint256 need = fundsTarget - have;
        _mint(issuer, need);
        vm.prank(issuer);
        treasury.fundIssuerDebt(address(usd), need);
    }

    /// @dev The issuer sweeps the settlement account's free balance above the buffer to its bank each business evening.
    function _sweep() internal {
        uint256 free = core.available(settlement, address(usd));
        if (free <= fundsTarget) return;
        vm.prank(settlement);
        usd.transfer(bank, free - fundsTarget);
        s.swept += free - fundsTarget;
        _checkLedger();
    }

    /// @dev Each business morning the bank sends what the network will be owed, plus the buffer.
    function _refill() internal {
        uint256 want = _unsettled() + fundsTarget;
        uint256 free = core.available(settlement, address(usd));
        if (free >= want) return;
        vm.prank(bank);
        usd.transfer(settlement, want - free);
        s.refilled += want - free;
        _repayAdvance();
        _checkLedger();
    }

    /// @dev Pays the network the unacknowledged net from the settlement account, advancing what it lacks from the
    ///      issuer's funds; short of both, the sponsor seizes the rest (when it covers) or the net stays unpaid.
    function _settleNetwork() internal {
        if (cutoffMode) return _settleCutoff();
        // What the live acknowledgement clears beyond the last cut-off: captured but not yet in a network settlement.
        (,, int128 liveNet,) = cards.ledger();
        if (liveNet > cutoffNet && uint256(int256(liveNet - cutoffNet)) > unpaidAcknowledgedMax) {
            unpaidAcknowledgedMax = uint256(int256(liveNet - cutoffNet));
        }
        uint256 owed = _unsettled();
        if (owed == 0) return;
        uint256 free = core.available(settlement, address(usd));
        uint256 can = free + treasury.issuerFunds(address(usd));
        uint256 applied;
        if (owed > can) {
            ++s.shortfalls;
            uint256 short = owed - can;
            if (short > s.maxShortfall) s.maxShortfall = short;
            if (!sponsorCovers) return;
            vm.prank(sponsor);
            treasury.seize(short);
            vm.prank(sponsor);
            usd.transfer(network, short);
            s.seized += short;
            applied = short;
            owed = can;
        }
        if (owed != 0) {
            vm.prank(issuer);
            uint256 advanced = treasury.payOut(network, owed, bytes32("network"));
            s.advanced += advanced;
        }
        (uint64 seq, uint64 through,,) = cards.ledger();
        if (seq > through) {
            vm.prank(sponsor);
            treasury.acknowledgeSettlement(seq, applied);
        }
        ++s.settlements;
        if (s.resumeHour == 0 && block.timestamp > outageStart) s.resumeHour = (block.timestamp - START) / HOUR;
        assertEq(_unsettled(), 0, "acknowledged net left");
        _checkLedger();
    }

    /// @dev Pays the network the net through the last cut-off and acknowledges through the cut-off sequence.
    function _settleCutoff() internal {
        if (cutoffNet <= paidNet) return;
        uint256 owed = uint256(int256(cutoffNet - paidNet));
        if (owed > core.available(settlement, address(usd)) + treasury.issuerFunds(address(usd))) {
            ++s.shortfalls;
            return;
        }
        vm.prank(issuer);
        s.advanced += treasury.payOut(network, owed, bytes32("network"));
        paidNet = cutoffNet;
        (, uint64 through,,) = cards.ledger();
        if (cutoffSeq > through) {
            (uint64 seq,,,) = cards.ledger();
            uint256 before = _unsettled();
            vm.prank(sponsor);
            treasury.acknowledgeSettlement(cutoffSeq, 0);
            uint256 cleared = before - _unsettled();
            (,,, int128 settledNow) = cards.ledger();
            assertEq(settledNow, cutoffNet, "an acknowledgement clears exactly the net through its cut-off");
            cutoffCleared += cleared;
            ++cutoffAcks;
            if (cutoffSeq < seq) {
                ++partialAcks;
                partialCleared += cleared;
            }
        }
        // Net the network has been paid for that the guard still counts as unsettled.
        (,,, int128 settledNet) = cards.ledger();
        if (paidNet > settledNet && uint256(int256(paidNet - settledNet)) > paidStillCountedMax) {
            paidStillCountedMax = uint256(int256(paidNet - settledNet));
        }
        ++s.settlements;
        if (s.resumeHour == 0 && block.timestamp > outageStart) s.resumeHour = (block.timestamp - START) / HOUR;
        _checkLedger();
    }

    function _settledThrough() internal view returns (uint64 through) {
        (, through,,) = cards.ledger();
    }

    function _observe() internal {
        uint256 e = treasury.exposure();
        uint256 v = treasury.valueOf();
        if (e > s.maxExposure) s.maxExposure = e;
        if (v != 0 && e * 10_000 / v > s.maxExposureBps) s.maxExposureBps = e * 10_000 / v;
        uint256 u = _unsettled();
        if (u > s.maxUnsettled) s.maxUnsettled = u;
        uint256 d = _issuerDebt();
        if (d > s.maxIssuerDebt) s.maxIssuerDebt = d;
        // The treasury always holds the funds it reports and never advances past them.
        assertGe(usd.balanceOf(address(treasury)), treasury.issuerFunds(address(usd)), "treasury short");
    }

    /// @dev Resolves every purchase still open, settles with funding restored, and checks nothing is left.
    function _drain(uint256 hr) internal {
        vm.warp(START + hr * HOUR);
        for (uint256 j; j < pending.length; ++j) {
            Buy memory b = buys[pending[j]];
            if (b.fate == 4) _releaseBuy(holders[b.holder], b.ref);
            else _resolve(b);
        }
        delete pending;
        fundingAt = 0;
        _topUp();
        _refill();
        if (cutoffMode) {
            // Closing out: the network pays everything still unpaid and the sponsor acknowledges the live sequence.
            (cutoffSeq,, cutoffNet,) = cards.ledger();
            cutoffMode = false;
            _refill();
            if (cutoffNet > paidNet) {
                vm.prank(issuer);
                treasury.payOut(network, uint256(int256(cutoffNet - paidNet)), bytes32("network"));
            }
            vm.prank(sponsor);
            treasury.acknowledgeSettlement(cutoffSeq, 0);
            cutoffMode = true;
        } else {
            _settleNetwork();
        }
        (uint256 held,) = cards.exposure();
        assertEq(held, 0, "holds left open");
        assertEq(s.standInsRefused, 0, "the network paid every stand-in, so each one books");
        assertEq(_unsettled(), 0, "unsettled left");
        for (uint256 j; j < buys.length; ++j) {
            assertFalse(cards.purchaseOf(buys[j].ref).open, "purchase left open");
        }
        for (uint256 i; i < n; ++i) {
            _checkHolder(holders[i]);
        }
        _checkLedger();
    }

    function _report() internal view {
        _log("holders", n);
        _log("auths", s.auths);
        _log("approved", s.approved);
        _log("declined_guard", s.declinedGuard);
        _log("declined_other", s.declinedOther);
        _log("outage_auths", s.outageAuths);
        _log("outage_declined_guard", s.outageGuard);
        _log("decline_rate_outage_bps", s.outageAuths == 0 ? 0 : s.outageGuard * 10_000 / s.outageAuths);
        _log("guard_trip_after_outage_h", s.firstTrip == 0 ? 0 : (s.firstTrip - outageStart) / HOUR);
        _log("guard_hours_tripped", s.tripHours);
        _log("first_settlement_after_outage_hour", s.resumeHour);
        _log(
            "guard_recovery_h_after_settlement",
            s.tripHours == 0 || lastTripHour < s.resumeHour ? 0 : lastTripHour - s.resumeHour + 1
        );
        _logUsd("collateral", treasury.valueOf());
        _logUsd("max_exposure", s.maxExposure);
        _log("max_exposure_vs_collateral_bps", s.maxExposureBps);
        _logUsd("max_unsettled", s.maxUnsettled);
        _logUsd("max_issuer_debt", s.maxIssuerDebt);
        _logUsd("advanced", s.advanced);
        _log("stand_ins", s.standIns);
        _log("stand_ins_refused", s.standInsRefused);
        _logUsd("stand_ins_absorbed", s.standInsAbsorbed);
        _log("settlement_shortfalls", s.shortfalls);
        _logUsd("max_shortfall", s.maxShortfall);
        _logUsd("sponsor_seized", s.seized);
        _logUsd("captured_volume", s.volume);
        _logUsd("acknowledged_before_network_paid_max", unpaidAcknowledgedMax);
        if (cutoffMode) {
            _log("cutoff_acks", cutoffAcks);
            _logUsd("cutoff_ack_cleared", cutoffCleared);
            _log("partial_acks", partialAcks);
            _logUsd("partial_ack_cleared", partialCleared);
            _logUsd("paid_still_counted_max", paidStillCountedMax);
        }
        _logUsd("swept_to_bank", s.swept);
        _logUsd("refilled_from_bank", s.refilled);
        _log("capture_failures", s.captureFailures);
        _log("gas_authorize_avg", s.authSampled == 0 ? 0 : s.authGas / s.authSampled);
        _log("gas_authorize_max", s.authGasMax);
        _log("gas_capture_avg", s.captureSampled == 0 ? 0 : s.captureGas / s.captureSampled);
        _log("gas_capture_max", s.captureGasMax);
    }
}
