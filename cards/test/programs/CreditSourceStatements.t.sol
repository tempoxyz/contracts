// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { Vm } from "forge-std/Vm.sol";

import { CreditSource } from "../../src/programs/CreditSource.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { CompEnv } from "./harness/CompStubs.sol";

/// @notice Credit line interest within the debt bound the borrower accepted, statements and autopay.
contract CreditSourceStatementsTest is CompEnv {
    /// @dev Bounds on collect over twelve past-due statements on the core model: a retry with nothing to draw, and one
    ///      paying all twelve from cash (about 165,000 and 3,400,000 when written).
    uint256 internal constant DRY_COLLECT_GAS = 250_000;
    uint256 internal constant FULL_COLLECT_GAS = 4_500_000;

    uint64 internal due;
    uint64 internal lineId;
    uint256 internal draws;
    bytes32 internal lastLeg;

    function setUp() public {
        _deployComp();
        usd.mint(lender, 100_000e6);
        vm.prank(lender);
        core.approveHolder(address(credit), address(usd), type(uint128).max, 0);
        due = uint64(block.timestamp + 365 days);
        vm.prank(lender);
        lineId = credit.openLine(alice, 1000e6, due, IEarnVault(address(0)), 0, 0, 0);
        _accept(alice, lineId);
    }

    // Interest.

    function test_accrue_interestStaysSimpleHoweverOftenAnyoneAccrues() public {
        _terms(5000);
        _owe(500e6);
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i = 1; i <= 365; ++i) {
            vm.warp(start + i * 1 days);
            credit.accrue(lineId);
        }
        // 50% a year on 500 is 250, within a unit of rounding per accrual.
        assertApproxEqAbs(credit.lineOf(lineId).owed, 750e6, 365);
        assertLe(credit.lineOf(lineId).owed, 750e6);
        assertEq(credit.interestOf(lineId), credit.lineOf(lineId).owed - 500e6);
    }

    function test_collect_frequentCallsStillAccrueInterest() public {
        _terms(2000);
        _owe(50e6);
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < 3600; ++i) {
            vm.warp(start + i + 1);
            credit.collect(lineId);
        }
        // 20% a year on 50 for an hour, at most: each whole unit carries the time it took, rounded up in the
        // borrower's favour, so per-second calls never erase the interest.
        uint256 exact = uint256(50e6) * 2000 * 3600 / (365 days * 10_000);
        uint256 interest = credit.lineOf(lineId).owed - 50e6;
        assertLe(interest, exact);
        assertGt(interest, exact * 3 / 4);
    }

    function test_repay_takesInterestFirstSoNoInterestEarnsInterest() public {
        _terms(5000);
        _owe(500e6);
        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        credit.accrue(lineId);
        assertEq(credit.interestOf(lineId), 125e6);
        _repay(100e6);
        assertEq(credit.interestOf(lineId), 25e6);
        vm.warp(vm.getBlockTimestamp() + 365 days / 2);
        credit.accrue(lineId);
        // The rest of the year earns on the 500 lent, not on the 25 of interest still owed.
        assertEq(credit.lineOf(lineId).owed, 525e6 + 125e6);
    }

    function test_accrue_addsTheAcceptedYearlyRateOverTimeElapsed() public {
        _terms(1000);
        _owe(200e6);
        vm.warp(vm.getBlockTimestamp() + 73 days);
        assertEq(credit.owedNow(lineId), 204e6);
        // Anyone may accrue: the rate and the time decide the interest.
        vm.prank(bob);
        credit.accrue(lineId);
        assertEq(credit.lineOf(lineId).owed, 204e6);
        // Interest comes out of the undrawn limit, and the commitment follows it.
        assertEq(credit.availableCredit(lineId), 796e6);
        assertEq(credit.committed(lineId), 796e6);
        // No time elapsed, no interest.
        credit.accrue(lineId);
        assertEq(credit.lineOf(lineId).owed, 204e6);
        _assertCoreBalanced();
    }

    function test_accrue_lenderCannotChooseTheRateOrRepeatIt() public {
        _terms(1000);
        _owe(100e6);
        vm.startPrank(lender);
        (bool ok,) = address(credit).call(abi.encodeWithSignature("accrue(uint64,uint16)", lineId, uint16(10_000)));
        assertFalse(ok);
        for (uint256 i; i < 3; ++i) {
            credit.accrue(lineId);
        }
        vm.stopPrank();
        assertEq(credit.lineOf(lineId).owed, 100e6, "no time elapsed");
    }

    function test_accrue_carriesTimeTooShortForAUnit() public {
        _terms(1000);
        _owe(1e6);
        uint64 start = credit.lineOf(lineId).lastAccrued;
        // At 10% a year, 1e6 earns one unit every 315.36 seconds.
        vm.warp(vm.getBlockTimestamp() + 200);
        credit.accrue(lineId);
        assertEq(credit.lineOf(lineId).owed, 1e6);
        assertEq(credit.lineOf(lineId).lastAccrued, start, "the time carries");
        vm.warp(vm.getBlockTimestamp() + 200);
        credit.accrue(lineId);
        assertEq(credit.lineOf(lineId).owed, 1e6 + 1);
        assertEq(credit.lineOf(lineId).lastAccrued, start + 316, "only the time the unit paid for");
    }

    function test_accrue_cappedAtTheAcceptedDebtBound() public {
        _terms(1000);
        assertEq(credit.lineOf(lineId).maxDebt, 1100e6, "the limit plus a year of interest");
        _owe(1000e6);
        vm.warp(vm.getBlockTimestamp() + 730 days);
        credit.accrue(lineId);
        assertEq(credit.lineOf(lineId).owed, 1100e6);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        credit.accrue(lineId);
        assertEq(credit.lineOf(lineId).owed, 1100e6);
        assertEq(credit.availableCredit(lineId), 0);
    }

    function test_acceptLine_mustMatchTheOfferedTerms() public {
        vm.prank(lender);
        uint64 id = credit.openLine(bob, 1000e6, due, IEarnVault(address(0)), 0, 1500, 2000e6);
        vm.startPrank(bob);
        vm.expectRevert(CreditSource.TermsMismatch.selector);
        credit.acceptLine(id, 1000, 2000e6);
        vm.expectRevert(CreditSource.TermsMismatch.selector);
        credit.acceptLine(id, 1500, 1999e6);
        credit.acceptLine(id, 1500, 2000e6);
        vm.stopPrank();
        CreditSource.Line memory l = credit.lineOf(id);
        assertTrue(l.accepted);
        assertEq(l.aprBps, 1500);
        assertEq(l.maxDebt, 2000e6);
        // A bound below the limit is refused.
        vm.prank(lender);
        vm.expectRevert(CreditSource.InvalidLine.selector);
        credit.offerTerms(id, 1500, 999e6);
    }

    function test_offerTerms_applyOnlyOnceTheBorrowerAccepts() public {
        vm.prank(lender);
        credit.offerTerms(lineId, 2000, 3000e6);
        assertEq(credit.lineOf(lineId).aprBps, 0);
        // The limit stays within the accepted bound until the borrower accepts a higher one.
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.DebtBoundExceeded.selector, 2000e6, 1000e6));
        credit.setLimit(lineId, 2000e6);
        _owe(100e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        credit.accrue(lineId);
        assertEq(credit.lineOf(lineId).owed, 100e6, "no interest at the accepted rate of zero");
        vm.prank(alice);
        credit.acceptLine(lineId, 2000, 3000e6);
        assertEq(credit.lineOf(lineId).aprBps, 2000);
        vm.prank(lender);
        credit.setLimit(lineId, 2000e6);
        assertEq(credit.lineOf(lineId).limit, 2000e6);
    }

    // Statements.

    function test_closeStatement_snapshotsWhatIsOwed() public {
        _owe(204e6);
        uint64 dueAt = uint64(block.timestamp + 25 days);
        vm.prank(lender);
        uint32 n = credit.closeStatement(lineId, dueAt);
        assertEq(n, 1);
        CreditSource.Statement memory s = credit.statementOf(lineId, n);
        assertEq(s.balance, 204e6);
        assertEq(s.paid, 0);
        assertEq(s.dueAt, dueAt);
        assertEq(uint8(s.status), uint8(CreditSource.StatementStatus.Due));
        // Owing nothing, a statement is paid at once.
        _repay(204e6);
        vm.prank(lender);
        n = credit.closeStatement(lineId, dueAt);
        assertEq(uint8(credit.statementOf(lineId, n).status), uint8(CreditSource.StatementStatus.Paid));
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditSource.StatementStatus.Due));
        assertEq(credit.statementOf(lineId, 1).paid, 204e6);
    }

    function test_closeStatement_billsOnlyWhatOpenStatementsDoNot_soRepaidDebtIsNeverPastDue() public {
        _owe(100e6);
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(block.timestamp + 10 days));
        _owe(100e6);
        vm.prank(lender);
        uint32 n2 = credit.closeStatement(lineId, uint64(block.timestamp + 40 days));
        assertEq(credit.statementOf(lineId, n2).balance, 100e6);
        _repay(200e6);
        assertEq(credit.lineOf(lineId).owed, 0);
        // New debt after both statements is the next statement's, not theirs.
        _owe(50e6);
        vm.warp(block.timestamp + 41 days);
        credit.collect(lineId);
        CreditSource.Statement memory st = credit.statementOf(lineId, n2);
        assertEq(st.paid, st.balance);
        assertEq(uint8(st.status), uint8(CreditSource.StatementStatus.Paid));
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditSource.StatementStatus.Paid));
    }

    function test_closeStatement_atMostTwelveOpenAtOnce() public {
        for (uint256 i; i < 12; ++i) {
            _owe(1e6);
            vm.prank(lender);
            credit.closeStatement(lineId, uint64(block.timestamp + 30 days));
        }
        _owe(1e6);
        vm.prank(lender);
        vm.expectRevert(CreditSource.InvalidStatement.selector);
        credit.closeStatement(lineId, uint64(block.timestamp + 30 days));
        // Paying the oldest makes room for one more.
        _repay(1e6);
        vm.prank(lender);
        uint32 n = credit.closeStatement(lineId, uint64(block.timestamp + 30 days));
        assertEq(n, 13);
        assertEq(credit.statementOf(lineId, n).balance, 1e6);
    }

    function test_closeStatement_billingNothingOpensNothing() public {
        for (uint256 i; i < 20; ++i) {
            vm.prank(lender);
            credit.closeStatement(lineId, uint64(block.timestamp + 30 days));
        }
        (uint32 count, uint32 collectFrom, uint32 payFrom) = credit.statementsOf(lineId);
        assertEq(count, 20);
        assertEq(collectFrom, 21);
        assertEq(payFrom, 21);
    }

    function test_refund_paysOpenStatements_soTheNextBillsOnlyNewDebt() public {
        _owe(100e6);
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(block.timestamp + 10 days));
        _refundOwed(40e6);
        assertEq(credit.statementOf(lineId, 1).paid, 40e6);
        _owe(50e6);
        vm.prank(lender);
        uint32 n = credit.closeStatement(lineId, uint64(block.timestamp + 20 days));
        assertEq(credit.statementOf(lineId, n).balance, 50e6);
        assertEq(credit.lineOf(lineId).owed, 110e6);
    }

    function test_closeStatement_onlyTheLenderAndAFutureDueDate() public {
        vm.prank(alice);
        vm.expectRevert(CreditSource.NotLender.selector);
        credit.closeStatement(lineId, uint64(block.timestamp + 1 days));
        vm.prank(lender);
        vm.expectRevert(CreditSource.InvalidStatement.selector);
        credit.closeStatement(lineId, uint64(block.timestamp));
    }

    function test_repay_paysStatementsOldestFirst() public {
        _owe(100e6);
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(block.timestamp + 10 days));
        _owe(50e6);
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(block.timestamp + 20 days));
        _repay(120e6);
        assertEq(credit.statementOf(lineId, 1).paid, 100e6);
        assertEq(credit.statementOf(lineId, 2).paid, 20e6);
        (,, uint32 payFrom) = credit.statementsOf(lineId);
        assertEq(payFrom, 2);
        vm.warp(vm.getBlockTimestamp() + 20 days);
        credit.collect(lineId);
        // Without autopay the first is paid by the repayment and the second, still short, goes past due.
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditSource.StatementStatus.Paid));
        assertEq(uint8(credit.statementOf(lineId, 2).status), uint8(CreditSource.StatementStatus.PastDue));
    }

    // Autopay.

    function test_collect_autopayFromSavingsPaysTheStatementOnly() public {
        uint256 shares = _savings(500e6);
        _owe(204e6);
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(block.timestamp + 25 days));
        _owe(51e6);
        // Not yet due: nothing moves.
        credit.collect(lineId);
        assertEq(earnShare.balanceOf(alice), shares);
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditSource.StatementStatus.Due));

        vm.warp(vm.getBlockTimestamp() + 25 days);
        uint256 lenderBefore = usd.balanceOf(lender) + core.reserved(lender, address(usd));
        vm.expectEmit(address(credit));
        emit CreditSource.Autopaid(lineId, 1, address(earnVault), 204e6);
        credit.collect(lineId);
        CreditSource.Statement memory s = credit.statementOf(lineId, 1);
        assertEq(s.paid, 204e6);
        assertEq(uint8(s.status), uint8(CreditSource.StatementStatus.Paid));
        assertEq(credit.lineOf(lineId).owed, 51e6);
        assertEq(usd.balanceOf(lender) + core.reserved(lender, address(usd)) - lenderBefore, 204e6);
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice)), 296e6, 1);
        assertEq(usd.balanceOf(address(credit)), 0);
        assertEq(earnShare.balanceOf(address(credit)), 0);
        // Collecting again changes nothing.
        credit.collect(lineId);
        assertEq(credit.lineOf(lineId).owed, 51e6);
        _assertCoreBalanced();
    }

    function test_collect_cashFirstThenSavings() public {
        _savings(100e6);
        usd.mint(alice, 30e6);
        vm.prank(alice);
        usd.approve(address(credit), type(uint256).max);
        _autopay(address(usd), address(earnVault));
        _owe(80e6);
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(block.timestamp + 1 days));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        credit.collect(lineId);
        assertEq(usd.balanceOf(alice), 0);
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice)), 50e6, 1);
        assertEq(credit.lineOf(lineId).owed, 0);
    }

    function test_collect_insufficientFundsGoesPastDueWithWhatItCould() public {
        usd.mint(alice, 30e6);
        vm.prank(alice);
        usd.approve(address(credit), type(uint256).max);
        _autopay(address(usd), address(earnVault));
        _owe(80e6);
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(block.timestamp + 1 days));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        credit.collect(lineId);
        CreditSource.Statement memory s = credit.statementOf(lineId, 1);
        assertEq(s.paid, 30e6);
        assertEq(uint8(s.status), uint8(CreditSource.StatementStatus.PastDue));
        assertEq(credit.lineOf(lineId).owed, 50e6);
        // Once autopay has the rest, the next collection pays the past-due statement in full.
        usd.mint(alice, 50e6);
        credit.collect(lineId);
        s = credit.statementOf(lineId, 1);
        assertEq(s.paid, 80e6);
        assertEq(uint8(s.status), uint8(CreditSource.StatementStatus.Paid));
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(credit.chargeableAt(lineId), 0);
    }

    function test_collect_retriesAPastDueStatementOnceAutopayIsFunded() public {
        _approveCash();
        _autopay(address(usd));
        _owe(80e6);
        uint64 dueAt = _closeDue(1 days);
        // Nothing to draw from: the collection misses and the statement goes past due.
        vm.warp(dueAt);
        credit.collect(lineId);
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditSource.StatementStatus.PastDue));
        assertEq(credit.chargeableAt(lineId), dueAt + credit.CHARGE_OFF_GRACE());

        // The borrower funds autopay later: anyone's next collection pays the statement and clears the clock.
        vm.warp(dueAt + 10 days);
        usd.mint(alice, 100e6);
        uint256 lenderBefore = usd.balanceOf(lender) + core.reserved(lender, address(usd));
        vm.expectEmit(address(credit));
        emit CreditSource.Autopaid(lineId, 1, address(usd), 80e6);
        vm.expectEmit(address(credit));
        emit CreditSource.Repaid(lineId, alice, 80e6, 0);
        vm.expectEmit(address(credit));
        emit CreditSource.StatementCollected(lineId, 1, 80e6, 80e6, CreditSource.StatementStatus.Paid);
        vm.prank(bob);
        credit.collect(lineId);
        CreditSource.Statement memory s = credit.statementOf(lineId, 1);
        assertEq(s.paid, 80e6);
        assertEq(uint8(s.status), uint8(CreditSource.StatementStatus.Paid));
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(credit.chargeableAt(lineId), 0);
        assertEq(usd.balanceOf(alice), 20e6);
        assertEq(usd.balanceOf(lender) + core.reserved(lender, address(usd)) - lenderBefore, 80e6);
        (, uint32 collectFrom, uint32 payFrom) = credit.statementsOf(lineId);
        assertEq(collectFrom, 2);
        assertEq(payFrom, 2);
        // Collecting again takes nothing more.
        credit.collect(lineId);
        assertEq(usd.balanceOf(alice), 20e6);
        _assertCoreBalanced();
    }

    function test_collect_paysPastDueStatementsOldestFirstUntilFundsRunOut() public {
        _approveCash();
        _autopay(address(usd));
        uint64[3] memory dues;
        uint128[3] memory balances = [uint128(30e6), 40e6, 50e6];
        for (uint256 i; i < 3; ++i) {
            _owe(balances[i]);
            dues[i] = _closeDue(1 days);
            vm.warp(dues[i]);
            credit.collect(lineId);
            assertEq(
                uint8(credit.statementOf(lineId, uint32(i + 1)).status), uint8(CreditSource.StatementStatus.PastDue)
            );
        }
        uint256 grace = credit.CHARGE_OFF_GRACE();
        assertEq(credit.chargeableAt(lineId), dues[0] + grace);

        // Enough for the first two and part of the third.
        usd.mint(alice, 100e6);
        vm.expectEmit(address(credit));
        emit CreditSource.Autopaid(lineId, 1, address(usd), 30e6);
        vm.expectEmit(address(credit));
        emit CreditSource.Autopaid(lineId, 2, address(usd), 40e6);
        vm.expectEmit(address(credit));
        emit CreditSource.Autopaid(lineId, 3, address(usd), 30e6);
        vm.expectEmit(address(credit));
        emit CreditSource.StatementCollected(lineId, 3, 50e6, 30e6, CreditSource.StatementStatus.PastDue);
        credit.collect(lineId);
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditSource.StatementStatus.Paid));
        assertEq(uint8(credit.statementOf(lineId, 2).status), uint8(CreditSource.StatementStatus.Paid));
        CreditSource.Statement memory third = credit.statementOf(lineId, 3);
        assertEq(third.paid, 30e6);
        assertEq(uint8(third.status), uint8(CreditSource.StatementStatus.PastDue));
        assertEq(usd.balanceOf(alice), 0);
        // What the statements still bill is what the line owes: nothing counted twice.
        assertEq(credit.lineOf(lineId).owed, 20e6);
        assertEq(third.balance - third.paid, credit.lineOf(lineId).owed);
        (,, uint32 payFrom) = credit.statementsOf(lineId);
        assertEq(payFrom, 3);
        // The third keeps its own due date: chargeableAt moves to it, not past it.
        assertEq(credit.chargeableAt(lineId), dues[2] + grace);
        _assertCoreBalanced();
    }

    function test_collect_partialPaymentOfAPastDueStatementKeepsItsClock() public {
        _approveCash();
        _autopay(address(usd));
        _owe(80e6);
        uint64 dueAt = _closeDue(1 days);
        vm.warp(dueAt);
        credit.collect(lineId);
        uint256 at = credit.chargeableAt(lineId);
        assertEq(at, dueAt + credit.CHARGE_OFF_GRACE());

        vm.warp(dueAt + 20 days);
        usd.mint(alice, 30e6);
        vm.expectEmit(address(credit));
        emit CreditSource.StatementCollected(lineId, 1, 80e6, 30e6, CreditSource.StatementStatus.PastDue);
        credit.collect(lineId);
        assertEq(credit.statementOf(lineId, 1).paid, 30e6);
        assertEq(credit.lineOf(lineId).owed, 50e6);
        assertEq(credit.chargeableAt(lineId), at, "a partial payment leaves the clock where it was");

        vm.warp(dueAt + 40 days);
        usd.mint(alice, 50e6);
        credit.collect(lineId);
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditSource.StatementStatus.Paid));
        assertEq(credit.chargeableAt(lineId), 0);
    }

    function test_collect_nothingToPayChangesNothing() public {
        // No statements yet.
        credit.collect(lineId);
        _approveCash();
        _autopay(address(usd));
        _owe(80e6);
        uint64 dueAt = _closeDue(1 days);
        vm.warp(dueAt);
        credit.collect(lineId);
        CreditSource.Statement memory before = credit.statementOf(lineId, 1);
        (uint32 count, uint32 collectFrom, uint32 payFrom) = credit.statementsOf(lineId);
        // Still nothing in autopay: a retry pays nothing and reports nothing.
        vm.warp(dueAt + 7 days);
        vm.recordLogs();
        credit.collect(lineId);
        _assertNoCollectionLogs();
        CreditSource.Statement memory after_ = credit.statementOf(lineId, 1);
        assertEq(after_.paid, before.paid);
        assertEq(uint8(after_.status), uint8(CreditSource.StatementStatus.PastDue));
        (uint32 count_, uint32 collectFrom_, uint32 payFrom_) = credit.statementsOf(lineId);
        assertEq(count_, count);
        assertEq(collectFrom_, collectFrom);
        assertEq(payFrom_, payFrom);
        assertEq(credit.lineOf(lineId).owed, 80e6);
        assertEq(credit.chargeableAt(lineId), dueAt + credit.CHARGE_OFF_GRACE());
    }

    function test_collect_paysTheStatementDueNotAnOlderOneNotYetDue() public {
        _approveCash();
        _autopay(address(usd));
        _owe(100e6);
        _closeDue(30 days);
        _owe(50e6);
        uint64 second = _closeDue(5 days);
        usd.mint(alice, 500e6);
        vm.warp(second);
        credit.collect(lineId);
        // Only the statement that fell due is collected, and the payment is its own.
        CreditSource.Statement memory s2 = credit.statementOf(lineId, 2);
        assertEq(s2.paid, 50e6);
        assertEq(uint8(s2.status), uint8(CreditSource.StatementStatus.Paid));
        assertEq(credit.statementOf(lineId, 1).paid, 0);
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditSource.StatementStatus.Due));
        assertEq(usd.balanceOf(alice), 450e6);
        assertEq(credit.lineOf(lineId).owed, 100e6);
        (, uint32 collectFrom, uint32 payFrom) = credit.statementsOf(lineId);
        assertEq(collectFrom, 1);
        assertEq(payFrom, 1);
        assertEq(credit.chargeableAt(lineId), second + 25 days + credit.CHARGE_OFF_GRACE());
    }

    function test_collect_twelvePastDueStatementsStayBounded() public {
        _approveCash();
        _autopay(address(usd), address(earnVault));
        for (uint256 i; i < 12; ++i) {
            _owe(10e6);
            vm.warp(_closeDue(1 days));
            credit.collect(lineId);
        }
        (uint32 count,, uint32 payFrom) = credit.statementsOf(lineId);
        assertEq(count, 12);
        assertEq(payFrom, 1);
        // With nothing in autopay a retry visits the twelve and stops drawing after the first miss.
        uint256 start = gasleft();
        credit.collect(lineId);
        uint256 dry = start - gasleft();
        // Funded, one collection pays all twelve.
        usd.mint(alice, 120e6);
        start = gasleft();
        credit.collect(lineId);
        uint256 full = start - gasleft();
        for (uint32 n = 1; n <= 12; ++n) {
            assertEq(uint8(credit.statementOf(lineId, n).status), uint8(CreditSource.StatementStatus.Paid));
        }
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(credit.chargeableAt(lineId), 0);
        (, uint32 collectFrom_, uint32 payFrom_) = credit.statementsOf(lineId);
        assertEq(collectFrom_, 13);
        assertEq(payFrom_, 13);
        assertLt(dry, DRY_COLLECT_GAS, "a retry with nothing to draw stays cheap");
        assertLt(full, FULL_COLLECT_GAS, "twelve statements in one collection");
    }

    function test_collect_neverTakesHeldOrUnapprovedFunds() public {
        // Cash under a hold and cash the borrower never approved stay out of reach.
        usd.mint(alice, 100e6);
        vm.prank(alice);
        core.hold(_holdRequest(bytes32("held"), 60e6));
        vm.prank(alice);
        usd.approve(address(credit), type(uint256).max);
        _autopay(address(usd));
        _owe(80e6);
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(block.timestamp + 1 days));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        credit.collect(lineId);
        assertEq(credit.statementOf(lineId, 1).paid, 40e6);
        assertEq(core.reserved(alice, address(usd)), 60e6);

        // Shares without an approval give nothing.
        _savings(100e6);
        vm.prank(alice);
        earnShare.approve(address(credit), 0);
        _autopay(address(earnVault));
        // The next statement bills only what was drawn since the first.
        _owe(20e6);
        uint64 next = uint64(vm.getBlockTimestamp() + 1 days);
        vm.prank(lender);
        credit.closeStatement(lineId, next);
        assertEq(credit.statementOf(lineId, 2).balance, 20e6);
        vm.warp(next);
        credit.collect(lineId);
        assertEq(credit.lineOf(lineId).owed, 60e6);
        assertEq(uint8(credit.statementOf(lineId, 2).status), uint8(CreditSource.StatementStatus.PastDue));
    }

    function test_collect_paysAtMostWhatTheLineOwes() public {
        usd.mint(alice, 500e6);
        vm.prank(alice);
        usd.approve(address(credit), type(uint256).max);
        _autopay(address(usd));
        _owe(100e6);
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(block.timestamp + 1 days));
        // A refund after the statement lowers what is owed below its balance.
        _refundOwed(40e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        credit.collect(lineId);
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(usd.balanceOf(alice), 440e6);
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditSource.StatementStatus.Paid));
    }

    function test_setAutopay_onlyTheBorrowerAndTheLinesAssets() public {
        address[] memory sources = new address[](1);
        sources[0] = address(usd);
        vm.prank(bob);
        vm.expectRevert(CreditSource.NotBorrower.selector);
        credit.setAutopay(lineId, sources);
        sources[0] = address(earnShare);
        vm.prank(alice);
        vm.expectRevert();
        credit.setAutopay(lineId, sources);
        sources[0] = bob;
        vm.prank(alice);
        vm.expectRevert(CreditSource.InvalidAutopay.selector);
        credit.setAutopay(lineId, sources);
        address[] memory many = new address[](5);
        for (uint256 i; i < many.length; ++i) {
            many[i] = address(usd);
        }
        vm.prank(alice);
        vm.expectRevert(CreditSource.InvalidAutopay.selector);
        credit.setAutopay(lineId, many);
    }

    // Helpers.

    /// @dev The lender offers aprBps a year with the default debt bound and the borrower accepts.
    function _terms(uint16 aprBps) internal {
        vm.prank(lender);
        credit.offerTerms(lineId, aprBps, 0);
        _accept(alice, lineId);
    }

    function _owe(uint128 amount) internal {
        lastLeg = bytes32(++draws);
        _draw(alice, lineId, lastLeg, amount, lastLeg);
    }

    function _refundOwed(uint128 amount) internal {
        auth.refundLeg(credit, alice, lastLeg, amount);
    }

    function _repay(uint128 amount) internal {
        usd.mint(alice, amount);
        vm.startPrank(alice);
        usd.approve(address(credit), amount);
        credit.repay(lineId, amount);
        vm.stopPrank();
    }

    function _savings(uint256 assets) internal returns (uint256 shares) {
        usd.mint(alice, assets);
        shares = _depositEarn(alice, assets);
        vm.prank(alice);
        earnShare.approve(address(credit), type(uint256).max);
        _autopay(address(earnVault));
    }

    function _holdRequest(bytes32 id, uint128 amount) internal view returns (IReservationCore.HoldRequest memory) {
        return IReservationCore.HoldRequest({
            token: address(usd), id: id, amount: amount, expiresAt: uint64(block.timestamp + 1 days), payee: bob
        });
    }

    function _approveCash() internal {
        vm.prank(alice);
        usd.approve(address(credit), type(uint256).max);
    }

    /// @dev The lender closes a statement due `after` from now.
    function _closeDue(uint256 after_) internal returns (uint64 dueAt) {
        dueAt = uint64(vm.getBlockTimestamp() + after_);
        vm.prank(lender);
        credit.closeStatement(lineId, dueAt);
    }

    function _assertNoCollectionLogs() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(credit)) continue;
            bytes32 topic = logs[i].topics[0];
            assertTrue(topic != CreditSource.Autopaid.selector, "no autopay");
            assertTrue(topic != CreditSource.Repaid.selector, "no repayment");
            assertTrue(topic != CreditSource.StatementCollected.selector, "no statement change");
        }
    }

    function _autopay(address a) internal {
        address[] memory sources = new address[](1);
        sources[0] = a;
        vm.prank(alice);
        credit.setAutopay(lineId, sources);
    }

    function _autopay(address a, address b) internal {
        address[] memory sources = new address[](2);
        (sources[0], sources[1]) = (a, b);
        vm.prank(alice);
        credit.setAutopay(lineId, sources);
    }
}
