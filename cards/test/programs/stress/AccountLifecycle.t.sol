// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { AccountKeys } from "../../../src/programs/AccountKeys.sol";
import { AccountLifecycle } from "../../../src/programs/AccountLifecycle.sol";
import { AdverseBase } from "./AdverseBase.sol";

/// @notice Four years of account lifecycles at scale: active cardholders, accounts that go silent for good and are
///         remitted as unclaimed property, owners who come back (some after their money was remitted), deaths with
///         and without a named executor (some with a purchase still open), lost devices recovered by guardians, and
///         two token pauses during which no payout can move. After every week: usd is conserved over every party, each
///         account holds exactly what it was given less what it paid on its card and what was paid out of it, every
///         payout went to the owner's choice, its executor or the noticed authority, and nothing is left behind once
///         an account is remitted, settled or closed.
contract AccountLifecycleStressTest is AdverseBase {
    uint8 internal constant ACTIVE = 0;
    uint8 internal constant SILENT = 1;
    uint8 internal constant RETURNS = 2;
    uint8 internal constant DIES_NAMED = 3;
    uint8 internal constant DIES_UNNAMED = 4;
    uint8 internal constant LOSES_DEVICE = 5;

    uint64 internal constant DORMANCY = 180 days;
    uint64 internal constant ESCHEAT_AFTER = 3 * 365 days;
    uint256 internal constant START_BALANCE = 2000e6;

    struct Person {
        uint8 kind;
        // The week its event happens: goes silent, returns, dies or loses its device.
        uint32 eventWeek;
        uint32 returnWeek;
        bool happened;
        bool done;
        uint32 doneWeek;
        address executor;
        address phone;
        address guardian;
        uint256 guardianKey;
        address newKey;
        address newWallet;
        bytes32 openRef;
    }

    struct Metrics {
        uint256 auths;
        uint256 authValue;
        uint256 marked;
        uint256 escheated;
        uint256 escheatedValue;
        uint256 escheatPaused;
        uint256 escheatNoNotice;
        uint256 maxEscheatLagWeeks;
        uint256 returned;
        uint256 returnedAfterEscheat;
        uint256 returnedAfterEscheatValue;
        uint256 estates;
        uint256 estateRefusedUnnamed;
        uint256 estatesSettled;
        uint256 estateValue;
        uint256 estateHoldsOpen;
        uint256 estatePaused;
        uint256 estateFrozenExecutor;
        uint256 maxEstateDays;
        uint256 recoveries;
        uint256 recoveredValue;
        uint256 recoveryPaused;
        uint256 maxRecoveryDays;
        uint256 sumRecoveryDays;
        uint256 dormantAtEnd;
        uint256 stuckValue;
    }

    AccountLifecycle internal life;
    AccountKeys internal keys;
    address internal registrar = makeAddr("registrar");
    address internal authority = makeAddr("unclaimed-property");
    address internal elsewhere = makeAddr("elsewhere");
    address[] internal noVaults;

    Person[] internal people;
    Metrics internal m;
    uint256 internal week;
    uint256 internal weeksTotal;
    bool internal paused;
    uint64 internal policy;
    uint256 internal startAt;

    mapping(uint256 => uint256) internal givenTo;
    mapping(uint256 => uint256) internal paidBy;
    mapping(uint256 => uint256) internal paidOut;
    mapping(uint256 => uint64) internal lostAt;

    function setUp() public {
        _setUpAdverse(keccak256("account-lifecycle"));
        keys = new AccountKeys();
        life = new AccountLifecycle(address(usd), registrar, address(keys), DORMANCY, ESCHEAT_AFTER);
        _setting(abi.encodeCall(cards.setCompanions, (address(0), address(0), address(life), address(0))));
        vm.startPrank(registrar);
        life.setProgram(address(cards), true);
        life.setEscheatAuthority(authority);
        vm.stopPrank();
        usd.grantRole(usd.PAUSE_ROLE(), address(this));
        usd.grantRole(usd.UNPAUSE_ROLE(), address(this));
        _track(authority);
        _track(elsewhere);
        policy = _blacklist();
    }

    /// @notice 120 accounts (times STRESS_SCALE) over 4 years with the token paused for 10 days in week 60 and for 14
    ///         days in week 160, and one executor frozen by the token issuer for good.
    function test_stress_massLifecycleWithOutages() public {
        string memory t = "lifecycle";
        _populate(120 * scale);
        _run(4 * 52);
        _report(t);
        assertGt(m.escheated, 0, "silent accounts were remitted");
        assertGt(m.estatesSettled, 0, "estates were settled");
        assertGt(m.recoveries, 0, "lost devices were recovered");
        assertGt(m.estateHoldsOpen, 0, "an estate waited for its last purchase to end");
        assertGt(m.estateRefusedUnnamed, 0, "an estate without a named executor was refused");
        assertEq(m.estateFrozenExecutor, 1, "the frozen executor's estate never pays out");
    }

    /// @notice An owner whose device is lost starts a guardian recovery the day the escheat it was noticed for falls
    ///         due. Current behaviour: the recovery is not activity and the owner cannot act until it completes, so the
    ///         registrar remits the account during the recovery delay.
    function test_stress_escheatLandsDuringRecoveryDelay() public {
        string memory t = "escheatDuringRecovery";
        _populate(1);
        Person storage p = people[0];
        vm.pauseGasMetering();
        address[] memory k = new address[](1);
        k[0] = p.phone;
        address[] memory g = new address[](1);
        g[0] = p.guardian;
        vm.prank(holders[0]);
        keys.configure(holders[0], k, g, 0);
        vm.warp(block.timestamp + ESCHEAT_AFTER);
        life.markDormant(holders[0]);
        vm.warp(block.timestamp + 90 days);
        // The device is lost; the guardians approve a new key.
        _recover(0);
        (, uint64 readyAt) = keys.recoveryOf(holders[0]);
        vm.prank(registrar);
        uint256 paid = life.escheat(holders[0], noVaults);
        vm.warp(readyAt);
        keys.completeRecovery(holders[0]);
        vm.prank(p.newKey);
        life.checkIn(holders[0]);
        _log(t, "escheated_usd", paid / 1e6);
        _log(t, "recovery_delay_hours", keys.RECOVERY_DELAY() / 1 hours);
        _log(t, "owner_left_usd", usd.balanceOf(holders[0]) / 1e6);
        assertEq(paid, START_BALANCE, "remitted while the owner waited out its recovery");
        assertEq(usd.balanceOf(holders[0]), 0);
    }

    // Population.

    function _populate(uint256 n) internal {
        _holders(n, START_BALANCE);
        startAt = block.timestamp;
        for (uint256 i; i < n; ++i) {
            address owner = holders[i];
            vm.startPrank(owner);
            life.enroll();
            usd.approve(address(life), type(uint256).max);
            vm.stopPrank();
            uint256 r = _rand() % 100;
            uint8 kind = r < 45
                ? ACTIVE
                : r < 65 ? SILENT : r < 75 ? RETURNS : r < 87 ? DIES_NAMED : r < 93 ? DIES_UNNAMED : LOSES_DEVICE;
            Person memory p;
            p.kind = kind;
            if (kind == SILENT) p.eventWeek = uint32(_between(1, 20));
            if (kind == RETURNS) {
                p.eventWeek = uint32(_between(1, 20));
                p.returnWeek = uint32(p.eventWeek + _between(30, 190));
            }
            if (kind == DIES_NAMED || kind == DIES_UNNAMED) p.eventWeek = uint32(_between(4, 180));
            if (kind == LOSES_DEVICE) p.eventWeek = uint32(_between(4, 190));
            if (kind == DIES_NAMED) {
                p.executor = makeAddr(string.concat("executor-", vm.toString(i)));
                _track(p.executor);
                vm.prank(owner);
                life.nameExecutor(owner, p.executor);
            }
            p.phone = makeAddr(string.concat("phone-", vm.toString(i)));
            (p.guardian, p.guardianKey) = makeAddrAndKey(string.concat("guardian-", vm.toString(i)));
            p.newKey = makeAddr(string.concat("new-key-", vm.toString(i)));
            p.newWallet = makeAddr(string.concat("new-wallet-", vm.toString(i)));
            if (kind == LOSES_DEVICE) {
                _track(p.newWallet);
                address[] memory k = new address[](1);
                k[0] = p.phone;
                address[] memory g = new address[](1);
                g[0] = p.guardian;
                vm.prank(owner);
                keys.configure(owner, k, g, 0);
            }
            people.push(p);
        }
        // The first executor of a named estate is frozen by the token issuer for good.
        for (uint256 i; i < n; ++i) {
            if (people[i].kind == DIES_NAMED) {
                _freeze(policy, people[i].executor, true);
                break;
            }
        }
    }

    // Engine.

    function _run(uint256 numWeeks) internal {
        vm.pauseGasMetering();
        weeksTotal = numWeeks;
        for (week = 1; week <= numWeeks; ++week) {
            vm.warp(block.timestamp + 7 days);
            _pause(week >= 60 && week < 60 + 2 ? true : week >= 160 && week < 162);
            for (uint256 i; i < people.length; ++i) {
                _live(i);
            }
            _registrar();
            _settle();
            _check();
        }
    }

    function _pause(bool on) internal {
        if (on == paused) return;
        paused = on;
        if (on) usd.pause();
        else usd.unpause();
    }

    function _live(uint256 i) internal {
        Person storage p = people[i];
        address owner = holders[i];
        if (p.done) return;
        bool shops = p.kind == ACTIVE || p.kind == LOSES_DEVICE
            || ((p.kind == DIES_NAMED || p.kind == DIES_UNNAMED) && week < p.eventWeek)
            || ((p.kind == SILENT || p.kind == RETURNS) && week < p.eventWeek)
            || (p.kind == RETURNS && week > p.returnWeek);
        if (p.kind == RETURNS && week == p.returnWeek) _return(i);
        if ((p.kind == DIES_NAMED || p.kind == DIES_UNNAMED) && week == p.eventWeek) _die(i);
        if (p.kind == LOSES_DEVICE && week >= p.eventWeek) {
            _lostDevice(i);
            return;
        }
        if (!shops || paused) return;
        if (week % 4 == 0) {
            _mintUsd(owner, 200e6);
            givenTo[i] += 200e6;
        }
        if (!_chance(5000)) return;
        _buy(i, uint64(_between(5, 80) * 1e6), 7 days, true);
    }

    function _buy(uint256 i, uint64 amount, uint256 term, bool present) internal returns (bytes32 ref) {
        ref = keccak256(abi.encode("buy", i, week, amount));
        vm.prank(issuer);
        try cards.authorize(cardIds[i], ref, amount, merchants[i % 8], uint64(block.timestamp + term), 0) {
            ++m.auths;
            m.authValue += amount;
            if (present) {
                vm.prank(issuer);
                cards.capture(ref, amount, true);
                paidBy[i] += amount;
            }
        } catch {
            ref = bytes32(0);
        }
    }

    function _return(uint256 i) internal {
        ++m.returned;
        bool remitted = life.accountOf(holders[i]).status == AccountLifecycle.Status.Dormant
            && usd.balanceOf(holders[i]) == 0 && paidOut[i] != 0;
        if (remitted) {
            ++m.returnedAfterEscheat;
            m.returnedAfterEscheatValue += paidOut[i];
        }
        vm.prank(holders[i]);
        life.checkIn(holders[i]);
    }

    function _die(uint256 i) internal {
        Person storage p = people[i];
        // A purchase opened the day before, never presented, holding for the longest term a hold may have.
        if (!paused) p.openRef = _buy(i, 50e6, 31 days, false);
        vm.prank(registrar);
        try life.setEstate(holders[i], p.kind == DIES_NAMED ? p.executor : makeAddr("someone")) {
            ++m.estates;
            p.happened = true;
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), AccountLifecycle.NotNamedExecutor.selector);
            ++m.estateRefusedUnnamed;
        }
    }

    function _lostDevice(uint256 i) internal {
        Person storage p = people[i];
        if (!p.happened) {
            p.happened = true;
            lostAt[i] = uint64(block.timestamp);
            _recover(i);
            return;
        }
        (address key,) = keys.recoveryOf(holders[i]);
        if (key != address(0)) keys.completeRecovery(holders[i]);
        vm.prank(p.newKey);
        try life.closeAccount(holders[i], p.newWallet, noVaults) returns (uint256 paid) {
            paidOut[i] += paid;
            ++m.recoveries;
            m.recoveredValue += paid;
            uint256 d = (block.timestamp - lostAt[i]) / 1 days;
            m.maxRecoveryDays = _max(m.maxRecoveryDays, d);
            m.sumRecoveryDays += d;
            p.done = true;
        } catch {
            ++m.recoveryPaused;
        }
    }

    function _recover(uint256 i) internal {
        Person storage p = people[i];
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(p.guardianKey, keys.recoveryDigest(holders[i], p.newKey));
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);
        keys.recover(holders[i], p.newKey, sigs);
    }

    /// @dev Weekly: anyone marks idle accounts dormant, the registrar remits those whose notice ran out, executors
    ///      settle estates past their notice (ending an expired purchase first when one is still open).
    function _registrar() internal {
        for (uint256 i; i < people.length; ++i) {
            Person storage p = people[i];
            address owner = holders[i];
            if (p.done) continue;
            AccountLifecycle.Account memory a = life.accountOf(owner);
            if (a.status == AccountLifecycle.Status.Active && block.timestamp >= a.lastActive + DORMANCY) {
                life.markDormant(owner);
                ++m.marked;
            } else if (a.status == AccountLifecycle.Status.Dormant && a.noticeAt != 0) {
                if (block.timestamp < a.noticeAt + 90 days || block.timestamp < a.lastActive + ESCHEAT_AFTER) continue;
                uint256 due = _max(a.noticeAt + 90 days, a.lastActive + ESCHEAT_AFTER);
                uint256 has = core.available(owner, address(usd));
                vm.prank(registrar);
                try life.escheat(owner, noVaults) returns (uint256 paid) {
                    assertEq(paid, has, "remits everything available");
                    paidOut[i] += paid;
                    ++m.escheated;
                    m.escheatedValue += paid;
                    m.maxEscheatLagWeeks = _max(m.maxEscheatLagWeeks, (block.timestamp - due) / 7 days);
                } catch {
                    ++m.escheatPaused;
                }
            } else if (a.status == AccountLifecycle.Status.Estate && block.timestamp >= a.noticeAt + 30 days) {
                _settleEstate(i, a.noticeAt);
            }
        }
    }

    function _settleEstate(uint256 i, uint64 noticeAt) internal {
        Person storage p = people[i];
        address owner = holders[i];
        uint256 has = core.available(owner, address(usd));
        vm.prank(p.executor);
        try life.settleEstate(owner, noVaults) returns (uint256 paid) {
            assertEq(paid, has, "the executor receives everything available");
            paidOut[i] += paid;
            ++m.estatesSettled;
            m.estateValue += paid;
            m.maxEstateDays = _max(m.maxEstateDays, (block.timestamp - noticeAt) / 1 days);
            p.done = true;
        } catch (bytes memory reason) {
            if (bytes4(reason) == AccountLifecycle.HoldsOpen.selector) {
                ++m.estateHoldsOpen;
                // The open purchase ends once it expired; anyone may release it.
                if (p.openRef != bytes32(0) && block.timestamp >= cards.purchaseOf(p.openRef).expiresAt) {
                    cards.release(p.openRef);
                    p.openRef = bytes32(0);
                }
            } else if (paused) {
                ++m.estatePaused;
            } else if (week == weeksTotal) {
                ++m.estateFrozenExecutor;
            }
        }
    }

    function _settle() internal {
        (uint64 seq, uint64 through,,) = cards.ledger();
        if (seq == through) return;
        vm.prank(issuer);
        cards.acknowledgeSettlement(seq);
    }

    function _check() internal {
        _checkConservation();
        for (uint256 i; i < people.length; ++i) {
            address owner = holders[i];
            uint256 has = usd.balanceOf(owner) + core.reserved(owner, address(usd));
            assertEq(
                has + paidOut[i] + paidBy[i], START_BALANCE + givenTo[i], "every unit of the account accounted for"
            );
            if (people[i].done) assertEq(core.available(owner, address(usd)), 0, "nothing left behind");
        }
    }

    function _report(string memory t) internal {
        for (uint256 i; i < people.length; ++i) {
            AccountLifecycle.Status s = life.statusOf(holders[i]);
            if (s == AccountLifecycle.Status.Dormant) ++m.dormantAtEnd;
            if (s == AccountLifecycle.Status.Estate || (s == AccountLifecycle.Status.Dormant && paidOut[i] == 0)) {
                m.stuckValue += usd.balanceOf(holders[i]);
            }
        }
        _log(t, "accounts", people.length);
        _log(t, "weeks", weeksTotal);
        _log(t, "auths", m.auths);
        _log(t, "auth_value_usd", m.authValue / 1e6);
        _log(t, "marked_dormant", m.marked);
        _log(t, "escheated", m.escheated);
        _log(t, "escheated_usd", m.escheatedValue / 1e6);
        _log(t, "escheat_retries_paused", m.escheatPaused);
        _log(t, "max_escheat_lag_weeks", m.maxEscheatLagWeeks);
        _log(t, "returned", m.returned);
        _log(t, "returned_after_escheat", m.returnedAfterEscheat);
        _log(t, "returned_after_escheat_usd", m.returnedAfterEscheatValue / 1e6);
        _log(t, "estates", m.estates);
        _log(t, "estate_refused_unnamed", m.estateRefusedUnnamed);
        _log(t, "estates_settled", m.estatesSettled);
        _log(t, "estate_usd", m.estateValue / 1e6);
        _log(t, "estate_waits_holds_open", m.estateHoldsOpen);
        _log(t, "estate_retries_paused", m.estatePaused);
        _log(t, "estate_frozen_executor", m.estateFrozenExecutor);
        _log(t, "max_estate_days", m.maxEstateDays);
        _log(t, "recoveries", m.recoveries);
        _log(t, "recovered_usd", m.recoveredValue / 1e6);
        _log(t, "recovery_retries_paused", m.recoveryPaused);
        _log(t, "max_recovery_days", m.maxRecoveryDays);
        _log(t, "avg_recovery_days", m.recoveries == 0 ? 0 : m.sumRecoveryDays / m.recoveries);
        _log(t, "dormant_at_end", m.dormantAtEnd);
        _log(t, "unpaid_dormant_or_estate_usd", m.stuckValue / 1e6);
        _log(t, "invariant_checks", checks);
    }
}
