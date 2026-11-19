// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CreditSource } from "../../src/programs/CreditSource.sol";
import { CompEnv } from "./harness/CompStubs.sol";

/// @notice Credit lines as a card program's funding source: legs hold the lender's balance and pay the settlement
///         account, captures add to what the borrower owes within the debt bound it accepted, repayments for a
///         purchase let a merchant win draw the line again for that purchase only, and secured lines lock shares.
contract CreditSourceTest is CompEnv {
    bytes32 internal constant REF = bytes32("purchase-1");
    bytes32 internal constant LEG = bytes32("leg-1");

    function setUp() public {
        _deployComp();
    }

    function test_hold_holdsTheLendersBalancePayableToTheSettlementAccount() public {
        uint64 lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        assertEq(credit.committed(lineId), 1000e6);
        assertEq(credit.coverable(alice, _pos(lineId)), 1000e6);
        assertEq(auth.hold(credit, alice, _pos(lineId), LEG, 300e6, false), 300e6);
        assertEq(credit.held(alice, _pos(lineId), LEG), 300e6);
        assertEq(credit.lineOf(lineId).pending, 300e6);
        // The commitment gives the leg its room, so the lender's reserved total stays the limit.
        assertEq(credit.committed(lineId), 700e6);
        assertEq(core.reserved(lender, address(usd)), 1000e6);
        auth.capture(credit, alice, LEG, 300e6, true, REF);
        assertEq(usd.balanceOf(settlement), 300e6);
        assertEq(credit.lineOf(lineId).owed, 300e6);
        assertEq(credit.lineOf(lineId).pending, 0);
        assertEq(credit.held(alice, _pos(lineId), LEG), 0);
        _assertCoreBalanced();
    }

    /// @dev The settlement account lending on its own line: a draw liens its balance and the capture leaves it whole,
    ///      since the core never pays an account from itself and this source passes the draw straight back.
    function test_ownLine_drawLeavesTheSettlementBalanceWhole() public {
        usd.mint(settlement, 1000e6);
        vm.prank(issuer);
        credit.setLender(settlement, true);
        vm.startPrank(settlement);
        core.approveHolder(address(credit), address(usd), type(uint128).max, 0);
        uint64 lineId =
            credit.openLine(alice, 500e6, uint64(block.timestamp + 60 days), IEarnVault(address(0)), 0, 0, 0);
        vm.stopPrank();
        _accept(alice, lineId);
        assertEq(core.reserved(settlement, address(usd)), 500e6);
        _draw(alice, lineId, LEG, 300e6, REF);
        assertEq(usd.balanceOf(settlement) + core.reserved(settlement, address(usd)), 1000e6);
        assertEq(usd.balanceOf(address(credit)), 0);
        assertEq(credit.lineOf(lineId).owed, 300e6);
        assertEq(core.reserved(settlement, address(usd)), 200e6);
        _assertCoreBalanced();
    }

    function test_hold_onlyTheProgram() public {
        uint64 lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        vm.expectRevert(CreditSource.NotProgram.selector);
        credit.hold(alice, _pos(lineId), LEG, 1e6, uint64(block.timestamp + 1 days), false);
        vm.expectRevert(CreditSource.NotProgram.selector);
        credit.capture(alice, _pos(lineId), LEG, 1e6, 1);
    }

    function test_hold_needsAnAcceptedOpenLineInTheSettlementToken() public {
        usd.mint(lender, 1000e6);
        vm.startPrank(lender);
        core.approveHolder(address(credit), address(usd), type(uint128).max, 0);
        uint64 lineId =
            credit.openLine(alice, 500e6, uint64(block.timestamp + 30 days), IEarnVault(address(0)), 0, 0, 0);
        vm.stopPrank();
        assertEq(credit.coverable(alice, _pos(lineId)), 0);
        vm.expectRevert(CreditSource.LineNotOpen.selector);
        auth.hold(credit, alice, _pos(lineId), LEG, 1e6, false);
        _accept(alice, lineId);
        // Only the borrower's purchases draw it.
        vm.expectRevert(CreditSource.NotBorrower.selector);
        auth.hold(credit, bob, _pos(lineId), LEG, 1e6, false);
        auth.hold(credit, alice, _pos(lineId), LEG, 1e6, false);
        // Past due, or in a token the program no longer settles in, it draws nothing.
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(CreditSource.LineNotOpen.selector);
        auth.hold(credit, alice, _pos(lineId), bytes32("leg-2"), 1e6, false);
        vm.expectRevert(CreditSource.InvalidLine.selector);
        auth.hold(credit, alice, _pos(99), bytes32("leg-2"), 1e6, false);
    }

    function test_hold_withinTheLimit_standInHoldsWhatIsLeft() public {
        uint64 lineId = _openLine(alice, 100e6, IEarnVault(address(0)), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.CreditExceeded.selector, 101e6, 100e6));
        auth.hold(credit, alice, _pos(lineId), LEG, 101e6, false);
        assertEq(auth.hold(credit, alice, _pos(lineId), LEG, 101e6, true), 100e6);
        // Without CAPTURE_BEYOND a capture takes only what the leg holds; with it, past that it needs credit the line
        // no longer has.
        vm.expectRevert(abi.encodeWithSelector(CreditSource.CreditExceeded.selector, 1e6, 0));
        auth.captureBeyond(credit, alice, LEG, 101e6);
        assertEq(auth.capture(credit, alice, LEG, 101e6, true, REF), 100e6);
        // A settled leg covers nothing more, and releasing it does nothing.
        assertEq(auth.capture(credit, alice, LEG, 1e6, true, REF), 0);
        auth.release(credit, alice, LEG);
        assertEq(credit.charge(alice, _pos(lineId), LEG, 1e6, true), 0);
        assertEq(credit.KIND(), 4);
        assertEq(credit.toleranceBps(alice, _pos(lineId)), 0);
    }

    function test_capture_owesWhatWasCaptured_refundAndRepay() public {
        uint64 lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        _draw(alice, lineId, LEG, 400e6, REF);
        assertEq(credit.availableCredit(lineId), 600e6);
        // A refund puts the program's tokens back on the leg: the lender has them and the borrower owes less.
        uint256 lenderBefore = usd.balanceOf(lender) + core.reserved(lender, address(usd));
        auth.refundLeg(credit, alice, LEG, 150e6);
        assertEq(credit.lineOf(lineId).owed, 250e6);
        assertEq(usd.balanceOf(lender) + core.reserved(lender, address(usd)) - lenderBefore, 150e6);
        usd.mint(alice, 250e6);
        vm.startPrank(alice);
        usd.approve(address(credit), 250e6);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.RepayExceedsOwed.selector, 251e6, 250e6));
        credit.repay(lineId, 251e6);
        credit.repay(lineId, 250e6);
        vm.stopPrank();
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(credit.committed(lineId), 1000e6);
        _assertCoreBalanced();
    }

    function test_refund_pastWhatTheLegCapturedGoesBackToTheProgram() public {
        uint64 lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        _draw(alice, lineId, LEG, 100e6, REF);
        uint256 before = usd.balanceOf(address(auth));
        assertEq(credit.refundable(alice, _pos(lineId), LEG), 100e6);
        auth.refundLeg(credit, alice, LEG, 130e6);
        assertEq(credit.refundable(alice, _pos(lineId), LEG), 0);
        assertEq(before - usd.balanceOf(address(auth)), 100e6);
        assertEq(usd.balanceOf(address(credit)), 0);
    }

    function test_refund_pastWhatIsOwedPaysTheBorrower() public {
        uint64 lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        _draw(alice, lineId, LEG, 100e6, REF);
        usd.mint(alice, 100e6);
        vm.startPrank(alice);
        usd.approve(address(credit), 100e6);
        credit.repay(lineId, 100e6);
        vm.stopPrank();
        // The borrower repaid the purchase already, so its refund is the borrower's money.
        auth.refundLeg(credit, alice, LEG, 40e6);
        assertEq(core.available(alice, address(usd)), 40e6);
        assertEq(credit.lineOf(lineId).owed, 0);
        _assertCoreBalanced();
    }

    function test_capture_beyondTheHoldGrowsItWithinTheCredit() public {
        uint64 lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        auth.hold(credit, alice, _pos(lineId), LEG, 100e6, false);
        assertEq(auth.captureBeyond(credit, alice, LEG, 130e6), 130e6);
        assertEq(credit.lineOf(lineId).owed, 130e6);
        assertEq(usd.balanceOf(settlement), 130e6);
        _assertCoreBalanced();
    }

    function test_capture_pastTheAcceptedDebtBoundCountsOnlyWithinIt() public {
        uint64 lineId = _openLine(alice, 100e6, IEarnVault(address(0)), 0, 0);
        // The lender lowers the limit after a stand-in leg was placed past what the bound leaves.
        auth.hold(credit, alice, _pos(lineId), LEG, 100e6, false);
        auth.capture(credit, alice, LEG, 100e6, true, REF);
        (, uint128 maxDebt) = credit.offerOf(lineId);
        assertEq(maxDebt, 100e6);
        assertEq(credit.lineOf(lineId).owed, 100e6);
        // A second purchase finds no room: the bound holds whatever the lender does.
        vm.expectRevert(abi.encodeWithSelector(CreditSource.CreditExceeded.selector, 1e6, 0));
        auth.hold(credit, alice, _pos(lineId), bytes32("leg-2"), 1e6, false);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.DebtBoundExceeded.selector, 200e6, 100e6));
        credit.setLimit(lineId, 200e6);
    }

    function test_revokedLender_liveLegStillSettles() public {
        uint64 lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        auth.hold(credit, alice, _pos(lineId), LEG, 200e6, false);
        vm.prank(lender);
        core.approveHolder(address(credit), address(usd), 0, 0);
        auth.capture(credit, alice, LEG, 200e6, true, REF);
        assertEq(usd.balanceOf(settlement), 200e6);
        assertEq(credit.lineOf(lineId).owed, 200e6);
    }

    function test_release_expiredLegFreesPending() public {
        uint64 lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        auth.hold(credit, alice, _pos(lineId), LEG, 200e6, false);
        vm.warp(block.timestamp + 8 days);
        auth.release(credit, alice, LEG);
        assertEq(credit.lineOf(lineId).pending, 0);
        assertEq(credit.availableCredit(lineId), 1000e6);
        // An unknown leg releases as a no-op.
        auth.release(credit, alice, bytes32("nope"));
        _assertCoreBalanced();
    }

    function test_openLine_rejectsBadTerms() public {
        vm.startPrank(lender);
        uint64 due = uint64(block.timestamp + 30 days);
        vm.expectRevert(CreditSource.InvalidLine.selector);
        credit.openLine(address(0), 1e6, due, IEarnVault(address(0)), 0, 0, 0);
        vm.expectRevert(CreditSource.InvalidLine.selector);
        credit.openLine(alice, 1e6, uint64(block.timestamp), IEarnVault(address(0)), 0, 0, 0);
        vm.expectRevert(CreditSource.InvalidLine.selector);
        credit.openLine(alice, 1e6, due, IEarnVault(address(0)), 5000, 0, 0);
        vm.expectRevert(CreditSource.InvalidLine.selector);
        credit.openLine(alice, 1e6, due, IEarnVault(address(earnVault)), 0, 0, 0);
        vm.expectRevert(CreditSource.InvalidLine.selector);
        credit.openLine(alice, 10e6, due, IEarnVault(address(0)), 0, 0, 9e6);
        credit.openLine(alice, 1e6, due, IEarnVault(address(0)), 0, 0, 0);
        // One open line per lender and borrower.
        vm.expectRevert(CreditSource.InvalidLine.selector);
        credit.openLine(alice, 1e6, due, IEarnVault(address(0)), 0, 0, 0);
        vm.stopPrank();
    }

    function test_locking_legLocksSharesWorthUsedOverLtv() public {
        uint64 lineId = _lockingLine(1000e6);
        assertApproxEqAbs(credit.availableCredit(lineId), 500e6, 1);
        _draw(alice, lineId, LEG, 280e6, REF);
        uint256 locked = credit.lockedShares(lineId);
        assertApproxEqAbs(earnVault.previewRedeem(locked), 560e6, 2);
        assertEq(core.reserved(alice, address(earnShare)), locked);
        assertApproxEqAbs(earnVault.previewRedeem(core.available(alice, address(earnShare))), 440e6, 2);
        _assertCoreBalanced();
    }

    function test_locking_underCollateralizedLegRefused() public {
        uint64 lineId = _lockingLine(100e6);
        vm.expectPartialRevert(CreditSource.CreditExceeded.selector);
        auth.hold(credit, alice, _pos(lineId), LEG, 51e6, false);
        auth.hold(credit, alice, _pos(lineId), LEG, credit.availableCredit(lineId), false);
        assertEq(credit.availableCredit(lineId), 0);
        assertLe(core.available(alice, address(earnShare)), 1);
    }

    function test_locking_revokedAllowanceRefusesTheLeg() public {
        uint64 lineId = _lockingLine(100e6);
        vm.prank(alice);
        core.approveHolder(address(credit), address(earnShare), 0, 0);
        vm.expectRevert();
        auth.hold(credit, alice, _pos(lineId), LEG, 10e6, false);
    }

    function test_locking_repayShrinksTheLock() public {
        uint64 lineId = _lockingLine(1000e6);
        _draw(alice, lineId, LEG, 200e6, REF);
        uint256 before = credit.lockedShares(lineId);
        usd.mint(alice, 100e6);
        vm.startPrank(alice);
        usd.approve(address(credit), 100e6);
        credit.repay(lineId, 100e6);
        vm.stopPrank();
        assertApproxEqAbs(credit.lockedShares(lineId), before / 2, 2);
    }

    function test_liquidate_onlyLender_onlyPastLtv_sellsJustEnough() public {
        uint64 lineId = _lockingLine(1000e6);
        _draw(alice, lineId, LEG, 400e6, REF);
        vm.prank(lender);
        vm.expectPartialRevert(CreditSource.NotUndercollateralized.selector);
        credit.liquidate(lineId);
        // The venue loses 30%: $700 of shares secure $400, past 50%.
        uint256 loss = usd.balanceOf(address(venue)) * 3 / 10;
        vm.prank(address(venue));
        usd.transfer(address(0xdead), loss);
        credit.relock(lineId);
        vm.prank(alice);
        vm.expectRevert(CreditSource.NotLender.selector);
        credit.liquidate(lineId);
        uint256 lenderBefore = usd.balanceOf(lender) + core.reserved(lender, address(usd));
        vm.prank(lender);
        (, uint256 assets) = credit.liquidate(lineId);
        assertApproxEqAbs(assets, 100e6, 2);
        assertEq(usd.balanceOf(lender) + core.reserved(lender, address(usd)) - lenderBefore, assets);
        uint128 owed = credit.lineOf(lineId).owed;
        uint256 left = earnVault.previewRedeem(earnShare.balanceOf(alice) + core.reserved(alice, address(earnShare)));
        assertApproxEqAbs(uint256(owed) * 2, left, 2);
        _assertCoreBalanced();
    }

    function test_capture_neverGrowsALegOnAClosedLine() public {
        uint64 lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        bytes32 leg = bytes32("leg-1");
        auth.hold(credit, alice, _pos(lineId), leg, 10e6, false);
        vm.prank(lender);
        credit.closeLine(lineId);
        auth.captureBeyond(credit, alice, leg, 900e6);
        assertEq(credit.lineOf(lineId).owed, 10e6, "only what the hold reserved");
        // A free capture (a tip, the last leg) neither.
        bytes32 leg2 = bytes32("leg-2");
        uint64 other = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        auth.hold(credit, alice, _pos(other), leg2, 10e6, false);
        vm.prank(lender);
        credit.closeLine(other);
        auth.captureFree(credit, alice, leg2, 900e6);
        assertEq(credit.lineOf(other).owed, 10e6);
    }

    function test_repayFor_onlyACompanionOfTheProgram() public {
        uint64 lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        _draw(alice, lineId, LEG, 100e6, REF);
        usd.mint(operator, 100e6);
        vm.startPrank(operator);
        usd.approve(address(credit), 100e6);
        vm.expectRevert(CreditSource.NotProgram.selector);
        credit.repayFor(lineId, 50e6, REF);
        vm.stopPrank();
        // A treasury role alone may not: it could otherwise give itself a right to draw the line again.
        auth.setRoles(operator, TREASURY | SETTLE, type(uint256).max);
        vm.prank(operator);
        vm.expectRevert(CreditSource.NotProgram.selector);
        credit.repayFor(lineId, 50e6, REF);
        // A registered companion of the program may (the desk is one).
        assertTrue(auth.isCompanion(address(desk)));
        auth.setCompanion(operator, true);
        vm.prank(operator);
        credit.repayFor(lineId, 50e6, REF);
        (uint128 repaid,) = credit.repaymentOf(lineId, REF);
        assertEq(repaid, 50e6);
    }

    function test_redraw_boundedByWhatTheRefRepaid_andPaysTheSettlementAccount() public {
        uint64 lineId = _repaidLine();
        uint256 before = usd.balanceOf(settlement);
        vm.prank(operator);
        assertEq(credit.redraw(lineId, 500e6, REF), 400e6);
        assertEq(usd.balanceOf(settlement) - before, 400e6);
        assertEq(credit.lineOf(lineId).owed, 400e6);
        assertEq(credit.redrawable(lineId, REF), 0);
        // Another purchase's repayment never funds this one's redraw.
        vm.prank(operator);
        vm.expectRevert(CreditSource.NothingToRedraw.selector);
        credit.redraw(lineId, 1, REF);
        vm.prank(operator);
        vm.expectRevert(CreditSource.NothingToRedraw.selector);
        credit.redraw(lineId, 1, bytes32("other"));
        _assertCoreBalanced();
    }

    function test_redraw_cumulativeForARefNeverExceedsWhatItRepaid() public {
        uint64 lineId = _repaidLine();
        vm.startPrank(operator);
        assertEq(credit.redraw(lineId, 150e6, REF), 150e6);
        assertEq(credit.redraw(lineId, 150e6, REF), 150e6);
        assertEq(credit.redraw(lineId, 150e6, REF), 100e6);
        vm.stopPrank();
        assertEq(credit.lineOf(lineId).owed, 400e6);
    }

    function test_redraw_boundedByTheUndrawnLimit() public {
        uint64 lineId = _repaidLine();
        // The limit drops while the purchase is repaid: the redraw takes what room is left.
        vm.prank(lender);
        credit.setLimit(lineId, 300e6);
        vm.prank(operator);
        assertEq(credit.redraw(lineId, 400e6, REF), 300e6);
        assertEq(credit.availableCredit(lineId), 0);
    }

    function test_redraw_refusedToAllButCompanionsOrOnAClosedLine() public {
        uint64 lineId = _repaidLine();
        auth.setCompanion(operator, false);
        auth.setRoles(operator, TREASURY | SETTLE, type(uint256).max);
        vm.prank(operator);
        vm.expectRevert(CreditSource.NotProgram.selector);
        credit.redraw(lineId, 1, REF);
        auth.setCompanion(operator, true);
        vm.prank(alice);
        credit.closeLine(lineId);
        assertEq(credit.redrawable(lineId, REF), 0);
        vm.prank(operator);
        vm.expectRevert(CreditSource.LineNotOpen.selector);
        credit.redraw(lineId, 1, REF);
    }

    function test_redraw_pastDueRefused() public {
        uint64 lineId = _repaidLine();
        vm.warp(block.timestamp + 61 days);
        vm.prank(operator);
        vm.expectRevert(CreditSource.LineNotOpen.selector);
        credit.redraw(lineId, 1, REF);
    }

    function test_openLine_onlyLendersTheIssuerAllows() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(CreditSource.NotLender.selector);
        credit.openLine(stranger, 1, uint64(block.timestamp + 3650 days), IEarnVault(address(0)), 0, 0, 0);
        assertEq(credit.lineCount(), 0);
        assertEq(credit.settlementTokenInUse(address(auth)), 0);
    }

    function test_setLender_onlyTheIssuer_andStoppingALenderKeepsItsOpenLines() public {
        vm.prank(lender);
        vm.expectRevert(CreditSource.NotIssuer.selector);
        credit.setLender(lender, true);
        uint64 lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        vm.prank(issuer);
        vm.expectEmit(address(credit));
        emit CreditSource.LenderSet(lender, false);
        credit.setLender(lender, false);
        assertFalse(credit.isLender(lender));
        // Its accepted line still draws and still keeps the token in use.
        _draw(alice, lineId, LEG, 10e6, REF);
        assertEq(credit.lineOf(lineId).owed, 10e6);
        assertEq(credit.settlementTokenInUse(address(auth)), 7);
        // It opens no more.
        vm.prank(lender);
        vm.expectRevert(CreditSource.NotLender.selector);
        credit.openLine(bob, 100e6, uint64(block.timestamp + 30 days), IEarnVault(address(0)), 0, 0, 0);
    }

    function test_settlementTokenInUse_whileAnAcceptedLineHasRoom() public {
        assertEq(credit.settlementTokenInUse(address(auth)), 0);
        vm.startPrank(lender);
        core.approveHolder(address(credit), address(usd), type(uint128).max, 0);
        uint64 lineId =
            credit.openLine(alice, 100e6, uint64(block.timestamp + 30 days), IEarnVault(address(0)), 0, 0, 0);
        vm.stopPrank();
        // A line the borrower never accepted holds nothing back.
        assertEq(credit.settlementTokenInUse(address(auth)), 0);
        _accept(alice, lineId);
        assertEq(credit.settlementTokenInUse(address(auth)), 7);
        vm.prank(lender);
        credit.closeLine(lineId);
        assertEq(credit.settlementTokenInUse(address(auth)), 0);
    }

    function _lockingLine(uint256 savings) internal returns (uint64 lineId) {
        lineId = _openLine(alice, 10_000e6, IEarnVault(address(earnVault)), 5000, 0);
        usd.mint(alice, savings);
        _depositEarn(alice, savings);
        vm.startPrank(alice);
        core.approveHolder(address(credit), address(earnShare), type(uint128).max, 0);
        credit.enableLocking(lineId);
        vm.stopPrank();
    }

    /// @dev A line that drew 400 for REF and that a companion of the program (operator) repaid for REF.
    function _repaidLine() internal returns (uint64 lineId) {
        lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        _draw(alice, lineId, LEG, 400e6, REF);
        auth.setCompanion(operator, true);
        usd.mint(operator, 400e6);
        vm.startPrank(operator);
        usd.approve(address(credit), 400e6);
        credit.repayFor(lineId, 400e6, REF);
        vm.stopPrank();
        assertEq(credit.lineOf(lineId).owed, 0);
    }
}
