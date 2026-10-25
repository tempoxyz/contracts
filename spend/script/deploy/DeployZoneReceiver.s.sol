// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

import { IZoneFactory, ZONE_FACTORY_ADDRESS, ZoneInfo } from "tempo-zones/interfaces/IZone.sol";

import { ZoneSpendReceiver } from "../../src/ZoneSpendReceiver.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { ProgramChecks } from "./ProgramChecks.sol";

/// @notice Deploys the `ZoneSpendReceiver` for one card program and one Zone, after checking the
///         program's clone was created for its ID and the Zone has a registered portal. The
///         receiver has no owner, so nothing else is configured here. A Zone with a closed callback
///         gateway must still grant the receiver the gateway role, and one that enforces access must
///         admit the program's refund recipient.
///         `run` reads FACTORY, SPENDER_ID, ZONE_ID and OUT, and DEPLOYER_PK unless the signer comes
///         from `--account` or `--ledger`. OUT is written only with `--broadcast`.
contract DeployZoneReceiver is Script {
    struct Output {
        address factory;
        bytes32 spenderId;
        address clone;
        uint32 zoneId;
        address portal;
        ZoneSpendReceiver receiver;
    }

    function run() external returns (ZoneSpendReceiver) {
        Output memory o = deploy(
            IBridgeSpenderFactory(vm.envAddress("FACTORY")),
            vm.envBytes32("SPENDER_ID"),
            ProgramChecks.zoneId(vm.envUint("ZONE_ID")),
            vm.envOr("DEPLOYER_PK", uint256(0))
        );
        if (
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                || vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) {
            write(o, vm.envString("OUT"));
        } else {
            console.log("dry run: OUT is written only with --broadcast");
        }
        return o.receiver;
    }

    /// @param deployerPk The deployer's key, or zero to sign with forge's `--account` or `--ledger`.
    function deploy(
        IBridgeSpenderFactory factory,
        bytes32 spenderId,
        uint32 zoneId,
        uint256 deployerPk
    ) public returns (Output memory o) {
        o.clone = factory.getSpenderAddress(spenderId);
        require(
            ProgramChecks.isCanonical(address(factory), spenderId, o.clone),
            "SPENDER_ID was added to an existing clone, which TS rejects"
        );
        ZoneInfo memory zone = IZoneFactory(ZONE_FACTORY_ADDRESS).zones(zoneId);
        require(
            zone.portal != address(0)
                && IZoneFactory(ZONE_FACTORY_ADDRESS).isZonePortal(zone.portal),
            "ZONE_ID has no portal"
        );
        if (deployerPk == 0) vm.startBroadcast();
        else vm.startBroadcast(deployerPk);
        o.receiver = new ZoneSpendReceiver(factory, spenderId, zoneId);
        vm.stopBroadcast();
        o.factory = address(factory);
        o.spenderId = spenderId;
        o.zoneId = zoneId;
        o.portal = zone.portal;
    }

    function write(Output memory o, string memory path) public {
        string memory key = "zone-receiver";
        vm.serializeAddress(key, "factory", o.factory);
        vm.serializeBytes32(key, "spenderId", o.spenderId);
        vm.serializeAddress(key, "clone", o.clone);
        vm.serializeUint(key, "zoneId", o.zoneId);
        vm.serializeAddress(key, "portal", o.portal);
        vm.writeJson(vm.serializeAddress(key, "receiver", address(o.receiver)), path);
    }
}
