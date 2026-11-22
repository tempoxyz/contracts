// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardLegs } from "../../../../src/spend/programs/CardLegs.sol";
import { CreditSource } from "../../../../src/spend/programs/CreditSource.sol";
import { ISource } from "../../../../src/interfaces/spend/programs/ISource.sol";
import { FundingBase } from "./FundingBase.sol";
import { IEarnVault } from "../../../../src/interfaces/earn/IEarnVault.sol";

/// @notice Lenders running dry: every cardholder draws a credit line first and falls back to cash. Lender A funds only
///         part of its limits and pulls its free balance every midday from Wednesday until Friday's repayments; lender
///         B stays liquid. Purchases keep capturing past their holds (tips), lines run into their agreed debt bound, and
///         holders repay on Friday. Every step checks conservation, custody, each line's debt bound, each lender's
///         outlay and each holder's cost.
contract FundingCreditStressTest is FundingBase {
    address internal lenderA = makeAddr("lender-a");
    address internal lenderB = makeAddr("lender-b");
    address internal elsewhere = makeAddr("lender-a.elsewhere");

    uint128 internal constant LIMIT = 1500e6;
    uint16 internal constant APR = 1800;

    struct Buy {
        bytes32 ref;
        uint32 holder;
        uint32 dueHour;
        uint8 fate;
        uint128 amount;
    }

    struct Side {
        uint256 auths;
        uint256 declined;
        uint256 creditVolume;
        uint256 cashVolume;
        uint256 creditExceeded;
        uint256 coverableDeclines;
    }

    Buy[] internal buys;
    uint256[] internal pending;
    uint64[] internal lineOfHolder;
    mapping(address lender => uint256) internal lenderIn;

    Side[2][3] internal sides;
    uint256 internal n;
    uint256 internal absorbed;
    uint256 internal absorbedCount;
    uint256 internal pulled;
    uint256 internal repaid;
    uint256 internal maxDebtHits;
    uint256 internal recoveryHour;
    uint256 internal tipVolume;
    uint256 internal tipCreditFree;
    uint256 internal linesUncommitted;
    uint256 internal authGas;
    uint256 internal authCount;

    function setUp() public {
        vm.pauseGasMetering();
        n = 90 * _scale();
        rng = 0xc4ed17;
        tolBps = 2000;
        _world(0);
        parties.push(lenderA);
        parties.push(lenderB);
        parties.push(elsewhere);
        vm.startPrank(issuer);
        credit.setLender(lenderA, true);
        credit.setLender(lenderB, true);
        vm.stopPrank();
        // Lender A holds half its limits; lender B all of them.
        uint256 half = n / 2;
        _fundLender(lenderA, half * LIMIT / 2);
        _fundLender(lenderB, (n - half) * LIMIT);
        for (uint256 i; i < n; ++i) {
            address lender = i < half ? lenderA : lenderB;
            address h = makeAddr(string.concat("holder-", vm.toString(i)));
            // A tight agreed bound: the limit plus 2%, so interest and tips run into it.
            uint128 maxDebt = LIMIT + LIMIT / 50;
            vm.prank(lender);
            uint64 lineId = credit.openLine(h, LIMIT, uint64(START + 120 days), IEarnVault(address(0)), 0, APR, maxDebt);
            vm.prank(h);
            credit.acceptLine(lineId, APR, maxDebt);
            if (credit.availableCredit(lineId) < LIMIT) ++linesUncommitted;
            lineOfHolder.push(lineId);
            CardLegs.Funding[] memory order = new CardLegs.Funding[](2);
            order[0] = CardLegs.Funding(ISource(address(credit)), bytes32(uint256(lineId)));
            order[1] = _cashEntry(address(usd), 0);
            _holder(i, 50e6 + _rand(350e6), order);
            _setTolerance(h, address(cash), address(usd), uint16(tolBps));
            vm.prank(h);
            usd.approve(address(credit), type(uint256).max);
        }
        _seal();
    }

    function _fundLender(address lender, uint256 amount) internal {
        _mint(lender, amount);
        lenderIn[lender] = amount;
        vm.prank(lender);
        core.approveHolder(address(credit), address(usd), type(uint128).max, 0);
    }

    /// @dev A line short of a purchase holds what it can and the cash entry behind it holds the rest, so a purchase
    ///      declines only when the line and cash together fall short. Committed liquidity cannot leave mid-week: lender
    ///      A finds almost nothing free to pull.
    function test_stress_lenderRunsDryMidweek() public {
        vm.pauseGasMetering();
        tag = "credit_lender_dry";
        for (uint256 hr; hr < 10 * 24; ++hr) {
            this.step(hr);
        }
        _drain(10 * 24);
        _report();
        uint256 exceeded;
        uint256 coverable;
        uint256 fallback_;
        for (uint256 p; p < 3; ++p) {
            for (uint256 s_; s_ < 2; ++s_) {
                exceeded += sides[p][s_].creditExceeded;
                coverable += sides[p][s_].coverableDeclines;
            }
            fallback_ += sides[p][0].cashVolume;
        }
        assertEq(exceeded, 0, "a short line declined");
        assertEq(coverable, 0, "declined a purchase the line and cash together could hold");
        // Cash behind lender A's lines pays the part of purchases the lines lack, well past tips.
        assertGt(fallback_, tipVolume, "cash did not cover what the lines lacked");
        assertLt(pulled, LIMIT / 100, "committed liquidity left mid-week");
    }

    /// @dev What the funding order promises: a line with $100 of credit left and $300 in cash behind it approves a
    ///      $200 purchase, $100 from each.
    function test_creditFirst_shortLineFallsBackToCash() public {
        vm.pauseGasMetering();
        uint256 i = n / 2;
        address h = holders[i];
        uint64 lineId = lineOfHolder[i];
        // Draw the line down to $100 of credit.
        bytes32 big = keccak256("draw-down");
        (uint256 got,,) = _try(h, cardIds[i], big, LIMIT - 100e6, 0);
        assertEq(got, LIMIT - 100e6);
        _book(h, big, LIMIT - 100e6);
        assertEq(credit.availableCredit(lineId), 100e6);
        _mint(h, 300e6);
        uint256 cashBefore = core.available(h, address(usd));
        bytes32 ref = keccak256("short-line");
        (uint256 approved, bytes4 err,) = _try(h, cardIds[i], ref, 200e6, 0);
        assertEq(err, bytes4(0));
        assertEq(approved, 200e6, "credit then cash should approve the purchase");
        assertEq(credit.availableCredit(lineId), 0, "line held what it had");
        assertEq(core.available(h, address(usd)), cashBefore - 100e6, "cash held the rest");
        uint256 owedBefore = credit.owedNow(lineId);
        (bool ok, uint256 covered,) = _book(h, ref, 200e6);
        assertTrue(ok);
        assertEq(covered, 200e6);
        assertEq(credit.owedNow(lineId), owedBefore + 100e6, "line paid its part");
    }

    // Simulation.

    /// @dev One simulated hour, as its own call so memory does not grow across the run.
    function step(uint256 hr) external {
        require(msg.sender == address(this));
        _hour(hr);
    }

    function _hour(uint256 hr) internal {
        uint256 t = START + hr * HOUR;
        vm.warp(t);
        uint256 hour = hr % 24;
        uint256 wd = _weekday(t);
        bool weekend = wd == 0 || wd == 6;
        // Wednesday and Thursday middays lender A moves its free balance elsewhere.
        if (hour == 12 && (wd == 3 || wd == 4) && hr < 7 * 24) _pull();
        if (hour == 8 && wd == 5) _repayDay();
        _captureDue(hr);
        uint256 rate = _curve(hour, weekend) * n;
        uint256 count = rate / 100 + (_rand(100) < rate % 100 ? 1 : 0);
        for (uint256 k; k < count; ++k) {
            vm.warp(t + (k + 1) * HOUR / (count + 1));
            _swipe(hr);
        }
        if (recoveryHour == 0 && pulled != 0 && hr > 4 * 24 + 8 && _phase(hr) == 2) {
            // Recovered once lender A's lines have room for a typical purchase again.
            uint256 room;
            for (uint256 i; i < n / 2; ++i) {
                if (credit.availableCredit(lineOfHolder[i]) >= 100e6) ++room;
            }
            if (room * 2 >= n / 2) recoveryHour = hr;
        }
    }

    /// @dev 0 before lender A pulls, 1 while it is dry, 2 after Friday's repayments.
    function _phase(uint256 hr) internal pure returns (uint256) {
        if (hr < 2 * 24 + 12) return 0;
        if (hr < 4 * 24 + 8) return 1;
        return 2;
    }

    function _pull() internal {
        uint256 free = core.available(lenderA, address(usd));
        if (free == 0) return;
        vm.prank(lenderA);
        usd.transfer(elsewhere, free);
        pulled += free;
        _checkAll();
    }

    function _swipe(uint256 hr) internal {
        uint256 i = _rand(n);
        address h = holders[i];
        uint128 amount = _ticket();
        bytes32 ref = keccak256(abi.encode("buy", buys.length));
        uint256 side = i < n / 2 ? 0 : 1;
        Side storage sd = sides[_phase(hr)][side];
        ++sd.auths;
        uint256 room = core.available(h, address(usd)) + credit.availableCredit(lineOfHolder[i]);
        (uint256 approved, bytes4 err, uint256 gasUsed) = _try(h, cardIds[i], ref, amount, 0);
        if (approved == 0) {
            ++sd.declined;
            if (err == CreditSource.CreditExceeded.selector) ++sd.creditExceeded;
            if (amount <= room) ++sd.coverableDeclines;
            return;
        }
        if (gasUsed != 0) {
            authGas += gasUsed;
            ++authCount;
        }
        uint256 r = _rand(100);
        uint8 fate = r < 75 ? 0 : r < 90 ? 1 : r < 95 ? 2 : 3;
        buys.push(Buy(ref, uint32(i), uint32(hr + 1 + _rand(30)), fate, uint128(approved)));
        pending.push(buys.length - 1);
        _checkAll();
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
            if (b.dueHour > hr) {
                ++j;
                continue;
            }
            _resolve(b, hr);
            pending[j] = pending[pending.length - 1];
            pending.pop();
        }
    }

    /// @dev 75% capture as authorized, 15% add a tip of up to 20%, 5% capture less, 5% are released.
    function _resolve(Buy memory b, uint256 hr) internal {
        address h = holders[b.holder];
        if (b.fate == 3) {
            _releaseBuy(h, b.ref);
            _checkAll();
            return;
        }
        uint64 lineId = lineOfHolder[b.holder];
        uint128 amount = b.fate == 1
            ? uint128(b.amount + b.amount * _rand(tolBps + 1) / 10_000)
            : b.fate == 2 ? uint128(b.amount * (50 + _rand(46)) / 100) : b.amount;
        uint256 lenderBefore = _lenderTotal(credit.lineOf(lineId).lender);
        uint256 cashBefore = _cashCost(h);
        uint256 availBefore = credit.availableCredit(lineId);
        (bool ok, uint256 covered,) = _book(h, b.ref, amount);
        if (!ok) {
            _releaseBuy(h, b.ref);
            _checkAll();
            return;
        }
        uint256 fromCredit = lenderBefore - _lenderTotal(credit.lineOf(lineId).lender);
        uint256 fromCash = _cashCost(h) - cashBefore;
        Side storage sd = sides[_phase(hr)][b.holder < n / 2 ? 0 : 1];
        sd.creditVolume += fromCredit;
        sd.cashVolume += fromCash;
        uint256 asked = amount;
        if (covered < asked) {
            absorbed += asked - covered;
            ++absorbedCount;
        }
        if (amount > b.amount) {
            tipVolume += amount - b.amount;
            if (availBefore == 0) ++tipCreditFree;
        }
        CreditSource.Line memory l = credit.lineOf(lineId);
        if (uint256(l.owed) + l.pending + 100e6 > l.maxDebt) ++maxDebtHits;
        _checkAll();
    }

    /// @dev Friday wages land, and each holder repays as much of their line as their wallet allows above a $50
    ///      float.
    function _repayDay() internal {
        for (uint256 i; i < n; ++i) {
            address h = holders[i];
            _payday(h, 200e6 + _rand(800e6));
            uint64 lineId = lineOfHolder[i];
            uint256 owed = credit.owedNow(lineId);
            uint256 free = core.available(h, address(usd));
            if (owed == 0 || free <= 50e6) continue;
            uint128 pay = uint128(owed < free - 50e6 ? owed : free - 50e6);
            vm.prank(h);
            credit.repay(lineId, pay);
            repaid += pay;
            _checkAll();
        }
    }

    function _drain(uint256 hr) internal {
        vm.warp(START + hr * HOUR);
        for (uint256 j; j < pending.length; ++j) {
            _resolve(buys[pending[j]], hr);
        }
        delete pending;
        (uint256 held,) = cards.exposure();
        assertEq(held, 0, "holds left open");
        for (uint256 j; j < buys.length; ++j) {
            assertFalse(cards.purchaseOf(buys[j].ref).open, "purchase left open");
        }
        for (uint256 i; i < n; ++i) {
            assertEq(credit.lineOf(lineOfHolder[i]).pending, 0, "line still pending");
        }
        _checkAll();
    }

    // Checks.

    function _lenderTotal(address lender) internal view returns (uint256) {
        return usd.balanceOf(lender) + core.reserved(lender, address(usd));
    }

    /// @dev A holder's cash outlay: wallet out (net of wages, not counting what cash legs still hold), before line
    ///      repayments.
    function _cashCost(address h) internal view returns (uint256) {
        return mintedTo[h] - usd.balanceOf(h) - core.reserved(h, address(usd));
    }

    function _checkAll() internal view {
        _checkLedger();
        uint256 lentA;
        uint256 lentB;
        for (uint256 i; i < n; ++i) {
            address h = holders[i];
            CreditSource.Line memory l = credit.lineOf(lineOfHolder[i]);
            // A line never owes and holds past what its borrower agreed to.
            assertLe(uint256(l.owed) + l.pending, l.maxDebt, "line past its agreed debt");
            if (i < n / 2) lentA += l.owed;
            else lentB += l.owed;
            // The holder's cost (cash outlay plus what the line still owes) stays within what their purchases
            // captured and hold, plus the line's interest.
            uint256 cost = _cashCost(h) + l.owed;
            uint256 cap = costCap[h];
            assertLe(cost, cap + cap * APR * 20 / (10_000 * 365) + 1e6, "holder paid past captured plus held");
        }
        // A lender never pays out more than it put in.
        assertLe(lenderIn[lenderA] - _lenderTotal(lenderA) - pulled, lentA + 1, "lender A paid past its lines");
        assertLe(lenderIn[lenderB] - _lenderTotal(lenderB), lentB + 1, "lender B paid past its lines");
    }

    function _report() internal view {
        string[3] memory phase = ["before", "dry", "after"];
        string[2] memory side = ["a", "b"];
        for (uint256 p; p < 3; ++p) {
            for (uint256 q; q < 2; ++q) {
                Side memory sd = sides[p][q];
                string memory k = string.concat(side[q], "_", phase[p]);
                _log(string.concat(k, "_auths"), sd.auths);
                _log(string.concat(k, "_decline_bps"), sd.auths == 0 ? 0 : sd.declined * 10_000 / sd.auths);
                _log(string.concat(k, "_credit_exceeded"), sd.creditExceeded);
                _log(string.concat(k, "_coverable_declines"), sd.coverableDeclines);
                _logUsd(string.concat(k, "_credit_volume"), sd.creditVolume);
                _logUsd(string.concat(k, "_cash_fallback_volume"), sd.cashVolume);
            }
        }
        _log("holders", n);
        _log("lines_opened_uncommitted", linesUncommitted);
        _logUsd("lender_a_pulled", pulled);
        _logUsd("repaid", repaid);
        _log("lender_a_lines_recovered", recoveryHour == 0 ? 0 : 1);
        _log("recovery_hours_after_repayments", recoveryHour == 0 ? 0 : recoveryHour - (4 * 24 + 8));
        _log("lines_near_agreed_bound", maxDebtHits);
        _logUsd("tip_volume", tipVolume);
        _log("tips_on_lines_without_room", tipCreditFree);
        _logUsd("issuer_absorbed", absorbed);
        _log("issuer_absorbed_captures", absorbedCount);
        _log("gas_authorize_avg", authCount == 0 ? 0 : authGas / authCount);
    }
}
