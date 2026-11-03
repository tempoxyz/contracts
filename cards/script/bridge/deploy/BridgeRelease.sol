// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { DeterministicRelease } from "tempo-earn/../script/deploy/DeterministicRelease.sol";

import { CardFactory } from "../../../src/core/CardFactory.sol";
import { CardSpender } from "../../../src/core/CardSpender.sol";
import { ICardProvider } from "../../../src/core/interfaces/ICardProvider.sol";
import { BridgeProvider } from "../../../src/providers/bridge/BridgeProvider.sol";
import { SpenderTempoSpend } from "../../../src/providers/bridge/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../../src/providers/bridge/interfaces/IBridgeSpenderFactory.sol";

/// @notice Deterministic creation of our ownerless contracts for Bridge card programs. Each is created
///         through the CREATE2 deployer with Earn's release salt (`DeterministicRelease`), so the same
///         build and constructor arguments land at the same address whoever deploys them, Bridge or
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
///         `CardFactory` and the program's `BridgeProvider` at their release addresses, and the program's
///         `CardSpender`, which that factory creates at the address its program ID (the Bridge spender ID)
///         and provider fix.
abstract contract BridgeProgramRelease is ReleaseAt {
    /// @notice The address the release `CardFactory` is created at, shared by every program.
    function cardFactoryAddress() public pure returns (address) {
        return _releaseAddress(type(CardFactory).creationCode);
    }

    /// @notice The address the `BridgeProvider` for `factory`'s program `spenderId` is created at.
    function bridgeProviderAddress(address factory, bytes32 spenderId) public pure returns (address) {
        return _releaseAddress(abi.encodePacked(type(BridgeProvider).creationCode, abi.encode(factory, spenderId)));
    }

    /// @notice The address the release `CardFactory` creates the program's `CardSpender` at.
    function bridgeProgramAddress(address factory, bytes32 spenderId) public pure returns (address) {
        address provider = bridgeProviderAddress(factory, spenderId);
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(CardSpender).creationCode, abi.encode(provider)));
        return vm.computeCreate2Address(keccak256(abi.encode(spenderId, provider)), initCodeHash, cardFactoryAddress());
    }

    /// @dev Creates the release `CardFactory`, or returns the one there.
    function _cardFactory() internal returns (CardFactory cardFactory, bool created) {
        address predicted = cardFactoryAddress();
        created = predicted.code.length == 0;
        cardFactory = created ? new CardFactory{ salt: RELEASE_SALT }() : CardFactory(predicted);
        _requireAt(address(cardFactory), predicted);
    }

    /// @dev Creates the program's `BridgeProvider` at its deterministic address, or returns the one there.
    function _bridgeProvider(IBridgeSpenderFactory factory, bytes32 spenderId)
        internal
        returns (BridgeProvider provider, bool created)
    {
        address predicted = bridgeProviderAddress(address(factory), spenderId);
        created = predicted.code.length == 0;
        provider = created ? new BridgeProvider{ salt: RELEASE_SALT }(factory, spenderId) : BridgeProvider(predicted);
        _requireAt(address(provider), predicted);
    }

    /// @dev Creates the factory, the provider contract and the program, each only when missing. The program is the
    ///      factory's `deploy`, called only when it does not exist yet.
    function _bridgeProgram(IBridgeSpenderFactory factory, bytes32 spenderId) internal returns (Created memory c) {
        (c.cardFactory, c.cardFactoryCreated) = _cardFactory();
        (c.provider, c.providerCreated) = _bridgeProvider(factory, spenderId);
        address predicted = bridgeProgramAddress(address(factory), spenderId);
        c.programCreated = predicted.code.length == 0;
        if (c.programCreated) c.cardFactory.deploy(spenderId, ICardProvider(address(c.provider)));
        c.program = CardSpender(predicted);
        _requireAt(predicted, c.cardFactory.predict(spenderId, ICardProvider(address(c.provider))));
    }

    struct Created {
        CardFactory cardFactory;
        BridgeProvider provider;
        CardSpender program;
        bool cardFactoryCreated;
        bool providerCreated;
        bool programCreated;
    }
}
