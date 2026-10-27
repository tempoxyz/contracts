// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script, console2 } from "forge-std/Script.sol";

import { ZoneRouterFactory } from "../../src/ZoneRouterFactory.sol";

/// @notice The profile lifecycle's `deploy-zone-router-factory` step: one ownerless ZoneRouterFactory.
contract DeployZoneRouterFactoryScript is Script {
    /// @notice The deployment step's typed input.
    struct Input {
        uint256 expectedChainId;
        string outputPath;
    }

    error UnexpectedChain(uint256 actual, uint256 expected);

    function run(Input calldata input) external returns (ZoneRouterFactory factory) {
        if (block.chainid != input.expectedChainId) revert UnexpectedChain(block.chainid, input.expectedChainId);
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        factory = new ZoneRouterFactory();
        vm.stopBroadcast();
        vm.writeJson(
            vm.serializeAddress("deployment", "zoneRouterFactory", address(factory)), input.outputPath, ".latestOutputs"
        );
        console2.log("ZONE_ROUTER_FACTORY_ADDRESS", address(factory));
    }
}
