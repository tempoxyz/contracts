// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuthBase } from "../../../src/programs/CardAuthBase.sol";
import { CardLegs } from "../../../src/programs/CardLegs.sol";
import { AdverseBase } from "./AdverseBase.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

/// @notice Settlement-token outages and token changes with purchases in flight: the token issuer freezes the
///         settlement account past the hold term, pauses the token over a weekend, or freezes a share of the
///         cardholders; the card issuer moves the program to another settlement token while it trades. Cardholders
///         keep buying, merchants keep presenting (some never do), lapsed purchases are released and charged late
///         once money moves again, and refunds keep flowing. After every step: usd is conserved over every party, each
///         cardholder's balance is exactly what it was given less what it paid plus what it was refunded, and nothing
///         the program holds is stuck.
contract FrozenSettlementStressTest is AdverseBase {
    uint8 internal constant OPEN = 1;
    uint8 internal constant CAPTURED = 2;
    uint8 internal constant LAPSED = 3;
    uint8 internal constant CHARGED = 4;
    uint8 internal constant DONE = 5;
    uint8 internal constant ORPHANED = 6;

    uint8 internal constant MODE_FREEZE_SETTLEMENT = 1;
    uint8 internal constant MODE_PAUSE = 2;
    uint8 internal constant MODE_FREEZE_HOLDERS = 3;
    uint8 internal constant MODE_SWITCH = 4;

    uint256 internal constant START_BALANCE = 1500e6;

    struct Buy {
        bytes32 ref;
        uint32 holder;
        uint64 amount;
        uint64 expiresAt;
        uint64 presentAt;
        uint64 refundAt;
        uint8 state;
    }

    struct Cfg {
        uint8 mode;
        uint256 numDays;
        uint256 outageFrom;
        uint256 outageUntil;
        uint256 holdTerm;
        uint256 maxLagDays;
        bool weekendCapture;
        // Share of purchases the merchant never presents (no-shows), left to expire.
        uint256 neverPresentBps;
        // Share of cardholders who move everything they hold elsewhere once a hold of theirs lapses.
        uint256 drainOnReleaseBps;
        // Share of cardholders the token issuer freezes in MODE_FREEZE_HOLDERS.
        uint256 frozenHolderBps;
        // Share of captured purchases refunded in part two days later.
        uint256 refundBps;
    }

    struct Metrics {
        uint256 auths;
        uint256 authValue;
        uint256 declines;
        uint256 outageDeclines;
        // Outage declines that name the settlement account as unable to receive the settlement token.
        uint256 settlementBlockedDeclines;
        uint256 outageAuths;
        uint256 captures;
        uint256 frozenHolderCaptures;
        uint256 captureFails;
        uint256 lapsed;
        uint256 lapsedValue;
        uint256 lateCharged;
        uint256 lateChargeFails;
        uint256 lateCoveredValue;
        uint256 absorbed;
        uint256 absorbedCount;
        uint256 refunds;
        uint256 refundValue;
        uint256 refundFails;
        uint256 maxHeld;
        uint256 maxUnsettled;
        uint256 maxBacklog;
        uint256 recoveryDay;
        uint256 switchAttempts;
        uint256 switchFails;
        uint256 switchDay;
        uint256 drainHours;
        uint256 drainDeclinedValue;
        uint256 orphaned;
        uint256 orphanedValue;
        uint256 noShows;
    }

    Buy[] internal buys;
    uint256 internal cursor;
    Metrics internal m;
    Cfg internal cfg;
    uint64 internal policy;
    bool internal outage;
    bool internal draining;
    bool internal switched;
    ITIP20Token internal eur;

    mapping(uint256 => uint256) internal givenTo;
    mapping(uint256 => uint256) internal paidBy;
    mapping(uint256 => uint256) internal refundedTo;
    mapping(uint256 => uint256) internal spentElsewhere;
    mapping(uint256 => bool) internal frozenHolder;
    mapping(uint256 => bool) internal drainer;

    address internal elsewhere = makeAddr("elsewhere");

    function setUp() public {
        _setUpAdverse(keccak256("frozen-settlement"));
        _track(elsewhere);
        _mintUsd(issuer, 10_000_000e6);
        vm.prank(issuer);
        usd.approve(address(cards), type(uint256).max);
        usd.grantRole(usd.PAUSE_ROLE(), address(this));
        usd.grantRole(usd.UNPAUSE_ROLE(), address(this));
    }

    /// @notice The settlement account is frozen for longer than a purchase's hold term (10 days against 7 by
    ///         default, `STRESS_FREEZE_DAYS` to change it). Every capture fails and every new purchase is declined
    ///         while the account cannot receive the settlement token; purchases approved before the freeze that lapse
    ///         are released and charged late after the account is unfrozen, from whatever the cardholder still holds
    ///         then; a fifth of the cardholders move their money elsewhere once their hold lapses, which the issuer
    ///         absorbs.
    function test_stress_settlementAccountFrozenPastHoldTerm() public {
        string memory t = "settlementFrozen";
        _holders(40 * scale, START_BALANCE);
        policy = _blacklist();
        _toMonday();
        uint256 start = block.timestamp;
        uint256 freezeDays = vm.envOr("STRESS_FREEZE_DAYS", uint256(10));
        cfg = _cfg(MODE_FREEZE_SETTLEMENT, 42, start + 8 days, start + 8 days + freezeDays * 1 days, 7 days, 2);
        cfg.drainOnReleaseBps = 2000;
        _run();
        _report(t, freezeDays);
        assertEq(m.lapsed, m.lateCharged, "every lapsed purchase charged late");
        (uint256 held,, uint256 unsettled) = cards.exposure();
        assertEq(held, 0, "nothing held at the end");
        assertEq(unsettled, 0, "everything acknowledged");
        assertEq(m.outageAuths, 0, "nothing approved while the account was frozen");
        assertGt(m.outageDeclines, 0, "purchases were tried while the account was frozen");
        assertEq(m.settlementBlockedDeclines, m.outageDeclines, "every outage decline names the settlement account");
        // Only purchases approved before the freeze lapse now, and the issuer absorbs exactly what their cardholders
        // no longer held when charged late (none at the default seed).
        assertEq(
            m.absorbed,
            m.lapsedValue - m.lateCoveredValue,
            "the issuer absorbed what drained cardholders no longer held"
        );
    }

    /// @notice The token is paused from Friday 18:00 to Monday 12:00 with short holds (3 days) and merchants that
    ///         present any day up to 4 days late: nothing authorizes or captures during the pause, holds that run out
    ///         over the weekend lapse and are charged late.
    function test_stress_tokenPausedOverWeekend() public {
        string memory t = "tokenPaused";
        _holders(40 * scale, START_BALANCE);
        _toMonday();
        uint256 start = block.timestamp;
        cfg = _cfg(MODE_PAUSE, 21, start + 4 days + 8 hours, start + 7 days + 2 hours, 3 days, 4);
        cfg.weekendCapture = true;
        _run();
        _report(t, 3);
        assertEq(m.outageAuths, 0, "nothing authorizes while paused");
        assertEq(m.lapsed, m.lateCharged, "every lapsed purchase charged late");
        (uint256 held,,) = cards.exposure();
        assertEq(held, 0, "nothing held at the end");
    }

    /// @notice The token issuer freezes a quarter of the cardholders for 14 days while they have purchases open. Their
    ///         open holds still capture (a capture within the hold is exempt from the sender check), new purchases and
    ///         late charges on them fail, and refunds to them wait until they are unfrozen.
    function test_stress_cardholdersFrozenWithOpenHolds() public {
        string memory t = "holdersFrozen";
        _holders(40 * scale, START_BALANCE);
        policy = _blacklist();
        _toMonday();
        uint256 start = block.timestamp;
        cfg = _cfg(MODE_FREEZE_HOLDERS, 35, start + 5 days, start + 19 days, 7 days, 3);
        cfg.frozenHolderBps = 2500;
        cfg.refundBps = 2000;
        cfg.neverPresentBps = 300;
        _run();
        _report(t, 14);
        assertGt(m.frozenHolderCaptures, 0, "frozen cardholders' open holds still captured");
        assertEq(m.lapsed, m.lateCharged, "every lapsed purchase charged late after the unfreeze");
        assertGt(m.refundFails, 0, "refunds to frozen cardholders waited");
        (uint256 held,,) = cards.exposure();
        assertEq(held, 0, "nothing held at the end");
    }

    /// @notice The card issuer moves the program to another settlement token while it trades 24/7 with 5% no-shows.
    ///         The switch needs nothing held and everything acknowledged, so it fails every day while purchases are
    ///         open; once the issuer stops approving it waits out the longest open hold. Purchases that lapsed before
    ///         the switch and are presented after it can no longer be charged under their reference.
    function test_stress_settlementTokenSwitchUnderLoad() public {
        string memory t = "tokenSwitch";
        eur = _createToken("Euro", "EURX");
        _setting(abi.encodeCall(cards.setCompanion, (address(this), true)));
        _holders(40 * scale, START_BALANCE);
        _toMonday();
        uint256 start = block.timestamp;
        // Attempts from day 7, stops approving on day 14.
        cfg = _cfg(MODE_SWITCH, 28, start + 7 days, start + 14 days, 7 days, 3);
        cfg.neverPresentBps = 500;
        cfg.weekendCapture = true;
        _run();
        _report(t, 0);
        assertTrue(switched, "the switch went through once the program drained");
        assertEq(cards.settlementToken(), address(eur));
        assertGt(m.switchFails, 0, "refused while purchases were open");
        assertGe(m.drainHours, 7 days / 1 hours - 24, "the drain waits out the hold term of no-shows");
        assertGt(m.orphaned, 0, "late presentments booked before the switch cannot be charged under their reference");
        assertEq(m.lapsed, m.lateCharged + m.orphaned, "every lapsed purchase charged late or orphaned");
    }

    function _cfg(uint8 mode, uint256 numDays, uint256 from, uint256 until, uint256 holdTerm, uint256 maxLagDays)
        internal
        pure
        returns (Cfg memory)
    {
        return Cfg(mode, numDays, from, until, holdTerm, maxLagDays, false, 0, 0, 0, 500);
    }

    // Engine.

    function _run() internal {
        vm.pauseGasMetering();
        if (cfg.mode == MODE_FREEZE_HOLDERS) {
            for (uint256 i; i < holders.length; ++i) {
                frozenHolder[i] = _chance(cfg.frozenHolderBps);
            }
        }
        for (uint256 i; i < holders.length; ++i) {
            drainer[i] = _chance(cfg.drainOnReleaseBps);
        }
        for (uint256 day; day < cfg.numDays + 10; ++day) {
            bool trading = day < cfg.numDays;
            // 10:00 merchants present, lapsed purchases are released and charged late, refunds go out.
            _setOutage();
            _present();
            _measureUnsettled();
            _settle(day);
            _check();
            // 18:00 cardholders buy and live their lives off the card.
            vm.warp(block.timestamp + 8 hours);
            _setOutage();
            if (trading) _shop();
            _offCard();
            _check();
            _measure(day);
            vm.warp(block.timestamp + 16 hours);
        }
    }

    function _setOutage() internal {
        bool on = block.timestamp >= cfg.outageFrom && block.timestamp < cfg.outageUntil;
        if (cfg.mode == MODE_SWITCH) {
            draining = !switched && block.timestamp >= cfg.outageUntil;
            return;
        }
        if (on == outage) return;
        outage = on;
        if (cfg.mode == MODE_FREEZE_SETTLEMENT) {
            _freeze(policy, settlement, on);
        } else if (cfg.mode == MODE_PAUSE) {
            if (on) usd.pause();
            else usd.unpause();
        } else if (cfg.mode == MODE_FREEZE_HOLDERS) {
            for (uint256 i; i < holders.length; ++i) {
                if (frozenHolder[i]) _freeze(policy, holders[i], on);
            }
        }
    }

    function _blocked(uint256 i) internal view returns (bool) {
        if (!outage) return false;
        if (cfg.mode == MODE_FREEZE_HOLDERS) return frozenHolder[i];
        return true;
    }

    function _shop() internal {
        for (uint256 i; i < holders.length; ++i) {
            if (!_chance(3000)) continue;
            uint64 amount = uint64(_between(5, 150) * 1e6);
            if (draining || switched) {
                // The issuer stopped approving to drain the program before the switch.
                if (draining) m.drainDeclinedValue += amount;
                continue;
            }
            bytes32 ref = keccak256(abi.encode("buy", buys.length, i));
            uint64 expiresAt = uint64(block.timestamp + cfg.holdTerm);
            vm.prank(issuer);
            _meter();
            try cards.authorize(cardIds[i], ref, amount, merchants[i % 8], expiresAt, 0) returns (uint256 got) {
                _metered("authorize");
                assertEq(got, amount, "full approval");
                uint256 lag = _between(1, cfg.maxLagDays) * 1 days;
                uint64 presentAt = uint64(block.timestamp + lag - 8 hours);
                if (_chance(cfg.neverPresentBps)) {
                    // Half of the no-shows never present; the other half present days after the hold ran out.
                    presentAt = _chance(5000) ? type(uint64).max : uint64(expiresAt + _between(1, 5) * 1 days);
                }
                buys.push(Buy(ref, uint32(i), amount, expiresAt, presentAt, 0, OPEN));
                ++m.auths;
                m.authValue += amount;
                if (_blocked(i)) ++m.outageAuths;
            } catch (bytes memory reason) {
                _metered("authorize_declined");
                ++m.declines;
                if (_blocked(i)) {
                    ++m.outageDeclines;
                    if (bytes4(reason) == CardAuthBase.SettlementAccountBlocked.selector) {
                        ++m.settlementBlockedDeclines;
                    }
                }
            }
        }
    }

    function _present() internal {
        bool capturing = cfg.weekendCapture || !_weekend();
        for (uint256 k = cursor; k < buys.length; ++k) {
            Buy storage b = buys[k];
            if (b.state == OPEN) {
                if (block.timestamp >= b.expiresAt) {
                    // Anyone may end a purchase once it expired: the cardholder's funds come back.
                    _meter();
                    cards.release(b.ref);
                    _metered("release_expired");
                    if (b.presentAt == type(uint64).max) {
                        b.state = DONE;
                        ++m.noShows;
                    } else {
                        b.state = LAPSED;
                        ++m.lapsed;
                        m.lapsedValue += b.amount;
                        if (drainer[b.holder] && !_blocked(b.holder)) _drain(b.holder);
                    }
                } else if (capturing && block.timestamp >= b.presentAt) {
                    vm.prank(issuer);
                    _meter();
                    try cards.capture(b.ref, b.amount, true) {
                        _metered("capture");
                        b.state = CAPTURED;
                        paidBy[b.holder] += b.amount;
                        ++m.captures;
                        if (_blocked(b.holder)) ++m.frozenHolderCaptures;
                        if (_chance(cfg.refundBps)) b.refundAt = uint64(block.timestamp + 2 days);
                    } catch {
                        _metered("capture_failed");
                        ++m.captureFails;
                    }
                }
            }
            if (b.state == LAPSED && !_blocked(b.holder) && block.timestamp >= b.presentAt) _lateCharge(b);
            if (b.state == CAPTURED && b.refundAt != 0 && block.timestamp >= b.refundAt) _refund(b);
        }
        while (cursor < buys.length && _final(buys[cursor])) {
            ++cursor;
        }
    }

    /// @dev The network still presents a lapsed purchase: a late charge on it, from free cash, the issuer absorbing
    ///      what the cardholder no longer holds.
    function _lateCharge(Buy storage b) internal {
        vm.prank(issuer);
        _meter();
        try cards.charge(cardIds[b.holder], b.ref, b.amount, merchants[b.holder % 8]) {
            _metered("late_charge");
            uint256 absorbed = cards.purchaseOf(b.ref).refunded;
            m.absorbed += absorbed;
            if (absorbed != 0) ++m.absorbedCount;
            m.lateCoveredValue += b.amount - absorbed;
            paidBy[b.holder] += b.amount - absorbed;
            ++m.lateCharged;
            b.state = CHARGED;
        } catch (bytes memory reason) {
            _metered("late_charge_failed");
            if (switched && bytes4(reason) == CardLegs.Unsettled.selector) {
                // Booked before the switch: only a force post under a new reference can collect it now.
                b.state = ORPHANED;
                ++m.orphaned;
                m.orphanedValue += b.amount;
            } else {
                ++m.lateChargeFails;
            }
        }
    }

    function _refund(Buy storage b) internal {
        uint64 back = b.amount / 2;
        vm.prank(issuer);
        try cards.refund(b.ref, back) {
            refundedTo[b.holder] += back;
            ++m.refunds;
            m.refundValue += back;
            b.state = DONE;
        } catch {
            ++m.refundFails;
        }
    }

    function _drain(uint256 i) internal {
        uint256 free = usd.balanceOf(holders[i]);
        if (free == 0) return;
        vm.prank(holders[i]);
        usd.transfer(elsewhere, free);
        spentElsewhere[i] += free;
    }

    function _final(Buy storage b) internal view returns (bool) {
        return b.state == CHARGED || b.state == DONE || b.state == ORPHANED || (b.state == CAPTURED && b.refundAt == 0);
    }

    /// @dev The issuer settles with the network off chain each business day and acknowledges it; in MODE_SWITCH it
    ///      then tries the switch.
    function _settle(uint256 day) internal {
        if (_weekend() && cfg.mode != MODE_SWITCH) return;
        (uint64 seq, uint64 through,,) = cards.ledger();
        if (seq != through) {
            vm.prank(issuer);
            cards.acknowledgeSettlement(seq);
        }
        if (cfg.mode == MODE_SWITCH && !switched && block.timestamp >= cfg.outageFrom) _trySwitch(day);
    }

    function _trySwitch(uint256 day) internal {
        ++m.switchAttempts;
        try cards.setSettlementToken(address(eur), 1e18) {
            switched = true;
            m.switchDay = day;
            m.drainHours = (block.timestamp - (cfg.outageUntil - 8 hours)) / 1 hours;
        } catch {
            ++m.switchFails;
        }
    }

    function _offCard() internal {
        bool payday = _dow() == 0;
        for (uint256 i; i < holders.length; ++i) {
            if (_blocked(i)) continue;
            if (payday && !switched) {
                _mintUsd(holders[i], 300e6);
                givenTo[i] += 300e6;
            }
            if (outage || !_chance(500)) continue;
            uint256 spend = usd.balanceOf(holders[i]) * 7 / 10;
            if (spend == 0) continue;
            vm.prank(holders[i]);
            usd.transfer(elsewhere, spend);
            spentElsewhere[i] += spend;
        }
    }

    function _check() internal {
        _checkConservation();
        for (uint256 i; i < holders.length; ++i) {
            uint256 has = usd.balanceOf(holders[i]) + core.reserved(holders[i], address(usd));
            assertEq(
                has,
                START_BALANCE + givenTo[i] + refundedTo[i] - paidBy[i] - spentElsewhere[i],
                "cardholder pays exactly what it was charged"
            );
        }
    }

    function _measureUnsettled() internal {
        (,, uint256 unsettled) = cards.exposure();
        m.maxUnsettled = _max(m.maxUnsettled, unsettled);
    }

    function _measure(uint256 day) internal {
        (uint256 held,,) = cards.exposure();
        m.maxHeld = _max(m.maxHeld, held);
        uint256 backlog;
        for (uint256 k = cursor; k < buys.length; ++k) {
            Buy storage b = buys[k];
            if ((b.state == OPEN && block.timestamp >= b.presentAt) || b.state == LAPSED) ++backlog;
        }
        m.maxBacklog = _max(m.maxBacklog, backlog);
        if (cfg.outageUntil != 0 && block.timestamp >= cfg.outageUntil && backlog == 0 && m.recoveryDay == 0) {
            m.recoveryDay = day + 1;
        }
    }

    function _report(string memory t, uint256 outageDays) internal view {
        _log(t, "holders", holders.length);
        _log(t, "outage_days", outageDays);
        _log(t, "auths", m.auths);
        _log(t, "auth_value_usd", m.authValue / 1e6);
        _log(t, "declines", m.declines);
        _log(t, "outage_auths", m.outageAuths);
        _log(t, "outage_declines", m.outageDeclines);
        _log(t, "outage_declines_settlement_blocked", m.settlementBlockedDeclines);
        _log(t, "captures", m.captures);
        _log(t, "frozen_holder_captures", m.frozenHolderCaptures);
        _log(t, "capture_fails", m.captureFails);
        _log(t, "no_shows_released", m.noShows);
        _log(t, "lapsed", m.lapsed);
        _log(t, "lapsed_value_usd", m.lapsedValue / 1e6);
        _log(t, "late_charged", m.lateCharged);
        _log(t, "late_charge_fails", m.lateChargeFails);
        _log(t, "late_covered_usd", m.lateCoveredValue / 1e6);
        _log(t, "issuer_absorbed_usd", m.absorbed / 1e6);
        _log(t, "issuer_absorbed_count", m.absorbedCount);
        _log(t, "issuer_absorbed_bps_of_volume", m.authValue == 0 ? 0 : m.absorbed * 10_000 / m.authValue);
        _log(t, "refunds", m.refunds);
        _log(t, "refund_fails", m.refundFails);
        _log(t, "max_held_usd", m.maxHeld / 1e6);
        _log(t, "max_unsettled_usd", m.maxUnsettled / 1e6);
        _log(t, "max_backlog", m.maxBacklog);
        _log(t, "recovery_day", m.recoveryDay);
        if (cfg.mode == MODE_SWITCH) {
            _log(t, "switch_attempts", m.switchAttempts);
            _log(t, "switch_fails", m.switchFails);
            _log(t, "switch_day", m.switchDay);
            _log(t, "drain_hours", m.drainHours);
            _log(t, "drain_declined_usd", m.drainDeclinedValue / 1e6);
            _log(t, "orphaned_late_presentments", m.orphaned);
            _log(t, "orphaned_value_usd", m.orphanedValue / 1e6);
        }
        _log(t, "invariant_checks", checks);
        _reportGas(t, "authorize");
        _reportGas(t, "authorize_declined");
        _reportGas(t, "capture");
        _reportGas(t, "capture_failed");
        _reportGas(t, "release_expired");
        _reportGas(t, "late_charge");
        _reportGas(t, "late_charge_failed");
    }
}
