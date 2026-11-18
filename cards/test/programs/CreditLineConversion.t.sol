// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { Conversion } from "../../src/programs/Conversion.sol";
import { CreditLine } from "../../src/programs/CreditLine.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice Lines owed in a token other than what the borrower pays with: repayments and autopay sell the borrower's
///         tokens through the program's conversion venue, and collateral in another token is valued and sold there.
///         This test is the line's card program, and names the venue as its `conversion`.
contract CreditLineConversionTest is ProgramsEnv {
    // EUR at $1.10 with a 30 bps conversion cost each way.
    uint256 internal constant BID = 1.0967e18;
    uint256 internal constant ASK = 1_103_310_000_000_000_000;

    /// @notice The program's conversion venue, read by the line.
    address public conversion;

    /// @notice The program's settlement token, read by the line's token guard.
    address public settlementToken;

    ITIP20Token internal eur;
    Conversion internal conv;
    FixedPricePool internal bid;
    FixedPricePool internal ask;
    uint64 internal due;

    function setUp() public {
        _deployPrograms();
        eur = _createToken("Euro", "EURX");
        conv = new Conversion(address(usd), address(this));
        bid = new FixedPricePool(address(eur), address(usd), BID);
        ask = new FixedPricePool(address(eur), address(usd), ASK);
        usd.mint(address(bid), 1_000_000e6);
        eur.mint(address(ask), 1_000_000e6);
        conv.setVenue(address(eur), address(usd), address(bid), true);
        conv.setVenue(address(usd), address(eur), address(ask), false);
        conv.setReferenceRate(address(eur), 1.1e18);
        conversion = address(conv);
        eur.mint(lender, 10_000e6);
        vm.prank(lender);
        core.approveHolder(address(credit), address(eur), type(uint128).max);
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
        vm.expectRevert(abi.encodeWithSelector(CreditLine.ConversionExceedsMax.selector, cost, cost - 1));
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
        conversion = address(0);
        usd.mint(alice, 50e6);
        vm.startPrank(alice);
        usd.approve(address(credit), type(uint256).max);
        vm.expectRevert(CreditLine.NoConversion.selector);
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
        assertEq(uint8(credit.statementOf(lineId, 1).status), uint8(CreditLine.StatementStatus.Paid));
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
        conversion = address(0);
        address[] memory sources = new address[](1);
        sources[0] = address(usd);
        vm.prank(alice);
        vm.expectRevert(CreditLine.InvalidAutopay.selector);
        credit.setAutopay(lineId, sources);
    }

    function test_secured_valuesAndSellsCollateralInTheLinesToken() public {
        uint64 lineId = _line(600e6, IEarnVault(address(earnVault)), 5000);
        usd.mint(alice, 1100e6);
        _depositEarn(alice, 1100e6);
        vm.startPrank(alice);
        core.approveHolder(address(credit), address(earnShare), type(uint128).max);
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
        core.approveHolder(address(credit), address(earnShare), type(uint128).max);
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
        vm.expectPartialRevert(Conversion.Slippage.selector);
        credit.liquidate(lineId);
        assertEq(credit.lockedShares(lineId), locked);
        assertEq(credit.lineOf(lineId).owed, 300e6);
    }

    function test_openLine_otherTokenCollateralNeedsAVenue() public {
        conversion = address(0);
        vm.prank(lender);
        vm.expectRevert(CreditLine.InvalidLine.selector);
        credit.openLine(alice, address(eur), address(this), 1, due, 0, IEarnVault(address(earnVault)), 5000, 0, 0);
    }

    function test_settlementTokenInUse_whileALineInTheTokenIsOpen() public {
        settlementToken = address(eur);
        assertEq(credit.settlementTokenInUse(address(this)), 0);
        uint64 lineId = _line(1000e6, IEarnVault(address(0)), 0);
        assertEq(credit.settlementTokenInUse(address(this)), 7);
        // A line in another token, or drawn by another program, does not hold this one.
        assertEq(credit.settlementTokenInUse(address(cards)), 0);
        settlementToken = address(usd);
        assertEq(credit.settlementTokenInUse(address(this)), 0);
        settlementToken = address(eur);
        // Closed to a zero limit with a balance still owed, it stays open until repaid.
        _owe(lineId, 40e6);
        vm.prank(lender);
        credit.setLimit(lineId, 0);
        assertEq(credit.settlementTokenInUse(address(this)), 7);
        eur.mint(alice, 40e6);
        vm.prank(alice);
        eur.approve(address(credit), 40e6);
        vm.prank(alice);
        credit.repay(lineId, 40e6);
        assertEq(credit.settlementTokenInUse(address(this)), 0);
    }

    function test_settlementTokenInUse_ignoresLinesTheBorrowerNeverAccepted() public {
        settlementToken = address(eur);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        uint64 lineId =
            credit.openLine(bob, address(eur), address(this), 1000e6, due, 0, IEarnVault(address(0)), 0, 0, 0);
        assertEq(credit.settlementTokenInUse(address(this)), 0);
        // Accepted, the line holds the token until it closes.
        _acceptLine(bob, lineId);
        assertEq(credit.settlementTokenInUse(address(this)), 7);
        vm.prank(bob);
        credit.closeLine(lineId);
        assertEq(credit.settlementTokenInUse(address(this)), 0);
    }

    function test_settlementTokenInUse_costDoesNotGrowWithLines() public {
        settlementToken = address(eur);
        uint256 gas = gasleft();
        credit.settlementTokenInUse(address(this));
        uint256 before = gas - gasleft();
        address stranger = makeAddr("stranger");
        for (uint160 i = 1; i <= 50; ++i) {
            vm.prank(stranger);
            credit.openLine(
                address(i + 0x1000), address(eur), address(this), 1e6, due, 0, IEarnVault(address(0)), 0, 0, 0
            );
        }
        gas = gasleft();
        assertEq(credit.settlementTokenInUse(address(this)), 0);
        uint256 later = gas - gasleft();
        assertLe(later, before + 5000);
    }

    function _line(uint128 limit, IEarnVault vault, uint16 ltvBps) internal returns (uint64 lineId) {
        vm.prank(lender);
        lineId = credit.openLine(alice, address(eur), address(this), limit, due, 7 days, vault, ltvBps, 0, 0);
        _acceptLine(alice, lineId);
    }

    function _owe(uint64 lineId, uint128 amount) internal {
        bytes32 ref = keccak256(abi.encode("purchase", credit.lineOf(lineId).owed, amount, block.timestamp));
        (bytes32 id,,) = credit.draw(lineId, alice, ref, amount, uint64(block.timestamp + 1 days));
        core.capture(lender, id, amount, true);
        credit.sync(id);
    }
}
