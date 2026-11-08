// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { RouterFactoryChecks } from "../../../script/bridge/deploy/RouterFactoryChecks.sol";
import { Test } from "forge-std/Test.sol";

import { ZoneRouter } from "zone-router/ZoneRouter.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";

import { DeployBridgeProgram } from "../../../script/bridge/deploy/DeployBridgeProgram.s.sol";
import { DeployZoneRouter } from "../../../script/bridge/deploy/DeployZoneRouter.s.sol";
import { IBridgeSpenderFactory } from "../../../src/providers/bridge/interfaces/IBridgeSpenderFactory.sol";
import { ZoneEnv } from "../harness/ZoneEnv.sol";

/// @dev Models the old deployment surface without the spender-list interface used by current preflight.
contract LegacyCardRouter {
    uint32 public allowedZoneId;
    uint8 public constant enabledOps = 4;
    address public constant earnVault = address(0);

    constructor(uint32 zoneId) {
        allowedZoneId = zoneId;
    }
}

contract LegacyCardRouterFactory {
    mapping(address => bool) public isRouter;

    function deploy(ZoneRouter.Mode calldata mode) external returns (address router) {
        router = address(new LegacyCardRouter(mode.zoneId));
        isRouter[router] = true;
    }
}

/// @dev New selectors and plausible getters do not establish factory code identity.
contract SpoofCardRouterFactory {
    function isRouter(address) external pure returns (bool) {
        return true;
    }

    function deploy(ZoneRouter.Mode calldata) external view returns (address) {
        return address(this);
    }

    function spenders() external pure returns (address[] memory) {
        return new address[](0);
    }
}

contract RouterFactoryAdmissionTest is ZoneEnv {
    uint256 internal constant DEPLOYER_PK = uint256(keccak256("factory.admission.deployer"));

    function setUp() public {
        _deployTempo();
        _deployZone(true);
    }

    function test_legacyFactoryRejectedBeforeRouterBroadcast() public {
        _rejectRouter(address(new LegacyCardRouterFactory()));
    }

    function test_legacyFactoryRejectedBeforeDirectProgramBroadcast() public {
        _rejectProgram(address(new LegacyCardRouterFactory()));
    }

    function test_spoofFactoryRejectedDespiteNewSelectors() public {
        address spoof = address(new SpoofCardRouterFactory());
        assertTrue(SpoofCardRouterFactory(spoof).isRouter(spoof));
        assertEq(SpoofCardRouterFactory(spoof).spenders().length, 0);
        _rejectRouter(spoof);
        _rejectProgram(spoof);
    }

    function test_canonicalZoneRouterProjectFactoryAccepted() public {
        // Supplied by the documented cross-project check, never read from a possibly stale sibling artifact.
        bytes memory runtime = vm.envOr("ZONE_ROUTER_FACTORY_RUNTIME", bytes(""));
        if (runtime.length == 0) {
            vm.skip(true);
            return;
        }
        assertNotEq(keccak256(runtime), keccak256(type(ZoneRouterFactory).runtimeCode), "distinct project metadata");
        address canonical = makeAddr("canonical.factory");
        vm.etch(canonical, runtime);
        DeployZoneRouter script = DeployZoneRouter(deployCode("DeployZoneRouter.s.sol:DeployZoneRouter"));
        DeployZoneRouter.Output memory result = script.deploy(
            IBridgeSpenderFactory(address(bridgeFactory)),
            SPENDER_ID,
            ZONE_ID,
            ZoneRouterFactory(canonical),
            DEPLOYER_PK
        );
        assertEq(result.router.spenders()[0], address(result.program));
    }

    function test_factoryRecheckedWhenProgramAlreadyExists() public {
        DeployBridgeProgram script = DeployBridgeProgram(deployCode("DeployBridgeProgram.s.sol:DeployBridgeProgram"));
        script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, address(routerFactory), DEPLOYER_PK);
        uint64 nonce = vm.getNonce(vm.addr(DEPLOYER_PK));
        vm.etch(address(routerFactory), address(new LegacyCardRouterFactory()).code);
        vm.expectRevert(bytes("ROUTER_FACTORY runtime mismatch"));
        script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, address(routerFactory), DEPLOYER_PK);
        assertEq(vm.getNonce(vm.addr(DEPLOYER_PK)), nonce, "reuse never broadcasts");
    }

    function _rejectRouter(address factory) internal {
        DeployZoneRouter script = DeployZoneRouter(deployCode("DeployZoneRouter.s.sol:DeployZoneRouter"));
        address predicted = script.bridgeProgramAddress(address(bridgeFactory), SPENDER_ID, factory);
        uint64 nonce = vm.getNonce(vm.addr(DEPLOYER_PK));
        vm.expectRevert(bytes("ROUTER_FACTORY runtime mismatch"));
        script.deploy(
            IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, ZONE_ID, ZoneRouterFactory(factory), DEPLOYER_PK
        );
        assertEq(vm.getNonce(vm.addr(DEPLOYER_PK)), nonce, "no broadcast nonce consumed");
        assertEq(predicted.code.length, 0, "no immutable program created");
        assertEq(script.cardFactoryAddress(factory).code.length, 0, "no card factory created");
    }

    function _rejectProgram(address factory) internal {
        DeployBridgeProgram script = DeployBridgeProgram(deployCode("DeployBridgeProgram.s.sol:DeployBridgeProgram"));
        address predicted = script.bridgeProgramAddress(address(bridgeFactory), SPENDER_ID, factory);
        uint64 nonce = vm.getNonce(vm.addr(DEPLOYER_PK));
        vm.expectRevert(bytes("ROUTER_FACTORY runtime mismatch"));
        script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, factory, DEPLOYER_PK);
        assertEq(vm.getNonce(vm.addr(DEPLOYER_PK)), nonce, "no broadcast nonce consumed");
        assertEq(predicted.code.length, 0, "no immutable program created");
        assertEq(script.cardFactoryAddress(factory).code.length, 0, "no card factory created");
    }
}

