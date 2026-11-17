// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardProgram } from "../../src/programs/CardProgram.sol";
import { Conversion } from "../../src/programs/Conversion.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice An issuer paying out more than its settlement account holds: the program advances the rest as core debt
///         the account owes the program, incoming funds repay it first, and a settlement token change carries it into
///         the new token at the venue's price.
contract IssuerDebtTest is ProgramsEnv {
    // EUR at $1.10 with a 30 bps conversion cost each way.
    uint256 internal constant BID = 1.0967e18;
    uint256 internal constant ASK = 1_103_310_000_000_000_000;

    ITIP20Token internal eur;
    Conversion internal conv;

    function setUp() public {
        _deployPrograms();
        eur = _createToken("Euro", "EURX");
        conv = new Conversion(address(usd), address(this));
        FixedPricePool bid = new FixedPricePool(address(eur), address(usd), BID);
        FixedPricePool ask = new FixedPricePool(address(eur), address(usd), ASK);
        usd.mint(address(bid), 1_000_000e6);
        eur.mint(address(ask), 1_000_000e6);
        conv.setVenue(address(eur), address(usd), address(bid), true);
        conv.setVenue(address(usd), address(eur), address(ask), false);
        conv.setReferenceRate(address(eur), 1.1e18);
        vm.prank(issuer);
        cards.setConversion(address(conv));
        _allowDebt(usd, 100e6);
        // The program's own funds, which advance what the settlement account lacks.
        usd.mint(address(cards), 50e6);
    }

    function test_payOut_advancesWhatTheSettlementAccountLacksAsDebt() public {
        usd.mint(settlement, 5e6);
        vm.prank(settlement);
        assertEq(cards.payOut(bob, 20e6, bytes32("credit-1")), 15e6);
        assertEq(usd.balanceOf(bob), 20e6);
        assertEq(usd.balanceOf(settlement), 0);
        assertEq(usd.balanceOf(address(cards)), 35e6);
        (address creditor, uint128 debt) = core.debtOf(settlement, address(usd));
        assertEq(creditor, address(cards));
        assertEq(debt, 15e6);
        // What the account receives repays the program first.
        usd.mint(settlement, 10e6);
        core.repay(settlement, address(usd));
        (, debt) = core.debtOf(settlement, address(usd));
        assertEq(debt, 5e6);
        assertEq(usd.balanceOf(address(cards)), 45e6);
        // A further payout adds to what it owes.
        vm.prank(issuer);
        assertEq(cards.payOut(bob, 4e6, bytes32("credit-2")), 4e6);
        (, debt) = core.debtOf(settlement, address(usd));
        assertEq(debt, 9e6);
        assertEq(usd.balanceOf(address(cards)), 41e6);
        assertEq(usd.balanceOf(bob), 24e6);
    }

    function test_payOut_fromWhatTheAccountHoldsNeedsNoAdvance() public {
        usd.mint(settlement, 30e6);
        vm.prank(settlement);
        assertEq(cards.payOut(bob, 20e6, bytes32("credit-1")), 0);
        assertEq(usd.balanceOf(settlement), 10e6);
        (, uint128 debt) = core.debtOf(settlement, address(usd));
        assertEq(debt, 0);
        assertEq(usd.balanceOf(address(cards)), 50e6);
    }

    function test_payOut_refusedPastTheDebtCap() public {
        vm.prank(settlement);
        vm.expectRevert();
        cards.payOut(bob, 100e6 + 1, bytes32("credit-1"));
    }

    function test_payOut_onlyTheSettlementAccountIssuerOrOperator() public {
        vm.prank(bob);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.payOut(bob, 1e6, bytes32("credit-1"));
    }

    function test_setSettlementToken_carriesIssuerDebtAtTheVenuePriceRoundedUp() public {
        vm.prank(settlement);
        cards.payOut(bob, 20e6, bytes32("credit-1"));
        _allowDebt(eur, type(uint128).max);
        uint256 carried = conv.quoteOut(address(eur), address(usd), 20e6);
        // About 18.24 euros buy back 20 dollars after the venue's cost.
        assertGt(carried, 18.23e6);
        assertLt(carried, 18.25e6);
        vm.prank(issuer);
        cards.setSettlementToken(address(eur));
        core.repay(settlement, address(usd));
        (, uint128 old) = core.debtOf(settlement, address(usd));
        assertEq(old, 0);
        (address creditor, uint128 debt) = core.debtOf(settlement, address(eur));
        assertEq(creditor, address(cards));
        assertEq(debt, carried);
        // Clearing the old debt cost the program nothing: what it sent came back as repayment.
        assertEq(usd.balanceOf(address(cards)), 30e6);
        // Euros the account receives repay it.
        eur.mint(settlement, carried);
        core.repay(settlement, address(eur));
        (, debt) = core.debtOf(settlement, address(eur));
        assertEq(debt, 0);
        assertEq(eur.balanceOf(address(cards)), carried);
    }

    function test_setSettlementToken_refusedWhenTheIssuerCannotOweInTheNewToken() public {
        vm.prank(settlement);
        cards.payOut(bob, 20e6, bytes32("credit-1"));
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SettlementTokenInUse.selector, uint8(7)));
        cards.setSettlementToken(address(eur));
        // Within a cap too small for the carried debt, it is refused as well.
        _allowDebt(eur, 18e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SettlementTokenInUse.selector, uint8(7)));
        cards.setSettlementToken(address(eur));
    }

    function test_setSettlementToken_withoutIssuerDebtChargesNothing() public {
        vm.prank(issuer);
        cards.setSettlementToken(address(eur));
        (, uint128 debt) = core.debtOf(settlement, address(eur));
        assertEq(debt, 0);
        assertEq(usd.balanceOf(address(cards)), 50e6);
    }

    function _allowDebt(ITIP20Token token, uint128 cap) internal {
        vm.startPrank(settlement);
        token.approve(address(cards), type(uint256).max);
        core.approveHolder(address(cards), address(token), type(uint128).max);
        core.setDebtCap(address(cards), address(token), cap);
        vm.stopPrank();
    }
}
