// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CreditLine } from "../../src/programs/CreditLine.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice Credit lines over the core model, with this test as the line's card program: draws are holds on the
///         lender, captures and refunds become what the borrower owes, and secured lines cap credit at the pledge.
contract CreditLineTest is ProgramsEnv {
    bytes32 internal constant REF = bytes32("purchase-1");
    bytes32 internal constant PLEDGE = bytes32("pledge-1");
    uint64 internal due;
    address internal immutable SETTLE = makeAddr("settlement-account");
    address internal immutable operatorKey = makeAddr("operator-key");
    mapping(address => bool) internal operatorKeys;
    mapping(address => bool) internal treasuryKeys;

    function setUp() public {
        _deployPrograms();
        usd.mint(lender, 100_000e6);
        vm.prank(lender);
        core.approveHolder(address(credit), address(usd), type(uint128).max);
        due = uint64(block.timestamp + 60 days);
    }

    // Unsecured lines.

    function test_draw_holdsTheLendersBalance() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0, true);
        bytes32 id = _draw(lineId, 100e6);
        IReservationCore.HoldRecord memory h = core.getHold(lender, id);
        assertEq(h.placer, address(credit));
        assertEq(h.payee, address(this));
        assertEq(h.held, 100e6);
        // The draw comes out of the commitment, so the lender's reserve stays at the limit.
        assertEq(core.reserved(lender, address(usd)), 1000e6);
        assertEq(credit.committed(lineId), 900e6);
        assertEq(credit.lineOf(lineId).pending, 100e6);
        assertEq(credit.availableCredit(lineId), 900e6);
        _assertCoreBalanced();
    }

    function test_draw_onlyTheLinesProgram() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0, true);
        vm.prank(bob);
        vm.expectRevert(CreditLine.NotProgram.selector);
        credit.draw(lineId, alice, REF, 1e6, uint64(block.timestamp + 1 days));
        vm.expectRevert(CreditLine.NotBorrower.selector);
        credit.draw(lineId, bob, REF, 1e6, uint64(block.timestamp + 1 days));
    }

    function test_draw_needsAcceptanceAndAnOpenLine() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0, false);
        vm.expectRevert(CreditLine.LineNotOpen.selector);
        credit.draw(lineId, alice, REF, 1e6, uint64(block.timestamp + 1 days));
        _acceptLine(alice, lineId);
        vm.prank(lender);
        credit.closeLine(lineId);
        vm.expectRevert(CreditLine.LineNotOpen.selector);
        credit.draw(lineId, alice, REF, 1e6, uint64(block.timestamp + 1 days));
    }

    function test_draw_notPastDue() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0, true);
        vm.warp(due);
        vm.expectRevert(CreditLine.LineNotOpen.selector);
        credit.draw(lineId, alice, REF, 1e6, uint64(block.timestamp + 1 days));
    }

    function test_draw_withinLimit() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0, true);
        _draw(lineId, 700e6);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.CreditExceeded.selector, uint256(400e6), uint256(300e6)));
        credit.draw(lineId, alice, bytes32("purchase-2"), 400e6, uint64(block.timestamp + 1 days));
    }

    function test_capture_owesWhatWasDrawn_refundAndRepay() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0, true);
        bytes32 id = _draw(lineId, 100e6);
        core.capture(lender, id, 60e6, true);
        credit.sync(id);
        assertEq(credit.lineOf(lineId).owed, 60e6);
        assertEq(credit.lineOf(lineId).pending, 0);
        assertEq(usd.balanceOf(address(this)), 60e6);
        assertEq(credit.availableCredit(lineId), 940e6);

        // A refund to the lender takes from what the borrower owes.
        core.refund(lender, id, 20e6);
        credit.sync(id);
        assertEq(credit.lineOf(lineId).owed, 40e6);

        usd.mint(alice, 40e6);
        vm.prank(alice);
        usd.approve(address(credit), 40e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.RepayExceedsOwed.selector, uint256(41e6), uint256(40e6)));
        credit.repay(lineId, 41e6);
        vm.prank(alice);
        credit.repay(lineId, 40e6);
        assertEq(credit.lineOf(lineId).owed, 0);
        // Repaid in full, the whole limit is committed again.
        assertEq(usd.balanceOf(lender) + core.reserved(lender, address(usd)), 100_000e6 - 60e6 + 20e6 + 40e6);
        assertEq(credit.committed(lineId), 1000e6);
    }

    function test_revokedLender_liveDrawStillSettles() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0, true);
        bytes32 id = _draw(lineId, 100e6);
        vm.prank(lender);
        core.approveHolder(address(credit), address(usd), 0);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        credit.draw(lineId, alice, bytes32("purchase-2"), 1e6, uint64(block.timestamp + 1 days));
        core.capture(lender, id, 100e6, true);
        credit.sync(id);
        assertEq(credit.lineOf(lineId).owed, 100e6);
    }

    function test_expiredDraw_freesPending() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0, true);
        bytes32 id = _draw(lineId, 100e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        core.releaseExpired(lender, id);
        credit.sync(id);
        assertEq(credit.lineOf(lineId).pending, 0);
        assertEq(credit.lineOf(lineId).owed, 0);
    }

    function test_sync_unknownDraw() public {
        vm.expectRevert(CreditLine.UnknownDraw.selector);
        credit.sync(bytes32("nothing"));
    }

    function test_openLine_rejectsBadTerms() public {
        vm.startPrank(lender);
        vm.expectRevert(CreditLine.InvalidLine.selector);
        credit.openLine(
            alice, address(usd), address(this), 1, uint64(block.timestamp), 0, IEarnVault(address(0)), 0, 0, 0
        );
        vm.expectRevert(CreditLine.InvalidLine.selector);
        credit.openLine(alice, address(usd), address(this), 1, due, 0, IEarnVault(address(earnVault)), 0, 0, 0);
        vm.expectRevert(CreditLine.InvalidLine.selector);
        credit.openLine(alice, address(otherUsd), address(this), 1, due, 0, IEarnVault(address(earnVault)), 5000, 0, 0);
        vm.stopPrank();
    }

    // Secured lines.

    function test_secured_creditIsPledgeValueTimesLtv() public {
        uint64 lineId = _securedLine(10_000e6, 200e6);
        uint256 value = credit.collateralValue(lineId);
        assertApproxEqAbs(value, 200e6, 1);
        assertEq(credit.availableCredit(lineId), value * 5000 / 10_000);
    }

    function test_secured_underCollateralizedRefused() public {
        uint64 lineId = _securedLine(10_000e6, 200e6);
        uint256 available = credit.availableCredit(lineId);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.CreditExceeded.selector, uint256(120e6), available));
        credit.draw(lineId, alice, REF, 120e6, uint64(block.timestamp + 1 days));
        _draw(lineId, 90e6);
    }

    function test_secured_noPledgeNoCredit() public {
        uint64 lineId = _line(10_000e6, IEarnVault(address(earnVault)), 5000, true);
        assertEq(credit.availableCredit(lineId), 0);
        vm.expectPartialRevert(CreditLine.CreditExceeded.selector);
        credit.draw(lineId, alice, REF, 1e6, uint64(block.timestamp + 1 days));
    }

    function test_attachPledge_mustOutliveDueAndNotice() public {
        uint64 lineId = _line(10_000e6, IEarnVault(address(earnVault)), 5000, true);
        usd.mint(alice, 200e6);
        _depositEarn(alice, 200e6);
        _pledge(alice, 100e6, due + 7 days);
        vm.prank(alice);
        vm.expectRevert(CreditLine.InvalidPledge.selector);
        credit.attachPledge(lineId, PLEDGE);
    }

    function test_attachPledge_onlyTheBorrowersPledge() public {
        uint64 lineId = _line(10_000e6, IEarnVault(address(earnVault)), 5000, true);
        usd.mint(bob, 100e6);
        _depositEarn(bob, 100e6);
        _pledge(bob, 50e6, due + 10 days);
        vm.prank(alice);
        vm.expectRevert(CreditLine.InvalidPledge.selector);
        credit.attachPledge(lineId, PLEDGE);
        vm.prank(bob);
        vm.expectRevert(CreditLine.NotBorrower.selector);
        credit.attachPledge(lineId, PLEDGE);
    }

    function test_seize_onlyPastDueAndCappedAtOwed() public {
        uint64 lineId = _securedLine(10_000e6, 500e6);
        (,, uint128 pledged,,) = core.lienOf(address(credit), PLEDGE);
        bytes32 id = _draw(lineId, 100e6);
        core.capture(lender, id, 100e6, true);
        credit.sync(id);

        vm.prank(lender);
        vm.expectRevert(CreditLine.NotPastDue.selector);
        credit.seize(lineId);
        vm.warp(due);
        vm.prank(lender);
        vm.expectRevert(CreditLine.NotPastDue.selector);
        credit.seize(lineId);
        vm.warp(due + 7 days);
        vm.prank(bob);
        vm.expectRevert(CreditLine.NotLender.selector);
        credit.seize(lineId);

        uint256 lenderBefore = usd.balanceOf(lender);
        uint256 cover = earnVault.previewWithdraw(100e6);
        vm.prank(lender);
        (uint128 seized, uint256 assets) = credit.seize(lineId);
        assertEq(seized, cover);
        assertGe(assets, 100e6);
        assertEq(usd.balanceOf(lender), lenderBefore + assets);
        assertEq(credit.lineOf(lineId).owed, 0);
        (,, uint128 left,,) = core.lienOf(address(credit), PLEDGE);
        assertEq(left, pledged - seized);

        vm.prank(lender);
        vm.expectRevert(CreditLine.NothingOwed.selector);
        credit.seize(lineId);
        _assertCoreBalanced();
    }

    function test_releasePledge_onlyWhenNothingOwed() public {
        uint64 lineId = _securedLine(10_000e6, 200e6);
        uint256 shares = earnShare.balanceOf(alice);
        bytes32 id = _draw(lineId, 50e6);
        vm.prank(alice);
        vm.expectRevert(CreditLine.StillOwed.selector);
        credit.releasePledge(lineId);
        core.release(lender, id);
        credit.sync(id);
        vm.prank(alice);
        credit.releasePledge(lineId);
        assertGt(earnShare.balanceOf(alice), shares);
        assertEq(core.liened(alice, address(earnShare)), 0);
    }

    // Helpers.

    // Share locks.

    function test_locking_drawLocksSharesWorthUsedOverLtv() public {
        uint64 lineId = _lockingLine(1000e6);
        assertApproxEqAbs(credit.availableCredit(lineId), 500e6, 1);
        _draw(lineId, 280e6);
        uint256 locked = credit.lockedShares(lineId);
        assertApproxEqAbs(earnVault.previewRedeem(locked), 560e6, 2);
        assertEq(core.reserved(alice, address(earnShare)), locked);
        // The rest of the shares stay free and keep earning.
        assertApproxEqAbs(earnVault.previewRedeem(core.available(alice, address(earnShare))), 440e6, 2);
        _assertCoreBalanced();
    }

    function test_locking_underCollateralizedDrawRefused() public {
        uint64 lineId = _lockingLine(100e6);
        vm.expectPartialRevert(CreditLine.CreditExceeded.selector);
        credit.draw(lineId, alice, REF, 51e6, uint64(block.timestamp + 1 days));
        // A draw up to the loan-to-value locks every share, so none can move away to borrow twice on them.
        // forge-lint: disable-next-line(unsafe-typecast)
        _draw(lineId, uint128(credit.availableCredit(lineId)));
        assertEq(credit.availableCredit(lineId), 0);
        assertLe(core.available(alice, address(earnShare)), 1);
    }

    function test_locking_revokedAllowanceRefusesTheDraw() public {
        uint64 lineId = _lockingLine(100e6);
        vm.prank(alice);
        core.approveHolder(address(credit), address(earnShare), 0);
        vm.expectRevert();
        credit.draw(lineId, alice, REF, 10e6, uint64(block.timestamp + 1 days));
    }

    function test_locking_repayShrinksTheLock() public {
        uint64 lineId = _lockingLine(1000e6);
        bytes32 id = _draw(lineId, 200e6);
        core.capture(lender, id, 200e6, true);
        credit.sync(id);
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
        bytes32 id = _draw(lineId, 400e6);
        core.capture(lender, id, 400e6, true);
        credit.sync(id);
        vm.prank(lender);
        vm.expectPartialRevert(CreditLine.NotUndercollateralized.selector);
        credit.liquidate(lineId);
        // The venue loses 30%: $700 of shares secure $400, past 50%.
        uint256 loss = usd.balanceOf(address(venue)) * 3 / 10;
        vm.prank(address(venue));
        usd.transfer(address(0xdead), loss);
        credit.relock(lineId);
        assertEq(core.available(alice, address(earnShare)), 0);
        vm.prank(alice);
        vm.expectRevert(CreditLine.NotLender.selector);
        credit.liquidate(lineId);
        uint256 lenderBefore = usd.balanceOf(lender) + core.reserved(lender, address(usd));
        vm.prank(lender);
        (, uint256 assets) = credit.liquidate(lineId);
        assertApproxEqAbs(assets, 100e6, 2);
        assertEq(usd.balanceOf(lender) + core.reserved(lender, address(usd)) - lenderBefore, assets);
        uint128 owed = credit.lineOf(lineId).owed;
        uint256 left = earnVault.previewRedeem(earnShare.balanceOf(alice) + core.reserved(alice, address(earnShare)));
        assertLe(uint256(owed) * 2, left + 2);
        assertGe(uint256(owed) * 2 + 2, left);
        _assertCoreBalanced();
    }

    function test_lender_cannotAddOwedOutsideADraw() public {
        uint64 lineId = _lockingLine(1000e6);
        bytes32 id = _draw(lineId, 400e6);
        core.capture(lender, id, 400e6, true);
        credit.sync(id);
        // The line has no entry point for a lender to raise what the borrower owes.
        vm.prank(lender);
        (bool ok,) = address(credit).call(abi.encodeWithSignature("charge(uint64,uint128)", lineId, uint128(5000e6)));
        assertFalse(ok);
        assertEq(credit.lineOf(lineId).owed, 400e6);
        // Drawn within the limit and covered by the locked shares, the line cannot be liquidated.
        uint256 locked = credit.lockedShares(lineId);
        vm.prank(lender);
        vm.expectPartialRevert(CreditLine.NotUndercollateralized.selector);
        credit.liquidate(lineId);
        assertEq(credit.lockedShares(lineId), locked);
    }

    function test_redraw_operatorKeyCannotRedraw() public {
        uint64 lineId = _repaidLine();
        operatorKeys[operatorKey] = true;
        vm.prank(operatorKey);
        vm.expectRevert(CreditLine.NotProgram.selector);
        credit.redraw(lineId, 100e6, REF);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        credit.redraw(lineId, 100e6, REF);
    }

    function test_redraw_refusedOnAClosedUnacceptedOrPastDueLine() public {
        uint64 unaccepted = _line(1000e6, IEarnVault(address(0)), 0, false);
        vm.expectRevert(CreditLine.LineNotOpen.selector);
        credit.redraw(unaccepted, 100e6, REF);
        vm.prank(lender);
        credit.closeLine(unaccepted);
        uint64 closed = _repaidLine();
        vm.prank(alice);
        credit.closeLine(closed);
        vm.expectRevert(CreditLine.LineNotOpen.selector);
        credit.redraw(closed, 100e6, REF);
        uint64 pastDue = _line(1000e6, IEarnVault(address(0)), 0, true);
        vm.warp(due);
        vm.expectRevert(CreditLine.LineNotOpen.selector);
        credit.redraw(pastDue, 100e6, REF);
    }

    function test_redraw_boundedByWhatTheRefRepaid_andPaysTheSettlementAccount() public {
        uint64 lineId = _repaidLine();
        assertEq(credit.redrawable(lineId, REF), 400e6);
        uint128 drawn = credit.redraw(lineId, 5000e6, REF);
        assertEq(drawn, 400e6, "only what the reference repaid");
        assertEq(credit.lineOf(lineId).owed, 400e6);
        assertEq(usd.balanceOf(SETTLE), 400e6);
        assertEq(credit.redrawable(lineId, REF), 0);
        // Nothing is left of the reference's repayment to draw again.
        vm.expectRevert(CreditLine.NothingToRedraw.selector);
        credit.redraw(lineId, 1, REF);
    }

    function test_redraw_boundedByTheUndrawnLimit() public {
        uint64 lineId = _repaidLine();
        vm.prank(lender);
        credit.setLimit(lineId, 150e6);
        assertEq(credit.redraw(lineId, 300e6, REF), 150e6);
        // Nothing is left of the limit; the rest of the reference's repayment stays.
        assertEq(credit.redraw(lineId, 1, REF), 0);
        assertEq(credit.redrawable(lineId, REF), 250e6);
    }

    function test_redraw_withoutARecordedRepaymentReverts() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0, true);
        // Nothing was repaid for the reference: the line cannot be drawn for the settlement account.
        vm.expectRevert(CreditLine.NothingToRedraw.selector);
        credit.redraw(lineId, 500e6, REF);
        assertEq(credit.lineOf(lineId).owed, 0);
        // The borrower's own repayment carries no reference and is never drawn again.
        bytes32 id = _draw(lineId, 100e6);
        core.capture(lender, id, 100e6, true);
        credit.sync(id);
        usd.mint(alice, 100e6);
        vm.startPrank(alice);
        usd.approve(address(credit), 100e6);
        credit.repay(lineId, 100e6);
        vm.stopPrank();
        vm.expectRevert(CreditLine.NothingToRedraw.selector);
        credit.redraw(lineId, 100e6, REF);
        vm.expectRevert(CreditLine.NothingToRedraw.selector);
        credit.redraw(lineId, 100e6, bytes32(0));
    }

    function test_redraw_cumulativeForARefNeverExceedsWhatItRepaid() public {
        uint64 lineId = _repaidLine();
        assertEq(credit.redraw(lineId, 300e6, REF), 300e6);
        assertEq(credit.redraw(lineId, 300e6, REF), 100e6, "the rest of the reference's repayment");
        vm.expectRevert(CreditLine.NothingToRedraw.selector);
        credit.redraw(lineId, 1, REF);
        // Another reference's repayment is its own.
        vm.expectRevert(CreditLine.NothingToRedraw.selector);
        credit.redraw(lineId, 1, bytes32("purchase-2"));
        assertEq(credit.lineOf(lineId).owed, 400e6);
    }

    function test_repayFor_onlyTheProgramOrItsTreasuryKey() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0, true);
        bytes32 id = _draw(lineId, 100e6);
        core.capture(lender, id, 100e6, true);
        credit.sync(id);
        address key = makeAddr("treasury-key");
        usd.mint(key, 100e6);
        vm.prank(key);
        usd.approve(address(credit), 100e6);
        vm.prank(key);
        vm.expectRevert(CreditLine.NotProgram.selector);
        credit.repayFor(lineId, 50e6, REF);
        treasuryKeys[key] = true;
        vm.prank(key);
        credit.repayFor(lineId, 50e6, REF);
        (uint128 repaid, uint128 redrawn) = credit.repaymentOf(lineId, REF);
        assertEq(repaid, 50e6);
        assertEq(redrawn, 0);
        assertEq(credit.lineOf(lineId).owed, 50e6);
    }

    function test_locking_excludesAPledge() public {
        uint64 lineId = _lockingLine(100e6);
        vm.prank(alice);
        vm.expectRevert(CreditLine.InvalidPledge.selector);
        credit.attachPledge(lineId, PLEDGE);
    }

    function _lockingLine(uint256 savings) internal returns (uint64 lineId) {
        lineId = _line(10_000e6, IEarnVault(address(earnVault)), 5000, true);
        usd.mint(alice, savings);
        _depositEarn(alice, savings);
        vm.startPrank(alice);
        core.approveHolder(address(credit), address(earnShare), type(uint128).max);
        credit.enableLocking(lineId);
        vm.stopPrank();
    }

    function _repaidLine() internal returns (uint64 lineId) {
        lineId = _line(1000e6, IEarnVault(address(0)), 0, true);
        bytes32 id = _draw(lineId, 400e6);
        core.capture(lender, id, 400e6, true);
        credit.sync(id);
        // The program repays the line for the purchase, as a provisional credit does.
        usd.mint(address(this), 400e6);
        usd.approve(address(credit), 400e6);
        credit.repayFor(lineId, 400e6, REF);
        assertEq(credit.lineOf(lineId).owed, 0);
    }

    /// @dev The line's program names its settlement account and its operator keys.
    function SETTLEMENT_ACCOUNT() external view returns (address) {
        return SETTLE;
    }

    function rolesOf(address key) external view returns (uint8) {
        return treasuryKeys[key] ? 4 : 0;
    }

    function operators(address key) external view returns (bool) {
        return operatorKeys[key];
    }

    function _line(uint128 limit, IEarnVault vault, uint16 ltvBps, bool accept) internal returns (uint64 lineId) {
        vm.prank(lender);
        lineId = credit.openLine(alice, address(usd), address(this), limit, due, 7 days, vault, ltvBps, 0, 0);
        if (accept) {
            _acceptLine(alice, lineId);
        }
    }

    function _securedLine(uint128 limit, uint256 collateral) internal returns (uint64 lineId) {
        lineId = _line(limit, IEarnVault(address(earnVault)), 5000, true);
        usd.mint(alice, collateral);
        uint256 shares = _depositEarn(alice, collateral);
        _pledge(alice, shares, due + 10 days);
        vm.prank(alice);
        credit.attachPledge(lineId, PLEDGE);
    }

    function _pledge(address owner, uint256 shares, uint64 expiresAt) internal {
        vm.prank(owner);
        // forge-lint: disable-next-line(unsafe-typecast)
        core.pledge(address(credit), address(earnShare), PLEDGE, uint128(shares), expiresAt);
    }

    function _draw(uint64 lineId, uint128 amount) internal returns (bytes32 id) {
        (id,,) = credit.draw(lineId, alice, REF, amount, uint64(block.timestamp + 1 days));
    }
}
