// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { Conversion } from "../../src/programs/Conversion.sol";
import { CreditSource } from "../../src/programs/CreditSource.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";
import { CompCardAuth, CompEnv } from "./harness/CompStubs.sol";
import { Rates } from "./harness/Rates.sol";

/// @notice Lines owed in the program's euro settlement token while the borrower pays with dollars: repayments and
///         autopay sell the borrower's tokens through the program's conversion venue, and dollar collateral is valued
///         and sold there.
contract CreditSourceConversionTest is CompEnv {
    // EUR at $1.10 with a 30 bps conversion cost each way.
    uint256 internal constant BID = 1.0967e18;
    uint256 internal constant ASK = 1_103_310_000_000_000_000;

    ITIP20Token internal eur;
    Conversion internal conv;
    FixedPricePool internal bid;
    FixedPricePool internal ask;
    uint64 internal due;
    uint256 internal draws;

    function setUp() public {
        _deployComp();
        eur = _createToken("Euro", "EURX");
        conv = new Conversion(address(usd), address(this));
        bid = new FixedPricePool(address(eur), address(usd), BID);
        ask = new FixedPricePool(address(eur), address(usd), ASK);
        usd.mint(address(bid), 1_000_000e6);
        eur.mint(address(ask), 1_000_000e6);
        conv.setVenue(address(eur), address(usd), address(bid), true);
        conv.setVenue(address(usd), address(eur), address(ask), false);
        Rates.set(conv, address(eur), 1.1e18);
        // The program settles in euros through the venue.
        auth = new CompCardAuth(issuer, settlement, address(eur));
        auth.setConversion(address(conv));
        credit = new CreditSource(auth);
        vm.prank(issuer);
        credit.setLender(lender, true);
        eur.mint(lender, 10_000e6);
        vm.prank(lender);
        core.approveHolder(address(credit), address(eur), type(uint128).max, 0);
        due = uint64(block.timestamp + 365 days);
    }

    function test_repayFrom_sellsTheBorrowersCashForWhatIsOwed() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0);
        _owe(lineId, 40e6);
        usd.mint(alice, 50e6);
        uint256 cost = conv.quoteOut(address(usd), address(eur), 40e6);
        // About $44.13 buys 40 euros after the venue's cost.
        assertGt(cost, 44.13e6);
        assertLt(cost, 44.14e6);
        vm.prank(alice);
        usd.approve(address(credit), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.ConversionExceedsMax.selector, cost, cost - 1));
        credit.repayFrom(lineId, address(usd), 40e6, cost - 1);
        vm.prank(alice);
        assertEq(credit.repayFrom(lineId, address(usd), 40e6, cost), cost);
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(usd.balanceOf(alice), 50e6 - cost);
        assertEq(usd.balanceOf(address(credit)), 0);
        assertEq(eur.balanceOf(address(credit)), 0);
        // The lender has its 40 euros back, committed again for the whole limit.
        assertEq(eur.balanceOf(lender) + core.reserved(lender, address(eur)), 10_000e6);
        assertEq(credit.committed(lineId), 1000e6);
        _assertCoreBalanced();
    }

    function test_repayFrom_inTheLinesTokenIsARepay() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0);
        _owe(lineId, 40e6);
        eur.mint(alice, 40e6);
        vm.startPrank(alice);
        eur.approve(address(credit), 40e6);
        assertEq(credit.repayFrom(lineId, address(eur), 40e6, 0), 40e6);
        vm.stopPrank();
        assertEq(credit.lineOf(lineId).owed, 0);
    }

    function test_repayFrom_needsAVenue() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0);
        _owe(lineId, 40e6);
        auth.setConversion(address(0));
        usd.mint(alice, 50e6);
        vm.startPrank(alice);
        usd.approve(address(credit), type(uint256).max);
        vm.expectRevert(CreditSource.NoConversion.selector);
        credit.repayFrom(lineId, address(usd), 40e6, 50e6);
        vm.stopPrank();
    }

    function test_autopay_sellsCashForAStatement() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0);
        address[] memory sources = new address[](1);
        sources[0] = address(usd);
        vm.prank(alice);
        credit.setAutopay(lineId, sources);
        _owe(lineId, 10e6);
        usd.mint(alice, 20e6);
        vm.prank(alice);
        usd.approve(address(credit), type(uint256).max);
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);
        uint256 cost = conv.quoteOut(address(usd), address(eur), 10e6);
        credit.collect(lineId);
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditSource.StatementStatus.Paid));
        assertEq(usd.balanceOf(alice), 20e6 - cost);
        _assertCoreBalanced();
    }

    function test_autopay_sellsWhatCashThereIsWhenShort() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0);
        address[] memory sources = new address[](1);
        sources[0] = address(usd);
        vm.prank(alice);
        credit.setAutopay(lineId, sources);
        _owe(lineId, 10e6);
        usd.mint(alice, 5e6);
        vm.prank(alice);
        usd.approve(address(credit), type(uint256).max);
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);
        uint256 bought = conv.quoteIn(address(usd), address(eur), 5e6);
        credit.collect(lineId);
        assertEq(usd.balanceOf(alice), 0);
        assertEq(credit.lineOf(lineId).owed, 10e6 - bought);
        assertEq(credit.statementOf(lineId, 1).paid, bought);
    }

    function test_setAutopay_otherTokenNeedsAVenue() public {
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0);
        auth.setConversion(address(0));
        address[] memory sources = new address[](1);
        sources[0] = address(usd);
        vm.prank(alice);
        vm.expectRevert(CreditSource.InvalidAutopay.selector);
        credit.setAutopay(lineId, sources);
    }

    function test_secured_valuesAndSellsCollateralInTheLinesToken() public {
        uint64 lineId = _line(600e6, IEarnVault(address(earnVault)), 5000);
        usd.mint(alice, 1100e6);
        _depositEarn(alice, 1100e6);
        vm.startPrank(alice);
        core.approveHolder(address(credit), address(earnShare), type(uint128).max, 0);
        credit.enableLocking(lineId);
        vm.stopPrank();
        // 1,100 dollars of shares sell for about 997 euros, so 50% lends about 498.50.
        uint256 value = conv.quoteIn(address(usd), address(eur), earnVault.previewRedeem(earnShare.balanceOf(alice)));
        assertEq(credit.collateralValue(lineId), value);
        assertEq(credit.availableCredit(lineId), value / 2);
        assertApproxEqAbs(credit.availableCredit(lineId), 498.5e6, 0.1e6);
        // 300 euros owed locks shares worth what buys 600.
        _owe(lineId, 300e6);
        uint256 locked = credit.lockedShares(lineId);
        assertApproxEqAbs(locked, earnVault.previewWithdraw(conv.quoteOut(address(usd), address(eur), 600e6)), 1);
        // Halved, the shares fall under the loan-to-value, and the lender sells some for euros.
        uint256 loss = usd.balanceOf(address(venue)) / 2;
        vm.prank(address(venue));
        usd.transfer(address(0xdead), loss);
        uint256 before = eur.balanceOf(lender) + core.reserved(lender, address(eur));
        vm.prank(lender);
        (, uint256 assets) = credit.liquidate(lineId);
        assertGt(assets, 0);
        assertEq(eur.balanceOf(lender) + core.reserved(lender, address(eur)) - before, assets);
        assertEq(credit.lineOf(lineId).owed, 300e6 - assets);
        assertEq(usd.balanceOf(address(credit)), 0);
        assertEq(eur.balanceOf(address(credit)), 0);
        _assertCoreBalanced();
    }

    function test_liquidate_refusesSellingFarBelowTheReferenceRate() public {
        uint64 lineId = _line(600e6, IEarnVault(address(earnVault)), 5000);
        usd.mint(alice, 1100e6);
        _depositEarn(alice, 1100e6);
        vm.startPrank(alice);
        core.approveHolder(address(credit), address(earnShare), type(uint128).max, 0);
        credit.enableLocking(lineId);
        vm.stopPrank();
        _owe(lineId, 300e6);
        uint256 loss = usd.balanceOf(address(venue)) / 2;
        vm.prank(address(venue));
        usd.transfer(address(0xdead), loss);
        // The venue sells dollars for a tenth of their reference value: the sale is refused, nothing is sold.
        ask.setPrice(11e18);
        uint256 locked = credit.lockedShares(lineId);
        vm.prank(lender);
        vm.expectPartialRevert(Conversion.RateDeviates.selector);
        credit.liquidate(lineId);
        assertEq(credit.lockedShares(lineId), locked);
        assertEq(credit.lineOf(lineId).owed, 300e6);
    }

    /// @dev A reference rate moved tenfold (after its delay) values the collateral at a tenth, but the venue no longer
    ///      agrees with it, so nothing is valued or sold at it.
    function test_liquidate_refusedWhenTheReferenceRateStraysFromTheVenue() public {
        uint64 lineId = _lockedLine();
        _owe(lineId, 300e6);
        Rates.set(conv, address(eur), 11e18);
        uint256 locked = credit.lockedShares(lineId);
        vm.prank(lender);
        vm.expectPartialRevert(Conversion.RateDeviates.selector);
        credit.liquidate(lineId);
        assertEq(credit.lockedShares(lineId), locked);
        assertEq(credit.lineOf(lineId).owed, 300e6);
    }

    /// @dev The lender takes what the sale fetched up to what is owed, and the borrower the rest; the sale is sized at
    ///      the venue price it sells at, so it fetches what restores the loan-to-value and little more.
    function test_liquidate_paysTheLenderWhatIsOwedAndTheBorrowerTheRest() public {
        uint64 lineId = _lockedLine();
        _owe(lineId, 495e6);
        // The venue sells dollars 1% dearer, and the reference follows within a step.
        ask.setPrice(ASK * 101 / 100);
        bid.setPrice(BID * 101 / 100);
        conv.setReferenceRate(address(eur), 1.111e18);
        uint256 lenderBefore = eur.balanceOf(lender) + core.reserved(lender, address(eur));
        uint256 borrowerBefore = eur.balanceOf(alice);
        vm.prank(lender);
        (uint128 shares, uint256 assets) = credit.liquidate(lineId);
        assertGt(shares, 0);
        uint256 toLender = eur.balanceOf(lender) + core.reserved(lender, address(eur)) - lenderBefore;
        uint256 toBorrower = eur.balanceOf(alice) - borrowerBefore;
        assertEq(toLender + toBorrower, assets);
        assertEq(credit.lineOf(lineId).owed, 495e6 - toLender);
        assertLe(toLender, 495e6);
        assertEq(eur.balanceOf(address(credit)), 0);
        // Sized at the price it sold at: a few units of rounding past what restores the ratio, never a windfall.
        assertLe(toBorrower, 1e3);
    }

    /// @dev A charge-off sells shares worth what is owed at the venue price it sells at: the lender takes what is owed
    ///      and the borrower the units of rounding past it.
    function test_chargeOff_paysTheLenderWhatIsOwedAndTheBorrowerTheRest() public {
        uint64 lineId = _lockedLine();
        _owe(lineId, 300e6);
        uint64 dueAt = uint64(block.timestamp + 21 days);
        vm.prank(lender);
        credit.closeStatement(lineId, dueAt);
        vm.warp(dueAt + credit.CHARGE_OFF_GRACE());
        // Meanwhile the venue sells dollars 1% dearer, and the reference rate follows.
        ask.setPrice(ASK * 101 / 100);
        bid.setPrice(BID * 101 / 100);
        Rates.set(conv, address(eur), 1.111e18);
        uint256 shares = earnShare.balanceOf(alice) + core.reserved(alice, address(earnShare));
        uint256 lenderBefore = eur.balanceOf(lender) + core.reserved(lender, address(eur));
        uint256 borrowerBefore = eur.balanceOf(alice);
        vm.prank(lender);
        (uint128 sold, uint256 assets) = credit.chargeOff(lineId);
        uint256 toLender = eur.balanceOf(lender) + core.reserved(lender, address(eur)) - lenderBefore;
        uint256 toBorrower = eur.balanceOf(alice) - borrowerBefore;
        assertEq(toLender, 300e6, "the lender takes everything owed");
        assertEq(toBorrower, assets - 300e6, "the borrower takes the rest of the sale");
        assertLe(toBorrower, 1e3);
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(credit.lockOf(lineId), bytes32(0));
        assertEq(earnShare.balanceOf(alice), shares - sold);
        assertEq(usd.balanceOf(address(credit)), 0);
        assertEq(eur.balanceOf(address(credit)), 0);
        _assertCoreBalanced();
    }

    function _lockedLine() internal returns (uint64 lineId) {
        lineId = _line(600e6, IEarnVault(address(earnVault)), 5000);
        usd.mint(alice, 1100e6);
        _depositEarn(alice, 1100e6);
        vm.startPrank(alice);
        core.approveHolder(address(credit), address(earnShare), type(uint128).max, 0);
        credit.enableLocking(lineId);
        vm.stopPrank();
    }

    function test_openLine_otherTokenCollateralNeedsAVenue() public {
        auth.setConversion(address(0));
        vm.prank(lender);
        vm.expectRevert(CreditSource.InvalidLine.selector);
        credit.openLine(alice, 1, due, IEarnVault(address(earnVault)), 5000, 0, 0);
    }

    function test_settlementTokenInUse_whileALineInTheTokenIsOpen() public {
        auth.setToken(address(eur));
        assertEq(credit.settlementTokenInUse(address(auth)), 0);
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0);
        assertEq(credit.settlementTokenInUse(address(auth)), 7);
        // A line in another token does not hold this one.
        auth.setToken(address(usd));
        assertEq(credit.settlementTokenInUse(address(auth)), 0);
        auth.setToken(address(eur));
        // Closed to a zero limit with a balance still owed, it stays open until repaid.
        _owe(lineId, 40e6);
        vm.prank(lender);
        credit.setLimit(lineId, 0);
        assertEq(credit.settlementTokenInUse(address(auth)), 7);
        eur.mint(alice, 40e6);
        vm.prank(alice);
        eur.approve(address(credit), 40e6);
        vm.prank(alice);
        credit.repay(lineId, 40e6);
        assertEq(credit.settlementTokenInUse(address(auth)), 0);
    }

    function test_settlementTokenInUse_ignoresLinesTheBorrowerNeverAccepted() public {
        auth.setToken(address(eur));
        address stranger = makeAddr("stranger");
        vm.prank(issuer);
        credit.setLender(stranger, true);
        vm.prank(stranger);
        uint64 lineId = credit.openLine(bob, 1000e6, due, IEarnVault(address(0)), 0, 0, 0);
        assertEq(credit.settlementTokenInUse(address(auth)), 0);
        // Accepted, the line holds the token until it closes.
        _accept(bob, lineId);
        assertEq(credit.settlementTokenInUse(address(auth)), 7);
        vm.prank(bob);
        credit.closeLine(lineId);
        assertEq(credit.settlementTokenInUse(address(auth)), 0);
    }

    function test_settlementTokenInUse_costDoesNotGrowWithLines() public {
        auth.setToken(address(eur));
        uint256 gas = gasleft();
        credit.settlementTokenInUse(address(auth));
        uint256 before = gas - gasleft();
        address stranger = makeAddr("stranger");
        vm.prank(issuer);
        credit.setLender(stranger, true);
        for (uint160 i = 1; i <= 50; ++i) {
            vm.prank(stranger);
            credit.openLine(address(i + 0x1000), 1e6, due, IEarnVault(address(0)), 0, 0, 0);
        }
        gas = gasleft();
        assertEq(credit.settlementTokenInUse(address(auth)), 0);
        uint256 later = gas - gasleft();
        assertLe(later, before + 5000);
    }

    function _line(uint128 limit, IEarnVault vault, uint16 ltvBps) internal returns (uint64 lineId) {
        vm.prank(lender);
        lineId = credit.openLine(alice, limit, due, vault, ltvBps, 0, 0);
        _accept(alice, lineId);
    }

    function _owe(uint64 lineId, uint128 amount) internal {
        bytes32 leg = bytes32(++draws);
        _draw(alice, lineId, leg, amount, leg);
    }
}
