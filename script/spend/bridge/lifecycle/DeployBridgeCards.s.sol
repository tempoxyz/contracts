// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { console2 } from "forge-std/Script.sol";

import { CardFactory } from "../../../../src/spend/CardFactory.sol";
import { CardSpender } from "../../../../src/spend/CardSpender.sol";
import { ICardProvider } from "../../../../src/interfaces/spend/ICardProvider.sol";
import { BridgeProvider } from "../../../../src/spend/providers/bridge/BridgeProvider.sol";
import { SpenderTempoSpend } from "../../../../src/spend/providers/bridge/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../../../src/spend/providers/bridge/interfaces/IBridgeSpenderFactory.sol";
import { ZoneRouterFactory } from "../../../../src/zone/ZoneRouterFactory.sol";
import { BridgeProgramRelease, BridgeRelease } from "../deploy/BridgeRelease.sol";
import { checkProgram, requireProgram, requireRouterFactory } from "../deploy/DeployBridgeProgram.s.sol";
import { RouterFactoryChecks } from "../deploy/RouterFactoryChecks.sol";

/// @notice The deployment lifecycle's entry points for Bridge card programs, at the same deterministic
///         addresses as Bridge's own deploy scripts (`BridgeRelease`): `pnpm release`'s "TS" handler and
///         `CardFactory`, and a profile's `deploy-card-provider` and `deploy-card-program` steps, which
///         take the released `CardFactory` from the registry and never create it. Each entry point reuses a
///         contract that already exists, and none sends a call that needs a role on Bridge's factory.
contract DeployBridgeCardsScript is BridgeRelease, BridgeProgramRelease {
    /// @notice The `deploy-card-provider` step's typed input.
    struct ProviderInput {
        uint256 expectedChainId;
        IBridgeSpenderFactory spenderFactory;
        bytes32 spenderId;
        string outputPath;
    }

    /// @notice The `deploy-card-program` step's typed input.
    struct Input {
        uint256 expectedChainId;
        CardFactory cardFactory;
        IBridgeSpenderFactory spenderFactory;
        bytes32 spenderId;
        string outputPath;
    }

    error NoCardFactory(address cardFactory);
    error NoProvider(address provider);
    error UnexpectedFoundryProfile(string actual);
    error UnexpectedChain(uint256 actual, uint256 expected);

    modifier release(uint256 expectedChainId) {
        // Release runtimes are compiled under the `deploy` profile.
        string memory foundryProfile = vm.envString("FOUNDRY_PROFILE");
        if (keccak256(bytes(foundryProfile)) != keccak256("deploy")) {
            revert UnexpectedFoundryProfile(foundryProfile);
        }
        _requireChain(expectedChainId);
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        _;
        vm.stopBroadcast();
    }

    /// @notice The "TS" handler for Bridge's `factory`, at its release address.
    function tempoSpend(uint256 expectedChainId, address factory)
        external
        release(expectedChainId)
        returns (SpenderTempoSpend handler)
    {
        require(factory.code.length != 0, "FACTORY has no code");
        (handler,) = _tempoSpend(factory);
        console2.log("TEMPO_SPEND_ADDRESS", address(handler));
    }

    /// @notice The `CardFactory` bound to the release `ZoneRouterFactory`, which this deploys or reuses.
    function cardFactory(uint256 expectedChainId) external release(expectedChainId) returns (CardFactory factory) {
        address routerFactory = releaseRouterFactory();
        if (routerFactory.code.length == 0) {
            _requireAt(address(new ZoneRouterFactory{ salt: RELEASE_SALT }()), routerFactory);
        }
        (factory,) = _cardFactory(routerFactory);
        console2.log("CARD_FACTORY_ADDRESS", address(factory));
    }

    /// @notice A profile's `BridgeProvider` for its Bridge program, at its release address.
    function provider(ProviderInput calldata input) external returns (BridgeProvider created) {
        _requireChain(input.expectedChainId);
        checkProgram(input.spenderFactory, input.spenderId);
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        (created,) = _bridgeProvider(input.spenderFactory, input.spenderId);
        vm.stopBroadcast();
        vm.writeJson(
            vm.serializeAddress("deployment", "cardProvider", address(created)), input.outputPath, ".latestOutputs"
        );
        console2.log("CARD_PROVIDER_ADDRESS", address(created));
    }

    /// @notice A profile's card program: its `CardSpender` from the released `CardFactory`, over the program's
    ///         `BridgeProvider` (`provider`). Both must already exist.
    function run(Input calldata input) external returns (CardSpender program) {
        _requireChain(input.expectedChainId);
        CardFactory factory = input.cardFactory;
        if (address(factory).code.length == 0) revert NoCardFactory(address(factory));
        address routerFactory = factory.ROUTER_FACTORY();
        RouterFactoryChecks.check(routerFactory);
        checkProgram(input.spenderFactory, input.spenderId);
        ICardProvider cardProvider =
            ICardProvider(bridgeProviderAddress(address(input.spenderFactory), input.spenderId));
        if (address(cardProvider).code.length == 0) revert NoProvider(address(cardProvider));
        address predicted = factory.predict(input.spenderId, cardProvider);
        if (predicted.code.length == 0) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
            factory.deploy(input.spenderId, cardProvider);
            vm.stopBroadcast();
        }
        program = CardSpender(predicted);
        require(address(program.PROVIDER()) == address(cardProvider), "program has another provider");
        requireProgram(program, input.spenderFactory, input.spenderId);
        requireRouterFactory(program, routerFactory);
        vm.serializeAddress("deployment", "cardRouterFactory", routerFactory);
        vm.serializeAddress("deployment", "cardFactory", address(factory));
        vm.writeJson(
            vm.serializeAddress("deployment", "cardProgram", address(program)), input.outputPath, ".latestOutputs"
        );
        console2.log("CARD_PROGRAM_ADDRESS", address(program));
    }

    /// @notice The release `ZoneRouterFactory`, whose routers alone may call a program's `spendFrom`.
    function releaseRouterFactory() public pure returns (address) {
        return _releaseAddress(type(ZoneRouterFactory).creationCode);
    }

    function _requireChain(uint256 expectedChainId) private view {
        if (block.chainid != expectedChainId) revert UnexpectedChain(block.chainid, expectedChainId);
    }
}
