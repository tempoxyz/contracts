// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CardFunding } from "../../../src/programs/CardFunding.sol";
import { CardLimits } from "../../../src/programs/CardLimits.sol";
import { CardProgram } from "../../../src/programs/CardProgram.sol";
import { CreditLine } from "../../../src/programs/CreditLine.sol";
import { SavingsFacility } from "../../../src/programs/SavingsFacility.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "../../../src/programs/interfaces/IReservationCore.sol";
import { CoreEnv } from "../../core/harness/CoreEnv.sol";
import { MockReservationCore } from "./MockReservationCore.sol";

/// @notice The world card programs run on: real TIP-20 tokens and a real EarnVault from `CoreEnv`, the test model
///         of the reservation core etched at its precompile address, and one issuer's `CardProgram` with a
///         `SavingsFacility` and a `CreditLine` it accepts as funding sources.
abstract contract ProgramsEnv is CoreEnv {
    MockReservationCore internal core = MockReservationCore(RESERVATION_CORE_ADDRESS);
    CardProgram internal cards;
    SavingsFacility internal facility;
    CreditLine internal credit;

    address internal issuer = makeAddr("issuer");
    address internal settlement = makeAddr("issuer.settlement");
    address internal funder = makeAddr("funder");
    address internal lender = makeAddr("lender");
    address internal merchant = makeAddr("merchant");

    bytes32 internal constant CARD = bytes32("card-1");
    uint256 internal constant FLOAT = 10_000e6;

    function _deployPrograms() internal {
        _deployCore();
        vm.etch(RESERVATION_CORE_ADDRESS, address(new MockReservationCore()).code);
        vm.allowCheatcodes(RESERVATION_CORE_ADDRESS);
        vm.label(RESERVATION_CORE_ADDRESS, "ReservationCore");

        cards = new CardProgram(issuer, address(usd), settlement);
        facility = new SavingsFacility(IEarnVault(address(earnVault)), settlement, funder);
        credit = new CreditLine();
        usd.mint(address(facility), FLOAT);
        vm.startPrank(issuer);
        cards.setSource(address(facility), true);
        cards.setSource(address(credit), true);
        vm.stopPrank();
        vm.label(address(cards), "CardProgram");
        vm.label(address(facility), "SavingsFacility");
        vm.label(address(credit), "CreditLine");
    }

    function _limits(uint80 perPurchase, uint80 daily, uint80 monthly)
        internal
        pure
        returns (CardProgram.Limits memory)
    {
        return CardProgram.Limits({ perPurchase: perPurchase, daily: daily, monthly: monthly });
    }

    /// @dev Issues `CARD` to `owner` with all legs and approves the program as holder of cash and shares.
    function _issue(address owner, CardProgram.Limits memory limits) internal {
        vm.prank(issuer);
        cards.issueCard(CARD, owner, uint40(block.timestamp + 365 days), limits, 7);
        vm.startPrank(owner);
        core.approveHolder(address(cards), address(usd), type(uint128).max);
        core.approveHolder(address(cards), address(earnShare), type(uint128).max);
        _setFunding(address(usd), address(facility), address(0), 0);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
        vm.stopPrank();
    }

    /// @dev Sets the caller's funding order to cash, then savings, then credit, skipping zero addresses.
    function _setFunding(address cash, address savings, address line, uint64 lineId) internal {
        uint256 n = (cash != address(0) ? 1 : 0) + (savings != address(0) ? 1 : 0) + (line != address(0) ? 1 : 0);
        CardFunding.Source[] memory order = new CardFunding.Source[](n);
        uint256 i;
        if (cash != address(0)) order[i++] = CardFunding.Source({ kind: 1, source: cash, lineId: 0 });
        if (savings != address(0)) order[i++] = CardFunding.Source({ kind: 2, source: savings, lineId: 0 });
        if (line != address(0)) order[i++] = CardFunding.Source({ kind: 4, source: line, lineId: lineId });
        cards.setFunding(cash, order);
    }

    /// @dev Opens an accepted line from `lender` to `borrower` for the program, funded and approved.
    function _openLine(address borrower, uint128 limit, IEarnVault vault, uint16 ltvBps)
        internal
        returns (uint64 lineId)
    {
        usd.mint(lender, 100_000e6);
        vm.startPrank(lender);
        core.approveHolder(address(credit), address(usd), type(uint128).max);
        lineId = credit.openLine(
            borrower, address(usd), address(cards), limit, uint64(block.timestamp + 60 days), 7 days, vault, ltvBps
        );
        vm.stopPrank();
        vm.prank(borrower);
        credit.acceptLine(lineId);
    }

    function _authorize(bytes32 ref, uint128 amount) internal {
        vm.prank(issuer);
        cards.authorize(CARD, ref, amount, merchant, uint64(block.timestamp + 7 days), 0);
    }

    function _capture(bytes32 ref, uint128 amount, bool isFinal) internal {
        vm.prank(issuer);
        cards.capture(ref, amount, isFinal);
    }

    function _hold(address owner, bytes32 ref, uint8 leg) internal view returns (IReservationCore.HoldRecord memory) {
        return core.getHold(owner, cards.legId(ref, leg));
    }

    /// @dev The model holds every reserved token itself, so its balance must equal the total reserved.
    function _assertCoreBalanced() internal view {
        assertEq(usd.balanceOf(address(core)), core.totalReserved(address(usd)), "usd reserved");
        assertEq(earnShare.balanceOf(address(core)), core.totalReserved(address(earnShare)), "share reserved");
    }
}