/// @notice Metadata compatibility never masks executable bytes or compiler and trailer structure.
contract RouterFactoryRuntimeTest is Test {
    function test_localFactoryAccepted() public pure {
        assertTrue(RouterFactoryChecks.matches(type(ZoneRouterFactory).runtimeCode));
    }

    function test_bothTerminalDigestsMayDiffer() public pure {
        bytes memory runtime = type(ZoneRouterFactory).runtimeCode;
        uint256 start = runtime.length - 106;
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 32; ++j) {
                runtime[start + i * 53 + 10 + j] ^= 0xff;
            }
        }
        assertTrue(RouterFactoryChecks.matches(runtime));
    }

    function testFuzz_everyOtherByteRemainsAuthenticated(uint256 position) public pure {
        bytes memory runtime = type(ZoneRouterFactory).runtimeCode;
        position = position % runtime.length;
        uint256 start = runtime.length - 106;
        bool digest = position >= start && (position - start) % 53 >= 10 && (position - start) % 53 < 42;
        runtime[position] ^= 0xff;
        assertEq(RouterFactoryChecks.matches(runtime), digest);
    }

    function test_trailerStructureCompilerAndDelimiterCannotChange() public pure {
        bytes memory original = type(ZoneRouterFactory).runtimeCode;
        // Check every byte in both trailers, not just the ones a fuzz run happens to select.
        for (uint256 i = original.length - 107; i < original.length; ++i) {
            bytes memory changed = type(ZoneRouterFactory).runtimeCode;
            uint256 start = original.length - 106;
            bool digest = i >= start && (i - start) % 53 >= 10 && (i - start) % 53 < 42;
            changed[i] ^= 0xff;
            assertEq(RouterFactoryChecks.matches(changed), digest);
        }
        assertFalse(RouterFactoryChecks.matches(abi.encodePacked(original, hex"00")));
        assertFalse(RouterFactoryChecks.matches(hex"00"));
    }
}
