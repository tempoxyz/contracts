// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { BridgeSettler } from "../../src/settler/BridgeSettler.sol";
import { ProgramChecks } from "./ProgramChecks.sol";
import { SpendRelease } from "./SpendRelease.sol";

/// @notice Deploys one card program's `BridgeSettler` at its deterministic address (`SpendRelease`),
///         or reuses the one already there, after checking the program's clone was created for its
///         ID. It has no owner, so nothing else is configured. `DeployZoneRouter` deploys the same
///         settler, at the same address, with the program's Spend-mode router.
///         `run` reads FACTORY (the Bridge spender factory), SPENDER_ID, OUT, and DEPLOYER_PK unless
///         the signer comes from `--account` or `--ledger`. OUT is written only with `--broadcast`.
contract DeployBridgeSettler is SpendRelease {
    struct Output {
        address factory;
        bytes32 spenderId;
        address clone;
        BridgeSettler settler;
        /// @dev False when the settler already existed at its address, so nothing was sent.
        bool created;
    }

    function run() external returns (BridgeSettler) {
        Output memory o = deploy(
            IBridgeSpenderFactory(vm.envAddress("FACTORY")),
            vm.envBytes32("SPENDER_ID"),
            vm.envOr("DEPLOYER_PK", uint256(0))
        );
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            write(o, vm.envString("OUT"));
        } else {
            console.log("dry run: OUT is written only with --broadcast");
        }
        return o.settler;
    }

    /// @param deployerPk The deployer's key, or zero to sign with forge's `--account` or `--ledger`.
    function deploy(IBridgeSpenderFactory factory, bytes32 spenderId, uint256 deployerPk)
        public
        returns (Output memory o)
    {
        require(address(factory).code.length != 0, "FACTORY has no code");
        o.clone = factory.getSpenderAddress(spenderId);
        require(
            ProgramChecks.isCanonical(address(factory), spenderId, o.clone),
            "SPENDER_ID was added to an existing clone, which TS rejects"
        );
        if (deployerPk == 0) vm.startBroadcast();
        else vm.startBroadcast(deployerPk);
        (o.settler, o.created) = _bridgeSettler(factory, spenderId);
        vm.stopBroadcast();
        o.factory = address(factory);
        o.spenderId = spenderId;
    }

    function write(Output memory o, string memory path) public {
        string memory key = "bridge-settler";
        vm.serializeAddress(key, "factory", o.factory);
        vm.serializeBytes32(key, "spenderId", o.spenderId);
        vm.serializeAddress(key, "clone", o.clone);
        vm.serializeBool(key, "created", o.created);
        vm.writeJson(vm.serializeAddress(key, "settler", address(o.settler)), path);
    }
}
