// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ISpenderHandler, SpenderStatus } from "bridge-spender/src/ISpenderHandler.sol";
import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { SpenderFactoryErrorsAndEvents } from "bridge-spender/src/SpenderFactoryErrorsAndEvents.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

import { DeployTempoSpend } from "../../script/deploy/DeployTempoSpend.s.sol";
import { DeployZoneRouter } from "../../script/deploy/DeployZoneRouter.s.sol";
import { Preflight } from "../../script/deploy/Preflight.s.sol";
import { ProgramCalls } from "../../script/deploy/ProgramCalls.s.sol";
import { Spend } from "../../src/SpenderTempoSpend.sol";
import { SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { NoopSpendHandler, OlderBridgeSettler } from "../harness/Mocks.sol";
import { ZoneEnv } from "../harness/ZoneEnv.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { IERC165 } from "openzeppelin-contracts/utils/introspection/IERC165.sol";
import { IEarnEngineExactWithdraw } from "tempo-earn/interfaces/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineRedeem } from "tempo-earn/interfaces/engines/IEarnEngineRedeem.sol";
import {
    IZoneFactory,
    IZonePortal,
    ZONE_FACTORY_ADDRESS,
    ZONE_MESSENGER_ADDRESS,
    ZoneInfo
} from "tempo-zones/interfaces/IZone.sol";
import { ZoneRouter } from "zone-router/ZoneRouter.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";
import { BridgeSettler } from "zone-router/settlers/BridgeSettler.sol";

/// @notice The deployment scripts against an existing Bridge factory: deploy, submit the calls
///         they write with the role each one needs, then spend.
contract DeployScriptsTest is ZoneEnv {
    uint256 internal constant DEPLOYER_PK = uint256(keccak256("tempo.deployer"));

    address internal alice = makeAddr("alice");
    /// @dev The factory the last `_deployRouter` used, which the preflight checks routers against.
    ZoneRouterFactory internal routerFactory;

    function setUp() public {
        _deployTempo();
        _mintUsd(alice, 100e6);
        vm.createDir("reports", true);
    }

    function test_deployHandlerThenTurnItOnForAProgram() public {
        _bridgeGovernorCall(abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(0), address(earnVault)));
        _clearTempoSpendHandler();
        DeployTempoSpend deployScript = new DeployTempoSpend();
        DeployTempoSpend.Output memory handler = deployScript.deploy(address(bridgeFactory), DEPLOYER_PK);
        assertEq(address(handler.handler.FACTORY()), address(bridgeFactory));
        assertTrue(handler.firstRegistration);
        assertEq(handler.status, "Disabled");
        _submit(bridgeAdmin, handler.adminRegisterHandler);
        _submit(bridgeGovernor, handler.governanceGateHandler);
        assertEq(address(bridgeFactory.getSpenderHandler(PREFIX_TEMPO_SPEND)), address(handler.handler));

        _approve(10e6);
        vm.prank(alice);
        vm.expectRevert(SpenderFactoryErrorsAndEvents.SpenderHandlerNotAllowed.selector);
        _cloneCall(_psCall(_stable(10e6)));

        address[] memory vaults = new address[](1);
        vaults[0] = address(earnVault);
        ProgramCalls.Output memory program =
            new ProgramCalls().calls(SpenderFactory(address(bridgeFactory)), SPENDER_ID, vaults);
        _submit(bridgeGovernor, program.governanceAllowlistProgram);
        assertEq(program.governanceAllowVaults.length, 1);
        _submit(bridgeGovernor, program.governanceAllowVaults[0]);

        bytes memory allowed = _cloneGet(abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("GV"), address(earnVault)));
        assertTrue(abi.decode(allowed, (bool)), "vault allowed");
        uint256 before = usd.balanceOf(settlement);
        vm.prank(alice);
        _cloneCall(_psCall(_stable(10e6)));
        assertEq(usd.balanceOf(settlement) - before, 10e6, "spend through the new handler");
    }

    /// @notice Replacing a live handler writes no gate call, so an `Enabled` handler stays
    ///         enabled for every program and spends keep working without new allowlisting.
    function test_replacementKeepsTheHandlerStatus() public {
        DeployTempoSpend.Output memory handler = new DeployTempoSpend().deploy(address(bridgeFactory), DEPLOYER_PK);
        assertFalse(handler.firstRegistration);
        assertEq(handler.governanceGateHandler.length, 0, "no gate call");
        _submit(bridgeAdmin, handler.adminRegisterHandler);

        _approve(10e6);
        uint256 before = usd.balanceOf(settlement);
        vm.prank(alice);
        _cloneCall(_psCall(_stable(10e6)));
        assertEq(usd.balanceOf(settlement) - before, 10e6, "spend through the replacement");
    }

    function test_handlerOutputWritesEveryCall() public {
        DeployTempoSpend deployScript = new DeployTempoSpend();
        DeployTempoSpend.Output memory o = deployScript.deploy(address(bridgeFactory), DEPLOYER_PK);
        string memory path = "reports/test-deploy-tempo-spend.json";
        deployScript.write(o, path);
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".handler"), address(o.handler));
        assertEq(vm.parseJsonBytes(json, ".adminRegisterHandler"), o.adminRegisterHandler);
        assertEq(vm.parseJsonBytes(json, ".governanceGateHandler"), o.governanceGateHandler);
    }

    function test_programCallsWithNoVaults() public {
        ProgramCalls script = new ProgramCalls();
        ProgramCalls.Output memory o =
            script.calls(SpenderFactory(address(bridgeFactory)), SPENDER_ID, new address[](0));
        string memory path = "reports/test-program-calls.json";
        script.write(o, path);
        assertEq(vm.parseJsonBytesArray(vm.readFile(path), ".governanceAllowVaults").length, 0);
    }

    function test_programCallsRejectUnknownProgram() public {
        ProgramCalls script = new ProgramCalls();
        vm.expectRevert(SpenderFactoryErrorsAndEvents.UnknownSpender.selector);
        script.calls(SpenderFactory(address(bridgeFactory)), keccak256("unknown.program"), new address[](0));
    }

    function test_deployRouterForAProgramAndZone() public {
        _deployZone(true);
        DeployZoneRouter script = _newDeployZoneRouter();
        DeployZoneRouter.Output memory o = script.deploy(
            IBridgeSpenderFactory(address(bridgeFactory)),
            SPENDER_ID,
            ZONE_ID,
            ZoneRouterFactory(address(0)),
            DEPLOYER_PK
        );
        assertEq(address(o.settler.FACTORY()), address(bridgeFactory));
        assertEq(o.settler.SPENDER_ID(), SPENDER_ID);
        assertTrue(o.routerFactory.isRouter(address(o.router)), "deployed by the factory");
        assertEq(o.router.allowedZoneId(), ZONE_ID);
        assertEq(o.router.enabledOps(), o.router.OP_SPEND(), "Spend only");
        assertEq(o.router.earnVault(), address(0), "no Earn bindings");
        address[] memory settlers = o.router.settlers();
        assertEq(settlers.length, 1);
        assertEq(settlers[0], address(o.settler));

        string memory path = "reports/test-deploy-zone-router.json";
        script.write(o, path);
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".router"), address(o.router));
        assertEq(vm.parseJsonAddress(json, ".settler"), address(o.settler));
        assertEq(vm.parseJsonAddress(json, ".routerFactory"), address(o.routerFactory));
        assertEq(vm.parseJsonAddress(json, ".clone"), spender);
        assertEq(vm.parseJsonAddress(json, ".portal"), address(portal));

        // An existing factory is reused.
        DeployZoneRouter.Output memory again = script.deploy(
            IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, ZONE_ID, o.routerFactory, DEPLOYER_PK
        );
        assertEq(address(again.routerFactory), address(o.routerFactory));
        assertTrue(o.routerFactory.isRouter(address(again.router)));
    }

    function test_deployRouterRejectsAFactoryWithoutCode() public {
        _deployZone(true);
        DeployZoneRouter script = _newDeployZoneRouter();
        vm.expectRevert(bytes("ROUTER_FACTORY has no code"));
        script.deploy(
            IBridgeSpenderFactory(address(bridgeFactory)),
            SPENDER_ID,
            ZONE_ID,
            ZoneRouterFactory(makeAddr("no.factory")),
            DEPLOYER_PK
        );
    }

    /// @notice The preflight reports a deployed router, refund account and program wallet that still
    ///         lack their closed-loop Zone roles, then passes once the Zone admin grants them.
    function test_preflightReportsZoneRolesStillMissing() public {
        _deployZone(true);
        address router = _deployRouter();
        address refund = makeAddr("bridge.refund-recipient");
        address[] memory vaults = new address[](1);
        vaults[0] = address(earnVault);
        Preflight preflight = new Preflight();

        Preflight.Report memory r = _preflight(preflight, router, refund, vaults);
        assertTrue(r.programCanonical, "clone created for the ID");
        assertTrue(r.handlerValid, "handler has code and belongs to the factory");
        assertTrue(r.handlerCurrent, "handler is this repo's build");
        assertTrue(r.routerFromFactory, "router deployed by the factory");
        assertTrue(r.routerMatches, "router matches");
        assertTrue(r.settler != address(0), "program's settler found");
        assertTrue(r.settlerCurrent, "settler is this repo's build");
        assertTrue(r.messengerAllowedByPolicy, "messenger allowed by policy");
        assertTrue(r.portalAllowedByPolicy, "portal allowed by policy");
        assertTrue(r.vaultsSpendable[0], "vault engine supports Earn spends");
        assertTrue(r.handlerUsable, "TS usable");
        assertTrue(r.destinationAuthorized, "destination");
        assertTrue(r.tokenEnabled, "token enabled");
        assertTrue(r.accessEnforced && !r.gatewayOpen, "closed loop");
        assertTrue(r.vaultsAllowed[0], "vault allowed");
        assertTrue(r.depositsActive, "deposits active");
        assertTrue(r.settlementAllowedByPolicy, "settlement allowed by policy");
        assertTrue(r.routerAllowedByPolicy, "router allowed by policy");
        assertTrue(r.settlerAllowedByPolicy, "settler allowed by policy");
        assertTrue(r.refundRecipientAllowedByPolicy, "refund recipient allowed by policy");
        assertTrue(r.programWalletAllowedByPolicy, "program wallet allowed by policy");
        assertTrue(r.zoneAdminAllowedByPolicy, "Zone admin allowed by policy");
        assertFalse(r.tokenIsEarnShare, "a stablecoin TOKEN");
        assertFalse(r.routerAdmitted, "router not yet a gateway");
        assertFalse(r.refundRecipientAdmitted, "refund account not yet admitted");
        assertFalse(r.programWalletAdmitted, "program wallet not yet admitted");
        preflight.print(r, vaults);

        _zoneRegisterGateway(router);
        _zoneAllowAccount(refund);
        _zoneAllowAccount(programWallet);
        r = _preflight(preflight, router, refund, vaults);
        assertTrue(r.routerAdmitted, "router is a gateway");
        assertTrue(r.refundRecipientAdmitted, "refund account admitted");
        assertTrue(r.programWalletAdmitted, "program wallet admitted");
    }

    /// @notice A router the given factory did not deploy, one for another Zone, and one whose only
    ///         settler serves another program are each reported, and none is read as the program's.
    function test_preflightReportsARouterThatIsNotTheProgramsOwn() public {
        _deployZone(false);
        Preflight preflight = new Preflight();
        address router = _deployRouter();

        // The same mode deployed by another factory.
        ZoneRouter.Mode memory mode = _spendMode(ZONE_ID, ZoneRouter(router).settlers()[0]);
        address direct = ZoneRouterFactory(deployCode("ZoneRouterFactory.sol:ZoneRouterFactory")).deploy(mode);
        Preflight.Report memory r = _preflight(preflight, direct, address(0), new address[](0));
        assertFalse(r.routerFromFactory, "not from the given factory");
        assertFalse(r.routerMatches);
        preflight.print(r, new address[](0));

        // Another Zone.
        address elsewhere = routerFactory.deploy(_spendMode(ZONE_ID + 1, mode.settlers[0]));
        r = _preflight(preflight, elsewhere, address(0), new address[](0));
        assertTrue(r.routerFromFactory);
        assertFalse(r.routerMatches, "another Zone");

        // Another program's settler.
        BridgeSettler other = new BridgeSettler(IBridgeSpenderFactory(address(bridgeFactory)), keccak256("other"));
        address otherProgram = routerFactory.deploy(_spendMode(ZONE_ID, address(other)));
        r = _preflight(preflight, otherProgram, address(0), new address[](0));
        assertTrue(r.routerFromFactory);
        assertFalse(r.routerMatches, "another program");
        assertEq(r.settler, address(0));
        assertFalse(r.settlerAllowedByPolicy, "no settler to check");
    }

    function test_preflightReportsAnUnknownProgramAndAPause() public {
        _deployZone(false);
        vm.prank(bridgePauser);
        bridgeFactory.pause();
        Preflight.Report memory r = new Preflight()
            .check(
                SpenderFactory(address(bridgeFactory)),
                keccak256("no.such.program"),
                settlement,
                address(usd),
                ZONE_ID,
                ZoneRouterFactory(address(0)),
                address(0),
                address(0),
                programWallet,
                new address[](0)
            );
        assertEq(r.clone, address(0));
        assertFalse(r.programCanonical);
        assertFalse(r.handlerUsable);
        assertFalse(r.destinationAuthorized);
        assertTrue(r.paused);
        assertFalse(r.routerMatches);
    }

    /// @notice A Zone without a portal still yields one vault entry per vault, so `print` reports
    ///         the portal as missing instead of reverting.
    function test_preflightWithoutAPortalStillReportsVaults() public {
        _deployZone(false);
        ZoneInfo memory none;
        vm.mockCall(ZONE_FACTORY_ADDRESS, abi.encodeCall(IZoneFactory.zones, (uint32(99))), abi.encode(none));
        address[] memory vaults = new address[](1);
        vaults[0] = address(earnVault);
        Preflight preflight = new Preflight();
        Preflight.Report memory r = preflight.check(
            SpenderFactory(address(bridgeFactory)),
            SPENDER_ID,
            settlement,
            address(usd),
            99,
            ZoneRouterFactory(address(0)),
            address(0),
            address(0),
            programWallet,
            vaults
        );
        assertEq(r.portal, address(0));
        assertEq(r.vaultsAllowed.length, 1);
        assertTrue(r.vaultsAllowed[0], "vault checked without a portal");
        preflight.print(r, vaults);
    }

    /// @notice A TOKEN that is not a TIP-20, with or without code, still yields the whole report,
    ///         its policy checks left false.
    function test_preflightWithABadTokenStillReports() public {
        _deployZone(false);
        Preflight preflight = new Preflight();
        address[2] memory tokens = [makeAddr("no.code"), address(preflight)];
        for (uint256 i; i < tokens.length; ++i) {
            Preflight.Report memory r = preflight.check(
                SpenderFactory(address(bridgeFactory)),
                SPENDER_ID,
                settlement,
                tokens[i],
                ZONE_ID,
                ZoneRouterFactory(address(0)),
                address(0),
                makeAddr("bridge.refund-recipient"),
                programWallet,
                new address[](0)
            );
            assertTrue(r.handlerUsable, "the rest of the report still runs");
            assertFalse(r.settlementAllowedByPolicy, "no policy for a bad token");
            assertFalse(r.refundRecipientAllowedByPolicy, "no policy for a bad token");
            assertFalse(r.programWalletAllowedByPolicy, "no policy for a bad token");
            assertFalse(r.tokenEnabled, "a bad token is not enabled");
            preflight.print(r, new address[](0));
        }
    }

    /// @notice A program wallet the token's policy will not let send is reported, since it pays
    ///         every refund into the Zone.
    function test_preflightReportsAProgramWalletThePolicyBlocks() public {
        _deployZone(false);
        Preflight preflight = new Preflight();
        vm.mockCall(
            address(StdPrecompiles.TIP403_REGISTRY),
            abi.encodeCall(ITIP403Registry.isAuthorizedSender, (usd.transferPolicyId(), programWallet)),
            abi.encode(false)
        );
        Preflight.Report memory r = _preflight(preflight, address(0), address(0), new address[](0));
        assertFalse(r.programWalletAllowedByPolicy);
        assertTrue(r.settlementAllowedByPolicy, "settlement unaffected");
        preflight.print(r, new address[](0));
    }

    /// @notice The portal pays its deposit fee to the Zone admin, so a policy that keeps the admin
    ///         from receiving would revert every Zone return and private refund.
    function test_preflightReportsAZoneAdminThePolicyBlocks() public {
        _deployZone(false);
        Preflight preflight = new Preflight();
        uint64 policy = StdPrecompiles.TIP403_REGISTRY.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
        vm.mockCall(address(usd), abi.encodeCall(ITIP20.transferPolicyId, ()), abi.encode(policy));

        Preflight.Report memory r = _preflight(preflight, address(0), address(0), new address[](0));
        assertFalse(r.zoneAdminAllowedByPolicy, "admin not on the whitelist");
        preflight.print(r, new address[](0));

        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(policy, portal.admin(), true);
        r = _preflight(preflight, address(0), address(0), new address[](0));
        assertTrue(r.zoneAdminAllowedByPolicy, "admin on the whitelist");
    }

    /// @notice An Earn program's refunds are in the vault asset, so the portal, Zone admin and
    ///         refund recipient are checked against the asset's policy as well.
    function test_preflightForAnEarnShareChecksTheRefundPath() public {
        _deployZone(false);
        address router = _deployRouter();
        Preflight preflight = new Preflight();
        address[] memory vaults = new address[](1);
        vaults[0] = address(earnVault);

        Preflight.Report memory r = _earnPreflight(preflight, router, vaults);
        assertTrue(r.assetRefundsAllowedByPolicy, "open asset policy");
        assertTrue(r.assetDepositsActive, "asset enabled on the portal");

        uint64 policy = StdPrecompiles.TIP403_REGISTRY.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
        vm.mockCall(address(usd), abi.encodeCall(ITIP20.transferPolicyId, ()), abi.encode(policy));
        r = _earnPreflight(preflight, router, vaults);
        assertFalse(r.assetRefundsAllowedByPolicy, "nobody on the asset whitelist");
        preflight.print(r, vaults);

        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(policy, address(portal), true);
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(policy, portal.admin(), true);
        r = _earnPreflight(preflight, router, vaults);
        assertTrue(r.assetRefundsAllowedByPolicy, "portal and admin whitelisted");

        // A bounced refund goes to the refund recipient, so it must be on the asset's policy too.
        address refundRecipient = makeAddr("refund-recipient");
        r = preflight.check(
            SpenderFactory(address(bridgeFactory)),
            SPENDER_ID,
            settlement,
            address(earnShare),
            ZONE_ID,
            routerFactory,
            router,
            refundRecipient,
            programWallet,
            vaults
        );
        assertFalse(r.assetRefundsAllowedByPolicy, "refund recipient not on the asset whitelist");
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(policy, refundRecipient, true);
        r = preflight.check(
            SpenderFactory(address(bridgeFactory)),
            SPENDER_ID,
            settlement,
            address(earnShare),
            ZONE_ID,
            routerFactory,
            router,
            refundRecipient,
            programWallet,
            vaults
        );
        assertTrue(r.assetRefundsAllowedByPolicy, "refund recipient whitelisted");

        vm.mockCall(address(portal), abi.encodeCall(IZonePortal.isTokenEnabled, (address(usd))), abi.encode(false));
        r = _earnPreflight(preflight, router, vaults);
        assertFalse(r.assetDepositsActive, "asset not enabled on the portal");
    }

    /// @notice With an EarnShare as TOKEN, the clone is checked against the share's policy, and the
    ///         settlement and program wallets against the vault asset's.
    function test_preflightForAnEarnShareChecksTheClone() public {
        _deployZone(false);
        Preflight preflight = new Preflight();
        address[] memory vaults = new address[](1);
        vaults[0] = address(earnVault);
        // A whitelist with nobody on it yet.
        uint64 policy = StdPrecompiles.TIP403_REGISTRY.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
        vm.mockCall(address(earnShare), abi.encodeCall(ITIP20.transferPolicyId, ()), abi.encode(policy));

        Preflight.Report memory r = _earnPreflight(preflight, address(0), vaults);
        assertTrue(r.tokenIsEarnShare);
        assertFalse(r.cloneAllowedByPolicy, "clone not on the share whitelist");
        assertFalse(r.vaultAllowedByPolicy, "vault not on the share whitelist");
        assertFalse(r.portalAllowedByPolicy, "portal not on the share whitelist");
        assertFalse(r.messengerAllowedByPolicy, "messenger not on the share whitelist");
        assertTrue(r.settlementAllowedByPolicy, "settlement checked against the vault asset");
        assertTrue(r.programWalletAllowedByPolicy, "program wallet checked against the vault asset");
        preflight.print(r, vaults);

        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(policy, spender, true);
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(policy, address(earnVault), true);
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(policy, address(portal), true);
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(policy, ZONE_MESSENGER_ADDRESS, true);
        r = _earnPreflight(preflight, address(0), vaults);
        assertTrue(r.cloneAllowedByPolicy, "clone on the share whitelist");
        assertTrue(r.vaultAllowedByPolicy, "vault on the share whitelist");
        assertTrue(r.portalAllowedByPolicy, "portal on the share whitelist");
        assertTrue(r.messengerAllowedByPolicy, "messenger on the share whitelist");
    }

    /// @notice A VAULTS entry that answers `earnShare()` with no data still yields the whole report.
    function test_preflightWithAVaultThatReturnsNothing() public {
        _deployZone(false);
        Preflight preflight = new Preflight();
        address[] memory vaults = new address[](1);
        vaults[0] = address(new SilentFallback());
        Preflight.Report memory r = _earnPreflight(preflight, address(0), vaults);
        assertFalse(r.tokenIsEarnShare);
        assertTrue(r.handlerUsable, "the rest of the report still runs");
        preflight.print(r, vaults);
    }

    function _earnPreflight(Preflight preflight, address router, address[] memory vaults)
        internal
        returns (Preflight.Report memory)
    {
        return preflight.check(
            SpenderFactory(address(bridgeFactory)),
            SPENDER_ID,
            settlement,
            address(earnShare),
            ZONE_ID,
            routerFactory,
            router,
            address(0),
            programWallet,
            vaults
        );
    }

    /// @notice An ID a manager added to an existing clone is reported, since "TS" rejects it.
    function test_preflightReportsAnIdAddedToAnExistingClone() public {
        _deployZone(false);
        bytes32 aliasId = keccak256("alias");
        address[] memory destinations = new address[](1);
        destinations[0] = settlement;
        vm.prank(bridgeManager);
        bridgeFactory.createSpenderWithExistingContract(aliasId, destinations, spender);
        Preflight.Report memory r = new Preflight()
            .check(
                SpenderFactory(address(bridgeFactory)),
                aliasId,
                settlement,
                address(usd),
                ZONE_ID,
                ZoneRouterFactory(address(0)),
                address(0),
                address(0),
                programWallet,
                new address[](0)
            );
        assertEq(r.clone, spender);
        assertFalse(r.programCanonical);
    }

    function _preflight(Preflight preflight, address router, address refund, address[] memory vaults)
        internal
        returns (Preflight.Report memory)
    {
        return preflight.check(
            SpenderFactory(address(bridgeFactory)),
            SPENDER_ID,
            settlement,
            address(usd),
            ZONE_ID,
            routerFactory,
            router,
            refund,
            programWallet,
            vaults
        );
    }

    function test_deployRouterRejectsUnknownProgram() public {
        _deployZone(true);
        DeployZoneRouter script = _newDeployZoneRouter();
        vm.expectRevert(SpenderFactoryErrorsAndEvents.UnknownSpender.selector);
        script.deploy(
            IBridgeSpenderFactory(address(bridgeFactory)),
            keccak256("unknown.program"),
            ZONE_ID,
            ZoneRouterFactory(address(0)),
            DEPLOYER_PK
        );
    }

    /// @notice Replacing a handler governance turned off writes no gate call, so the replacement
    ///         stays off until governance acts.
    function test_replacementOfADisabledHandlerStaysOff() public {
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderHandlerStatus(PREFIX_TEMPO_SPEND, SpenderStatus.Disabled);
        DeployTempoSpend.Output memory o = new DeployTempoSpend().deploy(address(bridgeFactory), DEPLOYER_PK);
        assertFalse(o.firstRegistration);
        assertEq(o.status, "Disabled");
        assertEq(o.governanceGateHandler.length, 0, "no gate call");
    }

    /// @notice A prefix whose handler was removed while `Enabled` is not lowered to `Gated`.
    function test_zeroedEnabledHandlerKeepsItsStatus() public {
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, ISpenderHandler(address(0)));
        DeployTempoSpend.Output memory o = new DeployTempoSpend().deploy(address(bridgeFactory), DEPLOYER_PK);
        assertTrue(o.firstRegistration);
        assertEq(o.status, "Enabled");
        assertEq(o.governanceGateHandler.length, 0, "no gate call");
    }

    function test_deployRejectsAFactoryWithoutCode() public {
        DeployTempoSpend script = new DeployTempoSpend();
        vm.expectRevert(bytes("FACTORY has no code"));
        script.deploy(makeAddr("no.factory"), DEPLOYER_PK);
    }

    /// @notice While the handler is gated, the factory refuses the program's vault call until
    ///         governance allowlists the program, which is why ProgramCalls orders them.
    function test_vaultCallRefusedBeforeTheProgramIsAllowlisted() public {
        _clearTempoSpendHandler();
        DeployTempoSpend.Output memory handler = new DeployTempoSpend().deploy(address(bridgeFactory), DEPLOYER_PK);
        _submit(bridgeAdmin, handler.adminRegisterHandler);
        _submit(bridgeGovernor, handler.governanceGateHandler);
        address[] memory vaults = new address[](1);
        vaults[0] = address(earnVault);
        ProgramCalls.Output memory program =
            new ProgramCalls().calls(SpenderFactory(address(bridgeFactory)), SPENDER_ID, vaults);
        vm.expectRevert(SpenderFactoryErrorsAndEvents.SpenderHandlerNotAllowed.selector);
        this.submitAs(bridgeGovernor, program.governanceAllowVaults[0]);
    }

    /// @notice A spender ID a manager added to an existing clone cannot spend, so neither script
    ///         writes calls or deploys a settler and router for it.
    function test_scriptsRejectAnIdAddedToAnExistingClone() public {
        _deployZone(false);
        bytes32 aliasId = _aliasOfTheClone();
        ProgramCalls calls = new ProgramCalls();
        vm.expectRevert(bytes("SPENDER_ID was added to an existing clone, which TS rejects"));
        calls.calls(SpenderFactory(address(bridgeFactory)), aliasId, new address[](0));
        DeployZoneRouter router = _newDeployZoneRouter();
        vm.expectRevert(bytes("SPENDER_ID was added to an existing clone, which TS rejects"));
        router.deploy(
            IBridgeSpenderFactory(address(bridgeFactory)), aliasId, ZONE_ID, ZoneRouterFactory(address(0)), DEPLOYER_PK
        );
    }

    function test_deployRouterRejectsAZoneWithoutAPortal() public {
        _deployZone(false);
        ZoneInfo memory none;
        vm.mockCall(ZONE_FACTORY_ADDRESS, abi.encodeCall(IZoneFactory.zones, (uint32(99))), abi.encode(none));
        DeployZoneRouter script = _newDeployZoneRouter();
        vm.expectRevert(bytes("ZONE_ID has no portal"));
        script.deploy(
            IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, 99, ZoneRouterFactory(address(0)), DEPLOYER_PK
        );
    }

    function test_programCallsRejectAVaultThatIsNotAnEarnVault() public {
        address notAVault = address(new SilentFallback());
        vm.mockCall(notAVault, abi.encodeWithSignature("earnShare()"), abi.encode(address(0)));
        address[] memory vaults = new address[](1);
        vaults[0] = notAVault;
        ProgramCalls script = new ProgramCalls();
        vm.expectRevert(bytes("not an Earn vault"));
        script.calls(SpenderFactory(address(bridgeFactory)), SPENDER_ID, vaults);
    }

    /// @notice A vault whose engine cannot withdraw an exact amount would fail every spend, and one
    ///         that cannot preview a redemption shows no Earn balance, so ProgramCalls refuses
    ///         both and the preflight reports them.
    function test_vaultWithoutEarnSpendSupportIsRejectedAndReported() public {
        _deployZone(false);
        address[] memory vaults = new address[](1);
        vaults[0] = address(earnVault);
        bytes4[2] memory capabilities =
            [type(IEarnEngineExactWithdraw).interfaceId, type(IEarnEngineRedeem).interfaceId];
        ProgramCalls script = new ProgramCalls();
        Preflight preflight = new Preflight();
        for (uint256 i; i < capabilities.length; ++i) {
            if (i > 0) _mockCapability(capabilities[i - 1], true);
            _mockCapability(capabilities[i], false);
            vm.expectRevert(bytes("vault engine lacks exact withdrawals or redeem previews"));
            script.calls(SpenderFactory(address(bridgeFactory)), SPENDER_ID, vaults);

            Preflight.Report memory r = _preflight(preflight, address(0), address(0), vaults);
            assertFalse(r.vaultsSpendable[0]);
            preflight.print(r, vaults);
        }
    }

    /// @notice A "TS" handler with no code, or one built for another factory, is reported. The
    ///         clone would delegatecall it without checking, so every spend would do nothing.
    function test_preflightReportsAHandlerThatIsNotThisFactorys() public {
        _deployZone(false);
        Preflight preflight = new Preflight();
        address[2] memory handlers = [makeAddr("no.code"), address(new SpenderTempoSpend(IFactory(makeAddr("other"))))];
        for (uint256 i; i < handlers.length; ++i) {
            vm.prank(bridgeAdmin);
            bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, ISpenderHandler(handlers[i]));
            Preflight.Report memory r = _preflight(preflight, address(0), address(0), new address[](0));
            assertFalse(r.handlerValid);
            preflight.print(r, new address[](0));
        }
    }

    /// @notice A handler or settler built from other code is reported, even when it answers the
    ///         identity checks, since an older build lacks checks this one makes.
    function test_preflightReportsAHandlerOrSettlerFromAnotherBuild() public {
        _deployZone(false);
        Preflight preflight = new Preflight();
        ISpenderHandler other = ISpenderHandler(address(new NoopSpendHandler(IFactory(address(bridgeFactory)))));
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, other);
        address older = address(new OlderBridgeSettler(address(bridgeFactory), SPENDER_ID));
        routerFactory = ZoneRouterFactory(deployCode("ZoneRouterFactory.sol:ZoneRouterFactory"));
        address router = routerFactory.deploy(_spendMode(ZONE_ID, older));

        Preflight.Report memory r = _preflight(preflight, router, address(0), new address[](0));
        assertTrue(r.handlerValid, "handler belongs to the factory");
        assertFalse(r.handlerCurrent, "handler is another build");
        assertTrue(r.routerMatches, "settler answers for the program");
        assertEq(r.settler, older);
        assertFalse(r.settlerCurrent, "settler is another build");
        preflight.print(r, new address[](0));
    }

    /// @notice Code that differs from this repo's build only in solc's metadata, as a build from
    ///         source with other comments would, reads as current. A change to the code does not.
    function test_preflightIgnoresOnlySolcMetadata() public {
        _deployZone(false);
        Preflight preflight = new Preflight();
        bytes memory code = address(bridgeFactory.getSpenderHandler(PREFIX_TEMPO_SPEND)).code;
        uint256 metadata = (uint256(uint8(code[code.length - 2])) << 8) | uint256(uint8(code[code.length - 1]));

        bytes memory otherMetadata = bytes.concat(code);
        otherMetadata[code.length - 3] = otherMetadata[code.length - 3] ^ 0x01;
        Preflight.Report memory r = _preflightWithHandlerCode(preflight, otherMetadata);
        assertTrue(r.handlerValid);
        assertTrue(r.handlerCurrent, "only the metadata differs");

        // The last byte before the metadata is unreachable, so the handler still works.
        bytes memory otherCode = bytes.concat(code);
        uint256 last = code.length - metadata - 3;
        otherCode[last] = otherCode[last] ^ 0x01;
        r = _preflightWithHandlerCode(preflight, otherCode);
        assertTrue(r.handlerValid);
        assertFalse(r.handlerCurrent, "the code differs");
    }

    function _preflightWithHandlerCode(Preflight preflight, bytes memory code)
        internal
        returns (Preflight.Report memory)
    {
        address handler = address(uint160(uint256(keccak256(code))));
        vm.etch(handler, code);
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, ISpenderHandler(handler));
        return _preflight(preflight, address(0), address(0), new address[](0));
    }

    /// @notice `run` reads every input from the environment and refuses a ZONE_ID the Zone
    ///         factory's `uint32` IDs cannot hold.
    function test_runReadsTheEnvironment() public {
        _deployZone(false);
        vm.setEnv("FACTORY", vm.toString(address(bridgeFactory)));
        vm.setEnv("DEPLOYER_PK", vm.toString(DEPLOYER_PK));
        vm.setEnv("SPENDER_ID", vm.toString(SPENDER_ID));
        vm.setEnv("SETTLEMENT", vm.toString(settlement));
        vm.setEnv("TOKEN", vm.toString(address(usd)));
        vm.setEnv("OUT", "reports/test-run.json");

        SpenderTempoSpend handler = new DeployTempoSpend().run();
        assertEq(address(handler.FACTORY()), address(bridgeFactory));
        new ProgramCalls().run();
        assertEq(
            vm.parseJsonBytes(vm.readFile("reports/test-run.json"), ".governanceAllowlistProgram"),
            abi.encodeCall(SpenderFactory.updateSpenderHandlerAllowlist, (PREFIX_TEMPO_SPEND, SPENDER_ID, true))
        );
        vm.setEnv("ZONE_ID", vm.toString(uint256(ZONE_ID)));
        ZoneRouter router = _newDeployZoneRouter().run();
        assertEq(router.allowedZoneId(), ZONE_ID);
        new Preflight().run();

        DeployZoneRouter deployRouter = _newDeployZoneRouter();
        Preflight preflight = new Preflight();
        vm.setEnv("ROUTER", vm.toString(address(router)));
        preflight.run();
        vm.setEnv("ZONE_ID", vm.toString(uint256(type(uint32).max) + uint256(ZONE_ID)));
        vm.expectRevert(bytes("ZONE_ID out of range"));
        deployRouter.run();
        vm.expectRevert(bytes("ZONE_ID out of range"));
        preflight.run();
        vm.setEnv("ZONE_ID", "0");
        vm.expectRevert(bytes("ZONE_ID out of range"));
        preflight.run();
    }

    /// @dev Deploys the program's settler and Spend-mode router for ZONE_ID with the deploy script,
    ///      remembering its router factory for `_preflight`.
    function _deployRouter() internal returns (address) {
        DeployZoneRouter.Output memory o = _newDeployZoneRouter()
            .deploy(
                IBridgeSpenderFactory(address(bridgeFactory)),
                SPENDER_ID,
                ZONE_ID,
                ZoneRouterFactory(address(0)),
                DEPLOYER_PK
            );
        routerFactory = o.routerFactory;
        return address(o.router);
    }

    /// @dev The deploy script, the router factory and the router are deployed from their artifacts:
    ///      their creation code nests the router's, and inlined here it would push this test past
    ///      what the compiler can assemble.
    function _newDeployZoneRouter() internal returns (DeployZoneRouter) {
        return DeployZoneRouter(deployCode("DeployZoneRouter.s.sol:DeployZoneRouter"));
    }

    function _spendMode(uint32 zoneId, address settler) internal pure returns (ZoneRouter.Mode memory mode) {
        mode.zoneId = zoneId;
        mode.enabledOps = uint8(1 << 2);
        mode.settlers = new address[](1);
        mode.settlers[0] = settler;
    }

    function submitAs(address role, bytes memory data) external {
        _submit(role, data);
    }

    function _aliasOfTheClone() internal returns (bytes32 aliasId) {
        aliasId = keccak256("alias");
        address[] memory destinations = new address[](1);
        destinations[0] = settlement;
        vm.prank(bridgeManager);
        bridgeFactory.createSpenderWithExistingContract(aliasId, destinations, spender);
    }

    function _mockCapability(bytes4 interfaceId, bool supported) internal {
        (, bytes memory data) = address(earnVault).staticcall(abi.encodeWithSignature("engine()"));
        vm.mockCall(
            abi.decode(data, (address)), abi.encodeCall(IERC165.supportsInterface, (interfaceId)), abi.encode(supported)
        );
    }

    /// @dev A factory that never had a "TS" handler: no handler, status back to `Disabled`.
    function _clearTempoSpendHandler() internal {
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, ISpenderHandler(address(0)));
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderHandlerStatus(PREFIX_TEMPO_SPEND, SpenderStatus.Disabled);
    }

    function _submit(address role, bytes memory data) internal {
        vm.prank(role);
        (bool ok, bytes memory err) = address(bridgeFactory).call(data);
        if (!ok) {
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }
    }

    function _approve(uint256 amount) internal {
        vm.prank(alice);
        usd.approve(spender, amount);
    }

    function _stable(uint256 amount) internal view returns (Spend memory) {
        return Spend({
            spenderId: SPENDER_ID,
            token: address(usd),
            amount: amount,
            destination: settlement,
            vault: address(0),
            fromVault: 0,
            maxShares: 0,
            ref: bytes32(0)
        });
    }
}

/// @dev Answers every call with success and no return data.
contract SilentFallback {
    fallback() external { }
}
