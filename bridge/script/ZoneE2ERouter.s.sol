// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IPropAMMVenue } from "tempo-earn/interfaces/external/propamm/IPropAMMVenue.sol";
import { ZoneRouter } from "zone-router/ZoneRouter.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";
import { SendSettler } from "zone-router/settlers/SendSettler.sol";

/// @notice Deploys, for the Zone E2E (`e2e/bridge`), a `SendSettler` converting through the Earn stack's par pool and a
///         `ZoneRouter` with every op: Earn deposit and redeem of the private asset through that pool, and Spend
///         through the card program's `BridgeSettler` and the `SendSettler`. The pool owner must still admit
///         both as taker and recipient.
///         Reads DEPLOYER_PK, ROUTER_FACTORY, BRIDGE_SETTLER, ZONE_ID, EARN_VAULT, PRIVATE_ASSET, POOL,
///         CUSTOMER_ID, SEND_CUSTOMER_ID and OUT from the env.
contract ZoneE2ERouter is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address vault = vm.envAddress("EARN_VAULT");
        address pool = vm.envAddress("POOL");

        vm.startBroadcast(deployerPk);
        SendSettler sender = new SendSettler(IEarnVault(vault), IPropAMMVenue(pool), vm.envBytes32("SEND_CUSTOMER_ID"));

        ZoneRouter.Mode memory mode;
        mode.zoneId = uint32(vm.envUint("ZONE_ID"));
        mode.enabledOps = uint8((1 << 0) | (1 << 1) | (1 << 2));
        mode.earnVault = vault;
        mode.privateAsset = vm.envAddress("PRIVATE_ASSET");
        mode.pool = pool;
        mode.customerId = vm.envBytes32("CUSTOMER_ID");
        mode.settlers = new address[](2);
        mode.settlers[0] = vm.envAddress("BRIDGE_SETTLER");
        mode.settlers[1] = address(sender);
        address router = ZoneRouterFactory(vm.envAddress("ROUTER_FACTORY")).deploy(mode);
        vm.stopBroadcast();

        string memory key = "zone-e2e-router";
        vm.serializeAddress(key, "sendSettler", address(sender));
        string memory json = vm.serializeAddress(key, "router", router);
        vm.writeJson(json, vm.envString("OUT"));
    }
}
