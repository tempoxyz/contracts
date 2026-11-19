// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardLegs } from "../../../src/programs/CardLegs.sol";
import { FundingBase } from "./FundingBase.sol";

/// @notice Savings venue that cannot redeem during a spending spike: cardholders fund from savings first and cash
///         second, volume triples from Friday noon to Sunday noon, and the venue refuses every redemption from Friday
///         noon to Monday 09:00. Captures defer onto the funder's float until it runs out; past that a capture fails
///         and the merchant retries it every hour. Once the venue redeems again the funder redeems the deferred
///         shares and the float refills. Every step checks conservation, custody, the float's backing and each
///         holder's cost.
contract FundingSavingsStressTest is FundingBase {
    struct Buy {
        bytes32 ref;
        uint32 holder;
        uint32 dueHour;
        uint32 firstFail;
        uint8 fate;
        uint128 amount;
    }

    struct Stats {
        uint256 auths;
        uint256 declined;
        uint256 captures;
        uint256 deferred;
        uint256 deferredValue;
        uint256 floatFailures;
        uint256 blockedMax;
        uint256 blockedMaxCount;
        uint256 maxDelay;
        uint256 cashDuringOutage;
        uint256 savingsDuringOutage;
        uint256 floatMin;
        uint256 refillHours;
        uint256 redeemedLater;
    }

    Buy[] internal buys;
    uint256[] internal pending;
    Stats internal s;
    mapping(address holder => uint256) internal deposited;
    mapping(address holder => uint256) internal sharesIn;

    uint256 internal n;
    uint256 internal float0;
    uint256 internal liquidAgain;
    bool internal illiquid;

    uint256 internal constant SPIKE_FROM = 4 * 24 + 12;
    uint256 internal constant SPIKE_TO = 6 * 24 + 12;
    uint256 internal constant DRY_FROM = 4 * 24 + 12;
    uint256 internal constant DRY_TO = 7 * 24 + 9;

    function _setUp(uint256 floatPerHolder) internal {
        vm.pauseGasMetering();
        n = 60 * _scale();
        rng = 0x5a71;
        tolBps = 2000;
        _world(0);
        parties.push(address(earnVault));
        parties.push(address(venue));
        CardLegs.Funding[] memory order = new CardLegs.Funding[](2);
        order[0] = _savingsEntry();
        order[1] = _cashEntry(address(usd), 0);
        for (uint256 i; i < n; ++i) {
            uint256 dep = 200e6 + _rand(1800e6);
            address h = _holder(i, dep + 20e6 + _rand(180e6), order);
            sharesIn[h] = _depositEarn(h, dep);
            deposited[h] = dep;
            _setDebtCap(h, address(cash), address(usd), 100e6);
            _setTolerance(h, address(cash), address(usd), uint16(tolBps));
            _setTolerance(h, address(savings), address(earnShare), uint16(tolBps));
        }
        // The funder sets its float.
        float0 = n * floatPerHolder;
        vm.prank(funder);
        savings.withdraw(address(usd), funder, FLOAT);
        _mint(funder, float0);
        vm.prank(funder);
        usd.transfer(address(savings), float0);
        s.floatMin = float0;
        _seal();
    }

    function _savingsEntry() internal view returns (CardLegs.Funding memory) {
        return CardLegs.Funding(savings, bytes32(0));
    }

    /// @dev A float of $40 per holder covers about two hours of the spike: captures fail for most of the weekend.
    function test_stress_savingsIlliquidDuringSpike_thinFloat() public {
        _setUp(40e6);
        tag = "savings_thin_float";
        _run();
        assertGt(s.floatFailures, 0, "the float never ran out");
    }

    /// @dev A float of $1,000 per holder carries the whole weekend.
    function test_stress_savingsIlliquidDuringSpike_ampleFloat() public {
        _setUp(1000e6);
        tag = "savings_ample_float";
        _run();
        assertEq(s.floatFailures, 0, "captures failed with an ample float");
    }

    function _run() internal {
        vm.pauseGasMetering();
        for (uint256 hr; hr < 10 * 24; ++hr) {
            this.step(hr);
        }
        _drain(10 * 24);
        _report();
    }

    /// @dev One simulated hour, as its own call so memory does not grow across the run.
    function step(uint256 hr) external {
        require(msg.sender == address(this));
        _hour(hr);
    }

    function _hour(uint256 hr) internal {
        uint256 t = START + hr * HOUR;
        vm.warp(t);
        if (hr == DRY_FROM) _setIlliquid(true);
        if (hr == DRY_TO) _setIlliquid(false);
        if (!illiquid && savings.heldShares() != 0) _redeemHeld(hr);
        _captureDue(hr);
        uint256 hour = hr % 24;
        uint256 wd = _weekday(t);
        uint256 rate = _curve(hour, wd == 0 || wd == 6) * n;
        if (hr >= SPIKE_FROM && hr < SPIKE_TO) rate *= 3;
        uint256 count = rate / 100 + (_rand(100) < rate % 100 ? 1 : 0);
        for (uint256 k; k < count; ++k) {
            vm.warp(t + (k + 1) * HOUR / (count + 1));
            _swipe(hr);
        }
        uint256 f = usd.balanceOf(address(savings));
        if (f < s.floatMin) s.floatMin = f;
        if (s.refillHours == 0 && liquidAgain != 0 && f + 1e6 >= float0) s.refillHours = hr - liquidAgain + 1;
    }

    /// @dev The venue refuses or resumes every redemption.
    function _setIlliquid(bool on) internal {
        illiquid = on;
        if (on) {
            vm.mockCallRevert(
                address(earnVault), abi.encodeWithSignature("redeem(uint256,address,uint256)"), "illiquid"
            );
        } else {
            vm.clearMockedCalls();
            liquidAgain = (block.timestamp - START) / HOUR;
        }
    }

    function _redeemHeld(uint256) internal {
        uint256 shares = savings.heldShares();
        uint256 quote = earnVault.previewRedeem(shares);
        vm.prank(funder);
        s.redeemedLater += savings.redeemHeld(shares, quote);
        _checkAll();
    }

    function _swipe(uint256 hr) internal {
        uint256 i = _rand(n);
        uint128 amount = _ticket();
        bytes32 ref = keccak256(abi.encode("buy", buys.length));
        ++s.auths;
        (uint256 approved,,) = _try(holders[i], cardIds[i], ref, amount, 0);
        if (approved == 0) {
            ++s.declined;
            return;
        }
        uint256 r = _rand(100);
        uint8 fate = r < 80 ? 0 : r < 92 ? 1 : r < 96 ? 2 : 3;
        buys.push(Buy(ref, uint32(i), uint32(hr + 1 + _rand(20)), 0, fate, uint128(approved)));
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
        uint256 blocked;
        uint256 blockedCount;
        for (uint256 j; j < pending.length;) {
            Buy storage b = buys[pending[j]];
            if (b.dueHour > hr) {
                ++j;
                continue;
            }
            if (_resolve(b, hr)) {
                pending[j] = pending[pending.length - 1];
                pending.pop();
            } else {
                blocked += b.amount;
                ++blockedCount;
                ++j;
            }
        }
        if (blocked > s.blockedMax) (s.blockedMax, s.blockedMaxCount) = (blocked, blockedCount);
    }

    /// @dev 80% capture as authorized, 12% add a tip of up to 20%, 4% capture less, 4% are released. A capture that
    ///      fails stays due and is retried every hour.
    function _resolve(Buy storage b, uint256 hr) internal returns (bool done) {
        address h = holders[b.holder];
        if (b.fate == 3) {
            _releaseBuy(h, b.ref);
            _checkAll();
            return true;
        }
        uint128 amount = b.fate == 1
            ? uint128(b.amount + b.amount * ((uint256(b.ref) >> 8) % (tolBps + 1)) / 10_000)
            : b.fate == 2 ? uint128(b.amount * (50 + uint256(b.ref) % 46) / 100) : b.amount;
        uint256 heldBefore = savings.heldShares();
        uint256 cashBefore = _cashOut(h);
        uint256 savedBefore = _sharesOut(h);
        (bool ok, uint256 covered,) = _book(h, b.ref, amount);
        if (!ok) {
            ++s.floatFailures;
            if (b.firstFail == 0) b.firstFail = uint32(hr);
            return false;
        }
        ++s.captures;
        if (b.firstFail != 0 && hr - b.firstFail > s.maxDelay) s.maxDelay = hr - b.firstFail;
        uint256 heldNow = savings.heldShares();
        if (heldNow > heldBefore) {
            ++s.deferred;
            s.deferredValue += earnVault.previewRedeem(heldNow - heldBefore);
        }
        if (illiquid) {
            // Net of what the capture released back to the holder.
            uint256 cashNow = _cashOut(h);
            uint256 savedNow = _sharesOut(h);
            if (cashNow > cashBefore) s.cashDuringOutage += cashNow - cashBefore;
            if (savedNow > savedBefore) s.savingsDuringOutage += earnVault.previewRedeem(savedNow - savedBefore);
        }
        covered;
        _checkAll();
        return true;
    }

    function _drain(uint256 hr) internal {
        vm.warp(START + hr * HOUR);
        if (savings.heldShares() != 0) _redeemHeld(hr);
        for (uint256 j; j < pending.length; ++j) {
            assertTrue(_resolve(buys[pending[j]], hr), "capture still fails once the venue redeems");
        }
        delete pending;
        (uint256 held,,) = cards.exposure();
        assertEq(held, 0, "holds left open");
        for (uint256 j; j < buys.length; ++j) {
            assertFalse(cards.purchaseOf(buys[j].ref).open, "purchase left open");
        }
        assertEq(savings.heldShares(), 0, "deferred shares left");
        // The funder ends with at least its float, less redemption rounding.
        assertGe(usd.balanceOf(address(savings)) + n, float0, "float lost value");
        _checkAll();
    }

    // Checks.

    function _cashOut(address h) internal view returns (uint256) {
        return mintedTo[h] - deposited[h] - usd.balanceOf(h) + _owed(h, address(usd), address(cash));
    }

    function _sharesOut(address h) internal view returns (uint256) {
        return sharesIn[h] - earnShare.balanceOf(h) - core.reserved(h, address(earnShare));
    }

    function _checkAll() internal view {
        _checkLedger();
        // The float plus what the deferred shares redeem for always backs the float the funder put in.
        assertGe(
            usd.balanceOf(address(savings)) + earnVault.previewRedeem(savings.heldShares()) + n,
            float0,
            "float unbacked"
        );
        assertGe(earnShare.balanceOf(address(savings)), savings.heldShares(), "deferred shares missing");
        for (uint256 i; i < n; ++i) {
            address h = holders[i];
            // Cash out plus savings given up stays within captured plus held, and within authorized plus tolerance,
            // allowing a cent per purchase of share rounding.
            uint256 cost = _cashOut(h) + earnVault.previewRedeem(_sharesOut(h));
            assertLe(cost, costCap[h] + 1e6, "holder paid past captured plus held");
            assertLe(cost, authorized[h] * (10_000 + tolBps) / 10_000 + 1e6, "holder paid past authorized");
        }
    }

    function _report() internal view {
        _log("holders", n);
        _logUsd("float", float0);
        _log("auths", s.auths);
        _log("declined", s.declined);
        _log("captures", s.captures);
        _log("deferred_captures", s.deferred);
        _logUsd("deferred_value", s.deferredValue);
        _logUsd("float_min", s.floatMin);
        _log("capture_failures_float", s.floatFailures);
        _logUsd("blocked_captures_max", s.blockedMax);
        _log("blocked_captures_max_count", s.blockedMaxCount);
        _log("capture_delay_max_h", s.maxDelay);
        _logUsd("savings_paid_during_outage", s.savingsDuringOutage);
        _logUsd("cash_paid_during_outage", s.cashDuringOutage);
        _logUsd("redeemed_after_outage", s.redeemedLater);
        _log("float_refill_h", s.refillHours);
    }
}
