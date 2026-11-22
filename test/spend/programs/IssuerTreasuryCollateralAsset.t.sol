// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../../src/interfaces/earn/IEarnVault.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { IssuerTreasury } from "../../../src/spend/programs/IssuerTreasury.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @dev A vault that prices its own shares: any TIP-20 as the share, any price, and redeeming pays nothing.
contract SelfPricedVault {
    address public earnShare;
    address public asset;

    constructor(address share, address asset_) {
        (earnShare, asset) = (share, asset_);
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares * 1e18;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return (assets + 1e18 - 1) / 1e18;
    }

    function redeem(uint256, address, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice The collateral asset is one the sponsor accepts, and neither it nor the sponsor changes while the sponsor
///         is owed.
contract IssuerTreasuryCollateralAssetTest is AuthEnv {
    IssuerTreasury internal treasury;
    address internal sponsor = makeAddr("sponsor");
    SelfPricedVault internal vault;
    bytes32 internal constant P1 = bytes32("asset-1");
    bytes32 internal constant P2 = bytes32("asset-2");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 1000e6);
        treasury = new IssuerTreasury(cards);
        usd.mint(settlement, 200e6);
        vm.startPrank(settlement);
        core.pledge(
            address(treasury),
            address(usd),
            treasury.pledgeId(1),
            100e6,
            uint64(block.timestamp + treasury.COVER_TERM() + 3 days)
        );
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
        _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
        ITIP20Token share = _createToken("Share", "SHR");
        share.mint(settlement, 1e6);
        vault = new SelfPricedVault(address(share), address(usd));
        bytes32 id = treasury.pledgeId(2);
        vm.prank(settlement);
        core.pledge(address(treasury), address(share), id, 1e6, uint64(block.timestamp + 365 days));
    }

    function test_post_refusesAVaultTheSponsorHasNotAccepted() public {
        _authorize(P1, 80e6);
        _lapse();
        vm.prank(settlement);
        vm.expectRevert(IssuerTreasury.WrongAsset.selector);
        treasury.post(sponsor, IEarnVault(address(vault)), 2);
        // Nothing covers the 80 owed, so the guard refuses more.
        assertEq(treasury.valueOf(), 0);
        vm.prank(issuer);
        vm.expectPartialRevert(IssuerTreasury.ExposureAboveCollateral.selector);
        cards.authorize(CARD, P2, 400e6, merchant, uint64(block.timestamp + 7 days), 0);
    }

    function test_post_keepsTheAssetWhileTheSponsorIsOwed() public {
        _authorize(P1, 80e6);
        _lapse();
        vm.prank(sponsor);
        treasury.acceptCollateral(IEarnVault(address(vault)));
        vm.prank(settlement);
        vm.expectRevert(IssuerTreasury.WrongAsset.selector);
        treasury.post(sponsor, IEarnVault(address(vault)), 2);
        // A fresh pledge in the same asset posts as before.
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), treasury.pledgeId(3), 100e6, uint64(block.timestamp + 365 days));
        treasury.post(sponsor, IEarnVault(address(0)), 3);
        vm.stopPrank();
        assertEq(treasury.valueOf(), 100e6);
    }

    function test_post_keepsTheAssetWhileASeizureIsOutstanding() public {
        _authorize(P1, 80e6);
        vm.prank(sponsor);
        treasury.seize(80e6);
        vm.prank(issuer);
        cards.release(P1);
        assertEq(treasury.exposure(), 0);
        assertEq(treasury.seized(), 80e6);
        _lapse();
        vm.prank(sponsor);
        treasury.acceptCollateral(IEarnVault(address(vault)));
        vm.prank(settlement);
        vm.expectRevert(IssuerTreasury.WrongAsset.selector);
        treasury.post(sponsor, IEarnVault(address(vault)), 2);
    }

    function test_post_changesTheAssetOnceNothingIsOwedAndTheSponsorAccepts() public {
        _lapse();
        vm.prank(settlement);
        vm.expectRevert(IssuerTreasury.WrongAsset.selector);
        treasury.post(sponsor, IEarnVault(address(vault)), 2);
        vm.prank(sponsor);
        treasury.acceptCollateral(IEarnVault(address(vault)));
        assertEq(address(treasury.acceptedVault(sponsor)), address(vault));
        vm.prank(settlement);
        treasury.post(sponsor, IEarnVault(address(vault)), 2);
        (, address token, IEarnVault posted,) = treasury.collateral();
        assertEq(token, vault.earnShare());
        assertEq(address(posted), address(vault));
    }

    /// @dev Ends the settlement-token pledge: the sponsor had COVER_TERM to seize before it.
    function _lapse() internal {
        vm.warp(block.timestamp + treasury.COVER_TERM() + 3 days);
        assertEq(treasury.unitsOf(), 0);
    }
}
