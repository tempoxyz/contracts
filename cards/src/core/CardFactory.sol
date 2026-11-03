// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardSpender } from "./CardSpender.sol";
import { ICardProvider } from "./interfaces/ICardProvider.sol";

/// @title CardFactory
/// @notice Ownerless, permissionless deployer of `CardSpender`s at addresses fixed by what they are.
/// @dev The CREATE2 salt is `keccak256(programId, provider)` and the init code carries the provider, so one
///      program has one address, known in advance through `predict`, whoever deploys it: deploying it again
///      returns the existing program, and nobody can take its address with another provider. A program cannot
///      be changed; a provider replaces one by deploying a new program. A Zone admin checks a router's
///      spender's provenance through `isSpender` and `SpenderDeployed`.
contract CardFactory {
    /// @notice Whether this factory deployed `program`.
    mapping(address program => bool deployed) public isSpender;

    event SpenderDeployed(address indexed program, bytes32 indexed programId, address indexed provider);

    /// @notice Deploys the program for `programId` and `provider`, or returns it if it exists.
    function deploy(bytes32 programId, ICardProvider provider) external returns (address program) {
        program = predict(programId, provider);
        if (isSpender[program]) return program;
        address deployed = address(new CardSpender{ salt: _salt(programId, provider) }(provider));
        // CREATE2 makes this an invariant; checked so a compiler or EVM change cannot silently diverge.
        if (deployed != program) revert();
        isSpender[program] = true;
        emit SpenderDeployed(program, programId, address(provider));
    }

    /// @notice The address `deploy(programId, provider)` deploys to.
    function predict(bytes32 programId, ICardProvider provider) public view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(CardSpender).creationCode, abi.encode(provider)));
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(programId, provider), initCodeHash))
                )
            )
        );
    }

    function _salt(bytes32 programId, ICardProvider provider) private pure returns (bytes32) {
        return keccak256(abi.encode(programId, provider));
    }
}
