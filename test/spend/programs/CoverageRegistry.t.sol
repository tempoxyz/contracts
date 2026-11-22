// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CoverageRegistry } from "../../../src/spend/programs/CoverageRegistry.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

contract CoverageRegistryTest is AuthEnv {
    CoverageRegistry internal registry;
    address internal registrar = makeAddr("registrar");
    address[] internal vaults;

    function setUp() public {
        _deployPrograms();
        registry = new CoverageRegistry(registrar);
        vaults.push(address(earnVault));
        usd.mint(alice, 300e6);
        vm.startPrank(alice);
        usd.approve(address(earnVault), type(uint256).max);
        earnVault.deposit(100e6, alice, 1);
        vm.stopPrank();
    }

    function test_onlyRegistrarSetsCoverage() public {
        vm.prank(bob);
        vm.expectRevert(CoverageRegistry.NotRegistrar.selector);
        registry.setCoverage(address(usd), "FDIC", 250e6);
        vm.prank(registrar);
        vm.expectRevert(CoverageRegistry.ZeroAddress.selector);
        registry.setCoverage(address(0), "FDIC", 250e6);
    }

    function test_uninsuredByDefault() public view {
        CoverageRegistry.Position[] memory p = registry.disclose(alice, address(usd), vaults);
        assertEq(p.length, 2);
        assertEq(p[0].value, 200e6);
        assertEq(p[0].insured, 0);
        assertEq(bytes(p[0].scheme).length, 0);
        assertApproxEqAbs(p[1].value, 100e6, 1);
        assertEq(p[1].insured, 0);
    }

    function test_schemeCapCountsOncePerAccountAcrossAssets() public {
        vm.startPrank(registrar);
        registry.setCoverage(address(usd), "FDIC", 250e6);
        registry.setCoverage(address(earnVault), "FDIC", 250e6);
        vm.stopPrank();
        CoverageRegistry.Position[] memory p = registry.disclose(alice, address(usd), vaults);
        assertEq(p[0].insured, 200e6);
        assertApproxEqAbs(p[1].insured, 50e6, 1);
        assertEq(p[1].scheme, "FDIC");
    }

    function test_separateSchemesHaveSeparateCaps() public {
        vm.startPrank(registrar);
        registry.setCoverage(address(usd), "FDIC", 150e6);
        registry.setCoverage(address(earnVault), "SIPC", 500e6);
        vm.stopPrank();
        CoverageRegistry.Position[] memory p = registry.disclose(alice, address(usd), vaults);
        assertEq(p[0].insured, 150e6);
        assertApproxEqAbs(p[1].insured, 100e6, 1);
    }

    function test_emptySchemeClearsCoverage() public {
        vm.startPrank(registrar);
        registry.setCoverage(address(usd), "FDIC", 250e6);
        registry.setCoverage(address(usd), "", 250e6);
        vm.stopPrank();
        assertEq(registry.coverageOf(address(usd)).cap, 0);
        assertEq(registry.disclose(alice, address(usd), vaults)[0].insured, 0);
    }

    function test_heldFundsStillCount() public {
        vm.prank(registrar);
        registry.setCoverage(address(usd), "FDIC", type(uint128).max);
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        _authorize(bytes32("p"), 50e6);
        // A hold is still the account's money until it captures.
        CoverageRegistry.Position[] memory p = registry.disclose(alice, address(usd), vaults);
        assertEq(p[0].units, 200e6);
        assertEq(p[0].insured, 200e6);
    }
}
