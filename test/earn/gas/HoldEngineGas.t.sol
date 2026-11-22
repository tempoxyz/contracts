// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test, console2 } from "forge-std/Test.sol";
import { EarnVault } from "../../../src/earn/core/EarnVault.sol";
import { HoldEngine } from "../../../src/earn/engines/hold/HoldEngine.sol";
import { CoreMockToken, earnVaultTestNoFees } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

/// @notice Steady-state HoldEngine exits through its EarnVault.
contract HoldEngineGasTest is Test {
    CoreMockToken asset;
    CoreMockToken earnShare;
    HoldEngine engine;
    EarnVault earnVault;
    address user = address(0xA11CE);

    function setUp() public {
        asset = new CoreMockToken("USD", "USD", 6);
        earnShare = new CoreMockToken("Earn USD", "eUSD", 6);
        engine = new HoldEngine(address(asset), address(this), "Hold USD", "hUSD");
        earnVault =
            EarnVaultTestDeployer.deploy(address(engine), address(earnShare), address(this), earnVaultTestNoFees());
        engine.initializeEarnVault(address(earnVault));
        asset.mint(user, 1000e6);
        vm.startPrank(user);
        asset.approve(address(earnVault), type(uint256).max);
        earnShare.approve(address(earnVault), type(uint256).max);
        earnVault.deposit(500e6, user, 1);
        vm.stopPrank();
    }

    function testGasHoldSteadyRedeem() public {
        vm.prank(user);
        uint256 g = gasleft();
        earnVault.redeem(100e6, user, 1);
        console2.log("hold.redeem.steady", g - gasleft());
    }

    function testGasHoldSteadyWithdrawExact() public {
        vm.prank(user);
        uint256 g = gasleft();
        earnVault.withdrawExact(100e6, user, type(uint256).max);
        console2.log("hold.withdrawExact.steady", g - gasleft());
    }
}
