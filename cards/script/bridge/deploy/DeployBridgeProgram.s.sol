// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

import { CardFactory } from "../../../src/core/CardFactory.sol";
import { CardSpender } from "../../../src/core/CardSpender.sol";
import { BridgeProvider } from "../../../src/providers/bridge/BridgeProvider.sol";
import { IBridgeSpenderFactory } from "../../../src/providers/bridge/interfaces/IBridgeSpenderFactory.sol";
import { BridgeProgramRelease } from "./BridgeRelease.sol";
import { ProgramChecks } from "./ProgramChecks.sol";

/// @notice Deploys one Bridge card program's `CardSpender`, after checking the program's clone was created
///         for its ID: the release `CardFactory` and the program's `BridgeProvider` at their deterministic
///         addresses (`BridgeProgramRelease`), then `CardFactory.deploy(spenderId, provider)`. Each
///         one already there is reused. The program is the cardholders' public spend entry point and the
///         settler a Spend-mode Zone router lists, which is a Zone router release (`DeployZoneRouter`).
///         `run` reads FACTORY (the spender factory), SPENDER_ID, OUT, and DEPLOYER_PK unless the signer
///         comes from `--account` or `--ledger`. OUT is written only with `--broadcast`.
contract DeployBridgeProgram is BridgeProgramRelease {
    struct Output {
        address factory;
        bytes32 spenderId;
        address clone;
        CardFactory cardFactory;
        BridgeProvider provider;
        CardSpender program;
        /// @dev False when the program already existed at its address, so nothing was sent for it.
        bool created;
    }

    function run() external returns (CardSpender) {
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
        return o.program;
    }

    /// @param deployerPk The deployer's key, or zero to sign with forge's `--account` or `--ledger`.
    function deploy(IBridgeSpenderFactory factory, bytes32 spenderId, uint256 deployerPk)
        public
        returns (Output memory o)
    {
        o.clone = checkProgram(factory, spenderId);
        if (deployerPk == 0) vm.startBroadcast();
        else vm.startBroadcast(deployerPk);
        Created memory c = _bridgeProgram(factory, spenderId);
        vm.stopBroadcast();
        requireProgram(c.program, factory, spenderId);
        o.factory = address(factory);
        o.spenderId = spenderId;
        o.cardFactory = c.cardFactory;
        o.provider = c.provider;
        o.program = c.program;
        o.created = c.programCreated;
    }

    function write(Output memory o, string memory path) public {
        string memory key = "bridge-program";
        vm.serializeAddress(key, "factory", o.factory);
        vm.serializeBytes32(key, "spenderId", o.spenderId);
        vm.serializeAddress(key, "clone", o.clone);
        vm.serializeAddress(key, "cardFactory", address(o.cardFactory));
        vm.serializeAddress(key, "provider", address(o.provider));
        vm.serializeBool(key, "created", o.created);
        vm.writeJson(vm.serializeAddress(key, "program", address(o.program)), path);
    }
}

/// @dev The checks every script that releases a Bridge program makes, before and after.
function checkProgram(IBridgeSpenderFactory factory, bytes32 spenderId) view returns (address clone) {
    require(address(factory).code.length != 0, "FACTORY has no code");
    require(spenderId != bytes32(0), "SPENDER_ID is zero");
    try factory.getSpenderAddress(spenderId) returns (address found) {
        clone = found;
    } catch { }
    require(clone.code.length != 0, "SPENDER_ID has no clone");
    require(
        ProgramChecks.isCanonical(address(factory), spenderId, clone),
        "SPENDER_ID was added to an existing clone, which TS rejects"
    );
}

/// @dev The program pays through `factory`'s clone for `spenderId`.
function requireProgram(CardSpender program, IBridgeSpenderFactory factory, bytes32 spenderId) view {
    BridgeProvider provider = BridgeProvider(address(program.PROVIDER()));
    require(
        address(provider.FACTORY()) == address(factory) && provider.SPENDER_ID() == spenderId
            && program.PAYOUT_TARGET() == provider.CLONE(),
        "program is bound to another Bridge program"
    );
}
