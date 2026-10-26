// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { IContributionTarget, EarnContributionController } from "../../src/rewards/EarnContributionController.sol";

/// @notice Deploys optional contribution orchestration for an existing Earn earnVault.
contract DeployEarnContributionControllerScript is Script {
    /// @notice The deployment step's typed input.
    struct Input {
        uint256 expectedChainId;
        address earnVault;
        address owner;
        string outputPath;
    }

    error BindingFailed();
    error UnexpectedChain(uint256 actual, uint256 expected);

    function run(Input calldata input) external returns (EarnContributionController controller) {
        if (block.chainid != input.expectedChainId) revert UnexpectedChain(block.chainid, input.expectedChainId);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        controller = _deployController(input.earnVault, input.owner);
        vm.stopBroadcast();
        _verifyController(controller, input.earnVault, input.owner);
        vm.writeJson(
            vm.serializeAddress("deployment", "earnContributionController", address(controller)),
            input.outputPath,
            ".latestOutputs"
        );

        console2.log("EARN_CONTRIBUTION_CONTROLLER_ADDRESS", address(controller));
        console2.log("EARN_VAULT_ADDRESS", input.earnVault);
        console2.log("EARN_CONTRIBUTION_CONTROLLER_OWNER_ADDRESS", input.owner);
    }

    function _deployController(address earnVault, address owner)
        internal
        returns (EarnContributionController controller)
    {
        controller = new EarnContributionController(IContributionTarget(earnVault), owner);
    }

    function _verifyController(EarnContributionController controller, address earnVault, address owner) internal view {
        if (
            address(controller.earnVault()) != earnVault || controller.asset() != IContributionTarget(earnVault).asset()
                || controller.asset() == address(0) || controller.owner() != owner
        ) {
            revert BindingFailed();
        }
    }
}
