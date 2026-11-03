// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";

import { BridgeRelease } from "../../../script/bridge/deploy/BridgeRelease.sol";
import { DeployBridgeProgram } from "../../../script/bridge/deploy/DeployBridgeProgram.s.sol";
import { DeployTempoSpend } from "../../../script/bridge/deploy/DeployTempoSpend.s.sol";
import { DeployZoneRouter } from "../../../script/bridge/deploy/DeployZoneRouter.s.sol";
import { CardSpender } from "../../../src/core/CardSpender.sol";
import { SpenderTempoSpend } from "../../../src/providers/bridge/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../../src/providers/bridge/interfaces/IBridgeSpenderFactory.sol";
import { ZoneEnv } from "../harness/ZoneEnv.sol";

/// @dev Calls the creating functions without a broadcast, which Forge does not route through the
///      CREATE2 deployer.
contract UnbroadcastRelease is BridgeRelease {
    function tempoSpend(address factory) external returns (SpenderTempoSpend handler) {
        (handler,) = _tempoSpend(factory);
    }
}

/// @notice The "TS" handler, the release `CardFactory` and a program's `BridgeProvider` land at their
///         deterministic release addresses, the CREATE2 deployer with Earn's release salt, whoever deploys
///         them, the factory creates the program's `CardSpender` at the address its ID, provider and guardian
///         fix, and a second deploy reuses them all without sending anything.
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

    /// @notice The release addresses, predicted here from the CREATE2 rules alone, are where the script
    ///         lands, and a second run by another deployer reuses all three without a transaction.
    function test_programLandsAtItsReleaseAddressesAndIsReused() public {
        address guardian = makeAddr("bridge.guardian");
        DeployBridgeProgram script = _newDeployBridgeProgram();
        address cardFactory_ = vm.computeCreate2Address(
            EARN_RELEASE_SALT, keccak256(vm.getCode("CardFactory.sol:CardFactory")), CREATE2_FACTORY
        );
        address provider_ = vm.computeCreate2Address(
            EARN_RELEASE_SALT,
            keccak256(
                abi.encodePacked(
                    vm.getCode("BridgeProvider.sol:BridgeProvider"), abi.encode(address(bridgeFactory), SPENDER_ID)
                )
            ),
            CREATE2_FACTORY
        );
        address program_ = vm.computeCreate2Address(
            keccak256(abi.encode(SPENDER_ID, provider_, guardian)),
            keccak256(abi.encodePacked(vm.getCode("CardSpender.sol:CardSpender"), abi.encode(provider_, guardian))),
            cardFactory_
        );
        assertEq(script.cardFactoryAddress(), cardFactory_);
        assertEq(script.bridgeProviderAddress(address(bridgeFactory), SPENDER_ID), provider_);
        assertEq(script.bridgeProgramAddress(address(bridgeFactory), SPENDER_ID, guardian), program_);
        assertEq(program_.code.length, 0);

        IBridgeSpenderFactory factory = IBridgeSpenderFactory(address(bridgeFactory));
        DeployBridgeProgram.Output memory first = script.deploy(factory, SPENDER_ID, guardian, TEMPO_PK);
        assertEq(address(first.cardFactory), cardFactory_, "factory at its release address");
        assertEq(address(first.provider), provider_, "provider at its release address");
        assertEq(address(first.program), program_, "program where the factory predicts it");
        assertTrue(first.created);
        assertEq(first.clone, spender);
        assertEq(address(first.provider.FACTORY()), address(bridgeFactory));
        assertEq(first.provider.SPENDER_ID(), SPENDER_ID);
        assertEq(first.program.GUARDIAN(), guardian);
        assertEq(first.program.PAYOUT_TARGET(), spender);
        assertTrue(first.cardFactory.isSpender(program_));

        uint64 nonce = vm.getNonce(vm.addr(BRIDGE_PK));
        DeployBridgeProgram.Output memory again =
            _newDeployBridgeProgram().deploy(factory, SPENDER_ID, guardian, BRIDGE_PK);
        assertEq(address(again.program), program_, "same address for another deployer");
        assertFalse(again.created);
        assertEq(vm.getNonce(vm.addr(BRIDGE_PK)), nonce, "no transaction");

        string memory path = "reports/test-deploy-bridge-program.json";
        script.write(first, path);
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".program"), program_);
        assertEq(vm.parseJsonAddress(json, ".provider"), provider_);
        assertEq(vm.parseJsonAddress(json, ".cardFactory"), cardFactory_);
        assertEq(vm.parseJsonAddress(json, ".guardian"), guardian);
        assertEq(vm.parseJsonAddress(json, ".clone"), spender);
        assertTrue(vm.parseJsonBool(json, ".created"));
    }

    /// @notice Each program and each guardian has its own program, at its own address, over one factory,
    ///         and one provider contract per Bridge program.
    function test_programAddressFollowsTheProgramAndGuardian() public {
        bytes32 otherId = keccak256("bridge.card-program.other");
        address[] memory destinations = new address[](1);
        destinations[0] = settlement;
        vm.prank(bridgeManager);
        bridgeFactory.createSpender(otherId, destinations);
        IBridgeSpenderFactory factory = IBridgeSpenderFactory(address(bridgeFactory));
        DeployBridgeProgram script = _newDeployBridgeProgram();

        DeployBridgeProgram.Output memory a = script.deploy(factory, SPENDER_ID, address(0), TEMPO_PK);
        DeployBridgeProgram.Output memory b = script.deploy(factory, otherId, address(0), TEMPO_PK);
        DeployBridgeProgram.Output memory c = script.deploy(factory, SPENDER_ID, makeAddr("guardian"), TEMPO_PK);
        assertEq(address(a.cardFactory), address(b.cardFactory), "one release factory");
        assertTrue(address(a.provider) != address(b.provider), "a provider contract per Bridge program");
        assertEq(address(a.provider), address(c.provider), "the guardian is the program's, not the provider's");
        assertTrue(address(a.program) != address(b.program) && address(a.program) != address(c.program));
        assertEq(b.provider.SPENDER_ID(), otherId);
        assertEq(address(b.program), script.bridgeProgramAddress(address(bridgeFactory), otherId, address(0)));
        assertEq(c.program.GUARDIAN(), makeAddr("guardian"));
    }

    /// @notice DeployZoneRouter deploys the program at its release address, reusing one already there,
    ///         and running it again reuses the router.
    function test_routerDeployUsesTheReleaseProgram() public {
        _deployZone(true);
        IBridgeSpenderFactory factory = IBridgeSpenderFactory(address(bridgeFactory));
        DeployBridgeProgram.Output memory released =
            _newDeployBridgeProgram().deploy(factory, SPENDER_ID, address(0), TEMPO_PK);
        DeployZoneRouter script = DeployZoneRouter(deployCode("DeployZoneRouter.s.sol:DeployZoneRouter"));
        DeployZoneRouter.Output memory o =
            script.deploy(factory, SPENDER_ID, address(0), ZONE_ID, ZoneRouterFactory(address(0)), BRIDGE_PK);
        assertEq(address(o.program), address(released.program), "the release program");
        assertEq(o.router.settlers()[0], address(released.program));

        uint64 nonce = vm.getNonce(vm.addr(BRIDGE_PK));
        DeployZoneRouter.Output memory again =
            script.deploy(factory, SPENDER_ID, address(0), ZONE_ID, o.routerFactory, BRIDGE_PK);
        assertEq(address(again.program), address(o.program));
        assertEq(address(again.router), address(o.router), "the factory's router for this mode");
        assertEq(vm.getNonce(vm.addr(BRIDGE_PK)), nonce + 1, "only the factory's deploy call, which returns it");
    }

    /// @notice Outside a broadcast the contract would be created by the script itself, elsewhere, so
    ///         the creation is refused.
    function test_creationOutsideABroadcastIsRefused() public {
        UnbroadcastRelease release = new UnbroadcastRelease();
        vm.expectRevert(bytes("not created at its deterministic address"));
        release.tempoSpend(address(bridgeFactory));
    }

    function test_programReleaseScriptRefusesAFactoryWithoutCode() public {
        DeployBridgeProgram script = _newDeployBridgeProgram();
        vm.expectRevert(bytes("FACTORY has no code"));
        script.deploy(IBridgeSpenderFactory(makeAddr("missing")), SPENDER_ID, address(0), TEMPO_PK);
    }

    function test_programReleaseScriptRefusesAProgramWithoutAClone() public {
        DeployBridgeProgram script = _newDeployBridgeProgram();
        vm.expectRevert(bytes("SPENDER_ID has no clone"));
        script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), keccak256("no such program"), address(0), TEMPO_PK);
        vm.expectRevert(bytes("SPENDER_ID is zero"));
        script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), bytes32(0), address(0), TEMPO_PK);
    }

    /// @notice An ID a manager added to an existing clone cannot spend through "TS", so no program is
    ///         deployed for it.
    function test_programReleaseScriptRefusesAnIdAddedToAnExistingClone() public {
        bytes32 aliasId = keccak256("alias");
        address[] memory destinations = new address[](1);
        destinations[0] = settlement;
        vm.prank(bridgeManager);
        bridgeFactory.createSpenderWithExistingContract(aliasId, destinations, spender);
        DeployBridgeProgram script = _newDeployBridgeProgram();
        vm.expectRevert(bytes("SPENDER_ID was added to an existing clone, which TS rejects"));
        script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), aliasId, address(0), TEMPO_PK);
    }

    /// @notice `run` reads FACTORY and SPENDER_ID, defaults GUARDIAN to none, and writes OUT only with a
    ///         broadcast.
    /// @dev The environment is the process's, shared with DeployScripts.t.sol's suite running alongside, so
    ///      this sets the same values that one does and leaves GUARDIAN unset.
    function test_programReleaseRunReadsTheEnvironment() public {
        vm.setEnv("FACTORY", vm.toString(address(bridgeFactory)));
        vm.setEnv("SPENDER_ID", vm.toString(SPENDER_ID));
        vm.setEnv("DEPLOYER_PK", vm.toString(uint256(keccak256("tempo.deployer"))));
        vm.setEnv("OUT", "reports/test-run.json");
        DeployBridgeProgram script = _newDeployBridgeProgram();
        CardSpender deployed = script.run();
        assertEq(address(deployed), script.bridgeProgramAddress(address(bridgeFactory), SPENDER_ID, address(0)));
        assertEq(deployed.GUARDIAN(), address(0), "no guardian by default");
    }

    function _newBridgeFactory() internal returns (SpenderFactory factory) {
        factory = new SpenderFactory();
    }

    /// @dev From its artifact: its creation code carries the factory's, which nests the program's.
    function _newDeployBridgeProgram() internal returns (DeployBridgeProgram) {
        return DeployBridgeProgram(deployCode("DeployBridgeProgram.s.sol:DeployBridgeProgram"));
    }
}
