// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { DeterministicRelease } from "tempo-earn/../script/deploy/DeterministicRelease.sol";

import { CardFactory } from "../../../src/core/CardFactory.sol";
import { CardProgram } from "../../../src/core/CardProgram.sol";
import { ICardIssuer } from "../../../src/core/interfaces/ICardIssuer.sol";
import { BridgeIssuer } from "../../../src/providers/bridge/BridgeIssuer.sol";
import { SpenderTempoSpend } from "../../../src/providers/bridge/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../../src/providers/bridge/interfaces/IBridgeSpenderFactory.sol";

/// @notice Deterministic creation of the card integration's ownerless contracts. Each is created
///         through the CREATE2 deployer with Earn's release salt (`DeterministicRelease`), so the same
///         build and constructor arguments land at the same address whoever deploys them, the issuer or
///         Tempo's Bridge Release workflow, and a contract that already exists there is reused instead of
///         created again.
/// @dev Call the creating functions while broadcasting: Forge routes a broadcast `new X{salt: s}`
///      through the CREATE2 deployer. No contract here has an owner, so anyone creating one first at
///      its address only pays its fee. The address follows the build: a change to the source, the
///      compiler settings or this project's remappings moves it.
abstract contract ReleaseAt is DeterministicRelease {
    /// @dev CREATE2 makes this an invariant; checked so a deploy outside a broadcast, which Forge does
    ///      not route through the CREATE2 deployer, fails instead of landing elsewhere.
    function _requireAt(address deployed, address predicted) internal view {
        require(deployed == predicted && deployed.code.length != 0, "not created at its deterministic address");
    }
}

/// @notice The "TS" handler's release (`DeployTempoSpend`).
abstract contract BridgeRelease is ReleaseAt {
    /// @notice The address the "TS" handler for `factory` is created at.
    function tempoSpendAddress(address factory) public pure returns (address) {
        return _releaseAddress(abi.encodePacked(type(SpenderTempoSpend).creationCode, abi.encode(factory)));
    }

    /// @dev Creates the "TS" handler for `factory` at its deterministic address, or returns the one there.
    function _tempoSpend(address factory) internal returns (SpenderTempoSpend handler, bool created) {
        address predicted = tempoSpendAddress(factory);
        created = predicted.code.length == 0;
        handler =
            created ? new SpenderTempoSpend{ salt: RELEASE_SALT }(IFactory(factory)) : SpenderTempoSpend(predicted);
        _requireAt(address(handler), predicted);
    }
}

/// @notice A Bridge card program's release (`DeployBridgeProgram`, `DeployZoneRouter`): the shared
///         `CardFactory` and the program's `BridgeIssuer` at their release addresses, and the program's
///         `CardProgram`, which that factory creates at the address its program ID (the Bridge spender ID),
///         issuer and guardian fix.
abstract contract BridgeProgramRelease is ReleaseAt {
    /// @notice The address the release `CardFactory` is created at, shared by every program.
    function cardFactoryAddress() public pure returns (address) {
        return _releaseAddress(type(CardFactory).creationCode);
    }

    /// @notice The address the `BridgeIssuer` for `factory`'s program `spenderId` is created at.
    function bridgeIssuerAddress(address factory, bytes32 spenderId) public pure returns (address) {
        return _releaseAddress(abi.encodePacked(type(BridgeIssuer).creationCode, abi.encode(factory, spenderId)));
    }

    /// @notice The address the release `CardFactory` creates the program's `CardProgram` at, with
    ///         `guardian` (zero for none) able to pause it.
    function bridgeProgramAddress(address factory, bytes32 spenderId, address guardian) public pure returns (address) {
        address issuer = bridgeIssuerAddress(factory, spenderId);
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(CardProgram).creationCode, abi.encode(issuer, guardian)));
        return vm.computeCreate2Address(
            keccak256(abi.encode(spenderId, issuer, guardian)), initCodeHash, cardFactoryAddress()
        );
    }

    /// @dev Creates the release `CardFactory`, or returns the one there.
    function _cardFactory() internal returns (CardFactory cardFactory, bool created) {
        address predicted = cardFactoryAddress();
        created = predicted.code.length == 0;
        cardFactory = created ? new CardFactory{ salt: RELEASE_SALT }() : CardFactory(predicted);
        _requireAt(address(cardFactory), predicted);
    }

    /// @dev Creates the program's `BridgeIssuer` at its deterministic address, or returns the one there.
    function _bridgeIssuer(IBridgeSpenderFactory factory, bytes32 spenderId)
        internal
        returns (BridgeIssuer issuer, bool created)
    {
        address predicted = bridgeIssuerAddress(address(factory), spenderId);
        created = predicted.code.length == 0;
        issuer = created ? new BridgeIssuer{ salt: RELEASE_SALT }(factory, spenderId) : BridgeIssuer(predicted);
        _requireAt(address(issuer), predicted);
    }

    /// @dev Creates the factory, the issuer and the program, each only when missing. The program is the
    ///      factory's `deploy`, called only when it does not exist yet.
    function _bridgeProgram(IBridgeSpenderFactory factory, bytes32 spenderId, address guardian)
        internal
        returns (Created memory c)
    {
        (c.cardFactory, c.cardFactoryCreated) = _cardFactory();
        (c.issuer, c.issuerCreated) = _bridgeIssuer(factory, spenderId);
        address predicted = bridgeProgramAddress(address(factory), spenderId, guardian);
        c.programCreated = predicted.code.length == 0;
        if (c.programCreated) c.cardFactory.deploy(spenderId, ICardIssuer(address(c.issuer)), guardian);
        c.program = CardProgram(predicted);
        _requireAt(predicted, c.cardFactory.predict(spenderId, ICardIssuer(address(c.issuer)), guardian));
    }

    struct Created {
        CardFactory cardFactory;
        BridgeIssuer issuer;
        CardProgram program;
        bool cardFactoryCreated;
        bool issuerCreated;
        bool programCreated;
    }
}
