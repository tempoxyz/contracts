// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../../src/interfaces/earn/IEarnVault.sol";

import { CreditSource } from "../../../src/spend/programs/CreditSource.sol";
import { CompEnv } from "./harness/CompStubs.sol";

/// @notice Keeping a secured line's collateral: its lock renews in the last half of its term and is taken over again
///         after it lapses while the line owes anything, and a line with a statement unpaid CHARGE_OFF_GRACE past due
///         is charged off, selling locked shares worth what it owes.
contract CreditSourceRecoveryTest is CompEnv {
    bytes32 internal constant REF = bytes32("purchase-1");
    bytes32 internal constant LEG = bytes32("leg-1");
    uint256 internal constant TERM = 30 days;

    address internal keeper = makeAddr("keeper");
    address internal elsewhere = makeAddr("elsewhere");

    function setUp() public {
        _deployComp();
    }

    function test_constants() public view {
        assertEq(credit.RENEW_WINDOW(), 15 days);
        assertEq(credit.CHARGE_OFF_GRACE(), 60 days);
    }

    // Lock renewal and takeover.

    function test_relock_renewsAnywhereInTheLastHalfOfTheTerm() public {
        uint64 lineId = _securedLine(1000e6, 0);
        _draw(alice, lineId, LEG, 200e6, REF);
        uint256 start = vm.getBlockTimestamp();
        uint256 locked = credit.lockedShares(lineId);
        assertEq(_lockExpiry(lineId), start + TERM);
        // Before the last half of the term a relock leaves the lock as it is.
        vm.warp(start + TERM - credit.RENEW_WINDOW() - 1);
        vm.prank(keeper);
        credit.relock(lineId);
        assertEq(_lockExpiry(lineId), start + TERM);
        // Inside it anyone renews the lock for a full term.
        vm.warp(start + TERM - credit.RENEW_WINDOW() + 1);
        vm.prank(keeper);
        credit.relock(lineId);
        assertEq(_lockExpiry(lineId), vm.getBlockTimestamp() + TERM);
        assertEq(credit.lockedShares(lineId), locked);
        _assertCoreBalanced();
    }

    function test_relock_weeklyTouchesNeverLetTheLockLapse() public {
        uint64 lineId = _securedLine(1000e6, 0);
        _draw(alice, lineId, LEG, 200e6, REF);
        uint256 locked = credit.lockedShares(lineId);
        for (uint256 i; i < 26; ++i) {
            vm.warp(vm.getBlockTimestamp() + 7 days);
            credit.relock(lineId);
            assertGt(_lockExpiry(lineId), vm.getBlockTimestamp() + 7 days, "a week's gap never reaches expiry");
            assertEq(credit.lockedShares(lineId), locked);
        }
    }

    function test_relock_takesOverALapsedLockWhileTheLineOwes() public {
        uint64 lineId = _securedLine(1000e6, 0);
        _draw(alice, lineId, LEG, 200e6, REF);
        uint256 locked = credit.lockedShares(lineId);
        vm.warp(vm.getBlockTimestamp() + TERM + 1);
        assertEq(credit.lockedShares(lineId), 0, "the lock lapsed");
        vm.prank(keeper);
        credit.relock(lineId);
        assertEq(credit.lockedShares(lineId), locked, "the same shares lock again");
        assertEq(_lockExpiry(lineId), vm.getBlockTimestamp() + TERM);
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice)), 600e6, 2);
        _assertCoreBalanced();
    }

    function test_relock_afterALapseLocksWhatIsLeft() public {
        uint64 lineId = _securedLine(1000e6, 0);
        _draw(alice, lineId, LEG, 400e6, REF);
        bytes32 id = credit.lockOf(lineId);
        vm.warp(vm.getBlockTimestamp() + TERM + 1);
        // The borrower ends the lapsed lock and moves most of its shares away.
        vm.startPrank(alice);
        core.releaseExpired(alice, address(credit), id);
        earnShare.transfer(elsewhere, earnShare.balanceOf(alice) * 7 / 10);
        vm.stopPrank();
        uint256 left = earnShare.balanceOf(alice);
        vm.prank(keeper);
        credit.relock(lineId);
        assertEq(credit.lockedShares(lineId), left, "every share still there locks");
        assertEq(earnShare.balanceOf(alice), 0);
        // The lender can sell what was locked again.
        vm.prank(lender);
        (uint128 sold,) = credit.liquidate(lineId);
        assertGt(sold, 0);
        _assertCoreBalanced();
    }

    function test_relock_lineOwingNothingLocksNothing() public {
        uint64 lineId = _securedLine(1000e6, 0);
        uint256 shares = earnShare.balanceOf(alice);
        vm.prank(keeper);
        credit.relock(lineId);
        assertEq(credit.lockOf(lineId), bytes32(0));
        _draw(alice, lineId, LEG, 200e6, REF);
        vm.warp(vm.getBlockTimestamp() + TERM + 1);
        // Repaying in full after the lock lapsed frees every share, and nobody can lock them again.
        _repay(lineId, 200e6);
        assertEq(credit.lockOf(lineId), bytes32(0));
        vm.prank(keeper);
        credit.relock(lineId);
        assertEq(credit.lockOf(lineId), bytes32(0));
        assertEq(earnShare.balanceOf(alice), shares);
        assertEq(core.reserved(alice, address(earnShare)), 0);
    }

    function test_withdraw_afterRepayAndClose() public {
        uint64 lineId = _securedLine(1000e6, 0);
        uint256 shares = earnShare.balanceOf(alice);
        _draw(alice, lineId, LEG, 300e6, REF);
        _repay(lineId, 300e6);
        vm.startPrank(alice);
        credit.closeLine(lineId);
        earnShare.transfer(elsewhere, shares);
        vm.stopPrank();
        assertEq(earnShare.balanceOf(elsewhere), shares);
        credit.relock(lineId);
        assertEq(credit.lockOf(lineId), bytes32(0));
    }

    function test_repay_inTheRenewWindowWithALowerAllowanceKeepsTheLock() public {
        uint64 lineId = _securedLine(1000e6, 0);
        _draw(alice, lineId, LEG, 400e6, REF);
        uint64 expiry = _lockExpiry(lineId);
        uint256 locked = credit.lockedShares(lineId);
        vm.warp(vm.getBlockTimestamp() + 20 days);
        // The borrower's allowance no longer admits a fresh lock; repaying shrinks the lock without renewing it.
        vm.prank(alice);
        core.approveHolder(address(credit), address(earnShare), 1, 0);
        _repay(lineId, 200e6);
        assertEq(_lockExpiry(lineId), expiry);
        assertApproxEqAbs(credit.lockedShares(lineId), locked / 2, 2);
    }

    // Charge-off.

    function test_chargeOff_refusedBeforeTheGracePeriodEnds() public {
        uint64 lineId = _securedLine(1000e6, 1000);
        _draw(alice, lineId, LEG, 400e6, REF);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.NotChargeable.selector, 0));
        credit.chargeOff(lineId);
        uint64 dueAt = _statement(lineId);
        uint256 at = dueAt + credit.CHARGE_OFF_GRACE();
        assertEq(credit.chargeableAt(lineId), at);
        vm.warp(at - 1);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.NotChargeable.selector, at));
        credit.chargeOff(lineId);
        vm.warp(at);
        vm.prank(lender);
        credit.chargeOff(lineId);
    }

    function test_chargeOff_onlyTheLenderOfASecuredLine() public {
        uint64 lineId = _securedLine(1000e6, 1000);
        _draw(alice, lineId, LEG, 400e6, REF);
        vm.warp(_statement(lineId) + credit.CHARGE_OFF_GRACE());
        vm.prank(alice);
        vm.expectRevert(CreditSource.NotLender.selector);
        credit.chargeOff(lineId);
        vm.prank(keeper);
        vm.expectRevert(CreditSource.NotLender.selector);
        credit.chargeOff(lineId);

        uint64 unsecured = _openLine(bob, 1000e6, IEarnVault(address(0)), 0, 0);
        vm.prank(lender);
        vm.expectRevert(CreditSource.InvalidLine.selector);
        credit.chargeOff(unsecured);
    }

    function test_chargeOff_refusedOnARepaidLine() public {
        uint64 lineId = _securedLine(1000e6, 1000);
        _draw(alice, lineId, LEG, 400e6, REF);
        uint64 dueAt = _statement(lineId);
        _repay(lineId, uint128(credit.owedNow(lineId)));
        assertEq(credit.chargeableAt(lineId), 0);
        vm.warp(dueAt + credit.CHARGE_OFF_GRACE() + 1);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.NotChargeable.selector, 0));
        credit.chargeOff(lineId);
    }

    function test_chargeOff_paidStatementLeavesOnlyLaterOnesChargeable() public {
        uint64 lineId = _securedLine(1000e6, 0);
        _draw(alice, lineId, LEG, 100e6, REF);
        uint64 first = _statement(lineId);
        _draw(alice, lineId, bytes32("leg-2"), 50e6, bytes32("purchase-2"));
        vm.prank(lender);
        uint64 second = first + 14 days;
        credit.closeStatement(lineId, second);
        assertEq(credit.chargeableAt(lineId), first + credit.CHARGE_OFF_GRACE());
        // Repaying the first statement's balance leaves the second as the one that counts.
        _repay(lineId, 100e6);
        assertEq(credit.chargeableAt(lineId), second + credit.CHARGE_OFF_GRACE());
        uint256 grace = credit.CHARGE_OFF_GRACE();
        vm.warp(first + grace);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.NotChargeable.selector, second + grace));
        credit.chargeOff(lineId);
        vm.warp(second + grace);
        vm.prank(lender);
        credit.chargeOff(lineId);
        assertEq(credit.lineOf(lineId).owed, 0);
    }

    function test_chargeOff_refusedOnceAutopayPaysThePastDueStatement() public {
        uint64 lineId = _securedLine(1000e6, 0);
        _autopayCash(lineId);
        _draw(alice, lineId, LEG, 400e6, REF);
        uint64 dueAt = _statement(lineId);
        // The collection on the due date finds nothing to draw.
        vm.warp(dueAt);
        credit.collect(lineId);
        uint256 at = dueAt + credit.CHARGE_OFF_GRACE();
        assertEq(credit.chargeableAt(lineId), at);
        // A month later the borrower funds autopay and a keeper's collection pays the statement.
        vm.warp(dueAt + 30 days);
        usd.mint(alice, 400e6);
        vm.prank(keeper);
        credit.collect(lineId);
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(credit.chargeableAt(lineId), 0);
        vm.warp(at);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.NotChargeable.selector, 0));
        credit.chargeOff(lineId);
        _assertCoreBalanced();
    }

    function test_chargeOff_afterAPartialRetryKeepsTheDueDateAndSellsOnlyTheRest() public {
        uint64 lineId = _securedLine(1000e6, 0);
        _autopayCash(lineId);
        _draw(alice, lineId, LEG, 400e6, REF);
        uint64 dueAt = _statement(lineId);
        vm.warp(dueAt);
        credit.collect(lineId);
        uint256 at = dueAt + credit.CHARGE_OFF_GRACE();
        // Autopay later covers a quarter: the debt falls, the clock does not move.
        vm.warp(dueAt + 30 days);
        usd.mint(alice, 100e6);
        credit.collect(lineId);
        assertEq(credit.lineOf(lineId).owed, 300e6);
        assertEq(credit.chargeableAt(lineId), at);
        vm.warp(at - 1);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.NotChargeable.selector, at));
        credit.chargeOff(lineId);
        vm.warp(at);
        uint256 lenderBefore = _lenderTotal();
        vm.prank(lender);
        credit.chargeOff(lineId);
        assertEq(_lenderTotal() - lenderBefore, 300e6, "the sale covers only what the retry left owed");
        assertEq(credit.lineOf(lineId).owed, 0);
        assertTrue(credit.lineOf(lineId).closed);
        _assertCoreBalanced();
    }

    function test_collect_afterAShortChargeOffDrawsAutopayTowardWhatIsStillOwed() public {
        uint64 lineId = _securedLine(1000e6, 0);
        _autopayCash(lineId);
        _draw(alice, lineId, LEG, 400e6, REF);
        // The venue loses 70%: the locked shares fetch about $300 against $400 owed.
        uint256 loss = usd.balanceOf(address(venue)) * 7 / 10;
        vm.prank(address(venue));
        usd.transfer(address(0xdead), loss);
        uint64 dueAt = _statement(lineId);
        vm.warp(dueAt + credit.CHARGE_OFF_GRACE());
        vm.prank(lender);
        credit.chargeOff(lineId);
        uint128 left = credit.lineOf(lineId).owed;
        assertGt(left, 0);
        // What stays owed stays billed to the past-due statement, which autopay pays once funded.
        usd.mint(alice, 500e6);
        credit.collect(lineId);
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(usd.balanceOf(alice), 500e6 - left);
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditSource.StatementStatus.Paid));
        _assertCoreBalanced();
    }

    function test_chargeOff_sellsWhatIsOwedAndFreesTheRest() public {
        uint64 lineId = _securedLine(1000e6, 1000);
        uint256 shares = earnShare.balanceOf(alice);
        _draw(alice, lineId, LEG, 400e6, REF);
        vm.warp(_statement(lineId) + credit.CHARGE_OFF_GRACE());
        uint256 owedNow = credit.owedNow(lineId);
        assertGt(owedNow, 400e6, "simple interest accrued");
        uint256 lenderBefore = _lenderTotal();
        uint256 aliceBefore = usd.balanceOf(alice);
        uint256 expected = earnVault.previewWithdraw(owedNow);
        vm.expectEmit(address(credit));
        emit CreditSource.ChargedOff(lineId, uint128(expected), earnVault.previewRedeem(expected), 0);
        vm.prank(lender);
        (uint128 sold, uint256 assets) = credit.chargeOff(lineId);
        assertEq(_lenderTotal() - lenderBefore, owedNow, "the lender takes everything owed");
        assertEq(usd.balanceOf(alice) - aliceBefore, assets - owedNow, "the borrower takes the rest of the sale");
        CreditSource.Line memory l = credit.lineOf(lineId);
        assertEq(l.owed, 0);
        assertTrue(l.closed);
        assertEq(credit.lockOf(lineId), bytes32(0), "nothing stays locked");
        assertEq(earnShare.balanceOf(alice), shares - sold, "the shares not sold are the borrower's");
        assertEq(usd.balanceOf(address(credit)), 0);
        _assertCoreBalanced();
        // The borrower moves what is left; the line cannot be charged off again.
        vm.prank(alice);
        earnShare.transfer(elsewhere, shares - sold);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.NotChargeable.selector, 0));
        credit.chargeOff(lineId);
    }

    function test_chargeOff_surplusGoesToTheBorrower() public {
        uint64 lineId = _securedLine(1000e6, 1000);
        // A thousandfold share price makes one share unit worth about 1,000 usd units, so selling whole share units
        // for what is owed fetches more than it.
        usd.mint(address(venue), usd.balanceOf(address(venue)) * 999);
        _draw(alice, lineId, LEG, 400e6, REF);
        vm.warp(_statement(lineId) + credit.CHARGE_OFF_GRACE());
        uint256 owedNow = credit.owedNow(lineId);
        uint256 lenderBefore = _lenderTotal();
        uint256 aliceBefore = usd.balanceOf(alice);
        vm.prank(lender);
        (, uint256 assets) = credit.chargeOff(lineId);
        assertGt(assets, owedNow, "the sale fetched more than owed");
        assertEq(_lenderTotal() - lenderBefore, owedNow, "the lender takes only what is owed");
        assertEq(usd.balanceOf(alice) - aliceBefore, assets - owedNow, "the borrower takes the surplus");
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(usd.balanceOf(address(credit)), 0);
        _assertCoreBalanced();
    }

    function test_chargeOff_shortCollateralSellsEverythingAndTheRestStaysOwed() public {
        uint64 lineId = _securedLine(1000e6, 1000);
        _draw(alice, lineId, LEG, 400e6, REF);
        // The venue loses 70%: every share is worth $300 against $400 owed.
        uint256 loss = usd.balanceOf(address(venue)) * 7 / 10;
        vm.prank(address(venue));
        usd.transfer(address(0xdead), loss);
        vm.warp(_statement(lineId) + credit.CHARGE_OFF_GRACE());
        uint256 owedNow = credit.owedNow(lineId);
        uint256 lenderBefore = _lenderTotal();
        uint256 aliceBefore = usd.balanceOf(alice);
        vm.prank(lender);
        (, uint256 assets) = credit.chargeOff(lineId);
        assertApproxEqAbs(assets, 300e6, 2);
        assertEq(_lenderTotal() - lenderBefore, assets, "the lender takes the whole sale");
        assertEq(usd.balanceOf(alice), aliceBefore, "no surplus");
        assertEq(credit.lineOf(lineId).owed, owedNow - assets, "the rest stays owed");
        assertEq(credit.lockedShares(lineId), 0);
        assertEq(earnShare.balanceOf(alice), 0);
        _assertCoreBalanced();
        // With nothing left to sell, a second charge-off is refused.
        vm.prank(lender);
        vm.expectRevert(CreditSource.NothingToSell.selector);
        credit.chargeOff(lineId);
    }

    function test_chargeOff_takesOverALapsedLock() public {
        uint64 lineId = _securedLine(1000e6, 1000);
        _draw(alice, lineId, LEG, 400e6, REF);
        // Nobody touched the line for longer than the lock's term.
        vm.warp(_statement(lineId) + credit.CHARGE_OFF_GRACE());
        assertEq(credit.lockedShares(lineId), 0);
        uint256 owedNow = credit.owedNow(lineId);
        uint256 lenderBefore = _lenderTotal();
        vm.prank(lender);
        credit.chargeOff(lineId);
        assertEq(_lenderTotal() - lenderBefore, owedNow);
        assertEq(credit.lineOf(lineId).owed, 0);
        _assertCoreBalanced();
    }

    function test_chargeOff_lineTheBorrowerClosed() public {
        uint64 lineId = _securedLine(1000e6, 1000);
        _draw(alice, lineId, LEG, 400e6, REF);
        uint64 dueAt = _statement(lineId);
        vm.prank(alice);
        credit.closeLine(lineId);
        vm.warp(dueAt + credit.CHARGE_OFF_GRACE());
        uint256 owedNow = credit.owedNow(lineId);
        uint256 lenderBefore = _lenderTotal();
        vm.prank(lender);
        credit.chargeOff(lineId);
        assertEq(_lenderTotal() - lenderBefore, owedNow);
    }

    // Helpers.

    function _securedLine(uint256 savings, uint16 aprBps) internal returns (uint64 lineId) {
        usd.mint(lender, 100_000e6);
        vm.startPrank(lender);
        core.approveHolder(address(credit), address(usd), type(uint128).max, 0);
        lineId = credit.openLine(
            alice, 10_000e6, uint64(block.timestamp + 400 days), IEarnVault(address(earnVault)), 5000, aprBps, 0
        );
        vm.stopPrank();
        _accept(alice, lineId);
        usd.mint(alice, savings);
        _depositEarn(alice, savings);
        vm.startPrank(alice);
        core.approveHolder(address(credit), address(earnShare), type(uint128).max, 0);
        credit.enableLocking(lineId);
        vm.stopPrank();
    }

    function _autopayCash(uint64 lineId) internal {
        address[] memory sources = new address[](1);
        sources[0] = address(usd);
        vm.startPrank(alice);
        credit.setAutopay(lineId, sources);
        usd.approve(address(credit), type(uint256).max);
        vm.stopPrank();
    }

    function _statement(uint64 lineId) internal returns (uint64 dueAt) {
        dueAt = uint64(vm.getBlockTimestamp() + 21 days);
        vm.prank(lender);
        credit.closeStatement(lineId, dueAt);
    }

    function _repay(uint64 lineId, uint128 amount) internal {
        usd.mint(alice, amount);
        vm.startPrank(alice);
        usd.approve(address(credit), amount);
        credit.repay(lineId, amount);
        vm.stopPrank();
    }

    function _lockExpiry(uint64 lineId) internal view returns (uint64) {
        return core.getHold(alice, address(credit), credit.lockOf(lineId)).expiresAt;
    }

    function _lenderTotal() internal view returns (uint256) {
        return usd.balanceOf(lender) + core.reserved(lender, address(usd));
    }
}
