// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardLegs } from "../../../../src/spend/programs/CardLegs.sol";
import { CardLimits } from "../../../../src/spend/programs/CardLimits.sol";
import { ISource } from "../../../../src/interfaces/spend/programs/ISource.sol";
import { FxBase } from "./FxBase.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @notice Rounding accumulated over many small operations: authorizations, full and partial captures and refunds in
///         one to three parts, on amounts from one unit to about one USD. Measures, in millionths of a unit, how far
///         what each party gave or got sits from the exact value, and who ends up with the units rounding moves.
///         About 10,000 operations by default; STRESS_SCALE=10 runs about 100,000.
contract FxRoundingStressTest is FxBase {
    using FixedPointMathLib for uint256;

    /// @dev About 72.9 LCL per USD, a rate with no short decimal form.
    uint256 internal constant ODD_RATE = 0.013717421124828532e18;
    uint256 internal constant CYCLES = 3300;
    uint256 internal constant MICRO = 1e6;

    /// @dev Totals in millionths of a settlement unit.
    struct Drift {
        uint256 ops;
        int256 holderPaidOverExact;
        int256 holderRefundShort;
        uint256 issuerAbsorbed;
        uint256 settlementSurplus;
        uint256 maxCaptureOver;
        uint256 maxRefundShort;
        uint256 dustRefundReverts;
        uint256 dustRefundUnits;
        uint256 maxDustPart;
    }

    /// @dev A purchase amount: a third from one to 99 units, the rest up to about one USD.
    function _small(uint256 seed) internal pure returns (uint128) {
        return uint128(seed % 3 == 0 ? 1 + seed % 99 : 1 + seed % 999_999);
    }

    function test_stress_conversionRoundingOverManyOperations() public {
        vm.pauseGasMetering();
        string memory t = "round_conversion";
        _fxWorld(ODD_RATE, 0, 1_000_000e6, 100_000_000e6);
        uint256 n = 10;
        _addHolders(n, true, 100, 100_000_000e6, 0);
        _baseline(1_000_000e6);
        uint256 floatBefore = _exactUsd(address(conv));
        uint256 venueBefore = _exactUsd(address(bidPool)) + _exactUsd(address(askPool));
        uint256 settlementBefore = _exactUsd(settlement);
        uint256 holdersBefore = _exactHolders();
        uint256 issuerBefore = _exactUsd(issuer);
        Drift memory r;
        uint256 cycles = CYCLES * _scaleBy();
        for (uint256 i; i < cycles; ++i) {
            if (i % 500 == 0) {
                vm.warp(vm.getBlockTimestamp() + 1 hours);
                conv.setReferenceRate(address(lcl), ODD_RATE);
            }
            uint256 seed = _rand(i, 1);
            uint256 k = i % n;
            bytes32 ref = _newRef();
            uint128 amount = _small(seed);
            (bool ok,) = _swipe(k, ref, amount, 7 days);
            ++r.ops;
            if (!ok) continue;
            uint128 take = seed % 10 < 7 ? amount : uint128(1 + _rand(seed, 2) % amount);
            _captureOne(k, ref, take, r);
            if (seed % 10 >= 6) _refundParts(k, ref, seed, r);
            _checkConservation();
        }
        int256 floatPnl = int256(_exactUsd(address(conv))) - int256(floatBefore);
        int256 venuePnl = int256(_exactUsd(address(bidPool)) + _exactUsd(address(askPool))) - int256(venueBefore);
        int256 settlementPnl = int256(_exactUsd(settlement)) - int256(settlementBefore);
        int256 issuerPnl = int256(_exactUsd(issuer)) - int256(issuerBefore);
        int256 holdersPnl = int256(_exactHolders()) - int256(holdersBefore);
        _logDrift(t, r);
        _logMicro(t, "float_pnl", floatPnl);
        _logMicro(t, "venue_pnl", venuePnl);
        _logMicro(t, "settlement_and_issuer_pnl", settlementPnl + issuerPnl);
        _logMicro(t, "holders_pnl", holdersPnl);
        // Value only moved: what the holders lost the others gained, to within the exact-value arithmetic.
        assertApproxEqAbs(floatPnl + venuePnl + settlementPnl + issuerPnl + holdersPnl, 0, 1e6, "value appeared");
        // Each capture costs the cardholder at most one token unit past the exact price, each refund part at most one.
        assertLe(r.maxCaptureOver, _tokenMicro(1) + MICRO, "capture rounding past a unit");
        assertLe(r.maxRefundShort, _tokenMicro(1) + MICRO, "refund rounding past a unit");
    }

    /// @dev Captures take of ref finally and records rounding against the exact price.
    function _captureOne(uint256 k, bytes32 ref, uint128 take, Drift memory r) internal {
        uint256 holderBefore = _holderTokens(k);
        uint256 got = usd.balanceOf(settlement);
        uint256 gotTokens = lcl.balanceOf(settlement);
        uint64 absorbedBefore = cards.purchaseOf(ref).refunded;
        vm.prank(issuer);
        cards.capture(ref, take, true);
        ++r.ops;
        uint256 covered = take - (cards.purchaseOf(ref).refunded - absorbedBefore);
        r.issuerAbsorbed += (take - covered) * MICRO;
        uint256 spent = holderBefore - _holderTokens(k);
        uint256 surplus = (usd.balanceOf(settlement) - got) * MICRO + _tokenMicro(lcl.balanceOf(settlement) - gotTokens);
        if (surplus > covered * MICRO) r.settlementSurplus += surplus - covered * MICRO;
        int256 over = int256(_tokenMicro(spent)) - int256(covered * MICRO);
        r.holderPaidOverExact += over;
        if (over > 0 && uint256(over) > r.maxCaptureOver) r.maxCaptureOver = uint256(over);
    }

    /// @dev Refunds what ref captured in one to three parts and records rounding against the exact price.
    function _refundParts(uint256 k, bytes32 ref, uint256 seed, Drift memory r) internal {
        uint256 room = cards.purchaseOf(ref).captured - cards.purchaseOf(ref).refunded;
        uint256 parts = 1 + _rand(seed, 3) % 3;
        uint256 sent;
        for (uint256 j; j < parts && sent < room; ++j) {
            uint256 part = j + 1 == parts ? room - sent : (room / parts == 0 ? 1 : room / parts);
            (bool ok, uint256 back) = _tryRefund(k, ref, uint128(part));
            assertTrue(ok, "refund reverted");
            ++r.ops;
            sent += part;
            int256 short = int256(part * MICRO) - int256(_tokenMicro(back));
            r.holderRefundShort += short;
            if (short > 0 && uint256(short) > r.maxRefundShort) r.maxRefundShort = uint256(short);
        }
    }

    function test_stress_savingsShareRoundingOverManyOperations() public {
        vm.pauseGasMetering();
        string memory t = "round_savings";
        _fxWorld(ODD_RATE, 0, 1_000_000e6, 100_000_000e6);
        uint256 n = 10;
        for (uint256 k; k < n; ++k) {
            address h = makeAddr(string.concat("saver-", vm.toString(k)));
            bytes32 card = keccak256(abi.encode("saver", k));
            holders.push(h);
            holderCards.push(card);
            vm.prank(issuer);
            cards.issueCard(card, h, uint40(vm.getBlockTimestamp() + 730 days), _limits(1e13, 1e14, 1e15), 7);
            usd.mint(h, 1_000_000e6);
            _depositEarn(h, 1_000_000e6);
            CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
            order[0] = CardLegs.Funding(ISource(address(savings)), bytes32(0));
            vm.startPrank(h);
            core.approveHolder(address(savings), address(earnShare), type(uint128).max, 0);
            cards.setFunding(order);
            cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
            vm.stopPrank();
        }
        _baseline(1_000_000e6);
        uint256 outsideUsd = usd.totalSupply() - _usdKnown();
        Drift memory r;
        uint256 yield;
        uint256 cycles = CYCLES * _scaleBy();
        for (uint256 i; i < cycles; ++i) {
            // Yield accrues in small, uneven steps, so the share price never stays round.
            if (i % 50 == 0) {
                uint256 add = usd.balanceOf(address(venue)) * (1 + i % 7) / 1_000_000;
                usd.mint(address(venue), add);
                yield += add;
            }
            uint256 seed = _rand(i, 11);
            uint256 k = i % n;
            bytes32 ref = _newRef();
            uint128 amount = _small(seed);
            (bool ok,) = _swipe(k, ref, amount, 7 days);
            ++r.ops;
            if (!ok) continue;
            uint128 take = seed % 10 < 7 ? amount : uint128(1 + _rand(seed, 2) % amount);
            _captureSavings(k, ref, take, r);
            if (seed % 10 >= 6) _refundSavings(k, ref, seed, r);
            assertEq(usd.totalSupply() - _usdKnown(), outsideUsd, "usd left the parties");
            assertEq(earnShare.balanceOf(address(core)), core.totalReserved(address(earnShare)), "shares reserved");
        }
        _logDrift(t, r);
        _logAmount(t, "yield_added", int256(yield));
        _log(t, "dust_refund_reverts", r.dustRefundReverts);
        _log(t, "dust_refund_units", r.dustRefundUnits);
        _log(t, "max_reverted_refund_units", r.maxDustPart);
        // Only refunds worth less than one share revert.
        assertLe(r.maxDustPart * MICRO, _shareMicro(1), "a refund over a share reverted");
        _log(t, "savings_held_shares", savings.heldShares());
        _logAmount(t, "savings_usd_float_change", int256(usd.balanceOf(address(savings))) - int256(FLOAT));
        assertLe(r.maxCaptureOver, _shareMicro(1) + MICRO, "capture rounding past a share unit");
        assertLe(r.maxRefundShort, _shareMicro(1) + MICRO, "refund rounding past a share unit");
    }

    /// @dev A savings refund worth less than one share reverts, so its cardholder can't be credited those units and
    ///      a purchase whose last part is that small stays short. Shows the current behaviour.
    function test_savingsRefundBelowOneShareReverts() public {
        _fxWorld(ODD_RATE, 0, 1_000_000e6, 100_000_000e6);
        address h = makeAddr("saver");
        bytes32 card = keccak256("saver-card");
        holders.push(h);
        holderCards.push(card);
        vm.prank(issuer);
        cards.issueCard(card, h, uint40(vm.getBlockTimestamp() + 730 days), _limits(1e13, 1e14, 1e15), 7);
        usd.mint(h, 1000e6);
        _depositEarn(h, 1000e6);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
        order[0] = CardLegs.Funding(ISource(address(savings)), bytes32(0));
        vm.startPrank(h);
        core.approveHolder(address(savings), address(earnShare), type(uint128).max, 0);
        cards.setFunding(order);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
        vm.stopPrank();
        _baseline(1000e6);
        bytes32 ref = _newRef();
        (bool ok,) = _swipe(0, ref, 10e6, 7 days);
        assertTrue(ok);
        vm.prank(issuer);
        cards.capture(ref, 10e6, true);
        assertGt(earnVault.previewRedeem(1), 0);
        vm.prank(issuer);
        cards.refund(ref, 10e6 - 1);
        // The last unit can't be refunded.
        vm.prank(issuer);
        vm.expectRevert();
        cards.refund(ref, 1);
    }

    function _captureSavings(uint256 k, bytes32 ref, uint128 take, Drift memory r) internal {
        address h = holders[k];
        uint256 sharesBefore = earnShare.balanceOf(h) + core.reserved(h, address(earnShare));
        uint256 got = usd.balanceOf(settlement);
        uint64 absorbedBefore = cards.purchaseOf(ref).refunded;
        uint256 price = earnVault.previewRedeem(1e15);
        vm.prank(issuer);
        cards.capture(ref, take, true);
        ++r.ops;
        uint256 covered = take - (cards.purchaseOf(ref).refunded - absorbedBefore);
        r.issuerAbsorbed += (take - covered) * MICRO;
        uint256 received = usd.balanceOf(settlement) - got;
        if (received > covered) r.settlementSurplus += (received - covered) * MICRO;
        uint256 taken = sharesBefore - earnShare.balanceOf(h) - core.reserved(h, address(earnShare));
        int256 over = int256(taken * price / 1e9) - int256(covered * MICRO);
        r.holderPaidOverExact += over;
        if (over > 0 && uint256(over) > r.maxCaptureOver) r.maxCaptureOver = uint256(over);
    }

    function _refundSavings(uint256 k, bytes32 ref, uint256 seed, Drift memory r) internal {
        address h = holders[k];
        uint256 room = cards.purchaseOf(ref).captured - cards.purchaseOf(ref).refunded;
        uint256 parts = 1 + _rand(seed, 3) % 3;
        uint256 sent;
        for (uint256 j; j < parts && sent < room; ++j) {
            uint256 part = j + 1 == parts ? room - sent : (room / parts == 0 ? 1 : room / parts);
            uint256 before = earnShare.balanceOf(h);
            vm.prank(issuer);
            try cards.refund(ref, uint128(part)) { }
            catch {
                // Units worth less than one share buy none, and the savings source's deposit asks for at least one.
                (r.dustRefundReverts, r.dustRefundUnits) = (r.dustRefundReverts + 1, r.dustRefundUnits + part);
                if (part > r.maxDustPart) r.maxDustPart = part;
                sent += part;
                continue;
            }
            ++r.ops;
            sent += part;
            uint256 back = earnShare.balanceOf(h) - before;
            int256 short = int256(part * MICRO) - int256(back * earnVault.previewRedeem(1e15) / 1e9);
            r.holderRefundShort += short;
            if (short > 0 && uint256(short) > r.maxRefundShort) r.maxRefundShort = uint256(short);
        }
    }

    /// @dev USD with every party the savings run touches, the Earn vault and its venue included.
    function _usdKnown() internal view returns (uint256) {
        return _partiesBalance(usd) + usd.balanceOf(address(savings)) + usd.balanceOf(address(earnVault))
            + usd.balanceOf(address(venue));
    }

    /// @dev Millionths of a USD unit that tokens of LCL are worth at the exact rate.
    function _tokenMicro(uint256 tokens) internal pure returns (uint256) {
        return tokens.mulDiv(ODD_RATE, 1e12);
    }

    /// @dev Millionths of a USD unit that shares are worth at the vault's current price.
    function _shareMicro(uint256 shares) internal view returns (uint256) {
        return shares * earnVault.previewRedeem(1e15) / 1e9;
    }

    /// @dev What account holds of both tokens, in millionths of a USD unit at the exact rate.
    function _exactUsd(address account) internal view returns (uint256) {
        uint256 l = lcl.balanceOf(account) + core.reserved(account, address(lcl));
        uint256 u = usd.balanceOf(account) + core.reserved(account, address(usd));
        return u * MICRO + _tokenMicro(l);
    }

    function _exactHolders() internal view returns (uint256 sum) {
        for (uint256 k; k < holders.length; ++k) {
            sum += _exactUsd(holders[k]);
        }
    }

    function _logDrift(string memory t, Drift memory r) internal pure {
        _log(t, "operations", r.ops);
        _logMicro(t, "holder_paid_over_exact", r.holderPaidOverExact);
        _logMicro(t, "holder_refund_short_of_exact", r.holderRefundShort);
        _logMicro(t, "issuer_absorbed", int256(r.issuerAbsorbed));
        _logMicro(t, "settlement_surplus", int256(r.settlementSurplus));
        _logMicro(t, "max_capture_over", int256(r.maxCaptureOver));
        _logMicro(t, "max_refund_short", int256(r.maxRefundShort));
    }

    /// @dev Logs millionths of a unit as units with six decimals.
    function _logMicro(string memory t, string memory metric, int256 micro) internal pure {
        _logAmount(t, string.concat(metric, "_units"), micro);
    }
}
