// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { SpenderFactoryErrorsAndEvents } from "bridge-spender/src/SpenderFactoryErrorsAndEvents.sol";
import { SpenderFactoryStorageLib } from "bridge-spender/src/lib/SpenderFactoryStorage.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { BridgeProgramRelease } from "../../../script/bridge/deploy/BridgeRelease.sol";
import { DeployBridgeProgram, requireProgram } from "../../../script/bridge/deploy/DeployBridgeProgram.s.sol";
import { CardSpender } from "../../../src/core/CardSpender.sol";
import { BridgeProvider } from "../../../src/providers/bridge/BridgeProvider.sol";
import { IBridgeSpenderFactory } from "../../../src/providers/bridge/interfaces/IBridgeSpenderFactory.sol";

/// @dev Historical repair fixture only: the vendored factory has no setter and refuses re-registering an ID.
contract HistoricalFactory is SpenderFactory {
    function restoreRegistry(bytes32 id, address clone) external onlyRole(DEFAULT_ADMIN_ROLE) {
        SpenderFactoryStorageLib.getStorage().spenderAddresses[id] = clone;
    }
}

/// @dev Creates real release artifacts without the supported script's admission checks, simulating prior misuse.
contract UncheckedProgramRelease is BridgeProgramRelease {
    function deploy(IBridgeSpenderFactory factory, bytes32 id, address routerFactory)
        external
        returns (Created memory created)
    {
        vm.startBroadcast(uint256(keccak256("historical.artifact.deployer")));
        created = _bridgeProgram(factory, id, routerFactory);
        vm.stopBroadcast();
    }
}

/// @dev External boundary for checking the script's shared admission guard and its reverts.
contract ProgramAdmission {
    function validate(CardSpender program, IBridgeSpenderFactory factory, bytes32 id) external view {
        requireProgram(program, factory, id);
    }
}

/// @notice Program adoption checks current canonical provenance, not only agreement between immutable artifacts.
contract ProgramAdmissionTest is Test {
    bytes32 internal constant PROGRAM_ID = keccak256("bridge.admission.program");
    HistoricalFactory internal factory;
    SpenderFactory internal foreignFactory;
    ProgramAdmission internal admission;
    address internal clone;
    address internal foreignClone;

    function setUp() public {
        factory = HistoricalFactory(_factory(address(new HistoricalFactory())));
        foreignFactory = SpenderFactory(_factory(address(new SpenderFactory())));
        clone = factory.createSpender(PROGRAM_ID, _destinations());
        foreignClone = foreignFactory.createSpender(PROGRAM_ID, _destinations());
        admission = new ProgramAdmission();
    }

    function test_admitsCanonicalProviderAndProgram() public {
        BridgeProvider provider = new BridgeProvider(IBridgeSpenderFactory(address(factory)), PROGRAM_ID);
        CardSpender program = new CardSpender(provider, address(this));
        admission.validate(program, IBridgeSpenderFactory(address(factory)), PROGRAM_ID);
        assertEq(provider.CLONE(), clone);
        assertEq(program.PAYOUT_TARGET(), clone);
    }

    function test_rejectsForeignCloneRegisteredForUnusedId() public {
        bytes32 id = keccak256("bridge.admission.foreign");
        address foreign = foreignFactory.createSpender(id, _destinations());
        factory.createSpenderWithExistingContract(id, _destinations(), foreign);
        BridgeProvider provider = new BridgeProvider(IBridgeSpenderFactory(address(factory)), id);
        CardSpender program = new CardSpender(provider, address(this));
        assertEq(provider.CLONE(), foreign);
        assertEq(program.PAYOUT_TARGET(), foreign);

        vm.expectRevert(bytes("SPENDER_ID was added to an existing clone, which TS rejects"));
        admission.validate(program, IBridgeSpenderFactory(address(factory)), id);
    }

    /// @notice A current canonical registry cannot legitimize artifacts created under an earlier wrong binding.
    function test_rejectsHistoricalArtifactsAfterCanonicalRegistryRestored() public {
        address routerFactory = deployCode("ZoneRouterFactory.sol:ZoneRouterFactory");
        factory.restoreRegistry(PROGRAM_ID, foreignClone);
        UncheckedProgramRelease uncheckedRelease =
            UncheckedProgramRelease(deployCode("ProgramAdmission.t.sol:UncheckedProgramRelease"));
        BridgeProgramRelease.Created memory historical =
            uncheckedRelease.deploy(IBridgeSpenderFactory(address(factory)), PROGRAM_ID, routerFactory);
        assertEq(address(historical.provider.FACTORY()), address(factory));
        assertEq(historical.provider.SPENDER_ID(), PROGRAM_ID);
        assertEq(historical.provider.CLONE(), foreignClone);
        assertEq(historical.program.PAYOUT_TARGET(), foreignClone);
        factory.restoreRegistry(PROGRAM_ID, clone);
        assertEq(factory.getSpenderAddress(PROGRAM_ID), clone);

        DeployBridgeProgram script = DeployBridgeProgram(deployCode("DeployBridgeProgram.s.sol:DeployBridgeProgram"));
        assertEq(address(historical.provider), script.bridgeProviderAddress(address(factory), PROGRAM_ID));
        assertEq(address(historical.program), script.bridgeProgramAddress(address(factory), PROGRAM_ID, routerFactory));
        vm.expectRevert(bytes("program is bound to another Bridge program"));
        script.deploy(
            IBridgeSpenderFactory(address(factory)), PROGRAM_ID, routerFactory, uint256(keccak256("adoption.deployer"))
        );
    }

    /// @notice Ordinary repointing is refused by the real factory, unlike the explicit historical repair fixture.
    function test_vendorFactoryRefusesRepointingAnExistingId() public {
        vm.expectRevert(SpenderFactoryErrorsAndEvents.SpenderAlreadyRegistered.selector);
        foreignFactory.createSpenderWithExistingContract(PROGRAM_ID, _destinations(), clone);
        assertEq(foreignFactory.getSpenderAddress(PROGRAM_ID), foreignClone);
    }

    function _factory(address implementation) internal returns (address deployed) {
        deployed = address(
            new ERC1967Proxy(
                implementation, abi.encodeCall(SpenderFactory.initialize, (address(this), address(this), address(this)))
            )
        );
        SpenderFactory(deployed).grantRole(SpenderFactory(deployed).MANAGER_ROLE(), address(this));
    }

    function _destinations() internal view returns (address[] memory destinations) {
        destinations = new address[](1);
        destinations[0] = address(this);
    }
}
