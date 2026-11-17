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
        lineId = credit.openLine(alice, address(usd), address(this), 1000e6, due, 7 days, IEarnVault(address(0)), 0);
        vm.prank(alice);
        credit.acceptLine(lineId);
    }

    // Interest.

    function test_accrue_addsInterestOnWhatIsOwed() public {
        _owe(200e6);
        vm.prank(lender);
        credit.accrue(lineId, 200);
        assertEq(credit.lineOf(lineId).owed, 204e6);
        // Interest comes out of the undrawn limit, and the commitment follows it.
        assertEq(credit.availableCredit(lineId), 796e6);
        assertEq(credit.committed(lineId), 796e6);
        _assertCoreBalanced();
    }

    function test_accrue_roundsUpToTheSmallestUnit() public {
        _owe(1);
        vm.prank(lender);
        credit.accrue(lineId, 1);
        assertEq(credit.lineOf(lineId).owed, 2);
        _owe(9998);
        vm.prank(lender);
        credit.accrue(lineId, 1);
        // 10_000 owed at 1 bp is exactly 1.
        assertEq(credit.lineOf(lineId).owed, 10_001);
    }

    function test_accrue_nothingOwedAddsNothing() public {
        vm.prank(lender);
        credit.accrue(lineId, 500);
        assertEq(credit.lineOf(lineId).owed, 0);
    }

    function test_accrue_onlyTheLenderAndAValidRate() public {
        _owe(100e6);
        vm.prank(alice);
        vm.expectRevert(CreditLine.NotLender.selector);
        credit.accrue(lineId, 100);
        vm.startPrank(lender);
        vm.expectRevert(CreditLine.InvalidRate.selector);
        credit.accrue(lineId, 0);
        vm.expectRevert(CreditLine.InvalidRate.selector);
        credit.accrue(lineId, 10_001);
        vm.stopPrank();
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
        vm.warp(block.timestamp + 20 days);
        credit.collect(lineId);
        // Without autopay the first is paid by the repayment and the second, still short, goes past due.
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditLine.StatementStatus.Paid));
        assertEq(uint8(credit.statementOf(lineId, 2).status), uint8(CreditLine.StatementStatus.PastDue));
    }

    // Autopay.

    function test_collect_autopayFromSavingsPaysTheStatementOnly() public {
        uint256 shares = _savings(500e6);
        _owe(200e6);
        vm.prank(lender);
        credit.accrue(lineId, 200);
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(block.timestamp + 25 days));
        _owe(51e6);
        // Not yet due: nothing moves.
        credit.collect(lineId);
        assertEq(earnShare.balanceOf(alice), shares);
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditLine.StatementStatus.Due));

        vm.warp(block.timestamp + 25 days);
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
        vm.warp(block.timestamp + 1 days);
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
        vm.warp(block.timestamp + 1 days);
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
        vm.warp(block.timestamp + 1 days);
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
        vm.warp(block.timestamp + 1 days);
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
