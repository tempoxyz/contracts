// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";

import { DeployRouterReleaseScript } from "../script/deploy/DeployRouterRelease.s.sol";
import { ZoneRouter } from "../src/ZoneRouter.sol";
import { ZoneRouterFactory } from "../src/ZoneRouterFactory.sol";
import { BridgeSettler } from "../src/settlers/BridgeSettler.sol";
import { SendSettler } from "../src/settlers/SendSettler.sol";
import { IBridgeSpenderFactory } from "../src/settlers/bridge/IBridgeSpender.sol";
import { MockClone, MockFactory } from "./BridgeSettler.t.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IPropAMMVenue } from "tempo-earn/interfaces/external/propamm/IPropAMMVenue.sol";

/// @dev Runs the router's release entry points as Zone Router Release does, with a throwaway deployer key.
contract DeployRouterReleaseTest is Test {
    /// @dev forge-std's CREATE2_FACTORY, which Forge routes broadcast salted creations through.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant RELEASE_SALT = keccak256("tempoxyz/earn shared factory release");
    uint256 internal constant DEPLOYER_KEY = 0xA11CE;

    DeployRouterReleaseScript internal script;

    function setUp() public {
        vm.setEnv("FOUNDRY_PROFILE", "deploy");
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        script = new DeployRouterReleaseScript();
    }

    function testZoneRouterFactoryIsDeterministicAndReused() public {
        ZoneRouterFactory factory = script.zoneRouterFactory(block.chainid);
        assertEq(
            address(factory),
            vm.computeCreate2Address(RELEASE_SALT, keccak256(type(ZoneRouterFactory).creationCode), CREATE2_DEPLOYER)
        );
        assertGt(address(factory).code.length, 0);
        assertEq(address(script.zoneRouterFactory(block.chainid)), address(factory));
    }

    function testSendSettlerIsDeterministicPerSettingAndReused() public {
        SendSettler settler = _plainSettler();
        assertEq(
            address(settler),
            vm.computeCreate2Address(
                RELEASE_SALT,
                keccak256(
                    abi.encodePacked(type(SendSettler).creationCode, abi.encode(address(0), address(0), bytes32(0)))
                ),
                CREATE2_DEPLOYER
            )
        );
        assertEq(address(settler.convertVault()), address(0));
        assertEq(address(settler.pool()), address(0));
        assertEq(address(_plainSettler()), address(settler));

        // Its settings are constructor arguments, so a converting settler is another contract, and the
        // constructor still refuses a partial binding (the CREATE2 deployer drops its revert data).
        vm.expectRevert(bytes(""));
        script.sendSettler(block.chainid, IEarnVault(address(0)), IPropAMMVenue(address(0)), keccak256("customer"));
    }

    function testBridgeSettlerIsDeterministicPerProgramAndReused() public {
        bytes32 spenderId = keccak256("program");
        MockFactory factory = new MockFactory();
        factory.setClone(spenderId, address(new MockClone()));
        BridgeSettler settler = script.bridgeSettler(block.chainid, factory, spenderId);
        assertEq(
            address(settler),
            vm.computeCreate2Address(
                RELEASE_SALT,
                keccak256(abi.encodePacked(type(BridgeSettler).creationCode, abi.encode(factory, spenderId))),
                CREATE2_DEPLOYER
            )
        );
        assertEq(address(settler.FACTORY()), address(factory));
        assertEq(settler.SPENDER_ID(), spenderId);
        assertEq(address(script.bridgeSettler(block.chainid, factory, spenderId)), address(settler));

        // Another program of the same factory gets its own settler.
        bytes32 otherId = keccak256("other program");
        factory.setClone(otherId, address(new MockClone()));
        assertTrue(address(script.bridgeSettler(block.chainid, factory, otherId)) != address(settler));
    }

    /// @dev A reverted entry point leaves its broadcast open, so each test expects one revert.
    function testBridgeSettlerRefusesAnAddressWithoutAFactory() public {
        IBridgeSpenderFactory missing = IBridgeSpenderFactory(makeAddr("missing"));
        vm.expectRevert(abi.encodeWithSelector(DeployRouterReleaseScript.NoFactory.selector, address(missing)));
        script.bridgeSettler(block.chainid, missing, keccak256("program"));
    }

    /// @dev Bridge's factory reverts for an unknown spender ID.
    function testBridgeSettlerRefusesAnUnknownProgram() public {
        MockFactory factory = new MockFactory();
        vm.expectRevert(abi.encodeWithSelector(DeployRouterReleaseScript.NoProgram.selector, keccak256("program")));
        script.bridgeSettler(block.chainid, factory, keccak256("program"));
    }

    function testBridgeSettlerRefusesAProgramWithoutAClone() public {
        MockFactory factory = new MockFactory();
        factory.setClone(keccak256("program"), makeAddr("not a clone"));
        vm.expectRevert(abi.encodeWithSelector(DeployRouterReleaseScript.NoProgram.selector, keccak256("program")));
        script.bridgeSettler(block.chainid, factory, keccak256("program"));
    }

    function testZoneRouterIsTheFactorysRouterForTheModeAndReused() public {
        ZoneRouterFactory factory = script.zoneRouterFactory(block.chainid);
        ZoneRouter.Mode memory mode = _spendMode(_plainSettler());
        ZoneRouter router = script.zoneRouter(block.chainid, factory, mode);
        assertEq(address(router), factory.predict(mode));
        assertEq(
            address(router),
            vm.computeCreate2Address(
                keccak256(abi.encode(mode)),
                keccak256(abi.encodePacked(type(ZoneRouter).creationCode, abi.encode(mode))),
                address(factory)
            )
        );
        assertTrue(factory.isRouter(address(router)));
        assertEq(router.settlers(), mode.settlers);
        assertEq(address(script.zoneRouter(block.chainid, factory, mode)), address(router));
    }

    function testZoneRouterRefusesAnAddressWithoutAFactory() public {
        ZoneRouterFactory missing = ZoneRouterFactory(makeAddr("missing"));
        ZoneRouter.Mode memory mode = _spendMode(SendSettler(makeAddr("settler")));
        vm.expectRevert(abi.encodeWithSelector(DeployRouterReleaseScript.NoFactory.selector, address(missing)));
        script.zoneRouter(block.chainid, missing, mode);
    }

    /// @dev FOUNDRY_PROFILE is process-wide and tests run in parallel, so only the chain check is exercised.
    function testRefusesAnotherChain() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeployRouterReleaseScript.UnexpectedChain.selector, block.chainid, block.chainid + 1)
        );
        script.zoneRouterFactory(block.chainid + 1);
    }

    function _plainSettler() internal returns (SendSettler) {
        return script.sendSettler(block.chainid, IEarnVault(address(0)), IPropAMMVenue(address(0)), bytes32(0));
    }

    function _spendMode(SendSettler settler) internal pure returns (ZoneRouter.Mode memory mode) {
        mode.zoneId = 7;
        mode.enabledOps = uint8(1 << 2);
        mode.settlers = new address[](1);
        mode.settlers[0] = address(settler);
    }
}
