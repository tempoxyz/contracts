// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ZoneRouter } from "./ZoneRouter.sol";

/// @title ZoneRouterFactory
/// @notice Ownerless, permissionless deployer of ZoneRouters at addresses fixed by their mode.
/// @dev The CREATE2 salt is the mode's hash, so one mode has one address, known in advance through
///      `predict`. Deploying a mode again returns the existing router. A Zone admin checks a gateway's
///      provenance and mode through `isRouter` and `RouterDeployed` before admitting it.
contract ZoneRouterFactory {
    /// @notice Whether this factory deployed `router`.
    mapping(address router => bool deployed) public isRouter;

    event RouterDeployed(address indexed router, bytes32 indexed modeHash, ZoneRouter.Mode mode);

    /// @notice Deploys the router for `mode`, or returns it if it already exists.
    function deploy(ZoneRouter.Mode calldata mode) external returns (address router) {
        router = predict(mode);
        if (isRouter[router]) return router;
        bytes32 modeHash = keccak256(abi.encode(mode));
        address deployed = address(new ZoneRouter{ salt: modeHash }(mode));
        // CREATE2 makes this an invariant; checked so a compiler or EVM change cannot silently diverge.
        if (deployed != router) revert();
        isRouter[router] = true;
        emit RouterDeployed(router, modeHash, mode);
    }

    /// @notice The address `deploy(mode)` deploys to.
    function predict(ZoneRouter.Mode calldata mode) public view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(ZoneRouter).creationCode, abi.encode(mode)));
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), keccak256(abi.encode(mode)), initCodeHash))
                )
            )
        );
    }
}
