// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CreditLine } from "../../src/programs/CreditLine.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice Credit line interest, statements and autopay, with this test as the line's card program.
contract CreditLineStatementsTest is ProgramsEnv {
    uint64 internal due;
    uint64 internal lineId;

    function setUp() public {
        _deployPrograms();
        usd.mint(lender, 100_000e6);
        vm.prank(lender);
        core.approveHolder(address(credit), address(usd), type(uint128).max);
        due = uint64(block.timestamp + 365 days);
        vm.prank(lender);
        lineId =
            credit.openLine(alice, address(usd), address(this), 1000e6, due, 7 days, IEarnVault(address(0)), 0, 0, 0);
        _acceptLine(alice, lineId);
    }

    // Interest.

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
        uint64 id = credit.openLine(
            bob, address(usd), address(this), 1000e6, due, 7 days, IEarnVault(address(0)), 0, 1500, 2000e6
        );
        vm.startPrank(bob);
        vm.expectRevert(CreditLine.TermsMismatch.selector);
        credit.acceptLine(id, 1000, 2000e6);
        vm.expectRevert(CreditLine.TermsMismatch.selector);
        credit.acceptLine(id, 1500, 1999e6);
        credit.acceptLine(id, 1500, 2000e6);
        vm.stopPrank();
        CreditLine.Line memory l = credit.lineOf(id);
        assertTrue(l.accepted);
        assertEq(l.aprBps, 1500);
        assertEq(l.maxDebt, 2000e6);
        // A bound below the limit is refused.
        vm.prank(lender);
        vm.expectRevert(CreditLine.InvalidLine.selector);
        credit.offerTerms(id, 1500, 999e6);
    }

    function test_offerTerms_applyOnlyOnceTheBorrowerAccepts() public {
        vm.prank(lender);
        credit.offerTerms(lineId, 2000, 3000e6);
        assertEq(credit.lineOf(lineId).aprBps, 0);
        // The limit stays within the accepted bound until the borrower accepts a higher one.
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.DebtBoundExceeded.selector, 2000e6, 1000e6));
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
        CreditLine.Statement memory s = credit.statementOf(lineId, n);
        assertEq(s.balance, 204e6);
        assertEq(s.paid, 0);
        assertEq(s.dueAt, dueAt);
        assertEq(uint8(s.status), uint8(CreditLine.StatementStatus.Due));
        // Owing nothing, a statement is paid at once.
        _repay(204e6);
        vm.prank(lender);
        n = credit.closeStatement(lineId, dueAt);
        assertEq(uint8(credit.statementOf(lineId, n).status), uint8(CreditLine.StatementStatus.Paid));
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditLine.StatementStatus.Due));
        assertEq(credit.statementOf(lineId, 1).paid, 204e6);
    }

    function test_closeStatement_onlyTheLenderAndAFutureDueDate() public {
        vm.prank(alice);
        vm.expectRevert(CreditLine.NotLender.selector);
        credit.closeStatement(lineId, uint64(block.timestamp + 1 days));
        vm.prank(lender);
        vm.expectRevert(CreditLine.InvalidStatement.selector);
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
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditLine.StatementStatus.Paid));
        assertEq(uint8(credit.statementOf(lineId, 2).status), uint8(CreditLine.StatementStatus.PastDue));
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
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditLine.StatementStatus.Due));

        vm.warp(vm.getBlockTimestamp() + 25 days);
        uint256 lenderBefore = usd.balanceOf(lender) + core.reserved(lender, address(usd));
        vm.expectEmit(address(credit));
        emit CreditLine.Autopaid(lineId, 1, address(earnVault), 204e6);
        credit.collect(lineId);
        CreditLine.Statement memory s = credit.statementOf(lineId, 1);
        assertEq(s.paid, 204e6);
        assertEq(uint8(s.status), uint8(CreditLine.StatementStatus.Paid));
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
        CreditLine.Statement memory s = credit.statementOf(lineId, 1);
        assertEq(s.paid, 30e6);
        assertEq(uint8(s.status), uint8(CreditLine.StatementStatus.PastDue));
        assertEq(credit.lineOf(lineId).owed, 50e6);
        // A past-due statement is not collected again; the borrower repays it.
        usd.mint(alice, 50e6);
        credit.collect(lineId);
        assertEq(credit.lineOf(lineId).owed, 50e6);
        _repay(50e6);
        assertEq(credit.statementOf(lineId, 1).paid, 80e6);
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
        uint64 next = uint64(vm.getBlockTimestamp() + 1 days);
        vm.prank(lender);
        credit.closeStatement(lineId, next);
        vm.warp(next);
        credit.collect(lineId);
        assertEq(credit.lineOf(lineId).owed, 40e6);
        assertEq(uint8(credit.statementOf(lineId, 2).status), uint8(CreditLine.StatementStatus.PastDue));
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
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditLine.StatementStatus.Paid));
    }

    function test_setAutopay_onlyTheBorrowerAndTheLinesAssets() public {
        address[] memory sources = new address[](1);
        sources[0] = address(usd);
        vm.prank(bob);
        vm.expectRevert(CreditLine.NotBorrower.selector);
        credit.setAutopay(lineId, sources);
        sources[0] = address(earnShare);
        vm.prank(alice);
        vm.expectRevert();
        credit.setAutopay(lineId, sources);
        sources[0] = bob;
        vm.prank(alice);
        vm.expectRevert(CreditLine.InvalidAutopay.selector);
        credit.setAutopay(lineId, sources);
        address[] memory many = new address[](5);
        for (uint256 i; i < many.length; ++i) {
            many[i] = address(usd);
        }
        vm.prank(alice);
        vm.expectRevert(CreditLine.InvalidAutopay.selector);
        credit.setAutopay(lineId, many);
    }

    // Helpers.

    /// @dev The lender offers `aprBps` a year with the default debt bound and the borrower accepts.
    function _terms(uint16 aprBps) internal {
        vm.prank(lender);
        credit.offerTerms(lineId, aprBps, 0);
        _acceptLine(alice, lineId);
    }

    function _owe(uint128 amount) internal {
        bytes32 ref = keccak256(abi.encode("purchase", credit.lineOf(lineId).owed, amount, block.timestamp));
        (bytes32 id,,) = credit.draw(lineId, alice, ref, amount, uint64(block.timestamp + 1 days));
        core.capture(lender, id, amount, true);
        credit.sync(id);
        lastDraw = id;
    }

    bytes32 internal lastDraw;

    function _refundOwed(uint128 amount) internal {
        core.refund(lender, lastDraw, amount);
        credit.sync(lastDraw);
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
            token: address(usd),
            id: id,
            amount: amount,
            expiresAt: uint64(block.timestamp + 1 days),
            payee: bob,
            standIn: false
        });
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
