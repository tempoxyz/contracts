// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CreditSource } from "../../../src/programs/CreditSource.sol";
import { CompEnv } from "../harness/CompStubs.sol";
import { console } from "forge-std/console.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

/// @notice A year of secured credit lines with defaults: dozens of borrowers draw weekly on lines secured by Earn
///         shares at 50-80% loan-to-value, accrue simple interest, get monthly statements collected weekly through
///         autopay until paid, and 10-30% of them default (moving their free money and shares away); the rest keep
///         earning after the year and pay down what they owe. The collateral's price falls 20-50% in two steps; the
///         lender liquidates every week and charges off lines with a statement unpaid past the grace period. After
///         every week: usd is conserved over every party, the core holds exactly what it reserves, a liquidation or
///         charge-off pays the lender at most what is owed and the borrower the surplus, and no borrower pays more
///         than it drew plus simple interest on it.
contract CreditDefaultsStressTest is CompEnv {
    uint256 internal constant YEAR = 365 days;

    struct Borrower {
        address who;
        uint64 lineId;
        uint16 ltvBps;
        uint16 aprBps;
        uint32 defaultWeek;
        bool defaulted;
        uint128 drawn;
        uint128 paid;
        uint128 surplus;
        uint32 liquidations;
        uint32 firstDraw;
    }

    struct Cfg {
        uint256 borrowers;
        uint256 weeks_;
        uint256 tailWeeks;
        uint256 defaultBps;
        uint256 firstDropWeek;
        uint256 firstDropBps;
        uint256 secondDropWeek;
        uint256 totalDropBps;
        // Weeks in which nobody collects, relocks or liquidates (a keeper outage), from outageFrom.
        uint256 outageFrom;
        uint256 outageWeeks;
        // The keeper renews locks that fall due each day; otherwise it only acts on the weekly run.
        bool dailyRelock;
        // Days between runs of a keeper on its own schedule, each of which relocks what is due, collects, liquidates
        // and charges off every line; zero runs collect, liquidate and charge-off with each week instead.
        uint256 keeperDays;
    }

    struct Metrics {
        uint256 draws;
        uint256 drawValue;
        uint256 drawRefusals;
        uint256 statements;
        uint256 statementRefusals;
        uint256 pastDue;
        uint256 collected;
        uint256 liquidations;
        uint256 liquidationsPerforming;
        uint256 saleProceeds;
        uint256 lenderFromSales;
        uint256 surplusToBorrowers;
        uint256 interestAccrued;
        uint256 maxOwed;
        uint256 maxUndercollateralized;
        uint256 lastLiquidationWeek;
        uint256 withdrawnAfterLapse;
        uint256 relocks;
        uint256 lapsedRelocks;
        uint256 chargeOffs;
        uint256 chargeOffsPerforming;
        uint256 chargeOffProceeds;
        uint256 lenderFromChargeOffs;
        uint256 surplusFromChargeOffs;
        uint256 chargeOffShort;
        uint256 keeperRuns;
        uint256 keeperRenewals;
        uint256 lapsedLocks;
    }

    Borrower[] internal bs;
    Cfg internal cfg;
    Metrics internal m;
    uint256 private _seed;
    uint256 internal week;
    uint256 internal nextKeeperAt;
    bytes4 internal lastRevert;

    address internal gone = makeAddr("gone");
    address internal dead = address(0xdead);
    address[] internal tracked;
    uint256 internal expectedUsd;

    function setUp() public {
        _deployComp();
        vm.warp(1_767_225_600); // 2026-01-01
        tracked.push(lender);
        tracked.push(settlement);
        tracked.push(address(credit));
        tracked.push(address(core));
        tracked.push(address(auth));
        tracked.push(address(venue));
        tracked.push(address(earnVault));
        tracked.push(gone);
        tracked.push(dead);
        tracked.push(address(this));
    }

    /// @notice 60 borrowers (times STRESS_SCALE), 20% default over the year, the collateral falls 20% in week 20
    ///         and 50% in all by week 36 (STRESS_DROP_BPS to change it); 26 weeks of tail after the year.
    function test_stress_defaultsWithCollateralCrash() public {
        string memory t = "creditCrash";
        _configure(60, vm.envOr("STRESS_DEFAULT_BPS", uint256(2000)), vm.envOr("STRESS_DROP_BPS", uint256(5000)));
        _run(keccak256("credit-crash"));
        _report(t);
        assertGt(m.liquidations, 0, "the lender liquidated");
        assertEq(m.chargeOffsPerforming, 0, "only defaulted lines are charged off");
        (uint256 loss,,) = _losses();
        assertGt(loss, 0, "past the loan-to-value, the lender loses what the collateral no longer covers");
    }

    /// @notice Same year at stable prices: defaulted borrowers' collateral covers their debt at its loan-to-value,
    ///         so liquidation only trims the interest that pushes a line past its ratio. Once a defaulted line's
    ///         statement is CHARGE_OFF_GRACE past due, the lender charges it off and sells locked shares worth what it
    ///         owes, so by the end of the tail no defaulted principal is left owed against locked collateral. A
    ///         borrower who never defaults but misses a collection pays the past-due statement through a later
    ///         collection once its paycheck lands, so only defaulted lines are charged off.
    function test_stress_defaultsAtStablePrices_chargedOff() public {
        string memory t = "creditStable";
        _configure(60, 2000, 0);
        _run(keccak256("credit-stable"));
        _report(t);
        (uint256 loss, uint256 stuck, uint256 stuckLines) = _losses();
        assertEq(loss, 0, "the collateral covers every defaulted line");
        assertGt(m.chargeOffs, 0, "the lender charged defaulted lines off");
        assertEq(m.chargeOffsPerforming, 0, "a later collection pays what a borrower who never defaults missed");
        assertEq(stuck, 0, "no defaulted principal stays owed against locked collateral");
        assertEq(stuckLines, 0);
    }

    /// @notice The same year at stable prices with a keeper that only runs weekly: each run relocks the locks in their
    ///         renewal window, then collects, liquidates and charges off. A lock renews for a full term whenever it is
    ///         touched in the last RENEW_WINDOW of its 30-day term, which every weekly run reaches at least twice, so
    ///         the runs renew the locks of borrowers who stopped drawing, none lapses and the lender loses nothing.
    function test_stress_weeklyKeeperKeepsLocks() public {
        string memory t = "creditWeeklyKeeper";
        _configure(60, 2000, 0);
        cfg.dailyRelock = false;
        cfg.keeperDays = 7;
        _run(keccak256("credit-stable"));
        _report(t);
        (uint256 loss, uint256 stuck,) = _losses();
        assertGt(m.keeperRenewals, 0, "the weekly runs renewed locks");
        assertEq(m.lapsedLocks, 0, "no lock lapsed");
        assertEq(m.withdrawnAfterLapse, 0, "no lock lapsed for a defaulted borrower to withdraw");
        assertEq(loss, 0, "the lender lost nothing at stable prices");
        assertEq(stuck, 0, "defaulted lines were charged off");
        assertEq(m.chargeOffsPerforming, 0, "only defaulted lines are charged off");
    }

    /// @notice A weekly keeper that misses every other run, so it runs every 14 days, inside RENEW_WINDOW. Whenever a
    ///         draw last renewed a lock, some run falls in the last RENEW_WINDOW of its term and renews it, so locks
    ///         never lapse and the lender loses nothing at stable prices.
    function test_stress_keeperEvery14DaysKeepsLocks() public {
        string memory t = "creditKeeper14Days";
        _configure(60, 2000, 0);
        cfg.dailyRelock = false;
        cfg.keeperDays = 14;
        _run(keccak256("credit-stable"));
        _report(t);
        (uint256 loss, uint256 stuck,) = _losses();
        assertGt(m.keeperRenewals, 0, "the keeper's runs renewed locks");
        assertEq(m.lapsedLocks, 0, "a run every 14 days renews every lock before it lapses");
        assertEq(m.withdrawnAfterLapse, 0, "no defaulted borrower withdrew collateral");
        assertEq(loss, 0, "the lender lost nothing at stable prices");
        assertEq(stuck, 0, "defaulted lines were charged off");
        assertEq(m.chargeOffsPerforming, 0, "only defaulted lines are charged off");
    }

    /// @notice A keeper that runs only every 20 days, past RENEW_WINDOW but inside the 30-day term. A lock a draw
    ///         renewed shortly before a run is still outside its renewal window at that run and lapses before the next
    ///         one, so a keeper keeps every lock only while it runs at least once per RENEW_WINDOW, not once per term.
    ///         The keeper takes each lapsed lock over again on its next run, and the lender loses at most what
    ///         defaulted borrowers withdrew while their locks were lapsed.
    function test_stress_keeperEvery20DaysLetsLocksLapse() public {
        string memory t = "creditKeeper20Days";
        _configure(60, 2000, 0);
        cfg.dailyRelock = false;
        cfg.keeperDays = 20;
        _run(keccak256("credit-stable"));
        _report(t);
        (uint256 loss,,) = _losses();
        assertGt(m.keeperRenewals, 0, "the keeper's runs renewed locks");
        assertGt(m.lapsedLocks, 0, "locks renewed between runs lapsed before the next one");
        assertGt(m.lapsedRelocks, 0, "the keeper took lapsed locks over again");
        assertEq(_performingLoss(), 0, "every loss sits on a defaulted line");
        assertLe(loss, m.withdrawnAfterLapse, "the lender loses at most what defaulted borrowers withdrew");
        assertEq(m.chargeOffsPerforming, 0, "only defaulted lines are charged off");
    }

    /// @notice A keeper that runs only every 40 days, longer than the 30-day term. Locks of borrowers who stopped
    ///         drawing lapse between runs: defaulted borrowers move their shares away at once and the lender is left
    ///         unsecured on those lines, while the keeper takes performing borrowers' lapsed locks over again on its
    ///         next run, so every loss sits on a defaulted line.
    function test_stress_keeperSlowerThanLockTerm() public {
        string memory t = "creditKeeper40Days";
        _configure(60, 2000, 0);
        cfg.dailyRelock = false;
        cfg.keeperDays = 40;
        _run(keccak256("credit-stable"));
        _report(t);
        (uint256 loss,,) = _losses();
        assertGt(m.lapsedLocks, 0, "locks lapsed between runs");
        assertGt(m.withdrawnAfterLapse, 0, "defaulted borrowers withdrew collateral whose lock lapsed");
        assertGt(m.lapsedRelocks, 0, "the keeper took lapsed locks over again");
        assertGt(loss, 0, "the lender lost what lapsed locks no longer secured");
        assertEq(_performingLoss(), 0, "every loss sits on a defaulted line");
        assertLe(loss, m.withdrawnAfterLapse, "the lender loses at most what defaulted borrowers withdrew");
        assertEq(m.chargeOffsPerforming, 0, "only defaulted lines are charged off");
    }

    /// @notice A keeper outage longer than the 30-day lock term: nobody collects, relocks, liquidates or charges off
    ///         for 6 weeks right after the first price drop. Locks lapse, defaulted borrowers move their shares away
    ///         at once, and the lender is left unsecured on those; performing borrowers' lapsed locks are taken over
    ///         again when the keeper returns.
    function test_stress_lockLapsesDuringKeeperOutage() public {
        string memory t = "creditLockLapse";
        _configure(60, 2000, 3000);
        cfg.outageFrom = 21;
        cfg.outageWeeks = 6;
        _run(keccak256("credit-lapse"));
        _report(t);
        assertGt(m.withdrawnAfterLapse, 0, "defaulted borrowers withdrew collateral whose lock lapsed");
        assertGt(m.lapsedRelocks, 0, "the keeper took lapsed locks over again");
        // Collections missed during the outage are paid once the keeper returns.
        assertEq(m.chargeOffsPerforming, 0, "only defaulted lines are charged off");
    }

    /// @notice Fuzzed default rate (10-30%), price fall (20-50%) and seed over a smaller book; every weekly invariant
    ///         holds, and the lender only loses on lines whose collateral was sold out.
    /// forge-config: default.fuzz.runs = 8
    /// forge-config: ci.fuzz.runs = 4
    function testFuzz_stress_creditDefaults(uint256 defaultBps, uint256 dropBps, bytes32 seed) public {
        defaultBps = bound(defaultBps, 1000, 3000);
        dropBps = bound(dropBps, 2000, 5000);
        _configure(16, defaultBps, dropBps);
        cfg.weeks_ = 40;
        cfg.tailWeeks = 12;
        cfg.secondDropWeek = 30;
        _run(seed);
        for (uint256 i; i < bs.length; ++i) {
            Borrower storage b = bs[i];
            uint256 owed = credit.owedNow(b.lineId);
            uint256 locked = credit.lockedShares(b.lineId);
            uint256 value = locked == 0 ? 0 : earnVault.previewRedeem(locked);
            // A line still owing more than its collateral is worth was sold down to its last few units.
            if (owed > value + 2) assertLe(value, 2, "lender loses only once the collateral is sold out");
        }
    }

    // Setup.

    function _configure(uint256 n, uint256 defaultBps, uint256 dropBps) internal {
        uint256 scale = vm.envOr("STRESS_SCALE", uint256(1));
        cfg = Cfg({
            borrowers: n * (scale == 0 ? 1 : scale),
            weeks_: 52,
            tailWeeks: 26,
            defaultBps: defaultBps,
            firstDropWeek: 20,
            firstDropBps: dropBps < 2000 ? dropBps : 2000,
            secondDropWeek: 36,
            totalDropBps: dropBps,
            outageFrom: 0,
            outageWeeks: 0,
            dailyRelock: true,
            keeperDays: 0
        });
    }

    function _open() internal {
        usd.mint(lender, 0);
        vm.prank(lender);
        core.approveHolder(address(credit), address(usd), type(uint128).max, 0);
        uint16[4] memory ltvs = [uint16(5000), 6000, 7000, 8000];
        for (uint256 i; i < cfg.borrowers; ++i) {
            address who = makeAddr(string.concat("borrower-", vm.toString(i)));
            uint128 limit = uint128(_between(1000, 5000) * 1e6);
            uint16 ltv = ltvs[i % 4];
            uint16 apr = uint16(_between(800, 2500));
            _mint(lender, limit);
            vm.prank(lender);
            uint64 lineId = credit.openLine(
                who, limit, uint64(block.timestamp + 400 days), IEarnVault(address(earnVault)), ltv, apr, 0
            );
            _accept(who, lineId);
            // Collateral worth 120% of what the line needs at its ratio.
            uint256 collateral = uint256(limit) * 10_000 / ltv * 12 / 10;
            _mint(who, collateral);
            _depositEarn(who, collateral);
            tracked.push(who);
            address[] memory sources = new address[](1);
            sources[0] = address(usd);
            vm.startPrank(who);
            core.approveHolder(address(credit), address(earnShare), type(uint128).max, 0);
            credit.enableLocking(lineId);
            credit.setAutopay(lineId, sources);
            usd.approve(address(credit), type(uint256).max);
            vm.stopPrank();
            uint32 defaultWeek = _chance(cfg.defaultBps) ? uint32(_between(8, cfg.weeks_ - 4)) : type(uint32).max;
            bs.push(Borrower(who, lineId, ltv, apr, defaultWeek, false, 0, 0, 0, 0, 0));
        }
        expectedUsd = _sumTracked();
    }

    // Engine.

    function _run(bytes32 seed) internal {
        vm.pauseGasMetering();
        _seed = uint256(seed);
        _open();
        // A keeper on its own schedule first runs half a day past a whole number of days, after that day's paychecks.
        nextKeeperAt = block.timestamp + cfg.keeperDays * 1 days + 12 hours;
        for (week = 1; week <= cfg.weeks_ + cfg.tailWeeks; ++week) {
            bool trading = week <= cfg.weeks_;
            bool keeper = !(week >= cfg.outageFrom && week < cfg.outageFrom + cfg.outageWeeks);
            // A daily keeper looks twice a day for locks to renew or take over.
            for (uint256 h; h < 14; ++h) {
                vm.warp(block.timestamp + 12 hours);
                if (keeper && cfg.dailyRelock) _relockDue();
                // A keeper on its own schedule runs whenever its next run falls due.
                if (cfg.keeperDays != 0 && block.timestamp >= nextKeeperAt) {
                    if (keeper) _keeperRun();
                    nextKeeperAt += cfg.keeperDays * 1 days;
                }
            }
            _price();
            for (uint256 i; i < bs.length; ++i) {
                Borrower storage b = bs[i];
                if (!b.defaulted && week >= b.defaultWeek) _default(b);
                if (b.defaulted) _sweepLapsed(b);
                if (!b.defaulted) _live(b, i, trading);
                if (trading && week % 4 == 0) _statement(b);
                if (keeper && cfg.keeperDays == 0) {
                    _collect(b);
                    _liquidate(b);
                    _chargeOff(b);
                }
                m.maxOwed = _max(m.maxOwed, credit.lineOf(b.lineId).owed);
            }
            if (keeper && cfg.keeperDays == 0) ++m.keeperRuns;
            _check();
        }
    }

    /// @dev One keeper run over every line, between the weekly steps.
    function _keeperRun() internal {
        ++m.keeperRuns;
        for (uint256 i; i < bs.length; ++i) {
            _keep(bs[i]);
            m.maxOwed = _max(m.maxOwed, credit.lineOf(bs[i].lineId).owed);
        }
        _check();
    }

    /// @dev The keeper relocks one line when its lock is in its renewal window or lapsed while it owes anything, then
    ///      collects, liquidates and charges it off, and counts what that did to its lock: renewed it for a full term,
    ///      or found it lapsed and took it over again.
    function _keep(Borrower storage b) internal {
        (uint64 expiresBefore, bool liveBefore, bool lapsedBefore) = _lockState(b);
        bool due = liveBefore && expiresBefore < block.timestamp + credit.RENEW_WINDOW();
        if (due || (lapsedBefore && credit.lineOf(b.lineId).owed != 0)) {
            credit.relock(b.lineId);
            ++m.relocks;
        }
        _collect(b);
        _liquidate(b);
        _chargeOff(b);
        (uint64 expiresAfter, bool liveAfter,) = _lockState(b);
        if (lapsedBefore) {
            ++m.lapsedLocks;
            if (liveAfter) ++m.lapsedRelocks;
        } else if (liveBefore && liveAfter && expiresAfter > expiresBefore) {
            ++m.keeperRenewals;
        }
    }

    /// @dev The line's lock hold: when it expires, whether it is live, and whether it lapsed without anyone ending it.
    function _lockState(Borrower storage b) internal view returns (uint64 expiresAt, bool live, bool lapsed) {
        bytes32 id = credit.lockOf(b.lineId);
        if (id == bytes32(0)) return (0, false, false);
        (address token, uint64 expires) = _hold(b.who, id);
        if (token == address(0)) return (0, false, false);
        return (expires, expires > block.timestamp, expires <= block.timestamp);
    }

    function _hold(address who, bytes32 id) internal view returns (address token, uint64 expiresAt) {
        token = core.getHold(who, address(credit), id).token;
        expiresAt = core.getHold(who, address(credit), id).expiresAt;
    }

    /// @dev The collateral's underlying venue loses assets, dropping the Earn share price for everyone.
    function _price() internal {
        uint256 cut;
        if (week == cfg.firstDropWeek) cut = cfg.firstDropBps;
        if (week == cfg.secondDropWeek && cfg.totalDropBps > cfg.firstDropBps) {
            // From (1 - first) to (1 - total) of the original price.
            cut = (cfg.totalDropBps - cfg.firstDropBps) * 10_000 / (10_000 - cfg.firstDropBps);
        }
        if (cut == 0) return;
        uint256 loss = usd.balanceOf(address(venue)) * cut / 10_000;
        vm.prank(address(venue));
        usd.transfer(dead, loss);
    }

    /// @dev Renews every lock in its renewal window, and takes over a lapsed lock while its line owes anything.
    function _relockDue() internal {
        uint256 window = credit.RENEW_WINDOW();
        for (uint256 i; i < bs.length; ++i) {
            bytes32 id = credit.lockOf(bs[i].lineId);
            if (id == bytes32(0)) continue;
            uint64 expiresAt = core.getHold(bs[i].who, address(credit), id).expiresAt;
            if (expiresAt > block.timestamp && expiresAt < block.timestamp + window) {
                credit.relock(bs[i].lineId);
                ++m.relocks;
                (uint64 renewedTo, bool live,) = _lockState(bs[i]);
                if (live && renewedTo > expiresAt) ++m.keeperRenewals;
            } else if (expiresAt != 0 && expiresAt <= block.timestamp && credit.lineOf(bs[i].lineId).owed != 0) {
                credit.relock(bs[i].lineId);
                ++m.lapsedLocks;
                ++m.lapsedRelocks;
            }
        }
    }

    function _live(Borrower storage b, uint256 i, bool trading) internal {
        // A weekly paycheck that covers what a performing borrower spends; it keeps coming after the year, when the
        // borrower stops spending and pays down what it still owes through autopay.
        _mint(b.who, 120e6);
        if (!trading || !_chance(4000)) return;
        uint256 room = credit.availableCredit(b.lineId);
        uint256 amount = _min(_between(20, 400) * 1e6, room);
        if (amount < 1e6) {
            ++m.drawRefusals;
            return;
        }
        bytes32 leg = keccak256(abi.encode("leg", i, week));
        try auth.hold(credit, b.who, _pos(b.lineId), leg, amount, false) returns (uint256 got) {
            if (got == 0) {
                ++m.drawRefusals;
                return;
            }
            uint128 before = credit.lineOf(b.lineId).owed;
            auth.capture(credit, b.who, leg, got, true, leg);
            uint128 added = credit.lineOf(b.lineId).owed - before;
            assertEq(added, got, "a draw owes what it captured");
            b.drawn += uint128(got);
            if (b.firstDraw == 0) b.firstDraw = uint32(week);
            ++m.draws;
            m.drawValue += got;
        } catch {
            ++m.drawRefusals;
        }
    }

    /// @dev A defaulting borrower moves every free unit and share it has away and never pays again.
    function _default(Borrower storage b) internal {
        b.defaulted = true;
        _moveAway(b);
    }

    function _sweepLapsed(Borrower storage b) internal {
        // Anyone may end a lapsed lock; a defaulted borrower does so at once.
        (,, bool lapsed) = _lockState(b);
        try core.releaseExpired(b.who, address(credit), credit.lockOf(b.lineId)) {
            if (lapsed) ++m.lapsedLocks;
        } catch { }
        uint256 shares = earnShare.balanceOf(b.who);
        if (shares != 0) m.withdrawnAfterLapse += earnVault.previewRedeem(shares);
        _moveAway(b);
    }

    function _moveAway(Borrower storage b) internal {
        uint256 cash = usd.balanceOf(b.who);
        vm.startPrank(b.who);
        if (cash != 0) usd.transfer(gone, cash);
        uint256 shares = earnShare.balanceOf(b.who);
        if (shares != 0) earnShare.transfer(gone, shares);
        vm.stopPrank();
    }

    function _statement(Borrower storage b) internal {
        if (credit.lineOf(b.lineId).owed == 0) return;
        vm.prank(lender);
        try credit.closeStatement(b.lineId, uint64(block.timestamp + 21 days)) {
            ++m.statements;
        } catch {
            ++m.statementRefusals;
        }
    }

    function _collect(Borrower storage b) internal {
        uint256 lenderBefore = _lenderTotal();
        uint256 borrowerBefore = usd.balanceOf(b.who);
        uint128 owedBefore = credit.lineOf(b.lineId).owed;
        credit.collect(b.lineId);
        uint256 got = borrowerBefore - usd.balanceOf(b.who);
        assertEq(_lenderTotal() - lenderBefore, got, "autopay lands with the lender");
        m.collected += got;
        b.paid += uint128(got);
        // What is owed now is what was owed plus interest less what was paid.
        m.interestAccrued += credit.lineOf(b.lineId).owed + got - owedBefore;
    }

    /// @dev The lender's free and committed balance: commitments renewing move between the two.
    function _lenderTotal() internal view returns (uint256) {
        return usd.balanceOf(lender) + core.reserved(lender, address(usd));
    }

    function _liquidate(Borrower storage b) internal {
        uint256 owedNow = credit.owedNow(b.lineId);
        uint128 owedBefore = credit.lineOf(b.lineId).owed;
        uint256 lenderBefore = _lenderTotal();
        uint256 borrowerBefore = usd.balanceOf(b.who);
        vm.prank(lender);
        try credit.liquidate(b.lineId) returns (uint128, uint256 assets) {
            uint256 toLender = _lenderTotal() - lenderBefore;
            uint256 toBorrower = usd.balanceOf(b.who) - borrowerBefore;
            assertEq(toLender + toBorrower, assets, "the sale's proceeds all land");
            assertLe(toLender, owedNow, "the lender takes at most what is owed");
            if (toBorrower != 0) assertEq(credit.lineOf(b.lineId).owed, 0, "surplus only once the debt is paid");
            m.interestAccrued += credit.lineOf(b.lineId).owed + toLender - owedBefore;
            ++m.liquidations;
            ++b.liquidations;
            if (!b.defaulted) ++m.liquidationsPerforming;
            m.saleProceeds += assets;
            m.lenderFromSales += toLender;
            m.surplusToBorrowers += toBorrower;
            b.paid += uint128(toLender);
            b.surplus += uint128(toBorrower);
            m.lastLiquidationWeek = week;
            // A defaulted borrower's surplus goes the way the rest of its money went.
            if (b.defaulted) _moveAway(b);
        } catch (bytes memory reason) {
            if (bytes4(reason) != CreditSource.NotUndercollateralized.selector) {
                ++m.maxUndercollateralized;
                lastRevert = bytes4(reason);
            }
        }
    }

    /// @dev The lender charges off a line once a statement is CHARGE_OFF_GRACE past due.
    function _chargeOff(Borrower storage b) internal {
        uint256 at = credit.chargeableAt(b.lineId);
        if (at == 0 || block.timestamp < at) return;
        uint256 owedNow = credit.owedNow(b.lineId);
        uint128 owedBefore = credit.lineOf(b.lineId).owed;
        uint256 lenderBefore = _lenderTotal();
        uint256 borrowerBefore = usd.balanceOf(b.who);
        vm.prank(lender);
        try credit.chargeOff(b.lineId) returns (uint128, uint256 assets) {
            uint256 toLender = _lenderTotal() - lenderBefore;
            uint256 toBorrower = usd.balanceOf(b.who) - borrowerBefore;
            uint128 left = credit.lineOf(b.lineId).owed;
            assertEq(toLender + toBorrower, assets, "the sale's proceeds all land");
            assertEq(toLender, owedNow - left, "the lender takes what the line no longer owes");
            if (toBorrower != 0) assertEq(left, 0, "surplus only once the debt is paid");
            if (left != 0) assertEq(credit.lockedShares(b.lineId), 0, "a short sale sells every locked share");
            assertTrue(credit.lineOf(b.lineId).closed, "a charged-off line is closed");
            m.interestAccrued += left + toLender - owedBefore;
            ++m.chargeOffs;
            if (!b.defaulted) ++m.chargeOffsPerforming;
            if (left != 0) ++m.chargeOffShort;
            m.chargeOffProceeds += assets;
            m.lenderFromChargeOffs += toLender;
            m.surplusFromChargeOffs += toBorrower;
            b.paid += uint128(toLender);
            b.surplus += uint128(toBorrower);
            if (b.defaulted) _moveAway(b);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), CreditSource.NothingToSell.selector, "charge-off refused only with nothing locked");
        }
    }

    // Invariants.

    function _check() internal {
        assertEq(_sumTracked(), expectedUsd, "usd conserved");
        _assertCoreBalanced();
        assertEq(usd.balanceOf(address(credit)), 0, "the credit source keeps nothing");
        for (uint256 i; i < bs.length; ++i) {
            Borrower storage b = bs[i];
            uint256 owed = credit.lineOf(b.lineId).owed;
            // Simple interest on everything drawn since the first draw bounds what a borrower pays and still owes.
            uint256 elapsed = b.firstDraw == 0 ? 0 : (week - b.firstDraw + 1) * 7 days;
            uint256 bound = uint256(b.drawn) + uint256(b.drawn) * b.aprBps * elapsed / (YEAR * 10_000) + 1;
            assertLe(b.paid + owed, bound, "never pays more than drawn plus simple interest");
        }
    }

    function _sumTracked() internal view returns (uint256 total) {
        for (uint256 i; i < tracked.length; ++i) {
            total += usd.balanceOf(tracked[i]);
        }
    }

    function _mint(address to, uint256 amount) internal {
        usd.mint(to, amount);
        expectedUsd += amount;
    }

    /// @dev Unrecoverable: owed on lines with no collateral left. Stuck: owed on defaulted lines whose collateral
    ///      covers it, which the lender has not yet charged off.
    function _losses() internal view returns (uint256 loss, uint256 stuck, uint256 stuckLines) {
        for (uint256 i; i < bs.length; ++i) {
            Borrower storage b = bs[i];
            uint256 owed = credit.owedNow(b.lineId);
            if (owed == 0) continue;
            uint256 locked = credit.lockedShares(b.lineId);
            uint256 value = locked == 0 ? 0 : earnVault.previewRedeem(locked);
            if (value < owed) loss += owed - value;
            if (b.defaulted && value >= owed) {
                stuck += owed;
                ++stuckLines;
            }
        }
    }

    /// @dev Owed past the locked collateral's value on lines whose borrower never defaulted.
    function _performingLoss() internal view returns (uint256 loss) {
        for (uint256 i; i < bs.length; ++i) {
            Borrower storage b = bs[i];
            if (b.defaulted) continue;
            uint256 owed = credit.owedNow(b.lineId);
            uint256 locked = credit.lockedShares(b.lineId);
            uint256 value = locked == 0 ? 0 : earnVault.previewRedeem(locked);
            if (value < owed) loss += owed - value;
        }
    }

    // Output.

    function _report(string memory t) internal view {
        (uint256 loss, uint256 stuck, uint256 stuckLines) = _losses();
        uint256 defaulted;
        uint256 defaultedDrawn;
        uint256 defaultedPaid;
        uint256 surplusDefaulted;
        for (uint256 i; i < bs.length; ++i) {
            if (!bs[i].defaulted) continue;
            ++defaulted;
            defaultedDrawn += bs[i].drawn;
            defaultedPaid += bs[i].paid;
            surplusDefaulted += bs[i].surplus;
        }
        _log(t, "borrowers", bs.length);
        _log(t, "defaulted", defaulted);
        _log(t, "price_drop_bps", cfg.totalDropBps);
        _log(t, "draws", m.draws);
        _log(t, "draw_value_usd", m.drawValue / 1e6);
        _log(t, "draw_refusals", m.drawRefusals);
        _log(t, "statements", m.statements);
        _log(t, "statement_refusals", m.statementRefusals);
        _log(t, "collected_usd", m.collected / 1e6);
        _log(t, "interest_accrued_usd", m.interestAccrued / 1e6);
        _log(t, "liquidations", m.liquidations);
        _log(t, "liquidations_of_performing", m.liquidationsPerforming);
        _log(t, "sale_proceeds_usd", m.saleProceeds / 1e6);
        _log(t, "lender_from_sales_usd", m.lenderFromSales / 1e6);
        _log(t, "surplus_to_borrowers_usd", m.surplusToBorrowers / 1e6);
        _log(t, "defaulted_drawn_usd", defaultedDrawn / 1e6);
        _log(t, "defaulted_recovered_usd", defaultedPaid / 1e6);
        _log(t, "lender_loss_usd", loss / 1e6);
        _log(t, "lender_loss_bps_of_drawn", m.drawValue == 0 ? 0 : loss * 10_000 / m.drawValue);
        _log(t, "stuck_principal_usd", stuck / 1e6);
        _log(t, "stuck_lines", stuckLines);
        _log(t, "max_line_owed_usd", m.maxOwed / 1e6);
        _log(t, "last_liquidation_week", m.lastLiquidationWeek);
        _log(t, "withdrawn_after_lapse_usd", m.withdrawnAfterLapse / 1e6);
        _log(t, "keeper_days", cfg.keeperDays == 0 ? 7 : cfg.keeperDays);
        _log(t, "keeper_runs", m.keeperRuns);
        _log(t, "keeper_renewals", m.keeperRenewals);
        _log(t, "lapsed_locks", m.lapsedLocks);
        _log(t, "lender_loss_performing_usd", _performingLoss() / 1e6);
        _log(t, "keeper_relocks", m.relocks);
        _log(t, "keeper_lapsed_relocks", m.lapsedRelocks);
        _log(t, "charge_offs", m.chargeOffs);
        _log(t, "charge_offs_of_performing", m.chargeOffsPerforming);
        _log(t, "charge_offs_short", m.chargeOffShort);
        _log(t, "charge_off_proceeds_usd", m.chargeOffProceeds / 1e6);
        _log(t, "lender_from_charge_offs_usd", m.lenderFromChargeOffs / 1e6);
        _log(t, "surplus_from_charge_offs_usd", m.surplusFromChargeOffs / 1e6);
        _log(t, "liquidate_other_reverts", m.maxUndercollateralized);
        _log(t, "liquidate_other_revert_selector", uint32(lastRevert));
    }

    function _log(string memory test, string memory metric, uint256 value) internal pure {
        console.log(string.concat("STRESS ", test, " ", metric, "=", vm.toString(value)));
    }

    function _rand() internal returns (uint256) {
        _seed = uint256(keccak256(abi.encode(_seed)));
        return _seed;
    }

    function _between(uint256 lo, uint256 hi) internal returns (uint256) {
        return lo + _rand() % (hi - lo + 1);
    }

    function _chance(uint256 bps) internal returns (bool) {
        return _rand() % 10_000 < bps;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
