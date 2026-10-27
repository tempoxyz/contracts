// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { SpenderFactoryErrorsAndEvents } from "bridge-spender/src/SpenderFactoryErrorsAndEvents.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";

import { DeployBridgeSettler } from "../../script/deploy/DeployBridgeSettler.s.sol";
import { DeployTempoSpend } from "../../script/deploy/DeployTempoSpend.s.sol";
import { DeployZoneRouter } from "../../script/deploy/DeployZoneRouter.s.sol";
import { SpendRelease } from "../../script/deploy/SpendRelease.sol";
import { SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { BridgeSettler } from "../../src/settler/BridgeSettler.sol";
import { ZoneEnv } from "../harness/ZoneEnv.sol";

/// @dev Calls the creating functions without a broadcast, which Forge does not route through the
///      CREATE2 deployer.
contract UnbroadcastRelease is SpendRelease {
    function tempoSpend(address factory) external returns (SpenderTempoSpend handler) {
        (handler,) = _tempoSpend(factory);
    }
}

/// @notice The "TS" handler and a program's BridgeSettler land at their deterministic release
///         addresses, the CREATE2 deployer with Earn's release salt, whoever deploys them, and a
///         second deploy reuses them without sending anything.
contract DeterministicDeployTest is ZoneEnv {
    /// @dev Earn's release salt (earn/script/deploy/DeterministicRelease.sol), which
    ///      deployments/core/factory-release.ts and the Spend Release workflow also predict with.
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
        DeployBridgeSettler tempo = new DeployBridgeSettler();
        assertEq(tempo.bridgeSettlerAddress(address(bridgeFactory), SPENDER_ID), predicted);

        DeployBridgeSettler.Output memory first =
            tempo.deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, TEMPO_PK);
        assertEq(address(first.settler), predicted, "created at the release address");
        assertTrue(first.created);
        assertEq(first.clone, spender);
        assertEq(address(first.settler.FACTORY()), address(bridgeFactory));
        assertEq(first.settler.SPENDER_ID(), SPENDER_ID);

        uint64 nonce = vm.getNonce(vm.addr(BRIDGE_PK));
        DeployBridgeSettler.Output memory again =
            new DeployBridgeSettler().deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, BRIDGE_PK);
        assertEq(address(again.settler), predicted, "same address for another deployer");
        assertFalse(again.created);
        assertEq(vm.getNonce(vm.addr(BRIDGE_PK)), nonce, "no transaction");

        string memory path = "reports/test-deploy-bridge-settler.json";
        tempo.write(first, path);
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".settler"), predicted);
        assertEq(vm.parseJsonAddress(json, ".clone"), spender);
        assertEq(vm.parseJsonBytes32(json, ".spenderId"), SPENDER_ID);
        assertTrue(vm.parseJsonBool(json, ".created"));
    }

    /// @notice DeployZoneRouter deploys the program's settler at the same address as
    ///         DeployBridgeSettler, reusing one already there, and running it again reuses the router.
    function test_routerDeployUsesTheReleaseSettler() public {
        _deployZone(true);
        DeployBridgeSettler.Output memory settler =
            new DeployBridgeSettler().deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, TEMPO_PK);
        DeployZoneRouter script = DeployZoneRouter(deployCode("DeployZoneRouter.s.sol:DeployZoneRouter"));
        DeployZoneRouter.Output memory o = script.deploy(
            IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, ZONE_ID, ZoneRouterFactory(address(0)), BRIDGE_PK
        );
        assertEq(address(o.settler), address(settler.settler), "the release settler");
        assertEq(o.router.settlers()[0], address(settler.settler));

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
        address[] memory destinations = new address[](1);
        destinations[0] = settlement;
        vm.prank(bridgeManager);
        bridgeFactory.createSpender(otherId, destinations);
        DeployBridgeSettler script = new DeployBridgeSettler();
        BridgeSettler a = script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, TEMPO_PK).settler;
        BridgeSettler b = script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), otherId, TEMPO_PK).settler;
        assertTrue(address(a) != address(b));
        assertEq(b.SPENDER_ID(), otherId);
        assertEq(address(b), script.bridgeSettlerAddress(address(bridgeFactory), otherId));
    }

    function test_settlerDeployRejectsAnUnusableProgram() public {
        DeployBridgeSettler script = new DeployBridgeSettler();
        vm.expectRevert(bytes("FACTORY has no code"));
        script.deploy(IBridgeSpenderFactory(makeAddr("no.factory")), SPENDER_ID, TEMPO_PK);

        vm.expectRevert(SpenderFactoryErrorsAndEvents.UnknownSpender.selector);
        script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), keccak256("unknown.program"), TEMPO_PK);

        bytes32 aliasId = keccak256("alias");
        address[] memory destinations = new address[](1);
        destinations[0] = settlement;
        vm.prank(bridgeManager);
        bridgeFactory.createSpenderWithExistingContract(aliasId, destinations, spender);
        vm.expectRevert(bytes("SPENDER_ID was added to an existing clone, which TS rejects"));
        script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), aliasId, TEMPO_PK);
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
