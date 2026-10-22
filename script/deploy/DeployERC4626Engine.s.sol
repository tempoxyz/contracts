// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console2 } from "forge-std/Script.sol";

import { ERC4626Engine, IERC4626Vault } from "../../src/engines/ERC4626Engine.sol";
import { ERC4626EngineFactory } from "../../src/engines/ERC4626EngineFactory.sol";

/// @notice Deploys (or resolves) the deterministic ERC-4626 engine for one Earn stack, and the
///         ownerless ERC-4626 engine factory release that profiles consume.
/// @dev Earn core deployment and the setup-owner binding remain separate resumable phases.
contract DeployERC4626EngineScript is Script {
    /// @notice The deployment step's typed input. `owner` holds the unbound engine; binding transfers
    ///         it to `finalOwner`.
    struct Input {
        uint256 expectedChainId;
        bytes32 deploymentId;
        ERC4626EngineFactory factory;
        IERC4626Vault venue;
        address owner;
        address finalOwner;
        string outputPath;
    }

    error EngineVerificationFailed();
    error UnexpectedChain(uint256 actual, uint256 expected);
    error UnexpectedFoundryProfile(string actual);

    /// @notice The shared factory release entry point (`<releaseKey>Factory`): one CREATE of the
    ///         ownerless factory.
    function erc4626EngineFactory(uint256 expectedChainId) external returns (ERC4626EngineFactory factory) {
        // Reviewed release runtimes are compiled under the `deploy` profile.
        string memory foundryProfile = vm.envString("FOUNDRY_PROFILE");
        if (keccak256(bytes(foundryProfile)) != keccak256("deploy")) {
            revert UnexpectedFoundryProfile(foundryProfile);
        }
        if (block.chainid != expectedChainId) revert UnexpectedChain(block.chainid, expectedChainId);
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        factory = new ERC4626EngineFactory();
        vm.stopBroadcast();
        if (address(factory).code.length == 0) revert EngineVerificationFailed();
        console2.log("ERC4626_ENGINE_FACTORY_ADDRESS", address(factory));
    }

    function run(Input calldata input) external returns (ERC4626Engine engine) {
        if (block.chainid != input.expectedChainId) revert UnexpectedChain(block.chainid, input.expectedChainId);
        ERC4626EngineFactory factory = input.factory;
        IERC4626Vault venue = input.venue;
        address owner = input.owner;
        address finalOwner = input.finalOwner;
        bytes32 deploymentId = input.deploymentId;

        address predicted = factory.predictEngine(deploymentId, venue, owner, "", "");
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        if (predicted.code.length == 0) {
            engine = factory.deploy(deploymentId, venue, owner, "", "");
        } else {
            engine = ERC4626Engine(predicted);
        }
        vm.stopBroadcast();

        address boundEarnVault = engine.earnVault();
        bool validOwnership = (boundEarnVault == address(0) && engine.owner() == owner)
            || (boundEarnVault != address(0) && engine.owner() == finalOwner);
        if (
            address(engine) != predicted || address(engine.vault()) != address(venue)
                || engine.baseAsset() != venue.asset() || !validOwnership
        ) revert EngineVerificationFailed();

        string memory object = "deployment";
        vm.serializeAddress(object, "engine", address(engine));
        vm.writeJson(vm.serializeAddress(object, "asset", engine.baseAsset()), input.outputPath, ".latestOutputs");
        console2.log("EARN_ENGINE_ADDRESS", address(engine));
    }
}
