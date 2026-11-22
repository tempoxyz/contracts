// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../../../src/interfaces/earn/IEarnVault.sol";

import { CardAuth } from "../../../../src/spend/programs/CardAuth.sol";
import { CardAuthAdmin } from "../../../../src/spend/programs/CardAuthAdmin.sol";
import { CardLegs } from "../../../../src/spend/programs/CardLegs.sol";
import { CardLimits } from "../../../../src/spend/programs/CardLimits.sol";
import { CashSource } from "../../../../src/spend/programs/CashSource.sol";
import { SavingsSource } from "../../../../src/spend/programs/SavingsSource.sol";
import {
    IReservationCore,
    RESERVATION_CORE_ADDRESS
} from "../../../../src/interfaces/spend/programs/IReservationCore.sol";
import { ISource } from "../../../../src/interfaces/spend/programs/ISource.sol";
import { CoreEnv } from "../../core/harness/CoreEnv.sol";
import { MockReservationCore } from "./MockReservationCore.sol";
import { StubSource } from "./StubSource.sol";

interface IMockToken {
    function balanceOf(address account) external view returns (uint256);
    function grantRole(bytes32 role, address account) external;
}

/// @notice The world card authorization runs on: real TIP-20 tokens and a real EarnVault from `CoreEnv`, the test
///         model of the reservation core etched at its precompile address, and one issuer's `CardAuth` with a
///         `CashSource`, a `SavingsSource` and a credit-like `StubSource` approved as funding sources.
abstract contract AuthEnv is CoreEnv {
    MockReservationCore internal core = MockReservationCore(RESERVATION_CORE_ADDRESS);
    /// @dev The one CardAuthAdmin every CardAuth here runs.
    CardAuthAdmin internal admin;
    CardAuth internal cards;
    CashSource internal cash;
    SavingsSource internal savings;
    StubSource internal line;

    address internal issuer = makeAddr("issuer");
    address internal settlement = makeAddr("issuer.settlement");
    address internal funder = makeAddr("funder");
    address internal merchant = makeAddr("merchant");

    bytes32 internal constant CARD = bytes32("card-1");
    uint256 internal constant FLOAT = 10_000e6;
    /// @dev Order entries in the default funding order.
    uint256 internal constant CASH_LEG = 0;
    uint256 internal constant SAVINGS_LEG = 1;
    uint256 internal constant CREDIT_LEG = 2;

    function _deployPrograms() internal {
        _deployCore();
        vm.etch(RESERVATION_CORE_ADDRESS, address(new MockReservationCore()).code);
        vm.allowCheatcodes(RESERVATION_CORE_ADDRESS);
        vm.label(RESERVATION_CORE_ADDRESS, "ReservationCore");

        admin = new CardAuthAdmin();
        cards = new CardAuth(issuer, settlement, address(usd), address(admin));
        cash = new CashSource(cards);
        savings = new SavingsSource(cards, IEarnVault(address(earnVault)), funder);
        line = new StubSource(cards, address(usd));
        usd.mint(address(savings), FLOAT);
        usd.mint(address(line), FLOAT);
        vm.startPrank(issuer);
        cards.setSource(address(cash), true);
        cards.setSource(address(savings), true);
        cards.setSource(address(line), true);
        vm.stopPrank();
        vm.label(address(cards), "CardAuth");
        vm.label(address(cash), "CashSource");
        vm.label(address(savings), "SavingsSource");
        vm.label(address(line), "StubSource");
    }

    function _limits(uint80 perPurchase, uint80 daily, uint80 monthly)
        internal
        pure
        returns (CardLimits.Limits memory)
    {
        return CardLimits.Limits({ perPurchase: perPurchase, daily: daily, monthly: monthly });
    }

    /// @dev Issues `CARD` to `owner` for every kind, approves the sources on cash and shares, orders cash then
    ///      savings, and grants open terms.
    function _issue(address owner, CardLimits.Limits memory limits) internal {
        vm.prank(issuer);
        cards.issueCard(CARD, owner, uint40(block.timestamp + 365 days), limits, 7);
        vm.startPrank(owner);
        core.approveHolder(address(cash), address(usd), type(uint128).max, 0);
        core.approveHolder(address(savings), address(earnShare), type(uint128).max, 0);
        _setFunding(true, true, false);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
        vm.stopPrank();
    }

    /// @dev Sets the caller's funding order to cash (in usd), then savings, then the stub line, skipping those off.
    function _setFunding(bool withCash, bool withSavings, bool withLine) internal {
        CardLegs.Funding[] memory order = new CardLegs.Funding[](3);
        uint256 n;
        if (withCash) order[n++] = _cashEntry(address(usd), 0);
        if (withSavings) order[n++] = CardLegs.Funding(ISource(address(savings)), bytes32(0));
        if (withLine) order[n++] = CardLegs.Funding(ISource(address(line)), bytes32(0));
        assembly ("memory-safe") {
            mstore(order, n)
        }
        cards.setFunding(order);
    }

    /// @dev A cash order entry in `token` that may convert at a cost of at most `maxCostBps`.
    function _cashEntry(address token, uint16 maxCostBps) internal view returns (CardLegs.Funding memory) {
        return CardLegs.Funding(ISource(address(cash)), _position(token, maxCostBps));
    }

    function _position(address token, uint16 maxCostBps) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(token)) | uint256(maxCostBps) << 160);
    }

    /// @dev Calls a program setting as the issuer and, when it waits SETTINGS_DELAY, applies it once the delay passes,
    ///      then sets the clock back so the test's timeline is unchanged.
    function _setting(bytes memory data) internal {
        _issuerCall(data);
        uint64 eta = cards.pendingSetting(keccak256(data));
        if (eta == 0) return;
        uint256 at = vm.getBlockTimestamp();
        vm.warp(eta);
        _issuerCall(data);
        vm.warp(at);
    }

    function _issuerCall(bytes memory data) private {
        vm.prank(issuer);
        (bool ok, bytes memory result) = address(cards).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _authorize(bytes32 ref, uint128 amount) internal returns (uint256) {
        vm.prank(issuer);
        return cards.authorize(CARD, ref, amount, merchant, uint64(block.timestamp + 7 days), 0);
    }

    function _capture(bytes32 ref, uint128 amount, bool isFinal) internal {
        vm.prank(issuer);
        cards.capture(ref, amount, isFinal);
    }

    /// @dev The hold order entry `leg` of purchase `ref` placed on `owner` through the default order.
    function _hold(address owner, bytes32 ref, uint256 leg) internal view returns (IReservationCore.HoldRecord memory) {
        address source = leg == CASH_LEG ? address(cash) : leg == SAVINGS_LEG ? address(savings) : address(line);
        return core.getHold(owner, source, cards.legId(ref, leg));
    }

    /// @dev Which order entries purchase `ref` drew on, as a bitmask.
    function _legs(bytes32 ref) internal view returns (uint256 legs) {
        (,, bytes32[] memory ids) = cards.legsOf(ref);
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < ids.length; ++j) {
                if (ids[j] == cards.legId(ref, i)) legs |= 1 << i;
            }
        }
    }

    /// @dev Sets `owner`'s capture tolerance for `payee` in `token`. Holds placed later take it.
    function _setTolerance(address owner, address payee, address token, uint16 bps) internal {
        vm.prank(owner);
        core.setCaptureTolerance(payee, token, bps);
    }

    /// @dev The model holds every reserved token itself, so its balance must equal the total reserved.
    function _assertCoreBalanced() internal view {
        assertEq(usd.balanceOf(address(core)), core.totalReserved(address(usd)), "usd reserved");
        assertEq(earnShare.balanceOf(address(core)), core.totalReserved(address(earnShare)), "share reserved");
    }

    /// @dev The sources keep nothing of the settlement token between calls.
    function _assertSourcesEmpty() internal view {
        assertEq(usd.balanceOf(address(cash)), 0, "cash source holds usd");
        assertEq(usd.balanceOf(address(cards)), 0, "card auth holds usd");
    }
}
