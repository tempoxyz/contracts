// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ISpenderHandler, SpenderStatus } from "bridge-spender/src/ISpenderHandler.sol";
import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { SpenderFactoryErrorsAndEvents } from "bridge-spender/src/SpenderFactoryErrorsAndEvents.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

import { DeployTempoSpend } from "../../script/deploy/DeployTempoSpend.s.sol";
import { DeployZoneReceiver } from "../../script/deploy/DeployZoneReceiver.s.sol";
import { Preflight } from "../../script/deploy/Preflight.s.sol";
import { ProgramCalls } from "../../script/deploy/ProgramCalls.s.sol";
import { Spend } from "../../src/SpenderTempoSpend.sol";
import { SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { NoopSpendHandler, OlderZoneSpendReceiver } from "../harness/Mocks.sol";
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

/// @notice The deployment scripts against an existing Bridge factory: deploy, submit the calls
///         they write with the role each one needs, then spend.
contract DeployScriptsTest is ZoneEnv {
    uint256 internal constant DEPLOYER_PK = uint256(keccak256("tempo.deployer"));

    address internal alice = makeAddr("alice");

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

    function test_deployReceiverForAProgramAndZone() public {
        _deployZone(true);
        DeployZoneReceiver script = new DeployZoneReceiver();
        DeployZoneReceiver.Output memory o =
            script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, ZONE_ID, DEPLOYER_PK);
        assertEq(address(o.receiver.FACTORY()), address(bridgeFactory));
        assertEq(o.receiver.SPENDER_ID(), SPENDER_ID);
        assertEq(o.receiver.ZONE_ID(), ZONE_ID);

        string memory path = "reports/test-deploy-zone-receiver.json";
        script.write(o, path);
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".receiver"), address(o.receiver));
        assertEq(vm.parseJsonAddress(json, ".clone"), spender);
        assertEq(vm.parseJsonAddress(json, ".portal"), address(portal));
    }

    /// @notice The preflight reports a deployed receiver and refund account that still lack their
    ///         closed-loop Zone roles, then passes once the Zone admin grants them.
    function test_preflightReportsZoneRolesStillMissing() public {
        _deployZone(true);
        DeployZoneReceiver.Output memory o = new DeployZoneReceiver()
            .deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, ZONE_ID, DEPLOYER_PK);
        address refund = makeAddr("bridge.refund-recipient");
        address[] memory vaults = new address[](1);
        vaults[0] = address(earnVault);
        Preflight preflight = new Preflight();

        Preflight.Report memory r = _preflight(preflight, address(o.receiver), refund, vaults);
        assertTrue(r.programCanonical, "clone created for the ID");
        assertTrue(r.handlerValid, "handler has code and belongs to the factory");
        assertTrue(r.handlerCurrent, "handler is this repo's build");
        assertTrue(r.receiverCurrent, "receiver is this repo's build");
        assertTrue(r.messengerAllowedByPolicy, "messenger allowed by policy");
        assertTrue(r.portalAllowedByPolicy, "portal allowed by policy");
        assertTrue(r.vaultsSpendable[0], "vault engine supports Earn spends");
        assertTrue(r.handlerUsable, "TS usable");
        assertTrue(r.destinationAuthorized, "destination");
        assertTrue(r.programWalletAuthorized, "program wallet can pay refunds");
        assertTrue(r.tokenEnabled, "token enabled");
        assertTrue(r.accessEnforced && !r.gatewayOpen, "closed loop");
        assertTrue(r.receiverMatches, "receiver matches");
        assertTrue(r.vaultsAllowed[0], "vault allowed");
        assertTrue(r.depositsActive, "deposits active");
        assertTrue(r.settlementAllowedByPolicy, "settlement allowed by policy");
        assertTrue(r.receiverAllowedByPolicy, "receiver allowed by policy");
        assertTrue(r.refundRecipientAllowedByPolicy, "refund recipient allowed by policy");
        assertTrue(r.programWalletAllowedByPolicy, "program wallet allowed by policy");
        assertTrue(r.zoneAdminAllowedByPolicy, "Zone admin allowed by policy");
        assertFalse(r.tokenIsEarnShare, "a stablecoin TOKEN");
        assertFalse(r.receiverAdmitted, "receiver not yet a gateway");
        assertFalse(r.refundRecipientAdmitted, "refund account not yet admitted");

        _zoneRegisterGateway(address(o.receiver));
        _zoneAllowAccount(refund);
        r = _preflight(preflight, address(o.receiver), refund, vaults);
        assertTrue(r.receiverAdmitted, "receiver is a gateway");
        assertTrue(r.refundRecipientAdmitted, "refund account admitted");
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
                address(0),
                address(0),
                programWallet,
                new address[](0)
            );
        assertEq(r.clone, address(0));
        assertFalse(r.programCanonical);
        assertFalse(r.handlerUsable);
        assertFalse(r.destinationAuthorized);
        assertFalse(r.programWalletAuthorized);
        assertTrue(r.paused);
        assertFalse(r.receiverMatches);
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

    /// @notice A program wallet that is not a destination is reported, since `refundPrivate` would
    ///         reject every refund it pays.
    function test_preflightReportsAProgramWalletThatCannotPayRefunds() public {
        _deployZone(false);
        Preflight preflight = new Preflight();
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderDestination(SPENDER_ID, programWallet, false);
        Preflight.Report memory r = _preflight(preflight, address(0), address(0), new address[](0));
        assertFalse(r.programWalletAuthorized);
        assertTrue(r.destinationAuthorized, "settlement is still a destination");
        preflight.print(r, new address[](0));
    }

    /// @notice A program wallet the token's policy will not let send is reported, since
    ///         `refundPrivate` pulls each refund from it.
    function test_preflightReportsAProgramWalletThePolicyBlocks() public {
        _deployZone(false);
        Preflight preflight = new Preflight();
        vm.mockCall(
            address(StdPrecompiles.TIP403_REGISTRY),
            abi.encodeCall(ITIP403Registry.isAuthorizedSender, (usd.transferPolicyId(), programWallet)),
            abi.encode(false)
        );
        Preflight.Report memory r = _preflight(preflight, address(0), address(0), new address[](0));
        assertTrue(r.programWalletAuthorized, "still a destination");
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

    /// @notice An Earn program's refunds are in the vault asset, so the receiver, portal and Zone
    ///         admin are checked against the asset's policy as well.
    function test_preflightForAnEarnShareChecksTheRefundPath() public {
        _deployZone(false);
        DeployZoneReceiver.Output memory o = new DeployZoneReceiver()
            .deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, ZONE_ID, DEPLOYER_PK);
        Preflight preflight = new Preflight();
        address[] memory vaults = new address[](1);
        vaults[0] = address(earnVault);

        Preflight.Report memory r = _earnPreflight(preflight, address(o.receiver), vaults);
        assertTrue(r.assetRefundsAllowedByPolicy, "open asset policy");
        assertTrue(r.assetDepositsActive, "asset enabled on the portal");

        uint64 policy = StdPrecompiles.TIP403_REGISTRY.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
        vm.mockCall(address(usd), abi.encodeCall(ITIP20.transferPolicyId, ()), abi.encode(policy));
        r = _earnPreflight(preflight, address(o.receiver), vaults);
        assertFalse(r.assetRefundsAllowedByPolicy, "nobody on the asset whitelist");
        preflight.print(r, vaults);

        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(policy, address(o.receiver), true);
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(policy, address(portal), true);
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(policy, portal.admin(), true);
        r = _earnPreflight(preflight, address(o.receiver), vaults);
        assertTrue(r.assetRefundsAllowedByPolicy, "receiver, portal and admin whitelisted");

        // A bounced refund goes to the refund recipient, so it must be on the asset's policy too.
        address refundRecipient = makeAddr("refund-recipient");
        r = preflight.check(
            SpenderFactory(address(bridgeFactory)),
            SPENDER_ID,
            settlement,
            address(earnShare),
            ZONE_ID,
            address(o.receiver),
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
            address(o.receiver),
            refundRecipient,
            programWallet,
            vaults
        );
        assertTrue(r.assetRefundsAllowedByPolicy, "refund recipient whitelisted");

        vm.mockCall(address(portal), abi.encodeCall(IZonePortal.isTokenEnabled, (address(usd))), abi.encode(false));
        r = _earnPreflight(preflight, address(o.receiver), vaults);
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

    function _earnPreflight(Preflight preflight, address receiver, address[] memory vaults)
        internal
        returns (Preflight.Report memory)
    {
        return preflight.check(
            SpenderFactory(address(bridgeFactory)),
            SPENDER_ID,
            settlement,
            address(earnShare),
            ZONE_ID,
            receiver,
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
                address(0),
                address(0),
                programWallet,
                new address[](0)
            );
        assertEq(r.clone, spender);
        assertFalse(r.programCanonical);
    }

    function _preflight(Preflight preflight, address receiver, address refund, address[] memory vaults)
        internal
        returns (Preflight.Report memory)
    {
        return preflight.check(
            SpenderFactory(address(bridgeFactory)),
            SPENDER_ID,
            settlement,
            address(usd),
            ZONE_ID,
            receiver,
            refund,
            programWallet,
            vaults
        );
    }

    function test_deployReceiverRejectsUnknownProgram() public {
        _deployZone(true);
        DeployZoneReceiver script = new DeployZoneReceiver();
        vm.expectRevert(SpenderFactoryErrorsAndEvents.UnknownSpender.selector);
        script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), keccak256("unknown.program"), ZONE_ID, DEPLOYER_PK);
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
    ///         writes calls or deploys a receiver for it.
    function test_scriptsRejectAnIdAddedToAnExistingClone() public {
        _deployZone(false);
        bytes32 aliasId = _aliasOfTheClone();
        ProgramCalls calls = new ProgramCalls();
        vm.expectRevert(bytes("SPENDER_ID was added to an existing clone, which TS rejects"));
        calls.calls(SpenderFactory(address(bridgeFactory)), aliasId, new address[](0));
        DeployZoneReceiver receiver = new DeployZoneReceiver();
        vm.expectRevert(bytes("SPENDER_ID was added to an existing clone, which TS rejects"));
        receiver.deploy(IBridgeSpenderFactory(address(bridgeFactory)), aliasId, ZONE_ID, DEPLOYER_PK);
    }

    function test_deployReceiverRejectsAZoneWithoutAPortal() public {
        _deployZone(false);
        ZoneInfo memory none;
        vm.mockCall(ZONE_FACTORY_ADDRESS, abi.encodeCall(IZoneFactory.zones, (uint32(99))), abi.encode(none));
        DeployZoneReceiver script = new DeployZoneReceiver();
        vm.expectRevert(bytes("ZONE_ID has no portal"));
        script.deploy(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, 99, DEPLOYER_PK);
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

    /// @notice A handler or receiver built from other code is reported, even when it answers the
    ///         identity checks, since an older build lacks checks this one makes.
    function test_preflightReportsAHandlerOrReceiverFromAnotherBuild() public {
        _deployZone(false);
        Preflight preflight = new Preflight();
        ISpenderHandler other = ISpenderHandler(address(new NoopSpendHandler(IFactory(address(bridgeFactory)))));
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, other);
        address older = address(new OlderZoneSpendReceiver(address(bridgeFactory), SPENDER_ID, ZONE_ID));

        Preflight.Report memory r = _preflight(preflight, older, address(0), new address[](0));
        assertTrue(r.handlerValid, "handler belongs to the factory");
        assertFalse(r.handlerCurrent, "handler is another build");
        assertTrue(r.receiverMatches, "receiver answers for the program and Zone");
        assertFalse(r.receiverCurrent, "receiver is another build");
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
        assertEq(new DeployZoneReceiver().run().ZONE_ID(), ZONE_ID);
        new Preflight().run();

        DeployZoneReceiver receiver = new DeployZoneReceiver();
        Preflight preflight = new Preflight();
        vm.setEnv("ZONE_ID", vm.toString(uint256(type(uint32).max) + uint256(ZONE_ID)));
        vm.expectRevert(bytes("ZONE_ID out of range"));
        receiver.run();
        vm.expectRevert(bytes("ZONE_ID out of range"));
        preflight.run();
        vm.setEnv("ZONE_ID", "0");
        vm.expectRevert(bytes("ZONE_ID out of range"));
        preflight.run();
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
