// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Vm } from "forge-std/Vm.sol";
import { EarnFactory } from "tempo-earn/core/EarnFactory.sol";

/// @notice Deploys Tempo Earn's factory and implementations from Earn's own build (`earn/out`, compiled
///         by solar), so card tests and scripts run the bytecode Earn releases rather than this
///         project's solc build of the same sources. Build Earn first: `forge build` in `earn/`.
library EarnArtifacts {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string private constant factoryArtifact = "../earn/out/EarnFactory.sol/EarnFactory.json";
    string private constant vaultArtifact = "../earn/out/EarnVault.sol/EarnVault.json";
    string private constant feesArtifact = "../earn/out/EarnFees.sol/EarnFees.json";

    /// @notice Deploys an EarnFactory over fresh EarnVault and EarnFees implementations.
    function deployFactory(address tip20Factory) internal returns (EarnFactory) {
        address vault = _deploy(vaultArtifact, "");
        address fees = _deploy(feesArtifact, "");
        return EarnFactory(_deploy(factoryArtifact, abi.encode(tip20Factory, vault, fees)));
    }

    function _deploy(string memory artifact, bytes memory args) private returns (address) {
        // A missing artifact means Earn was not built; never fall back to this project's compile.
        require(vm.exists(artifact), string.concat(artifact, " missing: run forge build in earn/"));
        return vm.deployCode(artifact, args);
    }
}
