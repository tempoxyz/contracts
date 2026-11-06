// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";

import { CardsE2EDeploy } from "../../../script/rain/CardsE2EDeploy.s.sol";
import { IRainController } from "../../../script/rain/RainStack.sol";

interface IRainCollateralAdmin {
    function isAdmin(address account) external view returns (bool);
}

/// @notice The Rain E2E report identifies the inputs and contracts of its own invocation.
contract CardsE2EDeployTest is Test {
    function test_reportBindsDeploymentInputs() public {
        _checkReport(false);
    }

    function test_reportBindsEarnDeploymentInputs() public {
        _checkReport(true);
    }

    function _checkReport(bool earn) private {
        CardsE2EDeploy.Inputs memory input;
        (input.deployer, input.deployerPk) = makeAddrAndKey("rain.e2e.deployer");
        input.rainAdmin = makeAddr("rain.e2e.admin");
        input.rainTreasury = makeAddr("rain.e2e.treasury");
        input.cardholder = makeAddr("rain.e2e.cardholder");
        input.partner = makeAddr("rain.e2e.partner");
        // Forge seeds both cases alike; include the case to keep their filesystem outputs separate.
        input.runId = string.concat(earn ? "earn-" : "stable-", vm.toString(vm.randomUint()));
        input.zoneId = 7;
        input.earn = earn;
        string memory directory = string.concat("reports/rain-script-identity-", input.runId);
        input.out = string.concat(directory, "/deployment.json");
        vm.createDir(directory, true);
        vm.chainId(1337);

        new CardsE2EDeployHarness().execute(input);

        string memory json = vm.readFile(input.out);
        vm.removeDir(directory, true);
        assertEq(vm.parseJsonString(json, ".runId"), input.runId);
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid);
        assertEq(vm.parseJsonUint(json, ".zoneId"), 7);
        assertEq(vm.parseJsonAddress(json, ".deployer"), input.deployer);
        assertEq(vm.parseJsonAddress(json, ".rainAdmin"), input.rainAdmin);
        assertEq(vm.parseJsonAddress(json, ".rainTreasury"), input.rainTreasury);
        assertEq(vm.parseJsonAddress(json, ".cardholder"), input.cardholder);
        assertEq(vm.parseJsonAddress(json, ".partner"), input.partner);
        assertEq(vm.parseJsonBool(json, ".earn"), earn);
        IRainController controller = IRainController(vm.parseJsonAddress(json, ".rainController"));
        assertEq(controller.controllerAdmin(), input.rainAdmin);
        assertEq(controller.treasury(), input.rainTreasury);
        assertTrue(IRainCollateralAdmin(vm.parseJsonAddress(json, ".cardholderCollateral")).isAdmin(input.cardholder));
        assertTrue(IRainCollateralAdmin(vm.parseJsonAddress(json, ".programCollateral")).isAdmin(input.partner));
        assertEq(vm.parseJsonUint(json, ".cardholderCollateralIndex"), 0);
        assertEq(vm.parseJsonUint(json, ".programCollateralIndex"), 1);
        if (earn) {
            assertNotEq(vm.parseJsonAddress(json, ".earnVault"), address(0));
            assertNotEq(vm.parseJsonAddress(json, ".earnShare"), address(0));
        } else {
            assertFalse(vm.keyExistsJson(json, ".earnVault"));
            assertFalse(vm.keyExistsJson(json, ".earnShare"));
        }
    }
}

/// @notice Exercises the script without process-wide environment changes between concurrent tests.
contract CardsE2EDeployHarness is CardsE2EDeploy {
    function execute(Inputs memory input) external {
        _run(input);
    }
}
