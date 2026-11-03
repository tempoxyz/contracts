// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

import { IZoneFactory, ZONE_FACTORY_ADDRESS, ZoneInfo } from "tempo-zones/interfaces/IZone.sol";
import { ZoneRouter } from "zone-router/ZoneRouter.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";

import { CardFactory } from "../../../src/core/CardFactory.sol";
import { CardSpender } from "../../../src/core/CardSpender.sol";
import { BridgeProvider } from "../../../src/providers/bridge/BridgeProvider.sol";
import { IBridgeSpenderFactory } from "../../../src/providers/bridge/interfaces/IBridgeSpenderFactory.sol";
import { BridgeProgramRelease } from "./BridgeRelease.sol";
import { checkProgram, requireProgram, requireRouterFactory } from "./DeployBridgeProgram.s.sol";
import { ProgramChecks } from "./ProgramChecks.sol";

/// @notice A card program's router mode: Spend only on `zoneId`, through `spender` alone, with no Earn
///         bindings.
library SpendMode {
    function forSpender(uint32 zoneId, address spender) internal pure returns (ZoneRouter.Mode memory mode) {
        mode.zoneId = zoneId;
        mode.enabledOps = uint8(1 << 2);
        mode.spenders = new address[](1);
        mode.spenders[0] = spender;
    }
}

/// @notice Deploys one Bridge card program's `CardSpender` (as `DeployBridgeProgram` does) and the
///         Spend-mode `ZoneRouter` that lists it as its only spender on one Zone, through a
///         `ZoneRouterFactory`, after checking the program's clone was created for its ID and the Zone has
///         a registered portal. The release `CardFactory` for that router factory, the program's
///         `BridgeProvider` and its program land at their deterministic addresses (`BridgeProgramRelease`),
///         and one already there is reused; so is a router the factory already deployed for this mode. The
///         program takes `spendFrom` only from that factory's routers, so the factory is the release
///         `ZoneRouterFactory` (`pnpm zone-router-release <network> zoneRouterFactory`), never a new one. None
///         of them has an owner, so nothing else is configured here. A Zone with a closed callback gateway must still grant the router the
///         gateway role, and one that enforces access must admit the program's refund recipient and the
///         program wallet that deposits refunds.
///         `run` reads FACTORY (the Bridge spender factory), SPENDER_ID, ZONE_ID, OUT, ROUTER_FACTORY (the
///         release ZoneRouterFactory) and DEPLOYER_PK unless the signer comes from `--account` or
///         `--ledger`. OUT is written only with `--broadcast`.
contract DeployZoneRouter is BridgeProgramRelease {
    struct Output {
        address factory;
        bytes32 spenderId;
        address clone;
        uint32 zoneId;
        address portal;
        CardFactory cardFactory;
        BridgeProvider provider;
        CardSpender program;
        ZoneRouterFactory routerFactory;
        ZoneRouter router;
    }

    function run() external returns (ZoneRouter) {
        Output memory o = deploy(
            IBridgeSpenderFactory(vm.envAddress("FACTORY")),
            vm.envBytes32("SPENDER_ID"),
            ProgramChecks.zoneId(vm.envUint("ZONE_ID")),
            ZoneRouterFactory(vm.envAddress("ROUTER_FACTORY")),
            vm.envOr("DEPLOYER_PK", uint256(0))
        );
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            write(o, vm.envString("OUT"));
        } else {
            console.log("dry run: OUT is written only with --broadcast");
        }
        return o.router;
    }

    /// @param routerFactory The release ZoneRouterFactory to deploy through. Its address is the Zone router
    ///        project's build, which this project cannot derive, so it is named rather than created here.
    /// @param deployerPk The deployer's key, or zero to sign with forge's `--account` or `--ledger`.
    function deploy(
        IBridgeSpenderFactory factory,
        bytes32 spenderId,
        uint32 zoneId,
        ZoneRouterFactory routerFactory,
        uint256 deployerPk
    ) public returns (Output memory o) {
        o.clone = checkProgram(factory, spenderId);
        ZoneInfo memory zone = IZoneFactory(ZONE_FACTORY_ADDRESS).zones(zoneId);
        require(
            zone.portal != address(0) && IZoneFactory(ZONE_FACTORY_ADDRESS).isZonePortal(zone.portal),
            "ZONE_ID has no portal"
        );
        require(address(routerFactory) != address(0), "ROUTER_FACTORY unset");
        require(address(routerFactory).code.length != 0, "ROUTER_FACTORY has no code");
        if (deployerPk == 0) vm.startBroadcast();
        else vm.startBroadcast(deployerPk);
        Created memory c = _bridgeProgram(factory, spenderId, address(routerFactory));
        o.router = ZoneRouter(routerFactory.deploy(SpendMode.forSpender(zoneId, address(c.program))));
        vm.stopBroadcast();
        requireProgram(c.program, factory, spenderId);
        requireRouterFactory(c.program, address(routerFactory));
        o.factory = address(factory);
        o.spenderId = spenderId;
        o.zoneId = zoneId;
        o.portal = zone.portal;
        o.cardFactory = c.cardFactory;
        o.provider = c.provider;
        o.program = c.program;
        o.routerFactory = routerFactory;
    }

    function write(Output memory o, string memory path) public {
        string memory key = "zone-router";
        vm.serializeAddress(key, "factory", o.factory);
        vm.serializeBytes32(key, "spenderId", o.spenderId);
        vm.serializeAddress(key, "clone", o.clone);
        vm.serializeUint(key, "zoneId", o.zoneId);
        vm.serializeAddress(key, "portal", o.portal);
        vm.serializeAddress(key, "cardFactory", address(o.cardFactory));
        vm.serializeAddress(key, "provider", address(o.provider));
        vm.serializeAddress(key, "program", address(o.program));
        vm.serializeAddress(key, "routerFactory", address(o.routerFactory));
        vm.writeJson(vm.serializeAddress(key, "router", address(o.router)), path);
    }
}
