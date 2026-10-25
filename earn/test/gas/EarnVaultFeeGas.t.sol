// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test, console2 } from "forge-std/Test.sol";

import { EarnVault } from "../../src/core/EarnVault.sol";
import { Simple4626Vault } from "../../src/demo/Simple4626Vault.sol";
import { ERC4626Engine, IERC4626Vault } from "../../src/engines/ERC4626Engine.sol";
import { ExcessReturnFee, FeeConfig, FixedFeeRecipient } from "../../src/interfaces/core/EarnFeeTypes.sol";
import { IEarnFees } from "../../src/interfaces/core/IEarnFees.sol";
import { CoreMockToken } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

contract EarnVaultFeeGasAudit is Test {
    uint256 private constant INITIAL_DEPOSIT = 100 ether;
    uint256 private constant ACTION_AMOUNT = 10 ether;

    CoreMockToken private asset;
    CoreMockToken private earnShare;
    Simple4626Vault private venue;
    ERC4626Engine private engine;
    EarnVault private earnVault;
    IEarnFees private fees;

    address private user = address(0xA11CE);
    address private receiver = address(0xB0B);
    address private feeRecipient = address(0xFEE);

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        earnShare = new CoreMockToken("Earn Share", "EARN", 18);
        venue = new Simple4626Vault(address(asset), "Venue", "V", 18);
        engine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");

        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(feeRecipient, 250);
        config.excess = ExcessReturnFee(true, feeRecipient, 300, 5_000);
        earnVault = EarnVaultTestDeployer.deploy(address(engine), address(earnShare), address(this), config);
        fees = IEarnFees(earnVault.earnFees());
        engine.initializeEarnVault(address(earnVault));

        asset.mint(user, 1_000 ether);
        vm.startPrank(user);
        asset.approve(address(earnVault), type(uint256).max);
        earnShare.approve(address(earnVault), type(uint256).max);
        earnVault.deposit(INITIAL_DEPOSIT, user, 1);
        vm.stopPrank();
    }

    function testGasDepositWithoutNewYield() public {
        vm.pauseGasMetering();
        vm.prank(user);
        uint256 gasBefore = _startMeasure();
        earnVault.deposit(ACTION_AMOUNT, user, 1);
        _stopMeasure("fees.deposit.no-yield", gasBefore);
    }

    function testGasRedeemWithoutNewYield() public {
        vm.pauseGasMetering();
        vm.prank(user);
        uint256 gasBefore = _startMeasure();
        earnVault.redeem(ACTION_AMOUNT, receiver, 1);
        _stopMeasure("fees.redeem.no-yield", gasBefore);
    }

    function testGasDepositWithFeesDisabled() public {
        vm.pauseGasMetering();
        earnVault.disableFees();
        vm.prank(user);
        uint256 gasBefore = _startMeasure();
        earnVault.deposit(ACTION_AMOUNT, user, 1);
        _stopMeasure("fees.deposit.disabled", gasBefore);
    }

    function testGasRedeemWithFeesDisabled() public {
        vm.pauseGasMetering();
        earnVault.disableFees();
        vm.prank(user);
        uint256 gasBefore = _startMeasure();
        earnVault.redeem(ACTION_AMOUNT, receiver, 1);
        _stopMeasure("fees.redeem.disabled", gasBefore);
    }

    function testGasDepositWithPendingYield() public {
        vm.pauseGasMetering();
        asset.mint(address(venue), 20 ether);
        vm.warp(block.timestamp + 30 days);
        vm.prank(user);
        uint256 gasBefore = _startMeasure();
        earnVault.deposit(ACTION_AMOUNT, user, 1);
        _stopMeasure("fees.deposit.pending-yield", gasBefore);
    }

    function testGasRedeemWithPendingYield() public {
        vm.pauseGasMetering();
        asset.mint(address(venue), 20 ether);
        vm.warp(block.timestamp + 30 days);
        vm.prank(user);
        uint256 gasBefore = _startMeasure();
        earnVault.redeem(ACTION_AMOUNT, receiver, 1);
        _stopMeasure("fees.redeem.pending-yield", gasBefore);
    }

    function _startMeasure() private returns (uint256 gasBefore) {
        vm.resumeGasMetering();
        gasBefore = gasleft();
    }

    function _stopMeasure(string memory label, uint256 gasBefore) private {
        uint256 rawGas = gasBefore - gasleft();
        vm.pauseGasMetering();
        console2.log(label, rawGas);
    }
}

