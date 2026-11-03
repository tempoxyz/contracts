// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";

import { DeployRouterReleaseScript } from "../script/deploy/DeployRouterRelease.s.sol";
import { ZoneRouter } from "../src/ZoneRouter.sol";
import { ZoneRouterFactory } from "../src/ZoneRouterFactory.sol";
import { SendSpender } from "../src/spenders/SendSpender.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IPropAMMVenue } from "tempo-earn/interfaces/external/propamm/IPropAMMVenue.sol";
import { IZoneFactory, ZONE_FACTORY_ADDRESS, ZoneInfo } from "tempo-earn/interfaces/external/tempo/IZone.sol";

/// @dev Runs the router's release entry points as Zone Router Release does, with a throwaway deployer key.
contract DeployRouterReleaseTest is Test {
    /// @dev forge-std's CREATE2_FACTORY, which Forge routes broadcast salted creations through.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant RELEASE_SALT = keccak256("tempoxyz/earn shared factory release");
    uint256 internal constant DEPLOYER_KEY = 0xA11CE;
    address internal constant ZONE_7_PORTAL = 0x5Ad0000000000000000000000000000000000007;

    DeployRouterReleaseScript internal script;

    function setUp() public {
        vm.setEnv("FOUNDRY_PROFILE", "deploy");
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        script = new DeployRouterReleaseScript();
        // A router reads its Zone's Portal from the Zone factory when it is created.
        ZoneInfo memory zone;
        zone.zoneId = 7;
        zone.portal = ZONE_7_PORTAL;
        vm.mockCall(ZONE_FACTORY_ADDRESS, abi.encodeCall(IZoneFactory.zones, (7)), abi.encode(zone));
        vm.mockCall(ZONE_FACTORY_ADDRESS, abi.encodeCall(IZoneFactory.isZonePortal, (ZONE_7_PORTAL)), abi.encode(true));
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

    /// @notice Without a factory, a SendSpender binds the release ZoneRouterFactory, deploying it first when it
    ///         is not there yet, so operators pass no factory and the spender's address stays deterministic.
    function testSendSpenderIsDeterministicPerSettingAndReused() public {
        address releaseFactory =
            vm.computeCreate2Address(RELEASE_SALT, keccak256(type(ZoneRouterFactory).creationCode), CREATE2_DEPLOYER);
        assertEq(releaseFactory.code.length, 0);
        SendSpender spender = _plainSpender();
        assertGt(releaseFactory.code.length, 0);
        assertEq(spender.ROUTER_FACTORY(), releaseFactory);
        assertEq(address(spender), _spenderAddress(releaseFactory));
        assertEq(address(spender.convertVault()), address(0));
        assertEq(address(spender.pool()), address(0));
        assertEq(address(_plainSpender()), address(spender));

        // Its settings are constructor arguments, so a converting spender is another contract, and the
        // constructor still refuses a partial binding (the CREATE2 deployer drops its revert data).
        vm.expectRevert(bytes(""));
        script.sendSpender(
            block.chainid, address(0), IEarnVault(address(0)), IPropAMMVenue(address(0)), keccak256("customer")
        );
    }

    /// @notice A SendSpender for another factory is another contract, and a factory address without code is refused.
    function testSendSpenderBindsAGivenFactory() public {
        ZoneRouterFactory other = new ZoneRouterFactory();
        SendSpender spender = script.sendSpender(
            block.chainid, address(other), IEarnVault(address(0)), IPropAMMVenue(address(0)), bytes32(0)
        );
        assertEq(spender.ROUTER_FACTORY(), address(other));
        assertEq(address(spender), _spenderAddress(address(other)));

        address missing = makeAddr("missing");
        vm.expectRevert(abi.encodeWithSelector(DeployRouterReleaseScript.NoFactory.selector, missing));
        script.sendSpender(block.chainid, missing, IEarnVault(address(0)), IPropAMMVenue(address(0)), bytes32(0));
    }

    function testZoneRouterIsTheFactorysRouterForTheModeAndReused() public {
        ZoneRouterFactory factory = script.zoneRouterFactory(block.chainid);
        ZoneRouter.Mode memory mode = _spendMode(_plainSpender());
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
        assertEq(router.spenders(), mode.spenders);
        assertEq(router.portal(), ZONE_7_PORTAL);
        assertEq(address(script.zoneRouter(block.chainid, factory, mode)), address(router));
    }

    function testZoneRouterRefusesAnAddressWithoutAFactory() public {
        ZoneRouterFactory missing = ZoneRouterFactory(makeAddr("missing"));
        ZoneRouter.Mode memory mode = _spendMode(SendSpender(makeAddr("spender")));
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

    function _plainSpender() internal returns (SendSpender) {
        return
            script.sendSpender(block.chainid, address(0), IEarnVault(address(0)), IPropAMMVenue(address(0)), bytes32(0));
    }

    /// @dev A non-converting SendSpender's release address for `factory`.
    function _spenderAddress(address factory) internal pure returns (address) {
        return vm.computeCreate2Address(
            RELEASE_SALT,
            keccak256(
                abi.encodePacked(
                    type(SendSpender).creationCode, abi.encode(factory, address(0), address(0), bytes32(0))
                )
            ),
            CREATE2_DEPLOYER
        );
    }

    function _spendMode(SendSpender spender) internal pure returns (ZoneRouter.Mode memory mode) {
        mode.zoneId = 7;
        mode.enabledOps = uint8(1 << 2);
        mode.spenders = new address[](1);
        mode.spenders[0] = address(spender);
    }
}
