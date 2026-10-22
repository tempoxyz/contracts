// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { EarnFees } from "../../../src/core/EarnFees.sol";
import { EarnVault } from "../../../src/core/EarnVault.sol";
import { Simple4626Vault } from "../../../src/demo/Simple4626Vault.sol";
import { ERC4626Engine, IERC4626Vault } from "../../../src/engines/ERC4626Engine.sol";
import {
    ExcessReturnFee,
    FeeConfig,
    FeePreview,
    FixedFeeRecipient
} from "../../../src/interfaces/core/EarnFeeTypes.sol";
import { CoreMockToken } from "../../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../../helpers/EarnVaultTestDeployer.sol";

/// @dev Drives only valid, complete user and venue transitions so custody can be checked at call boundaries.
contract ERC4626CompositionHandler is Test {
    CoreMockToken public immutable asset;
    CoreMockToken public immutable earnShare;
    Simple4626Vault public immutable venue;
    ERC4626Engine public immutable engine;
    EarnVault public immutable earnVault;
    EarnFees public immutable fees;

    address public immutable fixedRecipient;
    address public immutable excessRecipient;
    address public immutable actorOne = address(0xA11CE);
    address public immutable actorTwo = address(0xB0B);

    constructor(
        CoreMockToken asset_,
        CoreMockToken earnShare_,
        Simple4626Vault venue_,
        ERC4626Engine engine_,
        EarnVault earnVault_,
        address fixedRecipient_,
        address excessRecipient_
    ) {
        asset = asset_;
        earnShare = earnShare_;
        venue = venue_;
        engine = engine_;
        earnVault = earnVault_;
        fees = EarnFees(earnVault_.earnFees());
        fixedRecipient = fixedRecipient_;
        excessRecipient = excessRecipient_;

        _approveActor(address(this));
        _approveActor(actorOne);
        _approveActor(actorTwo);
    }

    function deposit(uint256 actorSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        assets = bound(assets, 1, 1e18);
        earnVault.accrueFees();

        uint256 venueShares = venue.convertToShares(assets);
        if (!_acceptableEntry(venueShares)) return;

        asset.mint(actor, assets);
        vm.prank(actor);
        earnVault.deposit(assets, actor, 1);
    }

    function depositVenueShares(uint256 actorSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        assets = bound(assets, 1, 1e18);
        earnVault.accrueFees();

        uint256 expectedVenueShares = venue.convertToShares(assets);
        if (!_acceptableEntry(expectedVenueShares)) return;

        asset.mint(actor, assets);
        vm.prank(actor);
        uint256 venueShares = venue.deposit(assets, actor);
        vm.prank(actor);
        earnVault.depositVenueShares(venueShares, actor, 1);
    }

    function donateYield(uint256 assets) external {
        if (venue.totalSupply() == 0) return;

        assets = bound(assets, 1, 1e18);
        asset.mint(address(this), assets);
        venue.donate(assets);
    }

    function accrueLoss(uint256 assets) external {
        uint256 venueAssets = asset.balanceOf(address(venue));
        if (venueAssets <= 1) return;

        assets = bound(assets, 1, venueAssets / 2);
        vm.prank(address(venue));
        asset.burn(assets);
    }

    function contribute(uint256 assets) external {
        if (earnShare.totalSupply() == 0) return;

        assets = bound(assets, 1, 1e18);
        earnVault.accrueFees();
        if (venue.convertToShares(assets) == 0) return;

        asset.mint(address(this), assets);
        earnVault.contribute(assets);
    }

    function redeem(uint256 actorSeed, uint256 earnShares) external {
        address actor = _actor(actorSeed);
        earnVault.accrueFees();
        uint256 balance = earnShare.balanceOf(actor);
        if (balance == 0) return;

        earnShares = bound(earnShares, 1, balance);
        if (earnVault.previewRedeem(earnShares) == 0) return;
        vm.prank(actor);
        earnVault.redeem(earnShares, actor, 1);
    }

    function withdrawExact(uint256 actorSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        earnVault.accrueFees();
        uint256 balance = earnShare.balanceOf(actor);
        if (balance == 0) return;

        uint256 maxAssets = earnVault.previewRedeem(balance);
        if (maxAssets <= 1) return;
        assets = bound(assets, 1, maxAssets - 1);

        uint256 requiredEarnShares = earnVault.previewWithdraw(assets);
        if (requiredEarnShares == 0 || requiredEarnShares > balance) return;
        vm.prank(actor);
        earnVault.withdrawExact(assets, actor, requiredEarnShares);
    }

    function checkpointFees() external {
        earnVault.accrueFees();
    }

    function advanceTime(uint256 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 1, 365 days));
    }

    function claimFees(uint256 recipientSeed, uint256 amount) external {
        address recipient = recipientSeed % 2 == 0 ? fixedRecipient : excessRecipient;
        uint256 claimable = fees.claimableEarnShares(recipient);
        if (claimable == 0) return;

        amount = bound(amount, 1, claimable);
        vm.prank(recipient);
        fees.claim(address(this), amount);
    }

    function _acceptableEntry(uint256 venueShares) private view returns (bool) {
        if (venueShares == 0) return false;
        uint256 earnShares = earnVault.convertEngineSharesToEarnShares(venueShares);
        if (earnShares == 0) return false;
        uint256 representedVenueShares = earnVault.convertToEngineShares(earnShares);
        return venueShares - representedVenueShares <= venueShares / 10_000;
    }

    function _actor(uint256 seed) private view returns (address) {
        return seed % 2 == 0 ? actorOne : actorTwo;
    }

    function _approveActor(address actor) private {
        vm.startPrank(actor);
        asset.approve(address(earnVault), type(uint256).max);
        asset.approve(address(venue), type(uint256).max);
        venue.approve(address(engine), type(uint256).max);
        earnShare.approve(address(earnVault), type(uint256).max);
        vm.stopPrank();
    }
}

