// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Optional contribution-orchestration coverage.
import { Test } from "forge-std/Test.sol";

import { EarnVault } from "../../src/core/EarnVault.sol";
import { ERC4626Engine, IERC4626Vault } from "../../src/engines/ERC4626Engine.sol";
import { Simple4626Vault } from "../../src/demo/Simple4626Vault.sol";
import { IContributionTarget, EarnContributionController } from "../../src/rewards/EarnContributionController.sol";
import { FeeConfig, FixedFeeRecipient } from "../../src/interfaces/core/EarnFeeTypes.sol";
import { IEarnFees } from "../../src/interfaces/core/IEarnFees.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";
import { FaultyMockToken, earnVaultTestNoFees } from "../helpers/EarnVaultMocks.sol";

contract EarnContributionControllerTest is Test {
    FaultyMockToken asset;
    FaultyMockToken share;
    Simple4626Vault underlying;
    ERC4626Engine engine;
    EarnVault earnVault;
    EarnContributionController rewards;

    address user = address(0xA11CE);
    address secondUser = address(0xB0B);
    address underlyingOnlyHolder = address(0xC0DE);
    address receiver = address(0xCAFE);
    address primaryFunder = address(0x1111);
    address secondaryFunder = address(0x2222);
    address stranger = address(0xDEAD);

    function setUp() public {
        asset = new FaultyMockToken("Asset", "AST", 18);
        share = new FaultyMockToken("Earn Share", "EARN", 18);
        underlying = new Simple4626Vault(address(asset), "Shared Underlying Vault", "sVAULT", 18);
        engine = new ERC4626Engine(IERC4626Vault(address(underlying)), address(this), "", "");
        earnVault = EarnVaultTestDeployer.deploy(address(engine), address(share), address(this), earnVaultTestNoFees());
        engine.initializeEarnVault(address(earnVault));
        rewards = new EarnContributionController(IContributionTarget(address(earnVault)), address(this));

        _depositUnderlyingOnly(underlyingOnlyHolder, 100 ether);
        _depositEarn(user, 100 ether);
        _fundAndApprove(primaryFunder, 100 ether, rewards);
        _fundAndApprove(secondaryFunder, 100 ether, rewards);
    }

    function testFalseReturningProviderTransferIsRecordedAsZero() public {
        asset.setFailTransferFrom(primaryFunder, true);

        assertEq(rewards.fund(primaryFunder, 1.5 ether, 100 ether), 0);
        assertEq(earnVault.engineShares(), 100 ether);
        assertEq(asset.balanceOf(address(rewards)), 0);
    }

    function testFundBatchExactRollsBackEveryLegWhenOneProviderFails() public {
        address[] memory funders = new address[](2);
        funders[0] = primaryFunder;
        funders[1] = secondaryFunder;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1.5 ether;
        amounts[1] = 2 ether;
        asset.setFailTransferFrom(secondaryFunder, true);
        uint256 primaryBalance = asset.balanceOf(primaryFunder);
        uint256 secondaryBalance = asset.balanceOf(secondaryFunder);

        vm.expectRevert(EarnContributionController.TokenCallFalse.selector);
        rewards.fundBatchExact(funders, amounts, 100 ether);

        assertEq(asset.balanceOf(primaryFunder), primaryBalance);
        assertEq(asset.balanceOf(secondaryFunder), secondaryBalance);
        assertEq(asset.balanceOf(address(rewards)), 0);
        assertEq(earnVault.engineShares(), 100 ether);
    }

    function testFundBatchExactChecksSupplyOnceBeforeFeeMintingBetweenLegs() public {
        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(address(0xFEE), 1_000);
        FaultyMockToken feeShare = new FaultyMockToken("Fee Earn Share", "FEARN", 18);
        ERC4626Engine feeEngine = new ERC4626Engine(IERC4626Vault(address(underlying)), address(this), "", "");
        EarnVault feeVault = EarnVaultTestDeployer.deploy(address(feeEngine), address(feeShare), address(this), config);
        feeEngine.initializeEarnVault(address(feeVault));
        EarnContributionController feeController =
            new EarnContributionController(IContributionTarget(address(feeVault)), address(this));

        asset.mint(secondUser, 100 ether);
        vm.startPrank(secondUser);
        asset.approve(address(feeVault), 100 ether);
        feeVault.deposit(100 ether, secondUser, 100 ether);
        vm.stopPrank();
        _fundAndApprove(primaryFunder, 2 ether, feeController);
        _fundAndApprove(secondaryFunder, 2 ether, feeController);

        address[] memory funders = new address[](2);
        funders[0] = primaryFunder;
        funders[1] = secondaryFunder;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;

        assertEq(feeController.fundBatchExact(funders, amounts, 100 ether), 2 ether);
        assertGt(feeVault.totalEarnShares(), 100 ether);
        assertEq(asset.balanceOf(address(feeController)), 0);
        assertTrue(feeVault.isAccountingAligned());
    }

    function testFundingSkipsWhenEarnShareSupplyExceedsOwnerMaximum() public {
        _depositEarn(secondUser, 1 ether);
        uint256 funderBefore = asset.balanceOf(primaryFunder);

        assertEq(rewards.fund(primaryFunder, 5 ether, 100 ether), 0);

        assertEq(asset.balanceOf(primaryFunder), funderBefore);
        assertEq(asset.balanceOf(address(rewards)), 0);
        assertEq(earnVault.totalEarnShares(), 101 ether);
        assertEq(earnVault.engineShares(), 101 ether);
    }

    function testFundingCapIncludesPendingFeeSharesBeforeProviderSpend() public {
        address feeRecipient = address(0xFEE);
        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(feeRecipient, 1_000);

        FaultyMockToken feeShare = new FaultyMockToken("Fee Earn Share", "FEARN", 18);
        ERC4626Engine feeEngine = new ERC4626Engine(IERC4626Vault(address(underlying)), address(this), "", "");
        EarnVault feeVault = EarnVaultTestDeployer.deploy(address(feeEngine), address(feeShare), address(this), config);
        feeEngine.initializeEarnVault(address(feeVault));
        EarnContributionController feeController =
            new EarnContributionController(IContributionTarget(address(feeVault)), address(this));

        asset.mint(user, 100 ether);
        vm.startPrank(user);
        asset.approve(address(feeVault), type(uint256).max);
        feeVault.deposit(100 ether, user, 100 ether);
        vm.stopPrank();

        asset.mint(address(underlying), 10 ether);
        IEarnFees fees = IEarnFees(feeVault.earnFees());
        uint256 pendingFeeShares = fees.previewAccruedFees().totalFeeEarnShares;
        assertGt(pendingFeeShares, 0);
        assertEq(feeVault.totalEarnShares(), 100 ether);

        _fundAndApprove(primaryFunder, 5 ether, feeController);
        uint256 funderBefore = asset.balanceOf(primaryFunder);
        assertEq(feeController.fund(primaryFunder, 5 ether, 100 ether), 0);

        assertEq(asset.balanceOf(primaryFunder), funderBefore);
        assertEq(asset.balanceOf(address(feeController)), 0);
        assertEq(feeVault.totalEarnShares(), 100 ether);
        assertEq(fees.claimableEarnShares(feeRecipient), 0);
        assertEq(fees.previewAccruedFees().totalFeeEarnShares, pendingFeeShares);

        uint256 feeInclusiveSupply = 100 ether + pendingFeeShares;
        assertEq(feeController.fund(primaryFunder, 5 ether, feeInclusiveSupply), 5 ether);
        assertGt(feeVault.totalEarnShares(), feeInclusiveSupply);
        assertGt(fees.claimableEarnShares(feeRecipient), pendingFeeShares);
        assertEq(asset.balanceOf(address(feeController)), 0);
        assertTrue(feeVault.isAccountingAligned());
    }

    function testZeroSupplyAndZeroMaximumLeaveProviderFundsUntouched() public {
        FaultyMockToken emptyShare = new FaultyMockToken("Empty Earn Share", "EMPTY", 18);
        Simple4626Vault emptyVault = new Simple4626Vault(address(asset), "Empty Vault", "emptyVAULT", 18);
        ERC4626Engine emptyEngine = new ERC4626Engine(IERC4626Vault(address(emptyVault)), address(this), "", "");
        EarnVault emptyEarnVault = EarnVaultTestDeployer.deploy(
            address(emptyEngine), address(emptyShare), address(this), earnVaultTestNoFees()
        );
        emptyEngine.initializeEarnVault(address(emptyEarnVault));
        EarnContributionController emptyRewards =
            new EarnContributionController(IContributionTarget(address(emptyEarnVault)), address(this));
        _fundAndApprove(stranger, 5 ether, emptyRewards);
        uint256 before = asset.balanceOf(stranger);

        assertEq(emptyRewards.fund(stranger, 5 ether, 0), 0);
        assertEq(asset.balanceOf(stranger), before);
        assertEq(emptyEarnVault.engineShares(), 0);

        vm.startPrank(stranger);
        asset.approve(address(emptyEarnVault), 5 ether);
        vm.expectRevert(EarnVault.NoEarnShares.selector);
        emptyEarnVault.contribute(5 ether);
        vm.stopPrank();

        asset.mint(secondUser, 1 ether);
        vm.startPrank(secondUser);
        asset.approve(address(emptyEarnVault), 1 ether);
        emptyEarnVault.deposit(1 ether, secondUser, 1 ether);
        vm.stopPrank();

        assertEq(emptyRewards.fund(stranger, 5 ether, 0), 0);
        assertEq(asset.balanceOf(stranger), before);
        assertEq(emptyEarnVault.totalEarnShares(), 1 ether);
        assertEq(emptyEarnVault.engineShares(), 1 ether);
    }

    function testExecuteFundingCanOnlyBeCalledByController() public {
        vm.expectRevert(EarnContributionController.NotSelf.selector);
        rewards.executeFunding(primaryFunder, 1 ether, 100 ether);
    }

    function _depositUnderlyingOnly(address holder, uint256 amount) private {
        asset.mint(holder, amount);
        vm.startPrank(holder);
        asset.approve(address(underlying), amount);
        underlying.deposit(amount, holder);
        vm.stopPrank();
    }

    function _depositEarn(address holder, uint256 amount) private {
        asset.mint(holder, amount);
        vm.startPrank(holder);
        asset.approve(address(earnVault), type(uint256).max);
        share.approve(address(earnVault), type(uint256).max);
        earnVault.deposit(amount, holder, 1);
        vm.stopPrank();
    }

    function _fundAndApprove(address funder, uint256 amount, EarnContributionController controller) private {
        asset.mint(funder, amount);
        vm.prank(funder);
        asset.approve(address(controller), amount);
    }
}
