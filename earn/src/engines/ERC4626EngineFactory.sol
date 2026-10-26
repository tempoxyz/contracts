// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { ERC4626Engine, IERC4626Vault } from "./ERC4626Engine.sol";

/// @notice Permissionless deterministic deployer for the canonical ERC-4626 Earn engine.
/// @dev The factory receives no authority. Each engine is constructed with its requested setup
///      owner, which may atomically bind the EarnVault and transfer to the final owner.
contract ERC4626EngineFactory {
    bytes32 public constant ENGINE_SALT_DOMAIN = keccak256("ERC4626EngineFactory.engine.v1");

    event ERC4626EngineDeployed(
        address indexed engine,
        address indexed vault,
        address indexed owner,
        address asset,
        bytes32 deploymentId,
        bytes32 engineSalt
    );

    error EmptyDeploymentId();
    error EngineAlreadyExists(address engine);
    error FactoryCannotBeFinalOwner();

    function deploy(
        bytes32 deploymentId,
        IERC4626Vault vault,
        address owner,
        string calldata nameOverride,
        string calldata symbolOverride
    ) external returns (ERC4626Engine engine) {
        if (deploymentId == bytes32(0)) revert EmptyDeploymentId();
        if (owner == address(this)) revert FactoryCannotBeFinalOwner();

        bytes32 engineSalt = computeEngineSalt(deploymentId, vault, owner, nameOverride, symbolOverride);
        address predicted = predictEngine(deploymentId, vault, owner, nameOverride, symbolOverride);
        if (predicted.code.length != 0) revert EngineAlreadyExists(predicted);

        engine = new ERC4626Engine{ salt: engineSalt }(vault, owner, nameOverride, symbolOverride);
        emit ERC4626EngineDeployed(address(engine), address(vault), owner, engine.asset(), deploymentId, engineSalt);
    }

    function computeEngineSalt(
        bytes32 deploymentId,
        IERC4626Vault vault,
        address owner,
        string calldata nameOverride,
        string calldata symbolOverride
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ENGINE_SALT_DOMAIN,
                deploymentId,
                vault,
                owner,
                keccak256(bytes(nameOverride)),
                keccak256(bytes(symbolOverride))
            )
        );
    }

    function predictEngine(
        bytes32 deploymentId,
        IERC4626Vault vault,
        address owner,
        string calldata nameOverride,
        string calldata symbolOverride
    ) public view returns (address) {
        bytes32 engineSalt = computeEngineSalt(deploymentId, vault, owner, nameOverride, symbolOverride);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(ERC4626Engine).creationCode, abi.encode(vault, owner, nameOverride, symbolOverride))
        );
        return Create2.computeAddress(engineSalt, initCodeHash, address(this));
    }
}
