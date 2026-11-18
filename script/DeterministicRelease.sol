// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";

/// @notice Deterministic creation for the shared factory releases. Each release contract is created
///         through the CREATE2 deployer (forge-std's `CREATE2_FACTORY`, present on every Tempo
///         network) with one fixed salt, so identical creation code lands at the same address on every
///         network and a contract that already exists is reused instead of created again.
/// @dev Release contracts are ownerless, so anyone creating one first at its address only pays its fee.
///      Deployments tooling predicts the same addresses (`releaseSalt` in
///      deployments/core/factory-release.ts).
abstract contract DeterministicRelease is Script {
    bytes32 internal constant RELEASE_SALT = keccak256("tempoxyz/earn shared factory release");

    /// @notice The address `initCode` (creation code with its constructor arguments) is created at.
    function _releaseAddress(bytes memory initCode) internal pure returns (address) {
        return vm.computeCreate2Address(RELEASE_SALT, keccak256(initCode));
    }
}
