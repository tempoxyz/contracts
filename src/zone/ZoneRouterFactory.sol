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

    /// @notice CREATE2 put the router somewhere other than its predicted address.
    error UnexpectedRouterAddress(address deployed, address predicted);

    /// @notice Deploys the router for `mode`, or returns it if it already exists.
    /// @custom:ensures isRouter[router]
    function deploy(ZoneRouter.Mode calldata mode) external returns (address router) {
        bytes memory modeArgs = abi.encode(mode);
        bytes32 modeHash = keccak256(modeArgs);
        router = _predict(modeHash, modeArgs);
        if (isRouter[router]) return router;
        address deployed = address(new ZoneRouter{ salt: modeHash }(mode));
        // CREATE2 makes this an invariant; checked so a compiler or EVM change cannot silently diverge.
        if (deployed != router) revert UnexpectedRouterAddress(deployed, router);
        /// @custom:assert deployed == router
        isRouter[router] = true;
        emit RouterDeployed(router, modeHash, mode);
    }

    /// @notice The address `deploy(mode)` deploys to.
    function predict(ZoneRouter.Mode calldata mode) external view returns (address) {
        bytes memory modeArgs = abi.encode(mode);
        return _predict(keccak256(modeArgs), modeArgs);
    }

    /// @dev `modeArgs` is `abi.encode(mode)`, both the constructor argument and, hashed, the salt.
    function _predict(bytes32 modeHash, bytes memory modeArgs) private view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(ZoneRouter).creationCode, modeArgs));
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), modeHash, initCodeHash)))));
    }
}
