// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardProgram } from "./CardProgram.sol";
import { ICardIssuer } from "./interfaces/ICardIssuer.sol";

/// @title CardFactory
/// @notice Ownerless, permissionless deployer of `CardProgram`s at addresses fixed by what they are.
/// @dev The CREATE2 salt is `keccak256(programId, issuer, guardian)` and the init code carries the same
///      arguments, so one program has one address, known in advance through `predict`, whoever deploys it:
///      deploying it again returns the existing program, and nobody can take its address with other
///      settings. A program cannot be changed; a provider replaces one by deploying a new program. A Zone
///      admin checks a router's settler's provenance through `isProgram` and `ProgramDeployed`.
contract CardFactory {
    /// @notice Whether this factory deployed `program`.
    mapping(address program => bool deployed) public isProgram;

    event ProgramDeployed(address indexed program, bytes32 indexed programId, address indexed issuer, address guardian);

    /// @notice Deploys the program for `programId`, `issuer` and `guardian` (zero for no guardian pause), or
    ///         returns it if it exists.
    function deploy(bytes32 programId, ICardIssuer issuer, address guardian) external returns (address program) {
        program = predict(programId, issuer, guardian);
        if (isProgram[program]) return program;
        address deployed = address(new CardProgram{ salt: _salt(programId, issuer, guardian) }(issuer, guardian));
        // CREATE2 makes this an invariant; checked so a compiler or EVM change cannot silently diverge.
        if (deployed != program) revert();
        isProgram[program] = true;
        emit ProgramDeployed(program, programId, address(issuer), guardian);
    }

    /// @notice The address `deploy(programId, issuer, guardian)` deploys to.
    function predict(bytes32 programId, ICardIssuer issuer, address guardian) public view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(CardProgram).creationCode, abi.encode(issuer, guardian)));
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), _salt(programId, issuer, guardian), initCodeHash)
                    )
                )
            )
        );
    }

    function _salt(bytes32 programId, ICardIssuer issuer, address guardian) private pure returns (bytes32) {
        return keccak256(abi.encode(programId, issuer, guardian));
    }
}
