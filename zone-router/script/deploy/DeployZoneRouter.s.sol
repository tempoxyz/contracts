// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script, console2 } from "forge-std/Script.sol";

import { ZoneRouter } from "../../src/ZoneRouter.sol";
import { ZoneRouterFactory } from "../../src/ZoneRouterFactory.sol";

/// @notice The profile lifecycle's `deploy-zone-router` step: the factory's router for one mode. The
///         factory returns an existing router for the mode instead of deploying it again.
contract DeployZoneRouterScript is Script {
    /// @notice The deployment step's typed input.
    struct Input {
        uint256 expectedChainId;
        ZoneRouterFactory factory;
        ZoneRouter.Mode mode;
        string outputPath;
    }

    error BindingFailed();
    error NoFactory(address factory);
    error NotFactoryRouter(address router);
    error UnexpectedChain(uint256 actual, uint256 expected);

    function run(Input calldata input) external returns (ZoneRouter router) {
        if (block.chainid != input.expectedChainId) revert UnexpectedChain(block.chainid, input.expectedChainId);
        if (address(input.factory).code.length == 0) revert NoFactory(address(input.factory));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        router = ZoneRouter(input.factory.deploy(input.mode));
        vm.stopBroadcast();

        if (address(router) != input.factory.predict(input.mode) || !input.factory.isRouter(address(router))) {
            revert NotFactoryRouter(address(router));
        }
        _verifyMode(router, input.mode);
        vm.writeJson(
            vm.serializeAddress("deployment", "zoneRouter", address(router)), input.outputPath, ".latestOutputs"
        );
        console2.log("ZONE_ROUTER_ADDRESS", address(router));
    }

    function _verifyMode(ZoneRouter router, ZoneRouter.Mode calldata mode) internal view {
        if (
            router.allowedZoneId() != mode.zoneId || router.enabledOps() != mode.enabledOps
                || router.earnVault() != mode.earnVault || router.privateAsset() != mode.privateAsset
                || address(router.pool()) != mode.pool || router.customerId() != mode.customerId
                || keccak256(abi.encode(router.settlers())) != keccak256(abi.encode(mode.settlers))
        ) revert BindingFailed();
    }
}
