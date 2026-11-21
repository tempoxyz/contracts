// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test, console2 } from "forge-std/Test.sol";
import { EarnVault } from "../../../src/earn/core/EarnVault.sol";
import { PropAMMEngine } from "../../../src/earn/engines/propamm/PropAMMEngine.sol";
import { CoreMockToken, earnVaultTestNoFees } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";
import { PropAMMTestToken, PropAMMTestOracle, PropAMMTestVenue } from "../helpers/PropAMMEngineMocks.sol";

contract PropAMMEngineGasTest is Test {
    PropAMMTestToken usdc;
    PropAMMTestToken baseToken;
    PropAMMTestOracle oracle;
    PropAMMTestVenue pool;
    PropAMMEngine engine;
    EarnVault earnVault;
    CoreMockToken earnShare;
    address user = address(0xA11CE);

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new PropAMMTestToken("USDC.e");
        baseToken = new PropAMMTestToken("BASE");
        oracle = new PropAMMTestOracle();
        pool = new PropAMMTestVenue(baseToken, usdc, oracle);
        engine = new PropAMMEngine(address(pool), address(this), 1 days, bytes32(uint256(1)));
        earnShare = new CoreMockToken("Earn Share", "EARN", 6);
        earnVault =
            EarnVaultTestDeployer.deploy(address(engine), address(earnShare), address(this), earnVaultTestNoFees());
        engine.initializeEarnVault(address(earnVault));
        baseToken.mint(address(pool), 10000e6);
        usdc.mint(address(pool), 10000e6);
        usdc.mint(user, 1000e6);
        vm.prank(user);
        usdc.approve(address(earnVault), type(uint256).max);
        vm.prank(user);
        earnVault.deposit(105e6, user, 1);
    }

    function testGasPropAMMSteadyDeposit() public {
        vm.prank(user);
        uint256 g = gasleft();
        earnVault.deposit(105e6, user, 1);
        console2.log("propamm.deposit.steady", g - gasleft());
    }
}