/// @dev Models the six-decimal EarnShare denomination used by current deployments. With a
///      100-asset pool, a 5% annualized one-minute contribution is approximately nine raw asset
///      units and does not advance the integer value-per-EarnShare checkpoint. A 100-raw-unit
///      contribution advances it by one raw EarnShare unit.
contract EarnVaultContributionFeeGasAudit is Test {
    uint256 private constant INITIAL_DEPOSIT = 100e6;
    uint256 private constant ACTION_AMOUNT = 10e6;
    uint256 private constant SUB_TICK_CONTRIBUTION = 9;
    uint256 private constant CROSS_TICK_CONTRIBUTION = 100;

    CoreMockToken private asset;
    CoreMockToken private earnShare;
    Simple4626Vault private venue;
    ERC4626Engine private engine;
    EarnVault private earnVault;
    IEarnFees private fees;

    address private holder = address(0xA11CE);
    address private contributor = address(0xC0117);
    address private receiver = address(0xB0B);
    address private feeRecipient = address(0xFEE);

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 6);
        earnShare = new CoreMockToken("Earn Share", "EARN", 6);
        venue = new Simple4626Vault(address(asset), "Venue", "V", 18);
        engine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");

        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(feeRecipient, 250);
        config.excess = ExcessReturnFee(true, feeRecipient, 300, 5_000);
        earnVault = EarnVaultTestDeployer.deploy(address(engine), address(earnShare), address(this), config);
        fees = IEarnFees(earnVault.earnFees());
        engine.initializeEarnVault(address(earnVault));

        asset.mint(holder, 1_000e6);
        asset.mint(contributor, 1_000e6);

        vm.startPrank(holder);
        asset.approve(address(earnVault), type(uint256).max);
        earnShare.approve(address(earnVault), type(uint256).max);
        earnVault.deposit(INITIAL_DEPOSIT, holder, 1);
        vm.stopPrank();

        vm.prank(contributor);
        asset.approve(address(earnVault), type(uint256).max);
    }

    function testGasContributeBelowValuePerShareTick() public {
        vm.pauseGasMetering();
        uint256 highWaterMark = fees.highWaterMark();
        vm.prank(contributor);
        uint256 gasBefore = _startMeasure();
        earnVault.contribute(SUB_TICK_CONTRIBUTION);
        _stopMeasure("fees.contribute.sub-tick", gasBefore);

        assertEq(fees.highWaterMark(), highWaterMark);
        assertEq(fees.claimableEarnShares(feeRecipient), 0);
    }

    function testGasContributeCrossingValuePerShareTick() public {
        vm.pauseGasMetering();
        vm.prank(contributor);
        uint256 gasBefore = _startMeasure();
        earnVault.contribute(CROSS_TICK_CONTRIBUTION);
        _stopMeasure("fees.contribute.cross-tick", gasBefore);

        assertGt(fees.claimableEarnShares(feeRecipient), 0);
    }

    function testGasDepositAfterSubTickContribution() public {
        vm.pauseGasMetering();
        vm.prank(contributor);
        earnVault.contribute(SUB_TICK_CONTRIBUTION);

        vm.prank(holder);
        uint256 gasBefore = _startMeasure();
        earnVault.deposit(ACTION_AMOUNT, holder, 1);
        _stopMeasure("fees.deposit.after-sub-tick-contribution", gasBefore);
    }

    function testGasRedeemAfterSubTickContribution() public {
        vm.pauseGasMetering();
        vm.prank(contributor);
        earnVault.contribute(SUB_TICK_CONTRIBUTION);

        vm.prank(holder);
        uint256 gasBefore = _startMeasure();
        earnVault.redeem(ACTION_AMOUNT, receiver, 1);
        _stopMeasure("fees.redeem.after-sub-tick-contribution", gasBefore);
    }

    function _startMeasure() private returns (uint256 gasBefore) {
        vm.resumeGasMetering();
        gasBefore = gasleft();
    }

    function _stopMeasure(string memory label, uint256 gasBefore) private {
        uint256 rawGas = gasBefore - gasleft();
        vm.pauseGasMetering();
        console2.log(label, rawGas);
    }
}
