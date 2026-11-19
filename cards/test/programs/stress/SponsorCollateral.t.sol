// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuthBase } from "../../../src/programs/CardAuthBase.sol";
import { IssuerTreasury } from "../../../src/programs/IssuerTreasury.sol";
import { IReservationCore } from "../../../src/programs/interfaces/IReservationCore.sol";
import { AdverseBase } from "./AdverseBase.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

/// @notice Sponsor collateral under growth and churn: the program's spend grows faster than the collateral the
///         settlement account pledges, pledges are posted every few days into the 16 slots and stop counting
///         COVER_TERM before they end, the sponsor pays the network each business day and is reimbursed by the issuer
///         or, when the issuer misses, seizes collateral and applies it to the acknowledged settlement. After every
///         step: usd is conserved, the guard never lets an approval take exposure past live collateral, what the
///         sponsor seized and has not applied matches the treasury's count, nothing is applied that was not cleared,
///         the sponsor never takes more than it paid out, and the issuer cannot acknowledge settlement on its own.
contract SponsorCollateralStressTest is AdverseBase {
    struct Open {
        bytes32 ref;
        uint64 presentAt;
        bool done;
    }

    struct Cfg {
        uint256 numDays;
        // Daily growth of spend and of each new pledge, in basis points.
        uint256 spendGrowthBps;
        uint256 pledgeGrowthBps;
        uint256 firstPledge;
        uint256 pledgeEvery;
        // How long a pledge counts: it stands COVER_TERM plus this.
        uint256 pledgeCounts;
        uint256 missBps;
        // Days from which the issuer neither reimburses nor posts (zero length: none).
        uint256 outageFrom;
        uint256 outageDays;
    }

    struct Metrics {
        uint256 auths;
        uint256 authValue;
        uint256 guardDeclines;
        uint256 guardDeclineValue;
        uint256 firstGuardDecline;
        uint256 lastWeekAuths;
        uint256 lastWeekDeclines;
        uint256 posts;
        uint256 postsSkippedNoSlot;
        uint256 pledgedValue;
        uint256 maxLiveSlots;
        uint256 maxExposure;
        uint256 maxExposureToCollateralBps;
        uint256 uncoveredDays;
        uint256 maxUncovered;
        uint256 paidToNetwork;
        uint256 reimbursed;
        uint256 seizes;
        uint256 seizedValue;
        uint256 seizedReceived;
        uint256 seizeShortfall;
        uint256 seizeRefused;
        uint256 applied;
        uint256 cleared;
        uint256 unpaidBySponsor;
        uint256 aloneRefused;
    }

    IssuerTreasury internal treasury;
    address internal sponsor = makeAddr("sponsor");
    address internal network = makeAddr("network");

    Cfg internal cfg;
    Metrics internal m;
    Open[] internal opens;
    uint256 internal cursor;
    uint256 internal day;
    uint256 internal pledgeSize;
    uint256 internal spendScale = 1e18;

    function setUp() public {
        _setUpAdverse(keccak256("sponsor-collateral"));
        treasury = new IssuerTreasury(cards);
        _track(sponsor);
        _track(network);
        _track(address(treasury));
        _mintUsd(sponsor, 50_000_000e6);
    }

    /// @notice 90 days, spend growing 3% a day against pledges growing 1% a day, posted every 3 days and counting 9
    ///         days each; the issuer misses 10% of its reimbursements and the sponsor seizes those.
    function test_stress_exposureOutgrowsCollateral() public {
        string memory t = "sponsorGrowth";
        cfg = Cfg(90, 300, 100, 4000e6, 3, 9 days, 1000, 0, 0);
        _run();
        _report(t);
        assertGt(m.guardDeclines, 0, "the guard declined once spend outgrew the collateral");
        assertGt(m.seizes, 0);
        assertEq(m.unpaidBySponsor, 0, "seizures made the sponsor whole");
    }

    /// @notice The issuer stops reimbursing and stops posting for 12 days: the sponsor seizes every business day
    ///         until the live pledges run out. Pledges keep counting toward seizure until they end, COVER_TERM after
    ///         they stop counting toward new approvals, so the sponsor stays whole while approvals stop.
    function test_stress_issuerOutageSponsorSeizesDaily() public {
        string memory t = "sponsorOutage";
        cfg = Cfg(60, 100, 100, 6000e6, 3, 9 days, 0, 20, 12);
        _run();
        _report(t);
        assertGt(m.seizes, 5, "the sponsor seized through the outage");
        assertEq(m.seizeShortfall, 0, "live pledges covered every seizure");
    }

    /// @notice Pledges posted every day and counting 20 days need more than the 16 slots: posting skips once every
    ///         slot holds a live pledge, until the oldest ends.
    function test_stress_pledgeSlotsChurn() public {
        string memory t = "sponsorSlots";
        cfg = Cfg(80, 150, 150, 1500e6, 1, 20 days, 1000, 0, 0);
        _run();
        _report(t);
        assertEq(m.maxLiveSlots, 16, "every slot in use at the peak");
        assertGt(m.postsSkippedNoSlot, 0, "posting waited for a free slot");
    }

    /// @notice Fuzzed growth, pledge size, cadence and miss rate over a shorter run; every per-step invariant holds.
    /// forge-config: default.fuzz.runs = 6
    /// forge-config: ci.fuzz.runs = 3
    function testFuzz_stress_sponsorCollateral(uint256 growth, uint256 pledge, uint256 every, uint256 miss) public {
        cfg = Cfg(
            35,
            bound(growth, 0, 500),
            bound(growth / 7, 0, 200),
            bound(pledge, 500e6, 8000e6),
            bound(every, 1, 5),
            bound(miss, 2, 15) * 1 days,
            bound(miss, 0, 5000),
            0,
            0
        );
        _run();
    }

    /// @notice The sponsor seizes after the pledges behind an unsettled capture ended. Current behaviour: the seizure
    ///         goes through, counts the whole value as seized and pays the sponsor only what live pledges still hold,
    ///         here nothing, so the sponsor's remaining room to seize shrinks by value it never received.
    function test_stress_seizeAfterPledgesEnd_countsWhatItCouldNotTake() public {
        string memory t = "sponsorLateSeize";
        vm.pauseGasMetering();
        _holders(1, 1_000_000e6);
        _toMonday();
        pledgeSize = 1000e6;
        cfg.pledgeCounts = 2 days;
        _post();
        _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
        bytes32 ref = bytes32("late-seize");
        vm.startPrank(issuer);
        cards.authorize(cardIds[0], ref, 800e6, merchants[0], uint64(block.timestamp + 1 days), 0);
        cards.capture(ref, 800e6, true);
        vm.stopPrank();
        // Nobody acknowledges, and the pledge ends.
        vm.warp(block.timestamp + treasury.COVER_TERM() + 3 days);
        assertEq(treasury.unitsOf(), 0);
        assertEq(treasury.exposure(), 800e6);
        uint256 before = usd.balanceOf(sponsor);
        vm.prank(sponsor);
        treasury.seize(800e6);
        uint256 got = usd.balanceOf(sponsor) - before;
        _log(t, "seize_value_usd", 800);
        _log(t, "sponsor_received_usd", got / 1e6);
        _log(t, "seized_counter_usd", treasury.seized() / 1e6);
        assertEq(got, 0, "nothing was left to take");
        assertEq(treasury.seized(), 800e6, "yet the whole value counts as seized");
        // A new pledge cannot be seized against the same exposure until the sponsor applies what it never received.
        cfg.pledgeCounts = 9 days;
        _post();
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, 1, 0));
        treasury.seize(1);
    }

    // Engine.

    function _run() internal {
        vm.pauseGasMetering();
        _holders(30 * scale, 1_000_000e6);
        _toMonday();
        pledgeSize = cfg.firstPledge;
        // The first pledge, then the guard; the sponsor owes the network from here.
        _post();
        _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
        for (day = 0; day < cfg.numDays + 10; ++day) {
            vm.warp(block.timestamp + 1 hours);
            if (day % cfg.pledgeEvery == 0 && day != 0 && !_inOutage()) _post();
            vm.warp(block.timestamp + 1 hours);
            _present();
            vm.warp(block.timestamp + 1 hours);
            _settle();
            _check();
            vm.warp(block.timestamp + 7 hours);
            if (day < cfg.numDays) _shop();
            _check();
            _measure();
            vm.warp(block.timestamp + 14 hours);
            pledgeSize = pledgeSize * (10_000 + cfg.pledgeGrowthBps) / 10_000;
            spendScale = spendScale * (10_000 + cfg.spendGrowthBps) / 10_000;
        }
    }

    function _inOutage() internal view returns (bool) {
        return cfg.outageDays != 0 && day >= cfg.outageFrom && day < cfg.outageFrom + cfg.outageDays;
    }

    /// @dev The settlement account pledges pledgeSize into the first free slot, ending stale pledges first.
    function _post() internal {
        uint256 live;
        uint256 free;
        for (uint256 n = 1; n <= 16; ++n) {
            IReservationCore.HoldRecord memory h = core.getHold(settlement, settlement, treasury.pledgeId(n));
            if (h.token == address(0)) {
                if (free == 0) free = n;
            } else if (h.expiresAt <= block.timestamp) {
                core.releaseExpired(settlement, settlement, treasury.pledgeId(n));
                if (free == 0) free = n;
            } else {
                ++live;
            }
        }
        m.maxLiveSlots = _max(m.maxLiveSlots, live);
        if (free == 0) {
            ++m.postsSkippedNoSlot;
            return;
        }
        _mintUsd(settlement, pledgeSize);
        vm.startPrank(settlement);
        core.pledge(
            address(treasury),
            address(usd),
            treasury.pledgeId(free),
            uint128(pledgeSize),
            uint64(block.timestamp + treasury.COVER_TERM() + cfg.pledgeCounts)
        );
        treasury.post(sponsor, IEarnVault(address(0)), free);
        vm.stopPrank();
        ++m.posts;
        m.pledgedValue += pledgeSize;
        m.maxLiveSlots = _max(m.maxLiveSlots, live + 1);
    }

    function _shop() internal {
        bool lastWeek = day + 7 >= cfg.numDays;
        for (uint256 i; i < holders.length; ++i) {
            if (!_chance(4000)) continue;
            uint256 amount = _between(5, 150) * 1e6 * spendScale / 1e18;
            bytes32 ref = keccak256(abi.encode("buy", opens.length, i, day));
            vm.prank(issuer);
            try cards.authorize(
                cardIds[i], ref, uint128(amount), merchants[i % 8], uint64(block.timestamp + 7 days), 0
            ) {
                opens.push(Open(ref, uint64(block.timestamp + _between(1, 2) * 1 days - 7 hours), false));
                ++m.auths;
                m.authValue += amount;
                if (lastWeek) ++m.lastWeekAuths;
                // The guard held: what the program may owe stays within live collateral.
                assertLe(treasury.exposure(), treasury.valueOf(), "approval within collateral");
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), IssuerTreasury.ExposureAboveCollateral.selector, "only the guard declines");
                ++m.guardDeclines;
                m.guardDeclineValue += amount;
                if (m.firstGuardDecline == 0) m.firstGuardDecline = day + 1;
                if (lastWeek) ++m.lastWeekDeclines;
            }
        }
    }

    function _present() internal {
        if (_weekend()) return;
        for (uint256 k = cursor; k < opens.length; ++k) {
            Open storage o = opens[k];
            if (o.done || block.timestamp < o.presentAt) continue;
            vm.startPrank(issuer);
            if (_chance(500)) cards.release(o.ref);
            else cards.capture(o.ref, cards.purchaseOf(o.ref).held, true);
            vm.stopPrank();
            o.done = true;
        }
        while (cursor < opens.length && opens[cursor].done) {
            ++cursor;
        }
    }

    /// @dev Business days: the sponsor pays the network what was captured, then the issuer reimburses it, or the
    ///      sponsor seizes that much and applies it as it acknowledges.
    function _settle() internal {
        if (_weekend()) return;
        (uint64 seq, uint64 through,,) = cards.ledger();
        if (seq == through) return;
        (,, uint256 unsettled) = cards.exposure();
        _issuerAlone(seq);
        vm.prank(sponsor);
        usd.transfer(network, unsettled);
        m.paidToNetwork += unsettled;
        bool miss = _inOutage() || _chance(cfg.missBps);
        uint256 recovered;
        uint256 applied;
        if (!miss) {
            uint256 pay = _min(unsettled, core.available(settlement, address(usd)));
            vm.prank(settlement);
            usd.transfer(sponsor, pay);
            m.reimbursed += pay;
            recovered = pay;
        }
        if (recovered < unsettled) {
            uint256 want = unsettled - recovered;
            uint256 room = treasury.exposure() - _min(treasury.exposure(), treasury.seized());
            uint256 value = _min(want, room);
            if (value != 0) {
                uint256 before = usd.balanceOf(sponsor);
                vm.prank(sponsor);
                try treasury.seize(value) {
                    uint256 got = usd.balanceOf(sponsor) - before;
                    ++m.seizes;
                    m.seizedValue += value;
                    m.seizedReceived += got;
                    if (got < value) m.seizeShortfall += value - got;
                    recovered += got;
                    applied = value;
                } catch {
                    ++m.seizeRefused;
                }
            }
        }
        if (recovered < unsettled) m.unpaidBySponsor += unsettled - recovered;
        applied = _min(treasury.seized(), applied == 0 ? treasury.seized() : applied);
        applied = _min(applied, unsettled);
        uint256 seizedBefore = treasury.seized();
        vm.prank(sponsor);
        treasury.acknowledgeSettlement(seq, applied);
        assertEq(treasury.seized(), seizedBefore - applied);
        m.applied += applied;
        m.cleared += unsettled;
    }

    /// @dev With the treasury as guard and a sponsor posted, the issuer can acknowledge neither on CardAuth nor on
    ///      the treasury.
    function _issuerAlone(uint64 seq) internal {
        vm.startPrank(issuer);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.acknowledgeSettlement(seq);
        vm.expectRevert(IssuerTreasury.NotSponsor.selector);
        treasury.acknowledgeSettlement(seq, 0);
        vm.stopPrank();
        ++m.aloneRefused;
    }

    function _check() internal {
        _checkConservation();
        assertEq(m.seizedValue - m.applied, treasury.seized(), "seized and not applied, counted once");
        assertLe(m.applied, m.cleared, "nothing applied that was not cleared");
        assertLe(m.seizedReceived + m.reimbursed, m.paidToNetwork, "the sponsor never takes more than it paid out");
        assertEq(usd.balanceOf(address(treasury)), 0, "the treasury keeps nothing");
    }

    function _measure() internal {
        uint256 due = treasury.exposure();
        uint256 value = treasury.valueOf();
        m.maxExposure = _max(m.maxExposure, due);
        if (value != 0) m.maxExposureToCollateralBps = _max(m.maxExposureToCollateralBps, due * 10_000 / value);
        if (due > value) {
            ++m.uncoveredDays;
            m.maxUncovered = _max(m.maxUncovered, due - value);
        }
    }

    function _report(string memory t) internal view {
        _log(t, "holders", holders.length);
        _log(t, "days", cfg.numDays);
        _log(t, "auths", m.auths);
        _log(t, "auth_value_usd", m.authValue / 1e6);
        _log(t, "guard_declines", m.guardDeclines);
        _log(t, "guard_decline_value_usd", m.guardDeclineValue / 1e6);
        _log(t, "first_guard_decline_day", m.firstGuardDecline);
        _log(t, "last_week_decline_bps", m.lastWeekDeclines * 10_000 / _max(1, m.lastWeekAuths + m.lastWeekDeclines));
        _log(t, "posts", m.posts);
        _log(t, "posts_skipped_no_slot", m.postsSkippedNoSlot);
        _log(t, "pledged_usd", m.pledgedValue / 1e6);
        _log(t, "max_live_slots", m.maxLiveSlots);
        _log(t, "max_exposure_usd", m.maxExposure / 1e6);
        _log(t, "max_exposure_to_collateral_bps", m.maxExposureToCollateralBps);
        _log(t, "uncovered_days", m.uncoveredDays);
        _log(t, "max_uncovered_usd", m.maxUncovered / 1e6);
        _log(t, "paid_to_network_usd", m.paidToNetwork / 1e6);
        _log(t, "reimbursed_usd", m.reimbursed / 1e6);
        _log(t, "seizes", m.seizes);
        _log(t, "seized_usd", m.seizedValue / 1e6);
        _log(t, "seize_shortfall_usd", m.seizeShortfall / 1e6);
        _log(t, "seize_refused", m.seizeRefused);
        _log(t, "applied_usd", m.applied / 1e6);
        _log(t, "sponsor_unpaid_usd", m.unpaidBySponsor / 1e6);
        _log(t, "issuer_alone_refused", m.aloneRefused);
        _log(t, "invariant_checks", checks);
    }
}
