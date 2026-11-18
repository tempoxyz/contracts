// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CardProgram } from "../../src/programs/CardProgram.sol";
import { IssuerDesk } from "../../src/programs/IssuerDesk.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice An issuer desk over a card program: splits and rewards paid at capture from the settlement account,
///         taken back in proportion by refunds, and corrections linked to the step they fix.
contract IssuerDeskTest is ProgramsEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    IssuerDesk internal desk;
    address internal network = makeAddr("network");
    address internal partner = makeAddr("partner");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        desk = new IssuerDesk(cards);
        vm.prank(issuer);
        cards.setOperator(address(desk), 7, 1e30);
        vm.prank(settlement);
        usd.approve(address(desk), type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            address payee = i == 0 ? network : partner;
            vm.startPrank(payee);
            core.approveHolder(address(desk), address(usd), type(uint128).max, 0);
            core.setPayeeTerms(settlement, address(usd), _withDebtCap(payee, settlement, address(usd), 1000e6));
            vm.stopPrank();
        }
        vm.prank(alice);
        core.approveHolder(address(desk), address(usd), type(uint128).max, 0);
        IssuerDesk.Line[] memory lines = new IssuerDesk.Line[](2);
        lines[0] = IssuerDesk.Line({ payee: network, bps: 100, kind: "interchange" });
        lines[1] = IssuerDesk.Line({ payee: partner, bps: 200, kind: "program" });
        vm.prank(issuer);
        desk.setTerms(lines);
        usd.mint(alice, 1000e6);
    }

    function _purchase(uint128 amount) internal {
        _authorize(P1, amount);
        vm.prank(issuer);
        desk.capture(P1, amount, true);
    }

    function test_capture_paysSplits() public {
        _purchase(100e6);
        assertEq(usd.balanceOf(network), 1e6, "network split");
        assertEq(usd.balanceOf(partner), 2e6, "partner split");
        assertEq(usd.balanceOf(settlement), 97e6, "issuer keeps the rest");
    }

    function test_charge_paysSplitsAndBooksForDisputes() public {
        vm.prank(issuer);
        desk.charge(CARD, P1, 100e6, merchant);
        assertEq(usd.balanceOf(network), 1e6, "network split");
        assertEq(usd.balanceOf(settlement), 97e6, "issuer keeps the rest");
        vm.prank(issuer);
        desk.openDispute(P1, 100e6, hex"c1a1");
        (, uint8 state,,) = desk.disputes(P1);
        assertEq(state, 1);
    }

    function test_refund_takesSplitsBackInProportion() public {
        _purchase(100e6);
        usd.mint(settlement, 100e6);
        vm.prank(issuer);
        desk.refund(P1, 50e6);
        assertEq(usd.balanceOf(network), 0.5e6, "half the network split back");
        assertEq(usd.balanceOf(partner), 1e6, "half the partner split back");
        assertEq(usd.balanceOf(alice), 950e6, "refund reaches the owner");
    }

    function test_refund_keepsStandingAllowance_andSeed() public {
        _purchase(100e6);
        usd.mint(address(desk), 1);
        usd.mint(settlement, 100e6);
        vm.prank(issuer);
        desk.refund(P1, 20e6);
        assertEq(usd.allowance(address(desk), address(cards)), type(uint256).max, "standing allowance");
        vm.prank(issuer);
        desk.refund(P1, 30e6);
        assertEq(usd.allowance(address(desk), address(cards)), type(uint256).max, "still standing");
        assertEq(usd.balanceOf(address(desk)), 1, "the seed stays");
        assertEq(usd.balanceOf(alice), 950e6, "both refunds reach the owner");
    }

    function test_refund_payeeWithoutFunds_owesTheRest() public {
        _purchase(100e6);
        vm.prank(network);
        usd.transfer(bob, 1e6);
        usd.mint(settlement, 100e6);
        vm.prank(issuer);
        desk.refund(P1, 100e6);
        (address creditor, uint128 debt) = _debt(network, address(usd));
        assertEq(creditor, settlement, "owed to the settlement account");
        assertEq(debt, 1e6, "the split it no longer has");
    }

    function test_refund_pastTheSettlementBalance_owesTheProgram() public {
        _purchase(100e6);
        // The settlement account kept $97 and spent $90 of it.
        vm.prank(settlement);
        usd.transfer(bob, 90e6);
        _allowIssuerDebt(50e6);
        vm.prank(issuer);
        desk.refund(P1, 20e6);
        assertEq(usd.balanceOf(alice), 920e6, "the whole refund reaches the owner");
        // The splits taken back reach the settlement account, and the core repays its debt from them at once.
        assertEq(usd.balanceOf(settlement), 0, "the splits taken back repay the debt");
        (address creditor, uint128 debt) = _debt(settlement, address(usd));
        assertEq(creditor, address(cards), "owed to the program");
        assertEq(debt, 13e6 - 0.6e6, "what the account lacked, less the splits taken back");
        assertEq(cards.issuerFunds(address(usd)), 37e6 + 0.6e6, "the program advanced it, less what came back");
        assertEq(usd.balanceOf(address(desk)), 0, "the desk keeps nothing");
    }

    function test_refund_pastTheIssuerDebtCap_refused() public {
        _purchase(100e6);
        vm.prank(settlement);
        usd.transfer(bob, 97e6);
        _allowIssuerDebt(10e6);
        vm.prank(issuer);
        vm.expectRevert();
        desk.refund(P1, 20e6);
    }

    function test_rewards_paidFromFunderSplit() public {
        IssuerDesk.Reward[] memory rewards = new IssuerDesk.Reward[](1);
        rewards[0] = IssuerDesk.Reward({ funder: partner, bps: 150, kind: "cashback" });
        vm.prank(issuer);
        desk.setRewards(rewards);
        _purchase(100e6);
        assertEq(usd.balanceOf(partner), 0.5e6, "partner keeps its split less the reward");
        assertEq(usd.balanceOf(alice), 900e6 + 1.5e6, "owner gets the reward");
        usd.mint(settlement, 100e6);
        vm.prank(issuer);
        desk.refund(P1, 100e6);
        assertEq(usd.balanceOf(alice), 1000e6, "reward taken back with the refund");
        // The partner's fee came back in full, past what it kept, as debt to the settlement account; the reward
        // returning to the partner repays that debt at once.
        assertEq(usd.balanceOf(partner), 0, "the reward returns to its funder and repays its debt");
        (, uint128 partnerDebt) = _debt(partner, address(usd));
        assertEq(partnerDebt, 0, "the partner owes nothing");
    }

    function test_rewards_aboveFunderSplit_refused() public {
        IssuerDesk.Reward[] memory rewards = new IssuerDesk.Reward[](1);
        rewards[0] = IssuerDesk.Reward({ funder: partner, bps: 201, kind: "cashback" });
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.InvalidRewards.selector);
        desk.setRewards(rewards);
    }

    function test_terms_wholeCapture_refused() public {
        IssuerDesk.Line[] memory lines = new IssuerDesk.Line[](1);
        lines[0] = IssuerDesk.Line({ payee: network, bps: 10_000, kind: "all" });
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.InvalidTerms.selector);
        desk.setTerms(lines);
    }

    function test_correct_overcharge_comesBackLikeARefund() public {
        _purchase(100e6);
        (uint64 seq,,,) = cards.ledger();
        usd.mint(settlement, 10e6);
        vm.prank(issuer);
        desk.correct(P1, seq, 10e6, "duplicate fee");
        assertEq(usd.balanceOf(alice), 910e6, "overcharge returned");
        assertEq(usd.balanceOf(partner), 1.8e6, "split taken back in proportion");
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.CorrectionTooLarge.selector);
        desk.correct(P1, seq, 91e6, "too much");
    }

    function test_correct_undercharge_isChargedWithSplits() public {
        _purchase(100e6);
        (uint64 seq,,,) = cards.ledger();
        vm.prank(issuer);
        desk.correct(P1, seq, -10e6, "short capture");
        assertEq(usd.balanceOf(alice), 890e6, "difference charged");
        assertEq(usd.balanceOf(partner), 2.2e6, "split on the difference");
    }

    function test_correct_unknownStep_refused() public {
        _purchase(100e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.NotCorrectable.selector);
        desk.correct(P1, 99, 1e6, "none");
    }

    function test_onlyOperators() public {
        _authorize(P1, 100e6);
        vm.prank(bob);
        vm.expectRevert(IssuerDesk.NotIssuer.selector);
        desk.capture(P1, 100e6, true);
    }

    function _disputed(uint128 amount) internal {
        _purchase(amount);
        _setDebtCap(alice, settlement, address(usd), amount);
        vm.prank(issuer);
        desk.openDispute(P1, amount, hex"c1a1");
    }

    function test_dispute_lost_takesProvisionalBack_restAsDebt() public {
        _disputed(80e6);
        usd.mint(settlement, 80e6);
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 80e6, "", false);
        assertEq(usd.balanceOf(alice), 1000e6, "provisional credit paid");
        vm.prank(alice);
        usd.transfer(bob, 990e6);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        (address creditor, uint128 debt) = _debt(alice, address(usd));
        assertEq(creditor, settlement, "owed to the settlement account");
        assertEq(debt, 70e6, "what the cardholder no longer has");
        assertEq(usd.balanceOf(alice), 0, "the rest taken at once");
    }

    function test_dispute_provisionalPastTheSettlementBalance_owesTheProgram() public {
        _disputed(80e6);
        // The settlement account kept $77.60 and spent $70.60 of it.
        vm.prank(settlement);
        usd.transfer(bob, 70.6e6);
        _allowIssuerDebt(100e6);
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 30e6, "", false);
        assertEq(usd.balanceOf(alice), 950e6, "provisional credit paid in full");
        (address creditor, uint128 debt) = _debt(settlement, address(usd));
        assertEq(creditor, address(cards), "owed to the program");
        assertEq(debt, 30e6 - 7e6, "what the account lacked");
    }

    function test_dispute_wonPastTheSettlementBalance_owesTheProgram() public {
        _disputed(80e6);
        vm.prank(settlement);
        usd.transfer(bob, 40e6);
        _allowIssuerDebt(100e6);
        vm.prank(issuer);
        desk.resolveDispute(P1, true);
        assertEq(usd.balanceOf(alice), 1000e6, "the whole disputed amount comes back");
        (address creditor, uint128 debt) = _debt(settlement, address(usd));
        assertEq(creditor, address(cards), "owed to the program");
        // The splits taken back (2.4) reach the settlement account and repay its debt at once.
        assertEq(debt, 80e6 - 37.6e6 - 2.4e6, "what the account lacked, less the splits taken back");
        assertEq(usd.balanceOf(address(desk)), 0, "the desk keeps nothing");
    }

    function test_dispute_steps_onlyForward_andProvisionalCapped() public {
        _disputed(50e6);
        usd.mint(settlement, 100e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.DisputeTooLarge.selector);
        desk.disputeStep(P1, 3, 51e6, "", false);
        vm.prank(issuer);
        desk.disputeStep(P1, 3, 50e6, "", true);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.InvalidDisputeStep.selector);
        desk.disputeStep(P1, 2, 0, "", false);
    }

    function test_dispute_won_countsAsRefund() public {
        _disputed(50e6);
        usd.mint(settlement, 50e6);
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 20e6, "", false);
        vm.prank(issuer);
        desk.resolveDispute(P1, true);
        assertEq(usd.balanceOf(alice), 1000e6, "provisional plus the refunded rest");
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.RefundTooLarge.selector);
        desk.refund(P1, 1e6);
    }

    function test_dispute_won_reserveCoveredRefundLeavesSettlement() public {
        _disputed(50e6);
        usd.mint(settlement, 50e6);
        (,, uint128 before,) = cards.ledger();
        // The merchant's reserves paid the issuer 30 of the 50.
        vm.prank(issuer);
        desk.collectedReserve(P1, 30e6);
        vm.prank(issuer);
        desk.resolveDispute(P1, true);
        assertEq(usd.balanceOf(alice), 1000e6, "the whole purchase refunded");
        // The network returns only the 20 the reserves did not cover.
        (,, uint128 net,) = cards.ledger();
        assertEq(before - net, 20e6, "net settlement less the reserve-paid part");
    }

    function test_reserveSettled_onlyOperatorAndKnownPurchase() public {
        _purchase(10e6);
        vm.prank(bob);
        vm.expectRevert();
        cards.reserveSettled(P1, 1e6);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.UnknownPurchase.selector);
        cards.reserveSettled(bytes32("missing"), 1e6);
    }

    function test_dispute_open_keepsTheSettlementToken() public {
        assertEq(desk.settlementTokenInUse(address(cards)), 0);
        _disputed(50e6);
        assertEq(desk.openDisputes(), 1);
        assertEq(desk.settlementTokenInUse(address(cards)), 4);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(desk.openDisputes(), 0);
        assertEq(desk.settlementTokenInUse(address(cards)), 0);
    }

    // A $100 purchase, $40 from cash and $60 from a credit line, disputed in full.
    function _disputedOnCredit() internal returns (uint64 lineId) {
        lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0);
        vm.startPrank(alice);
        _setFunding(address(usd), address(0), address(credit), lineId);
        usd.transfer(bob, 960e6);
        vm.stopPrank();
        _purchase(100e6);
        assertEq(credit.lineOf(lineId).owed, 60e6, "drawn");
        _setDebtCap(alice, settlement, address(usd), 100e6);
        vm.prank(issuer);
        desk.openDispute(P1, 100e6, hex"c1a1");
        usd.mint(settlement, 100e6);
    }

    function test_dispute_creditPurchase_provisionalRepaysTheLine_merchantWinDrawsItAgain() public {
        uint64 lineId = _disputedOnCredit();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 100e6, "", false);
        assertEq(credit.lineOf(lineId).owed, 0, "the line's share repaid it");
        assertEq(usd.balanceOf(alice), 40e6, "only the cash share came as cash");
        (uint128 repaid, uint128 landed) = desk.lineShares(P1, 1);
        assertEq(repaid, 60e6);
        assertEq(landed, 0);
        uint256 before = usd.balanceOf(settlement);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(credit.lineOf(lineId).owed, 60e6, "drawn again");
        assertEq(usd.balanceOf(settlement), before + 100e6, "the lender pays the line's share, the cardholder the rest");
        assertEq(usd.balanceOf(alice), 0);
        (, uint128 debt) = _debt(alice, address(usd));
        assertEq(debt, 0);
    }

    function test_redrawLine_needsTheTreasuryRoleAnApprovedLineAndRoomUnderTheCap() public {
        uint64 lineId = _disputedOnCredit();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 100e6, "", false);
        address key = makeAddr("redraw-key");
        uint8 authorizer = cards.ROLE_AUTHORIZE();
        uint8 treasury = cards.ROLE_TREASURY();
        vm.prank(issuer);
        cards.setOperator(key, authorizer, 1000e6);
        vm.prank(key);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.redrawLine(address(credit), lineId, 10e6, P1);
        vm.prank(issuer);
        cards.setOperator(key, treasury, 25e6);
        vm.prank(key);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SourceNotApproved.selector, bob));
        cards.redrawLine(bob, lineId, 10e6, P1);
        vm.prank(key);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.KeyCapExceeded.selector, 25e6));
        cards.redrawLine(address(credit), lineId, 30e6, P1);
        uint256 before = usd.balanceOf(settlement);
        vm.prank(key);
        assertEq(cards.redrawLine(address(credit), lineId, 20e6, P1), 20e6);
        assertEq(usd.balanceOf(settlement), before + 20e6);
        (, uint256 used) = cards.operatorCap(key);
        assertEq(used, 20e6);
    }

    function test_dispute_creditPurchase_merchantWinDrawsOnlyWhatTheLenderCanFund() public {
        uint64 lineId = _disputedOnCredit();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 100e6, "", false);
        vm.startPrank(lender);
        credit.setLimit(lineId, 25e6);
        usd.transfer(bob, usd.balanceOf(lender));
        vm.stopPrank();
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(credit.lineOf(lineId).owed, 25e6, "what the lender could fund");
        // The cardholder owes the other $75: the $40 it holds at once, the rest as debt.
        assertEq(usd.balanceOf(alice), 0);
        (, uint128 debt) = _debt(alice, address(usd));
        assertEq(debt, 35e6);
    }

    function test_dispute_creditPurchase_lineClosedBeforeTheMerchantWins_recoversFromTheCardholder() public {
        uint64 lineId = _disputedOnCredit();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 100e6, "", false);
        assertEq(credit.lineOf(lineId).owed, 0, "the line's share repaid it");
        // The cardholder closes the repaid line before the dispute ends.
        vm.prank(alice);
        credit.closeLine(lineId);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(credit.lineOf(lineId).owed, 0, "a closed line is not drawn again");
        // The whole provisional credit comes back from the cardholder: the $40 it holds, the rest as debt.
        assertEq(usd.balanceOf(alice), 0);
        (, uint128 debt) = _debt(alice, address(usd));
        assertEq(debt, 60e6);
    }

    function test_dispute_creditPurchase_repaidLineTakesItsShareAsCash() public {
        uint64 lineId = _disputedOnCredit();
        usd.mint(alice, 60e6);
        vm.startPrank(alice);
        usd.approve(address(credit), 60e6);
        credit.repay(lineId, 60e6);
        vm.stopPrank();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 50e6, "", false);
        assertEq(usd.balanceOf(alice), 50e6, "nothing owed, so all cash");
        (uint128 repaid, uint128 landed) = desk.lineShares(P1, 1);
        assertEq(repaid, 0);
        assertEq(landed, 30e6, "cash that still counts as the line's share");
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(credit.lineOf(lineId).owed, 0, "never drawn again");
    }

    function test_dispute_aboveCaptured_refused() public {
        _purchase(50e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.DisputeTooLarge.selector);
        desk.openDispute(P1, 51e6, "");
    }

    function test_refund_atTheLeastGasItSucceedsWith_takesEverySplitBack() public {
        _purchase(100e6);
        usd.mint(settlement, 100e6);
        // The network already owes the issuer from an earlier refund, so recording more costs little.
        vm.prank(network);
        core.approveHolder(address(desk), address(usd), 0, 0);
        vm.prank(issuer);
        desk.refund(P1, 10e6);
        uint256 owed = desk.payeeOwed(network, address(usd));
        assertGt(owed, 0);
        vm.prank(network);
        core.approveHolder(address(desk), address(usd), 100e6, 0);
        // Searching down to the least gas the refund succeeds with, as gas estimation does: every refund that
        // succeeds takes the network's split back rather than recording it as owed.
        (uint256 low, uint256 high) = (0, 20_000_000);
        while (high - low > 1) {
            uint256 g = (low + high) / 2;
            uint256 snapshot = vm.snapshotState();
            vm.prank(issuer);
            try desk.refund{ gas: g }(P1, 50e6) {
                high = g;
                assertEq(desk.payeeOwed(network, address(usd)), owed, "network");
            } catch {
                low = g;
            }
            vm.revertToStateAndDelete(snapshot);
        }
    }

    function test_refund_payeeRevokedApproval_stillRefunds() public {
        _purchase(100e6);
        vm.prank(network);
        core.approveHolder(address(desk), address(usd), 0, 0);
        usd.mint(settlement, 100e6);
        vm.prank(issuer);
        desk.refund(P1, 100e6);
        assertEq(usd.balanceOf(alice), 1000e6, "the whole refund reaches the owner");
        assertEq(usd.balanceOf(network), 1e6, "the network kept its split");
        assertEq(usd.balanceOf(partner), 0, "the partner returned its split");
        assertEq(desk.payeeOwed(network, address(usd)), 1e6, "the network owes its split to the issuer");
        assertEq(desk.payeeOwed(partner, address(usd)), 0);
        (, uint128 debt) = _debt(network, address(usd));
        assertEq(debt, 0, "no debt on the core");
    }

    function test_collectPayeeOwed_takesWhatThePayeeHas_andReducesTheRecord() public {
        test_refund_payeeRevokedApproval_stillRefunds();
        vm.prank(issuer);
        vm.expectRevert();
        desk.collectPayeeOwed(network, address(usd), 1e6);
        vm.startPrank(network);
        core.approveHolder(address(desk), address(usd), type(uint128).max, 0);
        usd.transfer(bob, 0.6e6);
        vm.stopPrank();
        uint256 before = usd.balanceOf(settlement);
        vm.prank(issuer);
        uint128 collected = desk.collectPayeeOwed(network, address(usd), 1e6);
        assertEq(collected, 0.4e6, "what the network had");
        assertEq(usd.balanceOf(settlement), before + 0.4e6, "to the settlement account");
        assertEq(desk.payeeOwed(network, address(usd)), 0.6e6, "the rest still owed");
        usd.mint(network, 5e6);
        vm.prank(issuer);
        collected = desk.collectPayeeOwed(network, address(usd), 5e6);
        assertEq(collected, 0.6e6, "never more than recorded");
        assertEq(desk.payeeOwed(network, address(usd)), 0);
        assertEq(usd.balanceOf(network), 4.4e6);
        vm.prank(bob);
        vm.expectRevert(IssuerDesk.NotIssuer.selector);
        desk.collectPayeeOwed(network, address(usd), 1);
    }

    function test_refund_emptyPayeeWithoutDebtCap_stillRefunds() public {
        _purchase(100e6);
        vm.startPrank(network);
        usd.transfer(bob, 1e6);
        core.setPayeeTerms(settlement, address(usd), _withDebtCap(network, settlement, address(usd), 0));
        vm.stopPrank();
        usd.mint(settlement, 100e6);
        vm.prank(issuer);
        desk.refund(P1, 100e6);
        assertEq(usd.balanceOf(alice), 1000e6, "the whole refund reaches the owner");
        assertEq(desk.payeeOwed(network, address(usd)), 1e6, "the split it could not return");
        assertEq(usd.balanceOf(partner), 0, "the partner returned its split");
    }

    function test_dispute_won_payeeRevokedApproval_stillResolves() public {
        _disputed(50e6);
        vm.prank(partner);
        core.approveHolder(address(desk), address(usd), 0, 0);
        usd.mint(settlement, 50e6);
        vm.prank(issuer);
        desk.resolveDispute(P1, true);
        assertEq(usd.balanceOf(alice), 1000e6, "the whole disputed amount comes back");
        (, uint8 state,,) = desk.disputes(P1);
        assertEq(state, desk.WON());
        assertEq(desk.payeeOwed(partner, address(usd)), 1e6, "the partner owes its split to the issuer");
        assertEq(usd.balanceOf(network), 0, "the network returned its split");
    }

    function test_programOperator_isNotADeskOperator() public {
        address key = makeAddr("swipeKey");
        vm.prank(issuer);
        cards.setOperator(key, 7, 1e30);
        _authorize(P1, 100e6);
        vm.prank(key);
        vm.expectRevert(IssuerDesk.NotIssuer.selector);
        desk.capture(P1, 100e6, true);
        vm.prank(issuer);
        desk.capture(P1, 100e6, true);
        usd.mint(settlement, 100e6);
        vm.prank(key);
        vm.expectRevert(IssuerDesk.NotIssuer.selector);
        desk.refund(P1, 100e6);
        vm.prank(key);
        vm.expectRevert(IssuerDesk.NotIssuer.selector);
        desk.openDispute(P1, 100e6, "");
    }

    function test_setOperator_onlyIssuer_andZeroCapRemoves() public {
        address key = makeAddr("deskKey");
        vm.prank(bob);
        vm.expectRevert(IssuerDesk.NotIssuer.selector);
        desk.setOperator(key, 1);
        vm.expectEmit(address(desk));
        emit IssuerDesk.OperatorSet(key, 10e6);
        vm.prank(issuer);
        desk.setOperator(key, 10e6);
        (uint256 cap, uint256 used) = desk.operatorCap(key);
        assertEq(cap, 10e6);
        assertEq(used, 0);
        assertEq(desk.ISSUER(), issuer);
        _authorize(P1, 100e6);
        vm.prank(key);
        desk.capture(P1, 100e6, true);
        vm.prank(issuer);
        desk.setOperator(key, 0);
        vm.prank(key);
        vm.expectRevert(IssuerDesk.NotIssuer.selector);
        desk.openDispute(P1, 50e6, "");
    }

    function test_cappedOperator_cannotCreditOrRecoverPastItsCap() public {
        address key = makeAddr("deskKey");
        vm.prank(issuer);
        desk.setOperator(key, 50e6);
        _disputed(80e6);
        usd.mint(settlement, 80e6);
        vm.prank(key);
        vm.expectRevert(IssuerDesk.OperatorCapExceeded.selector);
        desk.disputeStep(P1, 2, 60e6, "", false);
        vm.prank(key);
        desk.disputeStep(P1, 2, 30e6, "", false);
        (, uint256 used) = desk.operatorCap(key);
        assertEq(used, 30e6);
        // Taking the 30 back would bring it to 60, past its cap of 50.
        vm.prank(key);
        vm.expectRevert(IssuerDesk.OperatorCapExceeded.selector);
        desk.resolveDispute(P1, false);
        vm.prank(key);
        vm.expectRevert(IssuerDesk.OperatorCapExceeded.selector);
        desk.collectedReserve(P1, 21e6);
        vm.prank(key);
        desk.collectedReserve(P1, 20e6);
        vm.prank(key);
        vm.expectRevert(IssuerDesk.OperatorCapExceeded.selector);
        desk.refund(P1, 1e6);
        // Raising the cap lets it finish; the issuer itself is never capped.
        vm.prank(issuer);
        desk.setOperator(key, 80e6);
        vm.prank(key);
        desk.resolveDispute(P1, false);
        (, used) = desk.operatorCap(key);
        assertEq(used, 80e6);
        vm.prank(issuer);
        desk.refund(P1, 80e6);
    }

    function test_collectedReserve_boundedByTheDisputeAndWhatStaysUnrefunded() public {
        _purchase(100e6);
        vm.prank(issuer);
        desk.openDispute(P1, 60e6, "");
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.ReserveTooLarge.selector);
        desk.collectedReserve(P1, 1_000_000e6);
        vm.prank(issuer);
        desk.collectedReserve(P1, 40e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.ReserveTooLarge.selector);
        desk.collectedReserve(P1, 20e6 + 1);
        // A refund leaves 30 of the purchase unrefunded, below the dispute and what was already collected.
        usd.mint(settlement, 70e6);
        vm.prank(issuer);
        desk.refund(P1, 70e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.ReserveTooLarge.selector);
        desk.collectedReserve(P1, 1);
        assertEq(desk.reserveCollected(P1), 40e6);
    }

    function _allowIssuerDebt(uint128 cap) internal {
        vm.startPrank(settlement);
        usd.approve(address(cards), type(uint256).max);
        core.approveHolder(address(cards), address(usd), type(uint128).max, 0);
        core.setPayeeTerms(address(cards), address(usd), _withDebtCap(settlement, address(cards), address(usd), cap));
        vm.stopPrank();
        usd.mint(address(this), 50e6);
        usd.approve(address(cards), 50e6);
        cards.fundIssuerDebt(address(usd), 50e6);
    }
}
