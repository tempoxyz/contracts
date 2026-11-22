// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardLimits } from "../../../src/programs/CardLimits.sol";
import { AuthEnv } from "../harness/AuthEnv.sol";
import { console } from "forge-std/console.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

/// @notice Shared world for the adverse-event simulations: many cardholders on CardAuth over the core model, a
///         deterministic random stream, a calendar, a usd conservation ledger and the `STRESS <test> <metric>=<value>`
///         log format. `STRESS_SCALE` multiplies population sizes for heavier runs.
abstract contract AdverseBase is AuthEnv {
    ITIP403Registry internal registry = StdPrecompiles.TIP403_REGISTRY;

    uint256 internal scale;
    uint256 private _seed;

    address[] internal holders;
    bytes32[] internal cardIds;
    address[] internal merchants;

    /// @dev Every party whose usd balance the simulation accounts for.
    address[] internal tracked;
    /// @dev What the tracked parties hold in all; it moves only with `_mintUsd`.
    uint256 internal expectedUsd;
    uint256 internal checks;

    function _setUpAdverse(bytes32 seed) internal {
        _deployPrograms();
        scale = vm.envOr("STRESS_SCALE", uint256(1));
        if (scale == 0) scale = 1;
        _seed = uint256(seed);
        tracked.push(settlement);
        tracked.push(issuer);
        tracked.push(address(cash));
        tracked.push(address(cards));
        tracked.push(address(core));
        tracked.push(address(savings));
        tracked.push(address(line));
        tracked.push(funder);
        expectedUsd = _sumTracked();
        for (uint256 i; i < 8; ++i) {
            merchants.push(makeAddr(string.concat("merchant-", vm.toString(i))));
        }
    }

    // Population.

    /// @dev Issues `n` cardholders a card each, funding from cash only, each holding `balance` usd.
    function _holders(uint256 n, uint256 balance) internal {
        for (uint256 i; i < n; ++i) {
            address owner = makeAddr(string.concat("holder-", vm.toString(holders.length)));
            bytes32 card = keccak256(abi.encode("card", holders.length));
            vm.prank(issuer);
            cards.issueCard(
                card,
                owner,
                uint40(block.timestamp + 5 * 365 days),
                CardLimits.Limits({ perPurchase: 1_000_000e6, daily: 1_000_000e6, monthly: 10_000_000e6 }),
                7
            );
            vm.startPrank(owner);
            core.approveHolder(address(cash), address(usd), type(uint128).max, 0);
            _setFunding(true, false, false);
            cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
            vm.stopPrank();
            holders.push(owner);
            cardIds.push(card);
            tracked.push(owner);
            _mintUsd(owner, balance);
        }
    }

    /// @dev Adds a party to the conservation ledger with what it holds now.
    function _track(address party) internal {
        tracked.push(party);
        expectedUsd += usd.balanceOf(party);
    }

    /// @dev An explicit mint: the one way the tracked total may grow.
    function _mintUsd(address to, uint256 amount) internal {
        usd.mint(to, amount);
        expectedUsd += amount;
    }

    // Randomness and calendar.

    function _rand() internal returns (uint256) {
        _seed = uint256(keccak256(abi.encode(_seed)));
        return _seed;
    }

    /// @dev A uniform integer in [lo, hi].
    function _between(uint256 lo, uint256 hi) internal returns (uint256) {
        return lo + _rand() % (hi - lo + 1);
    }

    function _chance(uint256 bps) internal returns (bool) {
        return _rand() % 10_000 < bps;
    }

    /// @dev 0 Monday .. 6 Sunday.
    function _dow() internal view returns (uint256) {
        return (block.timestamp / 1 days + 3) % 7;
    }

    function _weekend() internal view returns (bool) {
        return _dow() >= 5;
    }

    /// @dev Moves to 10:00 UTC of the next Monday.
    function _toMonday() internal {
        uint256 day = block.timestamp / 1 days + 1;
        while ((day + 3) % 7 != 0) {
            ++day;
        }
        vm.warp(day * 1 days + 10 hours);
    }

    function _nextDay() internal {
        vm.warp(block.timestamp + 1 days);
    }

    // Invariants.

    function _sumTracked() internal view returns (uint256 total) {
        for (uint256 i; i < tracked.length; ++i) {
            total += usd.balanceOf(tracked[i]);
        }
    }

    /// @dev Conservation of usd over every tracked party, the core holding exactly what it reserves, and nothing left
    ///      in CardAuth or the cash source between calls.
    function _checkConservation() internal {
        ++checks;
        assertEq(_sumTracked(), expectedUsd, "usd conserved");
        _assertCoreBalanced();
        _assertSourcesEmpty();
    }

    /// @dev Gas measured per kind of program call while metering is otherwise paused (simulations run unmetered so
    ///      their size is not bounded by the block gas limit).
    mapping(bytes32 => uint256) internal gasTotal;
    mapping(bytes32 => uint256) internal gasCount;
    mapping(bytes32 => uint256) internal gasMax;
    uint256 private _gasMark;

    function _meter() internal {
        vm.resumeGasMetering();
        _gasMark = gasleft();
    }

    function _metered(bytes32 op) internal {
        uint256 used = _gasMark - gasleft();
        vm.pauseGasMetering();
        gasTotal[op] += used;
        ++gasCount[op];
        if (used > gasMax[op]) gasMax[op] = used;
    }

    function _reportGas(string memory test, string memory op) internal view {
        bytes32 key = bytes32(bytes(op));
        uint256 n = gasCount[key];
        if (n == 0) return;
        _log(test, string.concat("gas_avg_", op), gasTotal[key] / n);
        _log(test, string.concat("gas_max_", op), gasMax[key]);
    }

    // Policy.

    /// @dev Puts usd under a fresh blacklist policy the test contract administers.
    function _blacklist() internal returns (uint64 policy) {
        policy = registry.createPolicy(address(this), ITIP403Registry.PolicyType.BLACKLIST);
        usd.changeTransferPolicyId(policy);
    }

    function _freeze(uint64 policy, address account, bool frozen) internal {
        registry.modifyPolicyBlacklist(policy, account, frozen);
    }

    // Output.

    function _log(string memory test, string memory metric, uint256 value) internal pure {
        console.log(string.concat("STRESS ", test, " ", metric, "=", vm.toString(value)));
    }

    function _logInt(string memory test, string memory metric, int256 value) internal pure {
        console.log(string.concat("STRESS ", test, " ", metric, "=", vm.toString(value)));
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
