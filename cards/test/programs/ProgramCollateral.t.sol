// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CardFunding } from "../../src/programs/CardFunding.sol";
import { ProgramCollateral } from "../../src/programs/ProgramCollateral.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice A program's collateral: pledged by its settlement account to its sponsor, valued on chain, released and
///         seized only through ProgramCollateral and only within the program's live exposure.
contract ProgramCollateralTest is ProgramsEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    ProgramCollateral internal collateral;
    address internal sponsor = makeAddr("sponsor");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(5000e6, 10_000e6, 50_000e6));
        collateral = new ProgramCollateral();
        vm.prank(issuer);
        cards.setCollateral(address(collateral));
    }

    function test_cash_postedValueBoundsExposure() public {
        _postCash(150e6);
        assertEq(collateral.valueOf(address(cards)), 150e6);
        assertEq(core.reserved(settlement, address(usd)), 150e6);
        usd.mint(alice, 500e6);
        _authorize(P1, 100e6);
        (,,, uint256 value, uint256 total) = cards.exposure();
        assertEq(value, 150e6);
        assertEq(total, 100e6);
        vm.prank(issuer);
        vm.expectPartialRevert(CardFunding.OverExposure.selector);
        cards.authorize(CARD, bytes32("purchase-2"), 60e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_shares_earnAndValueFollowsThePrice() public {
        uint256 shares = _postShares(500e6);
        assertEq(core.reserved(settlement, address(earnShare)), shares);
        assertApproxEqAbs(collateral.valueOf(address(cards)), 500e6, 1);
        // Yield in the venue raises what the pledged shares are worth.
        usd.mint(address(venue), usd.balanceOf(address(venue)) / 4);
        assertGt(collateral.valueOf(address(cards)), 600e6);
    }

    function test_release_onlySponsor_andNeverBelowExposure() public {
        _postCash(150e6);
        usd.mint(alice, 500e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(ProgramCollateral.NotSponsor.selector);
        collateral.release(address(cards), 10e6);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(ProgramCollateral.BelowExposure.selector, uint256(90e6), uint256(100e6)));
        collateral.release(address(cards), 60e6);
        vm.prank(sponsor);
        collateral.release(address(cards), 50e6);
        assertEq(collateral.valueOf(address(cards)), 100e6);
        assertEq(core.reserved(settlement, address(usd)), 100e6);
    }

    function test_seize_cappedAtExposure_andPaysOnlyWhereTheSponsorSays() public {
        _postCash(150e6);
        usd.mint(alice, 500e6);
        _authorize(P1, 100e6);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(ProgramCollateral.AboveExposure.selector, uint256(101e6), uint256(100e6)));
        collateral.seize(address(cards), 101e6, sponsor);
        vm.prank(issuer);
        vm.expectRevert(ProgramCollateral.NotSponsor.selector);
        collateral.seize(address(cards), 10e6, issuer);
        vm.prank(sponsor);
        collateral.seize(address(cards), 100e6, sponsor);
        assertEq(usd.balanceOf(sponsor), 100e6);
        assertEq(collateral.valueOf(address(cards)), 50e6);
    }

    function test_nothingToSeize_withoutExposure() public {
        _postCash(150e6);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(ProgramCollateral.AboveExposure.selector, uint256(1), uint256(0)));
        collateral.seize(address(cards), 1, sponsor);
    }

    function test_post_onlySettlementAccount_withAMatchingPledge() public {
        vm.expectRevert(ProgramCollateral.NotSettlementAccount.selector);
        collateral.post(address(cards), sponsor, IEarnVault(address(0)));
        vm.prank(settlement);
        vm.expectPartialRevert(ProgramCollateral.PledgeMissing.selector);
        collateral.post(address(cards), sponsor, IEarnVault(address(0)));
    }

    function test_post_keepsOneAssetAndSponsor() public {
        _postCash(10e6);
        uint256 shares = _deposit(100e6);
        bytes32 id = collateral.pledgeId(address(cards), 2);
        vm.startPrank(settlement);
        // forge-lint: disable-next-line(unsafe-typecast)
        core.pledge(address(collateral), address(earnShare), id, uint128(shares), uint64(block.timestamp + 365 days));
        vm.expectRevert(ProgramCollateral.WrongAsset.selector);
        collateral.post(address(cards), sponsor, IEarnVault(address(earnVault)));
        vm.stopPrank();
        id = collateral.pledgeId(address(cards), 2);
        usd.mint(settlement, 10e6);
        vm.startPrank(settlement);
        core.pledge(address(collateral), address(usd), keccak256("other"), 10e6, uint64(block.timestamp + 365 days));
        vm.expectRevert(ProgramCollateral.WrongSponsor.selector);
        collateral.post(address(cards), issuer, IEarnVault(address(0)));
        vm.stopPrank();
    }

    function _postCash(uint128 amount) internal {
        usd.mint(settlement, amount);
        bytes32 id = collateral.pledgeId(address(cards), _count() + 1);
        vm.startPrank(settlement);
        core.pledge(address(collateral), address(usd), id, amount, uint64(block.timestamp + 365 days));
        collateral.post(address(cards), sponsor, IEarnVault(address(0)));
        vm.stopPrank();
    }

    function _postShares(uint256 assets) internal returns (uint256 shares) {
        shares = _deposit(assets);
        bytes32 id = collateral.pledgeId(address(cards), _count() + 1);
        vm.startPrank(settlement);
        // forge-lint: disable-next-line(unsafe-typecast)
        core.pledge(address(collateral), address(earnShare), id, uint128(shares), uint64(block.timestamp + 365 days));
        collateral.post(address(cards), sponsor, IEarnVault(address(earnVault)));
        vm.stopPrank();
    }

    function _deposit(uint256 assets) internal returns (uint256) {
        usd.mint(settlement, assets);
        return _depositEarn(settlement, assets);
    }

    function _count() internal view returns (uint256) {
        (,,, uint32 count) = collateral.positionOf(address(cards));
        return count;
    }
}

