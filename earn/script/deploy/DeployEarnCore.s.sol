// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console2 } from "forge-std/Script.sol";

import { EarnFactory } from "../../src/core/EarnFactory.sol";
import { EarnFees } from "../../src/core/EarnFees.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { IEarnEngine } from "../../src/interfaces/engines/IEarnEngine.sol";
import { ALWAYS_ALLOW_POLICY_ID, ITIP20PolicyAccess } from "../../src/interfaces/external/tempo/ITIP403Registry.sol";

/// @notice Deploys the customer-neutral Earn core around any reviewed, unbound IEarnEngine.
/// @dev Venue-specific engine provisioning happens before this phase. This is the shared boundary for
///      ERC-4626 and Veda engines, so Earn configuration is never duplicated by venue integration scripts.
contract DeployEarnCoreScript is Script {
    struct Deployment {
        address earnShare;
        address earnVault;
        address earnFees;
    }

    /// @notice The deployment step's typed input: the exact factory parameters the profile derives.
    struct Input {
        uint256 expectedChainId;
        EarnFactory factory;
        EarnFactory.DeployParams params;
        string outputPath;
    }

    error BindingFailed();
    error UnexpectedChain(uint256 actual, uint256 expected);

    function run(Input calldata input) external returns (Deployment memory deployment) {
        if (block.chainid != input.expectedChainId) revert UnexpectedChain(block.chainid, input.expectedChainId);
        EarnFactory factory = input.factory;
        EarnFactory.DeployParams memory params = input.params;
        IEarnEngine engine = IEarnEngine(params.engine);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        EarnVault earnVault;
        EarnFees earnFees;
        (deployment.earnShare, earnVault, earnFees) = factory.deploy(params);
        deployment.earnVault = address(earnVault);
        deployment.earnFees = address(earnFees);
        vm.stopBroadcast();
        _verify(factory, engine, params, deployment);

        string memory object = "deployment";
        vm.serializeAddress(object, "engine", address(engine));
        vm.serializeAddress(object, "asset", engine.asset());
        vm.serializeAddress(object, "earnShare", deployment.earnShare);
        vm.serializeAddress(object, "earnVault", deployment.earnVault);
        vm.writeJson(vm.serializeAddress(object, "earnFees", deployment.earnFees), input.outputPath, ".latestOutputs");
        console2.log("EARN_ENGINE_ADDRESS", address(engine));
        console2.log("EARN_SHARE_ADDRESS", deployment.earnShare);
        console2.log("EARN_VAULT_ADDRESS", deployment.earnVault);
        console2.log("EARN_FEES_ADDRESS", deployment.earnFees);
    }

    function _verify(
        EarnFactory factory,
        IEarnEngine engine,
        EarnFactory.DeployParams memory params,
        Deployment memory deployment
    ) private view {
        EarnVault vault = EarnVault(deployment.earnVault);
        EarnFees fees = EarnFees(deployment.earnFees);
        uint64 expectedPolicyId = params.transferPolicyId == 0 ? ALWAYS_ALLOW_POLICY_ID : params.transferPolicyId;
        if (
            engine.asset() == address(0) || engine.earnVault() != address(0)
                || factory.predictEarnShare(params) != deployment.earnShare
                || factory.predictEarnFees(params) != deployment.earnFees || vault.engine() != address(engine)
                || vault.earnShare() != deployment.earnShare || vault.earnFees() != deployment.earnFees
                || vault.operator() != params.owner || vault.emergencyGuardian() != params.controls.emergencyGuardian
                || vault.asyncJanitor() != params.controls.asyncJanitor
                || vault.maxManagedAssets() != params.controls.maxManagedAssets
                || vault.engineMigrationMode() != params.controls.migrationMode
                || vault.distributor() != params.distributorConfig.distributor
                || vault.distributorUpdateDelay() != params.distributorConfig.updateDelay
                || fees.earnVault() != deployment.earnVault || fees.earnShare() != deployment.earnShare
                || ITIP20PolicyAccess(deployment.earnShare).transferPolicyId() != expectedPolicyId
                || keccak256(abi.encode(fees.feeConfig(1))) != keccak256(abi.encode(params.fees))
        ) revert BindingFailed();
    }
}
