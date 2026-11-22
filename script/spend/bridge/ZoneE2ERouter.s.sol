// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";

import { IEarnVault } from "../../../src/interfaces/earn/IEarnVault.sol";
import { IPropAMMVenue } from "../../../src/interfaces/external/propamm/IPropAMMVenue.sol";
import { ZoneRouter } from "../../../src/zone/ZoneRouter.sol";
import { ZoneRouterFactory } from "../../../src/zone/ZoneRouterFactory.sol";
import { SendSpender } from "../../../src/zone/spenders/SendSpender.sol";

/// @notice Deploys, for the Zone E2E (`e2e/spend/bridge`), a `SendSpender` converting through the Earn stack's par pool and a
///         `ZoneRouter` with every op: Earn deposit and redeem of the private asset through that pool, and Spend
///         through the card program's `CardSpender` and the `SendSpender`. The pool owner must still admit
///         both as taker and recipient. The program and the `SendSpender` take `spendFrom` only from
///         ROUTER_FACTORY's routers, so it must be the factory the program was deployed for.
///         Reads DEPLOYER_PK, ROUTER_FACTORY, BRIDGE_PROGRAM, ZONE_ID, EARN_VAULT, PRIVATE_ASSET, POOL,
///         CUSTOMER_ID, SEND_CUSTOMER_ID and OUT from the env.
contract ZoneE2ERouter is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address vault = vm.envAddress("EARN_VAULT");
        address pool = vm.envAddress("POOL");

        vm.startBroadcast(deployerPk);
        address routerFactory = vm.envAddress("ROUTER_FACTORY");
        SendSpender sender =
            new SendSpender(routerFactory, IEarnVault(vault), IPropAMMVenue(pool), vm.envBytes32("SEND_CUSTOMER_ID"));

        ZoneRouter.Mode memory mode;
        mode.zoneId = uint32(vm.envUint("ZONE_ID"));
        mode.enabledOps = uint8((1 << 0) | (1 << 1) | (1 << 2));
        mode.earnVault = vault;
        mode.privateAsset = vm.envAddress("PRIVATE_ASSET");
        mode.pool = pool;
        mode.customerId = vm.envBytes32("CUSTOMER_ID");
        mode.spenders = new address[](2);
        mode.spenders[0] = vm.envAddress("BRIDGE_PROGRAM");
        mode.spenders[1] = address(sender);
        address router = ZoneRouterFactory(routerFactory).deploy(mode);
        vm.stopBroadcast();

        string memory key = "zone-e2e-router";
        vm.serializeAddress(key, "sendSpender", address(sender));
        string memory json = vm.serializeAddress(key, "router", router);
        vm.writeJson(json, vm.envString("OUT"));
    }
}
