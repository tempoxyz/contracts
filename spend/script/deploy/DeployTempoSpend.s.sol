// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

import { ISpenderHandler, SpenderStatus } from "bridge-spender/src/ISpenderHandler.sol";
import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import {
    SpenderFactoryErrorsAndEvents
} from "bridge-spender/src/SpenderFactoryErrorsAndEvents.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";

import { SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";

/// @notice Deploys the "TS" handler against Bridge's existing SpenderFactory. Registering it is an
///         admin call behind Bridge's timelock, and gating it is a governance call, so the script
///         writes both as calldata to OUT for Bridge to submit rather than sending them. The gate
///         call is written only while the prefix is `Disabled` with no handler, its state before
///         a first registration. A replacement keeps the prefix's status, so it never lowers an
///         `Enabled` handler back to `Gated`, and never turns a `Disabled` one back on.
///         `run` reads FACTORY and OUT, and DEPLOYER_PK unless the signer comes from `--account`
///         or `--ledger`. OUT is written only with `--broadcast`, once the handler exists.
contract DeployTempoSpend is Script {
    bytes2 internal constant PREFIX = "TS";

    struct Output {
        address factory;
        SpenderTempoSpend handler;
        /// @dev True when the factory had no "TS" handler before this deploy.
        bool firstRegistration;
        /// @dev The prefix's status before this deploy: "Disabled", "Gated" or "Enabled".
        string status;
        /// @dev For the admin (timelock): `setSpenderHandler("TS", handler)`.
        bytes adminRegisterHandler;
        /// @dev For governance: `updateSpenderHandlerStatus("TS", Gated)`. Empty on a replacement.
        bytes governanceGateHandler;
    }

    function run() external returns (SpenderTempoSpend) {
        Output memory o = deploy(vm.envAddress("FACTORY"), vm.envOr("DEPLOYER_PK", uint256(0)));
        if (_broadcasting()) {
            write(o, vm.envString("OUT"));
        } else {
            console.log("dry run: OUT is written only with --broadcast");
        }
        return o.handler;
    }

    /// @param deployerPk The deployer's key, or zero to sign with forge's `--account` or `--ledger`.
    function deploy(address factory, uint256 deployerPk) public returns (Output memory o) {
        require(factory.code.length != 0, "FACTORY has no code");
        SpenderStatus status = _status(SpenderFactory(factory));
        o.firstRegistration =
            address(SpenderFactory(factory).getSpenderHandler(PREFIX)) == address(0);
        if (deployerPk == 0) vm.startBroadcast();
        else vm.startBroadcast(deployerPk);
        o.handler = new SpenderTempoSpend(IFactory(factory));
        vm.stopBroadcast();
        o.factory = factory;
        o.status = _name(status);
        o.adminRegisterHandler = abi.encodeCall(
            SpenderFactory.setSpenderHandler, (PREFIX, ISpenderHandler(address(o.handler)))
        );
        if (o.firstRegistration && status == SpenderStatus.Disabled) {
            o.governanceGateHandler = abi.encodeCall(
                SpenderFactory.updateSpenderHandlerStatus, (PREFIX, SpenderStatus.Gated)
            );
        } else if (status == SpenderStatus.Disabled) {
            console.log("TS is Disabled: the new handler stays off until governance changes it");
        }
    }

    function write(Output memory o, string memory path) public {
        string memory key = "tempo-spend";
        vm.serializeAddress(key, "factory", o.factory);
        vm.serializeAddress(key, "handler", address(o.handler));
        vm.serializeBool(key, "firstRegistration", o.firstRegistration);
        vm.serializeString(key, "status", o.status);
        vm.serializeBytes(key, "adminRegisterHandler", o.adminRegisterHandler);
        vm.writeJson(vm.serializeBytes(key, "governanceGateHandler", o.governanceGateHandler), path);
    }

    /// @dev The factory exposes no status getter. Address zero is never on a handler's allowlist,
    ///      so the permission check tells the three statuses apart.
    function _status(SpenderFactory factory) private view returns (SpenderStatus) {
        try factory.getSpenderHandlerWithCheckedPermissions(PREFIX, address(0)) {
            return SpenderStatus.Enabled;
        } catch (bytes memory reason) {
            if (bytes4(reason) == SpenderFactoryErrorsAndEvents.SpenderHandlerDisabled.selector) {
                return SpenderStatus.Disabled;
            }
            return SpenderStatus.Gated;
        }
    }

    function _name(SpenderStatus status) private pure returns (string memory) {
        if (status == SpenderStatus.Enabled) return "Enabled";
        if (status == SpenderStatus.Gated) return "Gated";
        return "Disabled";
    }

    function _broadcasting() private view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }
}
