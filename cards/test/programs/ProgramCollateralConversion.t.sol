// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardFunding } from "../../src/programs/CardFunding.sol";
import { Conversion } from "../../src/programs/Conversion.sol";
import { ProgramCollateral } from "../../src/programs/ProgramCollateral.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice Collateral in an asset other than the token the program settles in: dollar Earn shares backing a program
///         that settles in euros are valued at what they sell for through the program's conversion venue, lock enough
///         shares to cover the exposure in euros, and are sold for euros when seized.
contract ProgramCollateralConversionTest is ProgramsEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    uint8 internal constant CASH = 1;
    uint8 internal constant TOKEN = 64;
    // EUR at $1.10 with a 30 bps conversion cost each way.
    uint256 internal constant BID = 1.0967e18;
    uint256 internal constant ASK = 1_103_310_000_000_000_000;

    ITIP20Token internal eur;
    Conversion internal conv;
    ProgramCollateral internal collateral;
    address internal sponsor = makeAddr("sponsor");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(5000e6, 10_000e6, 50_000e6));
        eur = _createToken("Euro", "EURX");
        conv = new Conversion(address(usd), address(this));
        FixedPricePool bid = new FixedPricePool(address(eur), address(usd), BID);
        FixedPricePool ask = new FixedPricePool(address(eur), address(usd), ASK);
        usd.mint(address(bid), 1_000_000e6);
        eur.mint(address(ask), 1_000_000e6);
        conv.setVenue(address(eur), address(usd), address(bid), true);
        conv.setVenue(address(usd), address(eur), address(ask), false);
        conv.setReferenceRate(address(eur), 1.1e18);
        collateral = new ProgramCollateral();
        vm.startPrank(issuer);
        cards.setConversion(address(conv));
        cards.setCollateral(address(collateral));
        cards.setSettlementToken(address(eur));
        vm.stopPrank();
        vm.prank(alice);
        core.approveHolder(address(cards), address(eur), type(uint128).max);
        CardFunding.Source[] memory order = new CardFunding.Source[](2);
        order[0] = CardFunding.Source({ kind: TOKEN, source: address(eur), lineId: 100 });
        order[1] = CardFunding.Source({ kind: CASH, source: address(usd), lineId: 0 });
        vm.prank(alice);
        cards.setFunding(address(usd), order);
        eur.mint(alice, 1000e6);
    }

    function test_dollarShares_valuedInEurosThroughTheVenue() public {
        uint256 shares = _postShares(550e6);
        uint256 value = collateral.valueOf(address(cards));
        assertEq(value, conv.quoteIn(address(usd), address(eur), earnVault.previewRedeem(shares)));
        // $550 buys about EUR 498.5 after the conversion cost, not EUR 550 at par.
        assertApproxEqAbs(value, uint256(550e6) * 1e18 / ASK, 2);
    }

    function test_unitsFor_locksSharesThatCoverTheValueInEuros() public view {
        uint256 units = collateral.unitsFor(address(cards), IEarnVault(address(earnVault)), 100e6);
        assertGe(conv.quoteIn(address(usd), address(eur), earnVault.previewRedeem(units)), 100e6);
        assertEq(collateral.unitsFor(address(cards), IEarnVault(address(0)), 100e6), 100e6);
    }

    function test_exposure_boundedByTheEuroValue() public {
        _postShares(110e6);
        // About EUR 99.7 of collateral: a EUR 100 purchase is past it, EUR 90 is within it.
        vm.prank(issuer);
        vm.expectPartialRevert(CardFunding.OverExposure.selector);
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 7 days), 0);
        _authorize(P1, 90e6);
        vm.prank(sponsor);
        vm.expectPartialRevert(ProgramCollateral.BelowExposure.selector);
        collateral.release(address(cards), 10e6);
    }

    function test_seize_sellsTheSharesForEuros() public {
        _postShares(330e6);
        _authorize(P1, 100e6);
        uint256 before = collateral.valueOf(address(cards));
        vm.prank(sponsor);
        collateral.seize(address(cards), 100e6, sponsor);
        assertApproxEqAbs(eur.balanceOf(sponsor), 100e6, 2);
        assertLe(eur.balanceOf(sponsor), 100e6);
        assertEq(usd.balanceOf(sponsor), 0);
        assertEq(usd.balanceOf(address(collateral)), 0);
        assertEq(earnShare.balanceOf(address(collateral)), 0);
        assertApproxEqAbs(collateral.valueOf(address(cards)), before - 100e6, 2);
    }

    function test_post_refusedWithoutAVenue() public {
        vm.prank(issuer);
        cards.setConversion(address(0));
        uint256 shares = _deposit(100e6);
        bytes32 id = collateral.pledgeId(address(cards), 1);
        vm.prank(settlement);
        // forge-lint: disable-next-line(unsafe-typecast)
        core.pledge(address(collateral), address(earnShare), id, uint128(shares), uint64(block.timestamp + 365 days));
        vm.prank(settlement);
        vm.expectRevert(ProgramCollateral.NoConversion.selector);
        collateral.post(address(cards), sponsor, IEarnVault(address(earnVault)));
    }

    function _postShares(uint256 assets) internal returns (uint256 shares) {
        shares = _deposit(assets);
        (,,, uint32 count) = collateral.positionOf(address(cards));
        bytes32 id = collateral.pledgeId(address(cards), count + 1);
        vm.prank(settlement);
        // forge-lint: disable-next-line(unsafe-typecast)
        core.pledge(address(collateral), address(earnShare), id, uint128(shares), uint64(block.timestamp + 365 days));
        vm.prank(settlement);
        collateral.post(address(cards), sponsor, IEarnVault(address(earnVault)));
    }

    function _deposit(uint256 assets) internal returns (uint256) {
        usd.mint(settlement, assets);
        return _depositEarn(settlement, assets);
    }
}
