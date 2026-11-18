// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardConvert } from "../../src/programs/CardConvert.sol";
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
        _setting(abi.encodeCall(cards.setConversion, (address(conv))));
        _allowDebt(usd, 100e6);
        // The program's own funds, which advance what the settlement account lacks.
        usd.mint(address(this), 50e6);
        usd.approve(address(cards), 50e6);
        cards.fundIssuerDebt(address(usd), 50e6);
    }

    function test_payOut_advancesWhatTheSettlementAccountLacksAsDebt() public {
        usd.mint(settlement, 5e6);
        vm.prank(settlement);
        assertEq(cards.payOut(bob, 20e6, bytes32("credit-1")), 15e6);
        assertEq(usd.balanceOf(bob), 20e6);
        assertEq(usd.balanceOf(settlement), 0);
        assertEq(usd.balanceOf(address(cards)), 35e6);
        (address creditor, uint128 debt) = _debt(settlement, address(usd));
        assertEq(creditor, address(cards));
        assertEq(debt, 15e6);
        // What the account receives repays the program first.
        usd.mint(settlement, 10e6);
        _repay(settlement, address(usd));
        (, debt) = _debt(settlement, address(usd));
        assertEq(debt, 5e6);
        assertEq(usd.balanceOf(address(cards)), 45e6);
        // A further payout adds to what it owes.
        vm.prank(issuer);
        assertEq(cards.payOut(bob, 4e6, bytes32("credit-2")), 4e6);
        (, debt) = _debt(settlement, address(usd));
        assertEq(debt, 9e6);
        assertEq(usd.balanceOf(address(cards)), 41e6);
        assertEq(usd.balanceOf(bob), 24e6);
    }

    function test_payOut_refusedPastTheProgramsFunds() public {
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(CardConvert.IssuerFundsShort.selector, 51e6, 50e6));
        cards.payOut(bob, 51e6, bytes32("credit-1"));
    }

    function test_issuerFunds_followTheDebtAndAreNotForwarded() public {
        assertEq(cards.issuerFunds(address(usd)), 50e6);
        vm.prank(settlement);
        cards.payOut(bob, 20e6, bytes32("credit-1"));
        assertEq(cards.issuerFunds(address(usd)), 30e6);
        // What the program forwards to the settlement account leaves its own funds in place, and repays the debt.
        usd.mint(address(cards), 7e6);
        cards.forward(address(usd));
        _repay(settlement, address(usd));
        (, uint128 debt) = _debt(settlement, address(usd));
        assertEq(debt, 13e6);
        assertEq(cards.issuerFunds(address(usd)), 37e6);
        assertEq(usd.balanceOf(address(cards)), 37e6);
        assertEq(usd.balanceOf(settlement), 0);
    }

    function test_payOut_fromWhatTheAccountHoldsNeedsNoAdvance() public {
        usd.mint(settlement, 30e6);
        vm.prank(settlement);
        assertEq(cards.payOut(bob, 20e6, bytes32("credit-1")), 0);
        assertEq(usd.balanceOf(settlement), 10e6);
        (, uint128 debt) = _debt(settlement, address(usd));
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

    function test_operatorRoles_authorizerCannotPayOutRefundOrCollect() public {
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 100e6);
        address key = makeAddr("key");
        uint8 authorizer = cards.ROLE_AUTHORIZE();
        uint8 treasury = cards.ROLE_TREASURY();
        vm.prank(issuer);
        cards.setOperator(key, authorizer, 1000e6);
        assertEq(cards.rolesOf(key), authorizer);
        vm.prank(key);
        cards.authorize(CARD, bytes32("purchase-1"), 10e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.prank(key);
        cards.capture(bytes32("purchase-1"), 10e6, true);
        vm.prank(key);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.payOut(bob, 1e6, bytes32("credit-1"));
        vm.prank(key);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.refund(bytes32("purchase-1"), 1e6);
        vm.prank(key);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.collectReserve(bytes32("reserve-1"), 1e6);
        vm.prank(key);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.reserve(settlement, address(usd), bytes32("reserve-1"), 1e6, uint64(block.timestamp + 1 days), "");
        // A key needs a cap, and zero roles remove it.
        vm.prank(issuer);
        vm.expectRevert(CardProgram.InvalidAmount.selector);
        cards.setOperator(key, treasury, 0);
        vm.prank(issuer);
        cards.setOperator(key, 0, 0);
        assertFalse(cards.operators(key));
        vm.prank(key);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.authorize(CARD, bytes32("purchase-2"), 1e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_operatorCap_countsAuthorizeChargeAndPayOutTogether() public {
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 100e6);
        address key = makeAddr("key");
        vm.prank(issuer);
        cards.setOperator(key, 7, 100e6);
        vm.prank(key);
        cards.authorize(CARD, bytes32("purchase-1"), 40e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.prank(key);
        cards.charge(CARD, bytes32("purchase-2"), 30e6, merchant);
        vm.prank(key);
        cards.payOut(bob, 20e6, bytes32("credit-1"));
        (uint256 cap, uint256 used) = cards.operatorCap(key);
        assertEq(cap, 100e6);
        assertEq(used, 90e6);
        vm.prank(key);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.KeyCapExceeded.selector, 10e6));
        cards.payOut(bob, 10e6 + 1, bytes32("credit-2"));
        vm.prank(key);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.KeyCapExceeded.selector, 10e6));
        cards.charge(CARD, bytes32("purchase-3"), 10e6 + 1, merchant);
        vm.prank(key);
        cards.payOut(bob, 10e6, bytes32("credit-2"));
        // The issuer itself has no cap.
        vm.prank(issuer);
        cards.payOut(bob, 1e6, bytes32("credit-3"));
    }

    function test_setSettlementToken_carriesIssuerDebtAtTheVenuePriceRoundedUp() public {
        vm.prank(settlement);
        cards.payOut(bob, 20e6, bytes32("credit-1"));
        _allowDebt(eur, type(uint128).max);
        uint256 carried = conv.quoteOut(address(eur), address(usd), 20e6);
        // About 18.24 euros buy back 20 dollars after the venue's cost.
        assertGt(carried, 18.23e6);
        assertLt(carried, 18.25e6);
        _setting(abi.encodeCall(cards.setSettlementToken, (address(eur))));
        _repay(settlement, address(usd));
        (, uint128 old) = _debt(settlement, address(usd));
        assertEq(old, 0);
        (address creditor, uint128 debt) = _debt(settlement, address(eur));
        assertEq(creditor, address(cards));
        assertEq(debt, carried);
        // Clearing the old debt cost the program nothing: what it sent came back as repayment.
        assertEq(usd.balanceOf(address(cards)), 30e6);
        // Euros the account receives repay it.
        eur.mint(settlement, carried);
        _repay(settlement, address(eur));
        (, debt) = _debt(settlement, address(eur));
        assertEq(debt, 0);
        assertEq(eur.balanceOf(address(cards)), carried);
    }

    function test_carryIssuerDebt_leavesIssuerFundsAtWhatTheProgramHolds() public {
        vm.prank(settlement);
        cards.payOut(bob, 20e6, bytes32("credit-1"));
        _allowDebt(eur, type(uint128).max);
        _setting(abi.encodeCall(cards.setSettlementToken, (address(eur))));
        // Until the account repays the old debt, the program holds 10 dollars and retains no more.
        assertEq(usd.balanceOf(address(cards)), 10e6);
        assertEq(cards.issuerFunds(address(usd)), 10e6);
        _repay(settlement, address(usd));
        // The old debt is cleared and the program holds 30 dollars, which is all it can still advance.
        assertEq(usd.balanceOf(address(cards)), 30e6);
        assertEq(cards.issuerFunds(address(usd)), 30e6);
        assertGe(usd.balanceOf(address(cards)), cards.issuerFunds(address(usd)));
        // Nothing of the program's dollars goes on to the settlement account.
        cards.forward(address(usd));
        assertEq(usd.balanceOf(address(cards)), 30e6);
    }

    function test_withdrawIssuerFunds_paysTheSettlementAccountWithinWhatIsRetained() public {
        vm.prank(settlement);
        cards.payOut(bob, 20e6, bytes32("credit-1"));
        vm.prank(bob);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.withdrawIssuerFunds(address(usd), 1e6);
        // 30 dollars stay retained while the account owes 20.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardConvert.IssuerFundsShort.selector, 30e6 + 1, 30e6));
        cards.withdrawIssuerFunds(address(usd), 30e6 + 1);
        vm.prank(issuer);
        cards.withdrawIssuerFunds(address(usd), 10e6);
        assertEq(usd.balanceOf(settlement), 10e6);
        assertEq(usd.balanceOf(address(cards)), 20e6);
        assertEq(cards.issuerFunds(address(usd)), 20e6);
    }

    function test_withdrawIssuerFunds_keepsWhatOpenAuthorizationsAndUnsettledDebtNeed() public {
        bytes32 ref = bytes32("purchase-1");
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 10e6);
        _setOfflineCap(alice, address(cards), address(usd), 100e6);
        // A stand-in approval of 30 the cardholder may not cover: the program's own funds stand behind it.
        uint8 standIn = cards.STAND_IN();
        vm.prank(issuer);
        cards.authorize(CARD, ref, 30e6, merchant, uint64(block.timestamp + 1 days), standIn);
        assertEq(cards.committedIssuerFunds(address(usd)), 30e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardConvert.IssuerFundsShort.selector, 20e6 + 1, 20e6));
        cards.withdrawIssuerFunds(address(usd), 20e6 + 1);
        vm.prank(issuer);
        cards.withdrawIssuerFunds(address(usd), 20e6);
        assertEq(cards.issuerFunds(address(usd)), 30e6);
        // Captured, the settlement account got the 10 the cardholder held (beside the 20 withdrawn); the other 20 is
        // the cardholder's debt, which the issuer still pays the network for until it settles.
        _capture(ref, 30e6, true);
        assertEq(usd.balanceOf(settlement), 30e6);
        assertEq(cards.committedIssuerFunds(address(usd)), 20e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardConvert.IssuerFundsShort.selector, 10e6 + 1, 10e6));
        cards.withdrawIssuerFunds(address(usd), 10e6 + 1);
        // The issuer pays the network and acknowledges it: the rest is free.
        vm.prank(settlement);
        assertEq(cards.payOut(bob, 30e6, bytes32("network")), 0);
        (uint64 seq,,,) = cards.ledger();
        vm.prank(issuer);
        cards.acknowledgeSettlement(seq);
        assertEq(cards.committedIssuerFunds(address(usd)), 0);
        vm.prank(issuer);
        cards.withdrawIssuerFunds(address(usd), 30e6);
        assertEq(cards.issuerFunds(address(usd)), 0);
    }

    function testFuzz_issuerFunds_neverAboveTheBalanceAfterATokenChange(uint64 paid, uint64 withdrawn) public {
        // Carrying sends the old debt from what the program still holds, so it carries at most half its funds.
        paid = uint64(bound(paid, 1, 25e6));
        vm.prank(settlement);
        cards.payOut(bob, paid, bytes32("credit-1"));
        _allowDebt(eur, type(uint128).max);
        _setting(abi.encodeCall(cards.setSettlementToken, (address(eur))));
        assertGe(usd.balanceOf(address(cards)), cards.issuerFunds(address(usd)));
        assertGe(eur.balanceOf(address(cards)), cards.issuerFunds(address(eur)));
        _repay(settlement, address(usd));
        assertGe(usd.balanceOf(address(cards)), cards.issuerFunds(address(usd)));
        withdrawn = uint64(bound(withdrawn, 0, cards.issuerFunds(address(usd))));
        if (withdrawn != 0) {
            vm.prank(issuer);
            cards.withdrawIssuerFunds(address(usd), withdrawn);
        }
        assertGe(usd.balanceOf(address(cards)), cards.issuerFunds(address(usd)));
    }

    function test_setSettlementToken_refusedWhenTheIssuerCannotOweInTheNewToken() public {
        vm.prank(settlement);
        cards.payOut(bob, 20e6, bytes32("credit-1"));
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SettlementTokenInUse.selector, uint8(8)));
        cards.setSettlementToken(address(eur));
        // Within a cap too small for the carried debt, it is refused as well.
        _allowDebt(eur, 18e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SettlementTokenInUse.selector, uint8(8)));
        cards.setSettlementToken(address(eur));
    }

    function test_setSettlementToken_withoutIssuerDebtChargesNothing() public {
        _setting(abi.encodeCall(cards.setSettlementToken, (address(eur))));
        (, uint128 debt) = _debt(settlement, address(eur));
        assertEq(debt, 0);
        assertEq(usd.balanceOf(address(cards)), 50e6);
    }

    function _allowDebt(ITIP20Token token, uint128 cap) internal {
        vm.startPrank(settlement);
        token.approve(address(cards), type(uint256).max);
        core.approveHolder(address(cards), address(token), type(uint128).max, 0);
        core.setPayeeTerms(
            address(cards), address(token), _withDebtCap(settlement, address(cards), address(token), cap)
        );
        vm.stopPrank();
    }
}
