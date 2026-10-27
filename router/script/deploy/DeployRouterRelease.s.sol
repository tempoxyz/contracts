// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { console2 } from "forge-std/Script.sol";

import { SendSettler } from "../../src/SendSettler.sol";
import { ZoneRouter } from "../../src/ZoneRouter.sol";
import { ZoneRouterFactory } from "../../src/ZoneRouterFactory.sol";
// Earn's own DeterministicRelease, reached through the existing `tempo-earn/` (earn/src/) remapping: a new
// remapping would change every router contract's metadata hash, and so its bytecode and address.
import { DeterministicRelease } from "tempo-earn/../script/deploy/DeterministicRelease.sol";
import { IPropAMMVenue } from "tempo-earn/interfaces/external/propamm/IPropAMMVenue.sol";

/// @notice Release entry points for the router project's ownerless contracts, which Factory Release
///         deploys like Earn's shared factories (docs/deployment/deployment.md#shared-factory-releases).
///         The ZoneRouterFactory and each SendSettler are created through the CREATE2 deployer with
///         Earn's release salt (DeterministicRelease); a ZoneRouter is created by its factory, at the
///         address its mode fixes. Each entry point reuses a contract that already exists, so whoever
///         deploys the same release lands at the same address.
contract DeployRouterReleaseScript is DeterministicRelease {
    error BindingFailed();
    error DeploymentVerificationFailed();
    error NoFactory(address factory);
    error UnexpectedFoundryProfile(string actual);
    error UnexpectedChain(uint256 actual, uint256 expected);

    modifier release(uint256 expectedChainId) {
        // Release runtimes are compiled under the `deploy` profile.
        string memory foundryProfile = vm.envString("FOUNDRY_PROFILE");
        if (keccak256(bytes(foundryProfile)) != keccak256("deploy")) {
            revert UnexpectedFoundryProfile(foundryProfile);
        }
        if (block.chainid != expectedChainId) revert UnexpectedChain(block.chainid, expectedChainId);
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        _;
        vm.stopBroadcast();
    }

    /// @notice The ownerless ZoneRouterFactory, at one address on every network.
    function zoneRouterFactory(uint256 expectedChainId)
        external
        release(expectedChainId)
        returns (ZoneRouterFactory factory)
    {
        address predicted = _releaseAddress(type(ZoneRouterFactory).creationCode);
        factory =
            predicted.code.length == 0 ? new ZoneRouterFactory{ salt: RELEASE_SALT }() : ZoneRouterFactory(predicted);
        if (address(factory) != predicted) revert DeploymentVerificationFailed();
        _requireCode(address(factory));
        console2.log("ZONE_ROUTER_FACTORY_ADDRESS", address(factory));
    }

    /// @notice An ownerless SendSettler; `pool` and `customerId` are both zero for one that never converts.
    function sendSettler(uint256 expectedChainId, IPropAMMVenue pool, bytes32 customerId)
        external
        release(expectedChainId)
        returns (SendSettler settler)
    {
        address predicted =
            _releaseAddress(abi.encodePacked(type(SendSettler).creationCode, abi.encode(pool, customerId)));
        settler = predicted.code.length == 0
            ? new SendSettler{ salt: RELEASE_SALT }(pool, customerId)
            : SendSettler(predicted);
        if (address(settler) != predicted) revert DeploymentVerificationFailed();
        _requireCode(address(settler));
        if (address(settler.pool()) != address(pool) || settler.customerId() != customerId) revert BindingFailed();
        console2.log("SEND_SETTLER_ADDRESS", address(settler));
    }

    /// @notice The router `factory` deploys for `mode`, unless the factory already deployed it.
    function zoneRouter(uint256 expectedChainId, ZoneRouterFactory factory, ZoneRouter.Mode calldata mode)
        external
        release(expectedChainId)
        returns (ZoneRouter router)
    {
        if (address(factory).code.length == 0) revert NoFactory(address(factory));
        address predicted = factory.predict(mode);
        if (!factory.isRouter(predicted)) factory.deploy(mode);
        router = ZoneRouter(predicted);
        if (!factory.isRouter(predicted)) revert DeploymentVerificationFailed();
        _requireCode(predicted);
        _verifyMode(router, mode);
        console2.log("ZONE_ROUTER_ADDRESS", predicted);
    }

    function _verifyMode(ZoneRouter router, ZoneRouter.Mode calldata mode) private view {
        if (
            router.allowedZoneId() != mode.zoneId || router.enabledOps() != mode.enabledOps
                || router.earnVault() != mode.earnVault || router.privateAsset() != mode.privateAsset
                || address(router.pool()) != mode.pool || router.customerId() != mode.customerId
                || keccak256(abi.encode(router.settlers())) != keccak256(abi.encode(mode.settlers))
        ) revert BindingFailed();
    }

    function _requireCode(address deployed) private view {
        if (deployed.code.length == 0) revert DeploymentVerificationFailed();
    }
}
