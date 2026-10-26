// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { Simple4626Vault } from "../../src/demo/Simple4626Vault.sol";
import { ERC4626Engine, IERC4626Vault } from "../../src/engines/ERC4626Engine.sol";
import { EarnVaultControls, EngineMigrationMode } from "../../src/interfaces/core/EarnVaultTypes.sol";
import { CoreMockToken, earnVaultTestNoFees } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

contract EarnVaultCapacityTest is Test {
    CoreMockToken asset;
    CoreMockToken earnShare;
    Simple4626Vault venue;
    ERC4626Engine engine;
    EarnVault earnVault;

    address user = address(0xA11CE);
    address receiver = address(0xB0B);

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        earnShare = new CoreMockToken("Earn", "EARN", 18);
        venue = new Simple4626Vault(address(asset), "Venue", "VENUE", 18);
        engine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        earnVault = EarnVaultTestDeployer.deploy(
            address(engine), address(earnShare), address(this), _controls(100 ether), earnVaultTestNoFees()
        );
        engine.initializeEarnVault(address(earnVault));

        asset.mint(user, 1_000 ether);
        vm.startPrank(user);
        asset.approve(address(earnVault), type(uint256).max);
        asset.approve(address(venue), type(uint256).max);
        earnShare.approve(address(earnVault), type(uint256).max);
        venue.approve(address(engine), type(uint256).max);
        vm.stopPrank();
    }

    function testAssetDepositsFillCapacityAndWithdrawalsReopenIt() public {
        assertEq(earnVault.maxManagedAssets(), 100 ether);
        assertEq(earnVault.remainingDepositCapacity(), 100 ether);

        vm.prank(user);
        earnVault.deposit(100 ether, user, 100 ether);
        assertEq(earnVault.remainingDepositCapacity(), 0);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EarnVault.MaxManagedAssetsExceeded.selector, 100 ether, 101 ether));
        earnVault.deposit(1 ether, user, 1);

        vm.prank(user);
        earnVault.redeem(40 ether, receiver, 40 ether);
        assertEq(earnVault.remainingDepositCapacity(), 40 ether);

        vm.prank(user);
        earnVault.deposit(40 ether, user, 40 ether);
        assertEq(earnVault.remainingDepositCapacity(), 0);
    }

    function testLoweringCapacityBelowManagedAssetsBlocksInflowsButNotExits() public {
        vm.prank(user);
        earnVault.deposit(80 ether, user, 80 ether);

        earnVault.setMaxManagedAssets(50 ether);
        assertEq(earnVault.remainingDepositCapacity(), 0);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EarnVault.MaxManagedAssetsExceeded.selector, 50 ether, 81 ether));
        earnVault.deposit(1 ether, user, 1);

        vm.prank(user);
        earnVault.redeem(40 ether, receiver, 40 ether);
        assertEq(earnVault.remainingDepositCapacity(), 10 ether);
    }

    function testContributionsConsumeManagedAssetCapacity() public {
        vm.startPrank(user);
        earnVault.deposit(80 ether, user, 80 ether);
        earnVault.contribute(20 ether);

        vm.expectRevert(abi.encodeWithSelector(EarnVault.MaxManagedAssetsExceeded.selector, 100 ether, 101 ether));
        earnVault.contribute(1 ether);
        vm.stopPrank();

        assertEq(earnVault.remainingDepositCapacity(), 0);
        assertEq(earnVault.engineShares(), 100 ether);
    }

    function testSurplusAbsorptionConsumesManagedAssetCapacity() public {
        vm.startPrank(user);
        earnVault.deposit(80 ether, user, 80 ether);
        venue.deposit(21 ether, user);
        assertTrue(venue.transfer(address(engine), 21 ether));
        vm.stopPrank();

        assertEq(earnVault.remainingDepositCapacity(), 20 ether);
        earnVault.absorbEngineShareSurplus(20 ether);
        assertEq(earnVault.remainingDepositCapacity(), 0);

        vm.expectRevert(abi.encodeWithSelector(EarnVault.MaxManagedAssetsExceeded.selector, 100 ether, 101 ether));
        earnVault.absorbEngineShareSurplus(1 ether);

        assertEq(earnVault.engineShares(), 100 ether);
        assertEq(earnVault.surplusEngineShares(), 1 ether);
    }

    function testInKindDepositsConsumeManagedAssetCapacity() public {
        vm.startPrank(user);
        venue.deposit(80 ether, user);
        earnVault.depositVenueShares(80 ether, user, 80 ether);
        assertEq(earnVault.remainingDepositCapacity(), 20 ether);

        venue.deposit(21 ether, user);
        vm.expectRevert(abi.encodeWithSelector(EarnVault.MaxManagedAssetsExceeded.selector, 100 ether, 101 ether));
        earnVault.depositVenueShares(21 ether, user, 1);
        vm.stopPrank();

        assertEq(venue.balanceOf(user), 21 ether);
        assertEq(earnVault.engineShares(), 80 ether);
    }

    function testPassiveYieldMayExceedCapacityWithoutBlockingExits() public {
        vm.prank(user);
        earnVault.deposit(100 ether, user, 100 ether);
        asset.mint(address(venue), 20 ether);

        assertEq(earnVault.remainingDepositCapacity(), 0);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EarnVault.MaxManagedAssetsExceeded.selector, 100 ether, 121 ether));
        earnVault.deposit(1 ether, user, 1);

        vm.prank(user);
        assertEq(earnVault.redeem(20 ether, receiver, 1), 24 ether);
        assertEq(asset.balanceOf(receiver), 24 ether);
        assertEq(earnVault.remainingDepositCapacity(), 4 ether);
    }

    function _controls(uint256 maxManagedAssets) private pure returns (EarnVaultControls memory) {
        return EarnVaultControls({
            emergencyGuardian: address(0),
            asyncJanitor: address(0),
            maxManagedAssets: maxManagedAssets,
            migrationMode: EngineMigrationMode.UserOnly
        });
    }
}
