// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

import { IZoneFactory, ZONE_FACTORY_ADDRESS, ZoneInfo } from "tempo-zones/interfaces/IZone.sol";
import { ZoneRouter } from "zone-router/ZoneRouter.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";

import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { BridgeRelease } from "./BridgeRelease.sol";
import { ProgramChecks } from "./ProgramChecks.sol";
import { BridgeSettler } from "zone-router/settlers/BridgeSettler.sol";

/// @notice A card program's router mode: Spend only on `zoneId`, through `settler` alone, with no Earn
///         bindings.
library SpendMode {
    function forSettler(uint32 zoneId, address settler) internal pure returns (ZoneRouter.Mode memory mode) {
        mode.zoneId = zoneId;
        mode.enabledOps = uint8(1 << 2);
        mode.settlers = new address[](1);
        mode.settlers[0] = settler;
    }
}

/// @notice Deploys one card program's `BridgeSettler` and the Spend-mode `ZoneRouter` that may use
///         it on one Zone, through a `ZoneRouterFactory`, after checking the program's clone was
///         created for its ID and the Zone has a registered portal. The settler lands at its
///         deterministic address (`BridgeRelease`), and one already there is reused; so is a router
///         the factory already deployed for this mode. Neither contract has an owner, so nothing else is configured here. A Zone with a closed
///         callback gateway must still grant the router the gateway role, and one that enforces
///         access must admit the program's refund recipient and the program wallet that deposits
///         refunds.
///         `run` reads FACTORY (the Bridge spender factory), SPENDER_ID, ZONE_ID, OUT,
///         ROUTER_FACTORY (optional: a new ZoneRouterFactory is deployed without it) and
///         DEPLOYER_PK unless the signer comes from `--account` or `--ledger`. OUT is written only
///         with `--broadcast`.
contract DeployZoneRouter is BridgeRelease {
    struct Output {
        address factory;
        bytes32 spenderId;
        address clone;
        uint32 zoneId;
        address portal;
        BridgeSettler settler;
        ZoneRouterFactory routerFactory;
        ZoneRouter router;
    }

    function run() external returns (ZoneRouter) {
        Output memory o = deploy(
            IBridgeSpenderFactory(vm.envAddress("FACTORY")),
            vm.envBytes32("SPENDER_ID"),
            ProgramChecks.zoneId(vm.envUint("ZONE_ID")),
            ZoneRouterFactory(vm.envOr("ROUTER_FACTORY", address(0))),
            vm.envOr("DEPLOYER_PK", uint256(0))
        );
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            write(o, vm.envString("OUT"));
        } else {
            console.log("dry run: OUT is written only with --broadcast");
        }
        return o.router;
    }

    /// @param routerFactory The ZoneRouterFactory to deploy through, or zero to deploy one.
    /// @param deployerPk The deployer's key, or zero to sign with forge's `--account` or `--ledger`.
    function deploy(
        IBridgeSpenderFactory factory,
        bytes32 spenderId,
        uint32 zoneId,
        ZoneRouterFactory routerFactory,
        uint256 deployerPk
    ) public returns (Output memory o) {
        o.clone = factory.getSpenderAddress(spenderId);
        require(
            ProgramChecks.isCanonical(address(factory), spenderId, o.clone),
            "SPENDER_ID was added to an existing clone, which TS rejects"
        );
        ZoneInfo memory zone = IZoneFactory(ZONE_FACTORY_ADDRESS).zones(zoneId);
        require(
            zone.portal != address(0) && IZoneFactory(ZONE_FACTORY_ADDRESS).isZonePortal(zone.portal),
            "ZONE_ID has no portal"
        );
        require(
            address(routerFactory) == address(0) || address(routerFactory).code.length != 0,
            "ROUTER_FACTORY has no code"
        );
        if (deployerPk == 0) vm.startBroadcast();
        else vm.startBroadcast(deployerPk);
        if (address(routerFactory) == address(0)) routerFactory = new ZoneRouterFactory();
        (o.settler,) = _bridgeSettler(factory, spenderId);
        o.router = ZoneRouter(routerFactory.deploy(SpendMode.forSettler(zoneId, address(o.settler))));
        vm.stopBroadcast();
        o.factory = address(factory);
        o.spenderId = spenderId;
        o.zoneId = zoneId;
        o.portal = zone.portal;
        o.routerFactory = routerFactory;
    }

    function write(Output memory o, string memory path) public {
        string memory key = "zone-router";
        vm.serializeAddress(key, "factory", o.factory);
        vm.serializeBytes32(key, "spenderId", o.spenderId);
        vm.serializeAddress(key, "clone", o.clone);
        vm.serializeUint(key, "zoneId", o.zoneId);
        vm.serializeAddress(key, "portal", o.portal);
        vm.serializeAddress(key, "settler", address(o.settler));
        vm.serializeAddress(key, "routerFactory", address(o.routerFactory));
        vm.writeJson(vm.serializeAddress(key, "router", address(o.router)), path);
    }
}
