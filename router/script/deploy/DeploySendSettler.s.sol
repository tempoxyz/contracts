// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script, console2 } from "forge-std/Script.sol";

import { SendSettler } from "../../src/SendSettler.sol";
import { IPropAMMVenue } from "tempo-earn/interfaces/external/propamm/IPropAMMVenue.sol";

/// @notice Deploys one ownerless SendSettler. A router mode lists it in `settlers` to allow sends; with a
///         pool, the pool owner admits it as a taker and recipient before it converts.
contract DeploySendSettlerScript is Script {
    /// @notice The deployment's typed input; `pool` and `customerId` are both zero for no conversion.
    struct Input {
        uint256 expectedChainId;
        address pool;
        bytes32 customerId;
        string outputPath;
    }

    error UnexpectedChain(uint256 actual, uint256 expected);

    function run(Input calldata input) external returns (SendSettler settler) {
        if (block.chainid != input.expectedChainId) revert UnexpectedChain(block.chainid, input.expectedChainId);
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        settler = new SendSettler(IPropAMMVenue(input.pool), input.customerId);
        vm.stopBroadcast();
        vm.writeJson(
            vm.serializeAddress("deployment", "sendSettler", address(settler)), input.outputPath, ".latestOutputs"
        );
        console2.log("SEND_SETTLER_ADDRESS", address(settler));
    }
}
