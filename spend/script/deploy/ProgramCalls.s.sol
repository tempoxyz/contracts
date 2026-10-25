// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";

import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";

import { ITempoEarnVault } from "../../src/interfaces/ITempoEarnVault.sol";
import { ProgramChecks } from "./ProgramChecks.sol";

/// @notice Writes the factory calls that turn the "TS" handler on for one card program: the
///         governance call that allowlists the program while the handler is gated, and one
///         governance call per Earn vault the program may spend from. Nothing is sent. Each call
///         targets the factory. Submit the allowlist call first: while the handler is gated, the
///         factory refuses the program's vault calls until it is allowlisted.
///         `run` reads FACTORY, SPENDER_ID, VAULTS (comma separated, optional) and OUT.
contract ProgramCalls is Script {
    bytes2 internal constant PREFIX = "TS";

    struct Output {
        address factory;
        bytes32 spenderId;
        /// @dev For governance: `updateSpenderHandlerAllowlist("TS", spenderId, true)`.
        bytes governanceAllowlistProgram;
        /// @dev For governance: `governorCall(spenderId, "TS" "UV" 0x01 vault)` per vault.
        bytes[] governanceAllowVaults;
    }

    function run() external {
        Output memory o = calls(
            SpenderFactory(vm.envAddress("FACTORY")),
            vm.envBytes32("SPENDER_ID"),
            vm.envOr("VAULTS", ",", new address[](0))
        );
        write(o, vm.envString("OUT"));
    }

    function calls(SpenderFactory factory, bytes32 spenderId, address[] memory vaults)
        public
        view
        returns (Output memory o)
    {
        require(
            ProgramChecks.isCanonical(
                address(factory), spenderId, factory.getSpenderAddress(spenderId)
            ),
            "SPENDER_ID was added to an existing clone, which TS rejects"
        );
        o.factory = address(factory);
        o.spenderId = spenderId;
        o.governanceAllowlistProgram =
            abi.encodeCall(SpenderFactory.updateSpenderHandlerAllowlist, (PREFIX, spenderId, true));
        o.governanceAllowVaults = new bytes[](vaults.length);
        for (uint256 i; i < vaults.length; ++i) {
            require(ITempoEarnVault(vaults[i]).earnShare() != address(0), "not an Earn vault");
            require(
                ProgramChecks.supportsEarnSpend(vaults[i]),
                "vault engine lacks exact withdrawals or redeem previews"
            );
            o.governanceAllowVaults[i] = abi.encodeCall(
                SpenderFactory.governorCall,
                (spenderId, abi.encodePacked(PREFIX, bytes2("UV"), uint8(1), vaults[i]))
            );
        }
    }

    function write(Output memory o, string memory path) public {
        string memory key = "program-calls";
        vm.serializeAddress(key, "factory", o.factory);
        vm.serializeBytes32(key, "spenderId", o.spenderId);
        vm.serializeBytes(key, "governanceAllowlistProgram", o.governanceAllowlistProgram);
        vm.writeJson(vm.serializeBytes(key, "governanceAllowVaults", o.governanceAllowVaults), path);
    }
}
