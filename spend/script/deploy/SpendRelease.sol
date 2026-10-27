// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { DeterministicRelease } from "tempo-earn/../script/deploy/DeterministicRelease.sol";

import { SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { BridgeSettler } from "../../src/settler/BridgeSettler.sol";

/// @notice Deterministic creation of spend's ownerless contracts: the "TS" handler and a program's
///         `BridgeSettler`. Each is created through the CREATE2 deployer with Earn's release salt
///         (`DeterministicRelease`), so the same build and constructor arguments land at the same
///         address whoever deploys them, Bridge or Tempo's Spend Release workflow, and a contract that
///         already exists there is reused instead of created again.
/// @dev Call the creating functions while broadcasting: Forge routes a broadcast `new X{salt: s}`
///      through the CREATE2 deployer. Neither contract has an owner, so anyone creating one first at
///      its address only pays its fee. The address follows the build: a change to the source, the
///      compiler settings or this project's remappings moves it.
abstract contract SpendRelease is DeterministicRelease {
    /// @notice The address the "TS" handler for `factory` is created at.
    function tempoSpendAddress(address factory) public pure returns (address) {
        return _releaseAddress(abi.encodePacked(type(SpenderTempoSpend).creationCode, abi.encode(factory)));
    }

    /// @notice The address the `BridgeSettler` for `factory`'s program `spenderId` is created at.
    function bridgeSettlerAddress(address factory, bytes32 spenderId) public pure returns (address) {
        return _releaseAddress(abi.encodePacked(type(BridgeSettler).creationCode, abi.encode(factory, spenderId)));
    }

    /// @dev Creates the "TS" handler for `factory` at its deterministic address, or returns the one there.
    function _tempoSpend(address factory) internal returns (SpenderTempoSpend handler, bool created) {
        address predicted = tempoSpendAddress(factory);
        created = predicted.code.length == 0;
        handler =
            created ? new SpenderTempoSpend{ salt: RELEASE_SALT }(IFactory(factory)) : SpenderTempoSpend(predicted);
        _requireAt(address(handler), predicted);
    }

    /// @dev Creates the program's `BridgeSettler` at its deterministic address, or returns the one there.
    function _bridgeSettler(IBridgeSpenderFactory factory, bytes32 spenderId)
        internal
        returns (BridgeSettler settler, bool created)
    {
        address predicted = bridgeSettlerAddress(address(factory), spenderId);
        created = predicted.code.length == 0;
        settler = created ? new BridgeSettler{ salt: RELEASE_SALT }(factory, spenderId) : BridgeSettler(predicted);
        _requireAt(address(settler), predicted);
    }

    /// @dev CREATE2 makes this an invariant; checked so a deploy outside a broadcast, which Forge does
    ///      not route through the CREATE2 deployer, fails instead of landing elsewhere.
    function _requireAt(address deployed, address predicted) private view {
        require(deployed == predicted && deployed.code.length != 0, "not created at its deterministic address");
    }
}
