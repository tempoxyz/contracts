// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardLegs } from "../../../../src/spend/programs/CardLegs.sol";
import { CardLimits } from "../../../../src/spend/programs/CardLimits.sol";
import { CreditSource } from "../../../../src/spend/programs/CreditSource.sol";
import { IssuerDesk } from "../../../../src/spend/programs/IssuerDesk.sol";
import { IssuerTreasury } from "../../../../src/spend/programs/IssuerTreasury.sol";
import { MerchantReserves } from "../../../../src/spend/programs/MerchantReserves.sol";
import { AuthEnv } from "../harness/AuthEnv.sol";
import { console } from "forge-std/console.sol";
import { IEarnVault } from "../../../../src/interfaces/earn/IEarnVault.sol";

/// @notice Shared world for the funding and liquidity stress runs: the real CardAuth with its cash and savings
///         sources, an issuer treasury registered as exposure guard behind pledged sponsor collateral, the issuer
///         desk and merchant reserves, many cardholders on their own cards, a calendar clock, a seeded generator,
///         and the ledger checks every step runs.
/// @dev Sizes scale with STRESS_SCALE (default 1). Measured outputs print as "STRESS <test> <metric>=<value>".
///      Runs pause gas metering and meter only a sample of the authorizations and captures they measure (reported
///      as gas_* over the sampled operations, zero for the rest), so the harness's own checks never count against
///      the test's gas.
abstract contract FundingBase is AuthEnv {
    /// @dev Monday 2026-01-05 00:00 UTC.
    uint256 internal constant START = 1_767_571_200;
    uint256 internal constant HOUR = 1 hours;
    uint256 internal constant DAY = 1 days;

    IssuerTreasury internal treasury;
    IssuerDesk internal desk;
    CreditSource internal credit;
    MerchantReserves internal reserves;
    address internal sponsor = makeAddr("sponsor");

    address[] internal holders;
    bytes32[] internal cardIds;
    address[] internal merchants;
    address[] internal parties;

    /// @dev Per holder: tokens minted to them, the most their purchases may have cost them so far (captured net of
    ///      refunds plus what open purchases hold), and everything they were approved for.
    mapping(address holder => uint256) internal mintedTo;
    mapping(address holder => uint256) internal costCap;
    mapping(address holder => uint256) internal authorized;
    /// @dev The capture tolerance every holder grants the cash source, in basis points.
    uint256 internal tolBps;

    uint256 internal rng;
    uint256 internal ops;
    uint256 internal residual;
    string internal tag;

    // Setup.

    function _scale() internal view returns (uint256) {
        return vm.envOr("STRESS_SCALE", uint256(1));
    }

    /// @dev Deploys the programs and companions, posts "collateral" of sponsor collateral from the settlement
    ///      account and registers the treasury as exposure guard (none when "collateral" is zero).
    function _world(uint128 collateral) internal {
        _deployPrograms();
        vm.warp(START);
        treasury = new IssuerTreasury(cards);
        credit = new CreditSource(cards);
        reserves = new MerchantReserves(cards);
        desk = new IssuerDesk(cards, credit, treasury, IEarnVault(address(earnVault)));
        _setting(abi.encodeCall(cards.setCompanion, (address(treasury), true)));
        _setting(abi.encodeCall(cards.setCompanion, (address(desk), true)));
        _setting(abi.encodeCall(cards.setCompanion, (address(reserves), true)));
        _setting(abi.encodeCall(cards.setCompanion, (address(credit), true)));
        _setting(abi.encodeCall(cards.setSource, (address(credit), true)));
        vm.startPrank(issuer);
        cards.setOperator(address(desk), cards.ROLE_SETTLE() | cards.ROLE_TREASURY(), 1e15);
        vm.stopPrank();
        vm.startPrank(settlement);
        usd.approve(address(desk), type(uint256).max);
        usd.approve(address(treasury), type(uint256).max);
        vm.stopPrank();
        if (collateral != 0) {
            _pledge(1, collateral);
            _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
        }
        for (uint256 i; i < 6; ++i) {
            merchants.push(makeAddr(string.concat("merchant-", vm.toString(i))));
        }
        parties.push(settlement);
        parties.push(sponsor);
        parties.push(address(treasury));
        parties.push(address(desk));
        parties.push(address(reserves));
        parties.push(address(credit));
        parties.push(address(cash));
        parties.push(address(savings));
        parties.push(address(line));
        parties.push(address(cards));
        parties.push(address(core));
        parties.push(funder);
        parties.push(issuer);
        for (uint256 i; i < merchants.length; ++i) {
            parties.push(merchants[i]);
        }
    }

    /// @dev Pledges "amount" from the settlement account into slot "n" for the sponsor.
    function _pledge(uint256 n, uint128 amount) internal {
        _mint(settlement, amount);
        bytes32 id = treasury.pledgeId(n);
        vm.startPrank(settlement);
        core.pledge(
            address(treasury), address(usd), id, amount, uint64(block.timestamp + treasury.COVER_TERM() + 60 days)
        );
        treasury.post(sponsor, IEarnVault(address(0)), n);
        vm.stopPrank();
    }

    /// @dev Issues holder "i" a card funded by "order", with "balance" in their wallet.
    function _holder(uint256 i, uint256 balance, CardLegs.Funding[] memory order) internal returns (address h) {
        h = makeAddr(string.concat("holder-", vm.toString(i)));
        bytes32 card = keccak256(abi.encode("card", i));
        vm.prank(issuer);
        cards.issueCard(card, h, uint40(START + 400 days), _limits(2000e6, 5000e6, 40_000e6), 7);
        vm.startPrank(h);
        core.approveHolder(address(cash), address(usd), type(uint128).max, 0);
        core.approveHolder(address(savings), address(earnShare), type(uint128).max, 0);
        cards.setFunding(order);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
        vm.stopPrank();
        holders.push(h);
        cardIds.push(card);
        parties.push(h);
        if (balance != 0) _mint(h, balance);
    }

    function _cashOnly() internal view returns (CardLegs.Funding[] memory order) {
        order = new CardLegs.Funding[](1);
        order[0] = _cashEntry(address(usd), 0);
    }

    /// @dev Meters one operation in eight (per unit of scale), so measured gas stays inside the test's gas limit.
    function _sample() internal returns (bool) {
        return ++ops % (8 * _scale()) == 0;
    }

    function _mint(address to, uint256 amount) internal {
        usd.mint(to, amount);
        mintedTo[to] += amount;
    }

    /// @dev Records the tokens outside every tracked party; that amount must not move afterwards.
    function _seal() internal {
        residual = usd.totalSupply() - _tracked();
    }

    // Clock and generator.

    function _rand(uint256 n) internal returns (uint256) {
        rng = uint256(keccak256(abi.encode(rng, "stress")));
        return n == 0 ? 0 : rng % n;
    }

    /// @dev Day of week, 0 = Sunday.
    function _weekday(uint256 t) internal pure returns (uint256) {
        return (t / DAY + 4) % 7;
    }

    function _hourOf(uint256 t) internal pure returns (uint256) {
        return (t % DAY) / HOUR;
    }

    /// @dev Authorizations per 100 cardholders in an hour of the day: quiet nights, lunch and evening peaks; weekends
    ///      run a fifth busier.
    function _curve(uint256 hour, bool weekend) internal pure returns (uint256) {
        uint8[24] memory w = [1, 0, 0, 0, 0, 1, 2, 4, 6, 6, 7, 9, 12, 10, 8, 7, 8, 10, 12, 11, 9, 6, 4, 2];
        uint256 n = w[hour];
        return weekend ? n * 6 / 5 : n;
    }

    // Steps.

    /// @dev Authorizes and returns the approved amount, or zero and the revert selector on a decline.
    function _try(address h, bytes32 card, bytes32 ref, uint128 amount, uint8 flags)
        internal
        returns (uint256 approved, bytes4 err, uint256 gasUsed)
    {
        address m = merchants[uint256(ref) % merchants.length];
        bool metered = _sample();
        if (metered) vm.resumeGasMetering();
        uint256 g = gasleft();
        vm.prank(issuer);
        try cards.authorize(card, ref, amount, m, uint64(block.timestamp + 7 days), flags) returns (uint256 a) {
            approved = a;
        } catch (bytes memory reason) {
            err = bytes4(reason);
        }
        if (metered) {
            gasUsed = g - gasleft();
            vm.pauseGasMetering();
        }
        if (approved != 0) {
            authorized[h] += approved;
            costCap[h] += _worth(ref);
        }
    }

    /// @dev Captures "amount" (final) and books what the holder paid for it; false when the capture reverts.
    function _book(address h, bytes32 ref, uint128 amount)
        internal
        returns (bool ok, uint256 covered, uint256 gasUsed)
    {
        uint256 before = _worth(ref);
        uint256 paidBefore = _paid(ref);
        bool metered = _sample();
        if (metered) vm.resumeGasMetering();
        uint256 g = gasleft();
        vm.prank(issuer);
        try cards.capture(ref, amount, true) {
            ok = true;
        } catch { }
        if (metered) {
            gasUsed = g - gasleft();
            vm.pauseGasMetering();
        }
        covered = _paid(ref) - paidBefore;
        costCap[h] = costCap[h] + _worth(ref) - before;
    }

    function _releaseBuy(address h, bytes32 ref) internal {
        uint256 before = _worth(ref);
        vm.prank(issuer);
        cards.release(ref);
        costCap[h] = costCap[h] + _worth(ref) - before;
    }

    /// @dev The most a purchase may have cost its holder: captured net of refunds plus what it still holds.
    function _worth(bytes32 ref) internal view returns (uint256) {
        return _paid(ref) + _openOf(ref);
    }

    function _paid(bytes32 ref) internal view returns (uint256) {
        (uint64 captured, uint64 refunded) = (cards.purchaseOf(ref).captured, cards.purchaseOf(ref).refunded);
        return captured > refunded ? captured - refunded : 0;
    }

    function _openOf(bytes32 ref) internal view returns (uint256) {
        (bool open, uint64 held, uint64 captured) =
            (cards.purchaseOf(ref).open, cards.purchaseOf(ref).held, cards.purchaseOf(ref).captured);
        if (!open) return 0;
        return held > captured ? held - captured : 0;
    }

    /// @dev Pays a holder's wages.
    function _payday(address h, uint256 amount) internal {
        _mint(h, amount);
    }

    /// @dev The settlement account repays what the treasury advanced it, as far as its free balance allows.
    function _repayAdvance() internal {
        if (treasury.advanceOf(address(usd)) == 0) return;
        vm.prank(settlement);
        treasury.repayAdvance(address(usd), type(uint256).max);
    }

    /// @dev Books a purchase the network approved without asking (a stand-in) with bookStandIn: the holder's free
    ///      cash covers what it can and the issuer absorbs the rest. False when the program refuses it, which only an
    ///      operator's cap may; the issuer would then owe the network outside the program.
    function _bookStandIn(address h, bytes32 card, bytes32 ref, uint128 amount)
        internal
        returns (bool ok, uint256 covered)
    {
        address m = merchants[uint256(ref) % merchants.length];
        vm.prank(issuer);
        try cards.bookStandIn(card, ref, amount, m) {
            ok = true;
        } catch { }
        if (!ok) return (false, 0);
        authorized[h] += amount;
        covered = _paid(ref);
        costCap[h] += _worth(ref);
    }

    // Checks.

    function _tracked() internal view returns (uint256 sum) {
        for (uint256 i; i < parties.length; ++i) {
            sum += usd.balanceOf(parties[i]);
        }
    }

    /// @dev Conservation and custody: no token leaves the tracked parties except by an explicit mint, the core holds
    ///      exactly what it reserves, and neither the program nor the cash source keeps tokens.
    function _checkLedger() internal view {
        assertEq(usd.totalSupply() - _tracked(), residual, "tokens left the tracked parties");
        _assertCoreBalanced();
        _assertSourcesEmpty();
    }

    /// @dev A holder never pays more than their purchases captured net of refunds plus what open purchases hold, and
    ///      never more than they authorized.
    function _checkHolder(address h) internal view {
        uint256 cost = _cost(h);
        assertLe(cost, costCap[h], "holder paid past captured plus held");
        assertLe(cost, authorized[h] * (10_000 + tolBps) / 10_000, "holder paid past authorized plus tolerance");
    }

    /// @dev What a holder has given up: tokens out of their wallet.
    function _cost(address h) internal view returns (uint256) {
        return mintedTo[h] - usd.balanceOf(h);
    }

    /// @dev What the settlement account owes the treasury for advanced payouts.
    function _issuerDebt() internal view returns (uint256) {
        return treasury.advanceOf(address(usd));
    }

    function _unsettled() internal view returns (uint256 u) {
        (, u) = cards.exposure();
    }

    // Output.

    function _log(string memory metric, uint256 value) internal view {
        console.log(string.concat("STRESS ", tag, " ", metric, "=", vm.toString(value)));
    }

    /// @dev "value" in whole dollars.
    function _logUsd(string memory metric, uint256 value) internal view {
        _log(string.concat(metric, "_usd"), value / 1e6);
    }
}
