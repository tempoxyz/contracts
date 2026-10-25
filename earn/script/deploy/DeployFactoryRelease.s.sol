// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script, console2 } from "forge-std/Script.sol";

import { EarnFactory } from "../../src/core/EarnFactory.sol";
import { EarnFees } from "../../src/core/EarnFees.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { EarnRewardsFactory } from "../../src/rewards/EarnRewardsFactory.sol";

/// @notice Deploys the ownerless shared factory releases: the EarnFactory with its locked
///         implementations, and the rewards factory. Each engine factory's release entry point lives
///         in that engine's deploy script.
/// @dev Customer profiles consume these addresses but deploy their own engines, core proxies, and
///      reward contracts. `earnFactoryRelease` deploys the whole core release in one broadcast; the
///      same release is also one CREATE per entry point (`earnVaultImplementation`,
///      `earnFeesImplementation`, `earnFactory`) for Tempo batches, which allow a single CREATE.
contract DeployFactoryReleaseScript is Script {
    address private constant TIP20_FACTORY = 0x20Fc000000000000000000000000000000000000;

    error DeploymentVerificationFailed();
    error UnexpectedFoundryProfile(string actual);
    error UnexpectedChain(uint256 actual, uint256 expected);

    modifier release(uint256 expectedChainId) {
        // Reviewed release runtimes are compiled under the `deploy` profile.
        string memory foundryProfile = vm.envString("FOUNDRY_PROFILE");
        if (keccak256(bytes(foundryProfile)) != keccak256("deploy")) {
            revert UnexpectedFoundryProfile(foundryProfile);
        }
        if (block.chainid != expectedChainId) revert UnexpectedChain(block.chainid, expectedChainId);
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        _;
        vm.stopBroadcast();
    }

    function earnFactoryRelease(uint256 expectedChainId) external release(expectedChainId) returns (EarnFactory) {
        return _earnFactory(_earnVaultImplementation(), _earnFeesImplementation());
    }

    function earnVaultImplementation(uint256 expectedChainId) external release(expectedChainId) returns (EarnVault) {
        return _earnVaultImplementation();
    }

    function earnFeesImplementation(uint256 expectedChainId) external release(expectedChainId) returns (EarnFees) {
        return _earnFeesImplementation();
    }

    function earnFactory(uint256 expectedChainId, EarnVault earnVaultImplementation_, EarnFees earnFeesImplementation_)
        external
        release(expectedChainId)
        returns (EarnFactory)
    {
        return _earnFactory(earnVaultImplementation_, earnFeesImplementation_);
    }

    function earnRewardsFactory(uint256 expectedChainId)
        external
        release(expectedChainId)
        returns (EarnRewardsFactory factory)
    {
        factory = new EarnRewardsFactory();
        _requireCode(address(factory));
        console2.log("EARN_REWARDS_FACTORY_ADDRESS", address(factory));
    }

    function _earnVaultImplementation() private returns (EarnVault implementation) {
        implementation = new EarnVault();
        _requireCode(address(implementation));
        console2.log("EARN_VAULT_IMPLEMENTATION", address(implementation));
    }

    function _earnFeesImplementation() private returns (EarnFees implementation) {
        implementation = new EarnFees();
        _requireCode(address(implementation));
        console2.log("EARN_FEES_IMPLEMENTATION", address(implementation));
    }

    function _earnFactory(EarnVault vaultImplementation, EarnFees feesImplementation)
        private
        returns (EarnFactory factory)
    {
        _requireCode(address(vaultImplementation));
        _requireCode(address(feesImplementation));
        factory = new EarnFactory(TIP20_FACTORY, address(vaultImplementation), address(feesImplementation));
        _requireCode(address(factory));
        if (
            factory.tip20Factory() != TIP20_FACTORY || factory.earnVaultImplementation() != address(vaultImplementation)
                || factory.earnFeesImplementation() != address(feesImplementation)
        ) revert DeploymentVerificationFailed();
        console2.log("EARN_FACTORY_ADDRESS", address(factory));
    }

    function _requireCode(address deployed) private view {
        if (deployed.code.length == 0) revert DeploymentVerificationFailed();
    }
}