/// @dev Composes the production EarnVault, EarnFees, and ERC4626Engine with a live ERC-4626 venue rate.
contract ERC4626CompositionInvariantTest is StdInvariant, Test {
    address private constant ADMINISTRATOR = address(0xAD);
    address private constant FIXED_RECIPIENT = address(0xF1);
    address private constant EXCESS_RECIPIENT = address(0xE1);

    CoreMockToken private asset;
    CoreMockToken private earnShare;
    Simple4626Vault private venue;
    ERC4626Engine private engine;
    EarnVault private earnVault;
    EarnFees private fees;
    ERC4626CompositionHandler private handler;

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 6);
        earnShare = new CoreMockToken("Earn Share", "EARN", 18);
        venue = new Simple4626Vault(address(asset), "ERC-4626 Venue", "vAST", 18);
        engine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        earnVault = EarnVaultTestDeployer.deploy(address(engine), address(earnShare), ADMINISTRATOR, _feeConfig());
        engine.initializeEarnVault(address(earnVault));
        fees = EarnFees(earnVault.earnFees());
        handler = new ERC4626CompositionHandler(
            asset, earnShare, venue, engine, earnVault, FIXED_RECIPIENT, EXCESS_RECIPIENT
        );

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = ERC4626CompositionHandler.deposit.selector;
        selectors[1] = ERC4626CompositionHandler.depositVenueShares.selector;
        selectors[2] = ERC4626CompositionHandler.donateYield.selector;
        selectors[3] = ERC4626CompositionHandler.accrueLoss.selector;
        selectors[4] = ERC4626CompositionHandler.contribute.selector;
        selectors[5] = ERC4626CompositionHandler.redeem.selector;
        selectors[6] = ERC4626CompositionHandler.withdrawExact.selector;
        selectors[7] = ERC4626CompositionHandler.checkpointFees.selector;
        selectors[8] = ERC4626CompositionHandler.advanceTime.selector;
        selectors[9] = ERC4626CompositionHandler.claimFees.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_projectedEarnSupplyRedeemsToActualVenueAssets() public view {
        FeePreview memory preview = fees.previewAccruedFees();
        uint256 projectedSupply = earnShare.totalSupply() + preview.totalFeeEarnShares;
        uint256 managedAssets = earnVault.totalAssets();

        if (projectedSupply == 0) {
            assertEq(managedAssets, 0);
        } else {
            assertEq(earnVault.previewRedeem(projectedSupply), managedAssets);
        }
    }

    function invariant_engineOwnsAllVenueShares() public view {
        uint256 engineVenueShares = venue.balanceOf(address(engine));
        assertEq(engineVenueShares, venue.totalSupply());
        assertEq(engine.totalShares(), engineVenueShares);
        assertEq(earnVault.rawEngineShares(), engineVenueShares);
        assertLe(earnVault.engineShares(), engineVenueShares);
        assertTrue(earnVault.isAccountingAligned());
    }

    function invariant_engineValueMatchesVenueCustody() public view {
        uint256 venueAssets = asset.balanceOf(address(venue));
        assertEq(engine.totalAssets(), venueAssets);
        assertEq(engine.previewRedeem(engine.totalShares()), venueAssets);
    }

    function invariant_feeCustodyEqualsRecordedClaims() public view {
        assertEq(earnShare.balanceOf(address(fees)), fees.totalClaimableEarnShares());
        assertLe(fees.totalClaimableEarnShares(), earnShare.totalSupply());
    }

    function invariant_intermediateContractsRetainNoTokensOrApprovals() public view {
        assertEq(asset.balanceOf(address(earnVault)), 0);
        assertEq(asset.balanceOf(address(engine)), 0);
        assertEq(venue.balanceOf(address(earnVault)), 0);
        assertEq(earnShare.balanceOf(address(earnVault)), 0);
        assertEq(asset.allowance(address(earnVault), address(engine)), 0);
        assertEq(asset.allowance(address(engine), address(venue)), 0);
    }

    function _feeConfig() private pure returns (FeeConfig memory config) {
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient({ account: FIXED_RECIPIENT, rateBps: 1_000 });
        config.excess = ExcessReturnFee({
            enabled: true, account: EXCESS_RECIPIENT, annualTargetRateBps: 500, excessFeeRateBps: 2_000
        });
    }
}
