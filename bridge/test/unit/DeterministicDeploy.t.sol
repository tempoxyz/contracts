// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";

import { BridgeRelease } from "../../script/deploy/BridgeRelease.sol";
import { DeployTempoSpend } from "../../script/deploy/DeployTempoSpend.s.sol";
import { DeployZoneRouter } from "../../script/deploy/DeployZoneRouter.s.sol";
import { SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { ZoneEnv } from "../harness/ZoneEnv.sol";
import { BridgeSettler } from "zone-router/settlers/BridgeSettler.sol";

/// @dev Calls the creating functions without a broadcast, which Forge does not route through the
///      CREATE2 deployer.
contract UnbroadcastRelease is BridgeRelease {
    function tempoSpend(address factory) external returns (SpenderTempoSpend handler) {
        (handler,) = _tempoSpend(factory);
    }
}

/// @dev Creates a program's settler in a broadcast, as `DeployZoneRouter` does before its router.
contract SettlerRelease is BridgeRelease {
    function deploy(IBridgeSpenderFactory factory, bytes32 spenderId, uint256 deployerPk)
        external
        returns (BridgeSettler settler, bool created)
    {
        vm.startBroadcast(deployerPk);
        (settler, created) = _bridgeSettler(factory, spenderId);
        vm.stopBroadcast();
    }
}

/// @notice The "TS" handler and a program's BridgeSettler land at their deterministic release
///         addresses, the CREATE2 deployer with Earn's release salt, whoever deploys them, and a
///         second deploy reuses them without sending anything.
contract DeterministicDeployTest is ZoneEnv {
    /// @dev Earn's release salt (earn/script/deploy/DeterministicRelease.sol), which
    ///      deployments/core/factory-release.ts and the Bridge Release workflow also predict with.
    bytes32 internal constant EARN_RELEASE_SALT = keccak256("tempoxyz/earn shared factory release");
    uint256 internal constant TEMPO_PK = uint256(keccak256("tempo.release-deployer"));
    uint256 internal constant BRIDGE_PK = uint256(keccak256("bridge.deployer"));

    function setUp() public {
        _deployTempo();
        vm.createDir("reports", true);
    }

    function test_handlerLandsAtItsReleaseAddressAndIsReused() public {
        address predicted = vm.computeCreate2Address(
            EARN_RELEASE_SALT,
            keccak256(abi.encodePacked(type(SpenderTempoSpend).creationCode, abi.encode(address(bridgeFactory)))),
            CREATE2_FACTORY
        );
        DeployTempoSpend tempo = new DeployTempoSpend();
        assertEq(tempo.tempoSpendAddress(address(bridgeFactory)), predicted);
        assertEq(predicted.code.length, 0);

        DeployTempoSpend.Output memory first = tempo.deploy(address(bridgeFactory), TEMPO_PK);
        assertEq(address(first.handler), predicted, "created at the release address");
        assertTrue(first.created);
        assertFalse(first.registered, "the harness registered another handler");
        assertEq(address(first.handler.FACTORY()), address(bridgeFactory));
        assertEq(first.adminRegisterHandler, abi.encodeCall(SpenderFactory.setSpenderHandler, ("TS", first.handler)));

        // Bridge runs the same script with its own key: the handler is reused and nothing is sent.
        uint64 nonce = vm.getNonce(vm.addr(BRIDGE_PK));
        DeployTempoSpend.Output memory again = new DeployTempoSpend().deploy(address(bridgeFactory), BRIDGE_PK);
        assertEq(address(again.handler), predicted, "same address for another deployer");
        assertFalse(again.created);
        assertEq(vm.getNonce(vm.addr(BRIDGE_PK)), nonce, "no transaction");
        assertEq(again.adminRegisterHandler, first.adminRegisterHandler);

        vm.prank(bridgeAdmin);
        (bool ok,) = address(bridgeFactory).call(again.adminRegisterHandler);
        assertTrue(ok);
        assertTrue(new DeployTempoSpend().deploy(address(bridgeFactory), BRIDGE_PK).registered, "already registered");
    }

    /// @notice A handler for another factory is another contract, at another address.
    function test_handlerAddressFollowsTheFactory() public {
        DeployTempoSpend script = new DeployTempoSpend();
        address other = address(_newBridgeFactory());
        assertTrue(script.tempoSpendAddress(other) != script.tempoSpendAddress(address(bridgeFactory)));
        assertEq(address(script.deploy(other, TEMPO_PK).handler), script.tempoSpendAddress(other));
    }

    function test_settlerLandsAtItsReleaseAddressAndIsReused() public {
        address predicted = vm.computeCreate2Address(
            EARN_RELEASE_SALT,
            keccak256(
                abi.encodePacked(type(BridgeSettler).creationCode, abi.encode(address(bridgeFactory), SPENDER_ID))
            ),
            CREATE2_FACTORY
        );
        SettlerRelease tempo = new SettlerRelease();
        assertEq(tempo.bridgeSettlerAddress(address(bridgeFactory), SPENDER_ID), predicted);

        (BridgeSettler first, bool created) =
            tempo.deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, TEMPO_PK);
        assertEq(address(first), predicted, "created at the release address");
        assertTrue(created);
        assertEq(address(first.FACTORY()), address(bridgeFactory));
        assertEq(first.SPENDER_ID(), SPENDER_ID);

        uint64 nonce = vm.getNonce(vm.addr(BRIDGE_PK));
        (BridgeSettler again, bool createdAgain) =
            new SettlerRelease().deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, BRIDGE_PK);
        assertEq(address(again), predicted, "same address for another deployer");
        assertFalse(createdAgain);
        assertEq(vm.getNonce(vm.addr(BRIDGE_PK)), nonce, "no transaction");
    }

    /// @notice DeployZoneRouter deploys the program's settler at its release address, reusing one
    ///         already there, and running it again reuses the router.
    function test_routerDeployUsesTheReleaseSettler() public {
        _deployZone(true);
        (BridgeSettler settler,) =
            new SettlerRelease().deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, TEMPO_PK);
        DeployZoneRouter script = DeployZoneRouter(deployCode("DeployZoneRouter.s.sol:DeployZoneRouter"));
        DeployZoneRouter.Output memory o = script.deploy(
            IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, ZONE_ID, ZoneRouterFactory(address(0)), BRIDGE_PK
        );
        assertEq(address(o.settler), address(settler), "the release settler");
        assertEq(o.router.settlers()[0], address(settler));

        uint64 nonce = vm.getNonce(vm.addr(BRIDGE_PK));
        DeployZoneRouter.Output memory again = script.deploy(
            IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, ZONE_ID, o.routerFactory, BRIDGE_PK
        );
        assertEq(address(again.settler), address(o.settler));
        assertEq(address(again.router), address(o.router), "the factory's router for this mode");
        assertEq(vm.getNonce(vm.addr(BRIDGE_PK)), nonce + 1, "only the factory's deploy call, which returns it");
    }

    /// @notice Each program has its own settler, at its own address.
    function test_settlerAddressFollowsTheProgram() public {
        bytes32 otherId = keccak256("bridge.card-program.other");
        SettlerRelease script = new SettlerRelease();
        (BridgeSettler a,) = script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, TEMPO_PK);
        (BridgeSettler b,) = script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), otherId, TEMPO_PK);
        assertTrue(address(a) != address(b));
        assertEq(b.SPENDER_ID(), otherId);
        assertEq(address(b), script.bridgeSettlerAddress(address(bridgeFactory), otherId));
    }

    /// @notice Outside a broadcast the contract would be created by the script itself, elsewhere, so
    ///         the creation is refused.
    function test_creationOutsideABroadcastIsRefused() public {
        UnbroadcastRelease release = new UnbroadcastRelease();
        vm.expectRevert(bytes("not created at its deterministic address"));
        release.tempoSpend(address(bridgeFactory));
    }

    function _newBridgeFactory() internal returns (SpenderFactory factory) {
        factory = new SpenderFactory();
    }
}
