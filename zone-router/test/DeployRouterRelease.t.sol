// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";

import { DeployRouterReleaseScript } from "../script/deploy/DeployRouterRelease.s.sol";
import { ZoneRouter } from "../src/ZoneRouter.sol";
import { ZoneRouterFactory } from "../src/ZoneRouterFactory.sol";
import { SendSpender } from "../src/spenders/SendSpender.sol";
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

    function testSendSpenderIsDeterministicPerSettingAndReused() public {
        SendSpender spender = _plainSpender();
        assertEq(
            address(spender),
            vm.computeCreate2Address(
                RELEASE_SALT,
                keccak256(
                    abi.encodePacked(type(SendSpender).creationCode, abi.encode(address(0), address(0), bytes32(0)))
                ),
                CREATE2_DEPLOYER
            )
        );
        assertEq(address(spender.convertVault()), address(0));
        assertEq(address(spender.pool()), address(0));
        assertEq(address(_plainSpender()), address(spender));

        // Its settings are constructor arguments, so a converting spender is another contract, and the
        // constructor still refuses a partial binding (the CREATE2 deployer drops its revert data).
        vm.expectRevert(bytes(""));
        script.sendSpender(block.chainid, IEarnVault(address(0)), IPropAMMVenue(address(0)), keccak256("customer"));
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
        return script.sendSpender(block.chainid, IEarnVault(address(0)), IPropAMMVenue(address(0)), bytes32(0));
    }

    function _spendMode(SendSpender spender) internal pure returns (ZoneRouter.Mode memory mode) {
        mode.zoneId = 7;
        mode.enabledOps = uint8(1 << 2);
        mode.spenders = new address[](1);
        mode.spenders[0] = address(spender);
    }
}
