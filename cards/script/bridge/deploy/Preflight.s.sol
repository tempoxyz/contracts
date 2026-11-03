// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ERC1967Utils } from "openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { IAddressRegistry } from "tempo-std/interfaces/IAddressRegistry.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import {
    IZoneFactory,
    IZonePortal,
    Role,
    ZONE_FACTORY_ADDRESS,
    ZONE_MESSENGER_ADDRESS,
    ZoneInfo
} from "tempo-zones/interfaces/IZone.sol";

import { SpenderDelegator } from "bridge-spender/src/SpenderDelegator.sol";
import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";

import { ZoneRouter } from "zone-router/ZoneRouter.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";

import { ITempoEarnVault } from "../../../src/core/interfaces/ITempoEarnVault.sol";
import { SpenderTempoSpend } from "../../../src/providers/bridge/SpenderTempoSpend.sol";
import { BridgeProgramRelease } from "./BridgeRelease.sol";
import { ProgramChecks } from "./ProgramChecks.sol";

/// @notice Read-only check of one card program before private spend goes live: the "TS" handler,
///         the program and its destination, the Zone's portal and token, the program's Spend-mode
///         router and the `CardSpender` it lists as its spender, and the Zone roles of the router, the
///         refund recipient and the program wallet that deposits refunds, Bridge's trust anchors (its
///         default admin, the factory's implementation, the clones' delegator and beacon), and the warm-ups
///         and seeds a spend's callback gas assumes. Nothing is sent: the script
///         deploys copies of the handler, the program's `BridgeProvider` and its `CardSpender` only in its
///         own simulation, to compare their code. `run` reads
///         FACTORY, SPENDER_ID, SETTLEMENT, TOKEN, ZONE_ID, ROUTER_FACTORY and ROUTER (optional),
///         REFUND_RECIPIENT (optional), PROGRAM_WALLET (optional) and VAULTS (comma separated,
///         optional), and prints each missing step with who submits it. For an Earn spend, TOKEN is the EarnShare of one of
///         VAULTS, and the settlement wallet and program wallet are checked against its asset. A settlement
///         wallet that is a TIP-1022 virtual address is checked through the master its transfers credit.
contract Preflight is BridgeProgramRelease {
    bytes2 internal constant PREFIX = "TS";

    struct Report {
        address clone;
        /// @dev `createSpender(spenderId)` deployed the clone, which "TS" requires.
        bool programCanonical;
        address handler;
        /// @dev The handler has code and was built for this factory. The clone delegatecalls it with
        ///      no code check, so an empty address would make every spend a silent no-op.
        bool handlerValid;
        /// @dev The handler runs this repo's code, ignoring solc's metadata, so it has every check
        ///      this version adds.
        bool handlerCurrent;
        /// @dev The factory runs "TS" for this program: enabled, or gated with the program allowed.
        bool handlerUsable;
        bool destinationAuthorized;
        bool paused;
        /// @dev TOKEN is the EarnShare of one of VAULTS.
        bool tokenIsEarnShare;
        /// @dev The stablecoin the destination receives: TOKEN, or the vault asset when TOKEN is an EarnShare.
        address stablecoin;
        /// @dev The vault whose EarnShare TOKEN is; zero otherwise.
        address earnVault;
        /// @dev The policy of the stablecoin the destination receives lets the settlement wallet
        ///      receive it: TOKEN's, or the vault asset's when TOKEN is an EarnShare.
        bool settlementAllowedByPolicy;
        /// @dev The policy lets the router receive the withdrawal and send it on and back.
        bool routerAllowedByPolicy;
        /// @dev The policy lets the program receive the input it uses and send it on and back, and so
        ///      does the stablecoin's, which a public spend moves through it.
        bool programAllowedByPolicy;
        /// @dev The policy lets the refund recipient receive a rejected Zone return.
        bool refundRecipientAllowedByPolicy;
        /// @dev The stablecoin's policy lets the program wallet send, which its refund deposits into
        ///      the Zone need.
        bool programWalletAllowedByPolicy;
        /// @dev The EarnShare's policy lets the clone receive and send, since an Earn spend moves
        ///      shares through it.
        bool cloneAllowedByPolicy;
        /// @dev The EarnShare's policy lets its vault receive the shares a spend burns.
        bool vaultAllowedByPolicy;
        /// @dev The EarnShare's policy lets the portal send withdrawals and receive returns.
        bool portalAllowedByPolicy;
        /// @dev The token's policy lets the Zone admin receive, since the portal pays it the
        ///      deposit fee of every Zone return and private refund.
        bool zoneAdminAllowedByPolicy;
        /// @dev For an EarnShare TOKEN, the vault asset's policy lets a private refund reach the
        ///      Zone: the portal receives and sends, and the Zone admin and refund recipient receive.
        bool assetRefundsAllowedByPolicy;
        /// @dev For an EarnShare TOKEN, the portal takes deposits of the vault asset, which
        ///      refunds are paid in.
        bool assetDepositsActive;
        address portal;
        bool tokenEnabled;
        /// @dev The portal is not paused and takes deposits of the token, which every Zone return
        ///      and private refund is.
        bool depositsActive;
        bool accessEnforced;
        bool gatewayOpen;
        /// @dev ROUTER_FACTORY deployed ROUTER, so its mode is fixed and public.
        bool routerFromFactory;
        /// @dev ROUTER takes Spend callbacks from this Zone and lists a `CardSpender` for this program.
        bool routerMatches;
        /// @dev The `CardSpender` ROUTER lists whose provider is a `BridgeProvider` for this factory and program;
        ///      zero when it lists none.
        address program;
        /// @dev The program and its provider run this repo's code, ignoring solc's metadata, so they have
        ///      every check this version makes.
        bool programCurrent;
        /// @dev The router has the Zone role its callbacks need: callback gateway when the
        ///      gateway is closed, the account role when it is open and access is enforced.
        bool routerAdmitted;
        bool refundRecipientAdmitted;
        /// @dev The program wallet may deposit refunds into the Zone: it holds the account role
        ///      when access is enforced.
        bool programWalletAdmitted;
        /// @dev The portal's messenger is the canonical one and the token's policy lets it send and
        ///      receive, since every withdrawal passes through it.
        bool messengerAllowedByPolicy;
        bool[] vaultsAllowed;
        /// @dev Each vault's engine supports the exact withdrawals a spend makes and the redeem
        ///      previews `availableBalance` uses.
        bool[] vaultsSpendable;
        /// @dev Bridge's trust anchors, which this repository cannot change: the default admin upgrades
        ///      the factory and grants every role, after `defaultAdminDelay` for a new admin.
        address defaultAdmin;
        /// @dev The default admin answers `getMinDelay()`, as a TimelockController does.
        bool adminIsTimelock;
        uint256 adminMinDelay;
        uint48 defaultAdminDelay;
        /// @dev The factory proxy's ERC-1967 implementation slot.
        address factoryImplementation;
        /// @dev `factory.implementation()`, the `SpenderDelegator` every clone runs.
        address delegator;
        /// @dev The delegator runs this repo's `SpenderDelegator` for this factory, ignoring solc's metadata.
        bool delegatorCurrent;
        /// @dev The clone's ERC-1967 beacon slot names the factory, so its logic is the factory's delegator.
        bool cloneBeaconIsFactory;
        /// @dev SETTLEMENT is a TIP-1022 virtual address.
        bool settlementVirtual;
        /// @dev Who a transfer to SETTLEMENT credits: its registered master when virtual, else itself;
        ///      zero for a virtual address without one. The policy checks read this account.
        address settlementPayee;
        /// @dev The program is `bridgeProgramAddress(FACTORY, SPENDER_ID, ROUTER_FACTORY)`.
        bool programAtRelease;
        /// @dev The program takes `spendFrom` only from ROUTER_FACTORY's routers.
        bool programRouterFactory;
        /// @dev The settlement payee holds the stablecoin it receives, so no spend creates that balance.
        bool settlementFunded;
        /// @dev The program's standing approval of TOKEN to its payout target (`program.warm(TOKEN)`);
        ///      true for a program that pays directly, which has none.
        bool programWarm;
        /// @dev The router's standing approval of TOKEN to the portal (`router.warm(TOKEN)`).
        bool routerWarm;
        /// @dev The program and the router each hold some TOKEN, so no callback creates their balances.
        ///      Safe: only a router ROUTER_FACTORY deployed that lists the program may call `spendFrom`.
        bool programSeeded;
        bool routerSeeded;
        /// @dev For an EarnShare TOKEN, the clone holds some of it.
        bool cloneSeeded;
        /// @dev For an EarnShare TOKEN paid to a virtual settlement, the clone holds some of the vault asset, which
        ///      it redeems to itself and forwards on every such spend.
        bool cloneAssetSeeded;
        /// @dev For an EarnShare TOKEN paid to a virtual settlement, the vault asset's policy lets the clone
        ///      receive and send it.
        bool cloneAssetAllowedByPolicy;
        /// @dev The clone's standing approval of each vault's share to the vault (governance's `UV`).
        bool[] cloneVaultApproved;
        /// @dev The program pays directly, without a payout target.
        bool paysDirect;
        /// @dev For a program that pays directly, its standing share approval to each vault (`warmVault`).
        bool[] programVaultApproved;
    }

    function run() external {
        address[] memory vaults = vm.envOr("VAULTS", ",", new address[](0));
        Report memory r = check(
            SpenderFactory(vm.envAddress("FACTORY")),
            vm.envBytes32("SPENDER_ID"),
            vm.envAddress("SETTLEMENT"),
            vm.envAddress("TOKEN"),
            ProgramChecks.zoneId(vm.envUint("ZONE_ID")),
            ZoneRouterFactory(vm.envOr("ROUTER_FACTORY", address(0))),
            vm.envOr("ROUTER", address(0)),
            vm.envOr("REFUND_RECIPIENT", address(0)),
            vm.envOr("PROGRAM_WALLET", address(0)),
            vaults
        );
        print(r, vaults);
    }

    function check(
        SpenderFactory factory,
        bytes32 spenderId,
        address settlement,
        address token,
        uint32 zoneId,
        ZoneRouterFactory routerFactory,
        address router,
        address refundRecipient,
        address programWallet,
        address[] memory vaults
    ) public returns (Report memory r) {
        try factory.getSpenderAddress(spenderId) returns (address clone) {
            r.clone = clone;
        } catch { }
        r.programCanonical = ProgramChecks.isCanonical(address(factory), spenderId, r.clone);
        r.handler = address(factory.getSpenderHandler(PREFIX));
        (bool factoryOk, address handlerFactory) = ProgramChecks.readAddress(r.handler, bytes4(keccak256("FACTORY()")));
        r.handlerValid = factoryOk && handlerFactory == address(factory);
        r.handlerCurrent = r.handlerValid
            && ProgramChecks.sameLogic(r.handler, address(new SpenderTempoSpend(IFactory(address(factory)))));
        if (r.clone != address(0) && r.handler != address(0)) {
            try factory.getSpenderHandlerWithCheckedPermissions(PREFIX, r.clone) {
                r.handlerUsable = true;
            } catch { }
        }
        r.destinationAuthorized = r.clone != address(0) && factory.isAuthorizedDestination(spenderId, settlement);
        r.paused = factory.paused();
        _checkTrust(r, factory);
        (r.settlementVirtual, r.settlementPayee) = _payee(settlement);

        _findEarnShare(r, token, vaults);
        _checkPolicies(r, token, router, refundRecipient, programWallet);
        _checkVaults(r, vaults);
        _checkRouter(r, address(factory), spenderId, zoneId, routerFactory, router);
        r.programAllowedByPolicy = _movesThrough(token, r.program) && _movesThrough(r.stablecoin, r.program);
        _checkZone(r, token, zoneId, router, refundRecipient, programWallet);
        _checkGas(r, token, router, vaults);
    }

    /// @dev Whether TOKEN is the EarnShare of one of VAULTS, and so the stablecoin the destination receives.
    function _findEarnShare(Report memory r, address token, address[] memory vaults) private view {
        r.stablecoin = token;
        for (uint256 i; i < vaults.length; ++i) {
            (bool shareOk, address share) = ProgramChecks.readAddress(vaults[i], ITempoEarnVault.earnShare.selector);
            if (!shareOk || share != token) continue;
            (bool assetOk, address asset) = ProgramChecks.readAddress(vaults[i], ITempoEarnVault.asset.selector);
            if (assetOk) {
                r.tokenIsEarnShare = true;
                r.stablecoin = asset;
                r.earnVault = vaults[i];
            }
            break;
        }
    }

    /// @dev A token that is not a TIP-20 leaves its policy checks false instead of ending the report.
    function _checkPolicies(
        Report memory r,
        address token,
        address router,
        address refundRecipient,
        address programWallet
    ) private view {
        (bool stableOk, uint64 stablePolicy) = _policy(r.stablecoin);
        if (stableOk) {
            r.settlementAllowedByPolicy = r.settlementPayee != address(0)
                && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(stablePolicy, r.settlementPayee);
            r.programWalletAllowedByPolicy = programWallet != address(0)
                && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(stablePolicy, programWallet);
            r.cloneAssetAllowedByPolicy = _sendsAndReceives(stablePolicy, r.clone);
        }
        (bool tokenOk, uint64 tokenPolicy) = _policy(token);
        if (tokenOk) {
            r.routerAllowedByPolicy = _sendsAndReceives(tokenPolicy, router);
            r.refundRecipientAllowedByPolicy = refundRecipient != address(0)
                && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(tokenPolicy, refundRecipient);
            r.cloneAllowedByPolicy = r.clone != address(0)
                && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(tokenPolicy, r.clone)
                && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(tokenPolicy, r.clone);
            r.vaultAllowedByPolicy = r.earnVault != address(0)
                && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(tokenPolicy, r.earnVault);
        }
    }

    /// @dev The Zone's portal and token, and the Zone roles and policy of the accounts a spend reaches.
    function _checkZone(
        Report memory r,
        address token,
        uint32 zoneId,
        address router,
        address refundRecipient,
        address programWallet
    ) private view {
        ZoneInfo memory zone = IZoneFactory(ZONE_FACTORY_ADDRESS).zones(zoneId);
        if (zone.portal == address(0) || !IZoneFactory(ZONE_FACTORY_ADDRESS).isZonePortal(zone.portal)) return;
        (bool tokenOk, uint64 tokenPolicy) = _policy(token);
        r.portal = zone.portal;
        IZonePortal portal = IZonePortal(zone.portal);
        r.tokenEnabled = portal.isTokenEnabled(token);
        r.depositsActive = portal.areDepositsActive(token);
        r.accessEnforced = portal.isAccessEnforced();
        r.gatewayOpen = portal.isGatewayOpen();
        r.portalAllowedByPolicy = tokenOk && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(tokenPolicy, zone.portal)
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(tokenPolicy, zone.portal);
        address admin = portal.admin();
        r.zoneAdminAllowedByPolicy = tokenOk && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(tokenPolicy, admin);
        if (r.tokenIsEarnShare) {
            _checkAssetRefunds(r, portal, r.stablecoin, admin, refundRecipient);
        }
        address messenger = portal.messenger();
        r.messengerAllowedByPolicy = tokenOk && messenger == ZONE_MESSENGER_ADDRESS
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(tokenPolicy, messenger)
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(tokenPolicy, messenger);

        if (r.routerMatches) {
            if (!r.gatewayOpen) {
                r.routerAdmitted = portal.hasRole(router, Role.CallbackGateway);
            } else {
                r.routerAdmitted = !r.accessEnforced || portal.hasRole(router, Role.Account);
            }
        }
        r.refundRecipientAdmitted =
            refundRecipient != address(0) && (!r.accessEnforced || portal.hasRole(refundRecipient, Role.Account));
        r.programWalletAdmitted =
            programWallet != address(0) && (!r.accessEnforced || portal.hasRole(programWallet, Role.Account));
    }

    function print(Report memory r, address[] memory vaults) public view {
        _line(r.handler != address(0), "TS handler registered", "admin: DeployTempoSpend's adminRegisterHandler");
        _line(
            r.handlerValid,
            "TS handler has code and belongs to this factory",
            "admin: setSpenderHandler(\"TS\", the handler DeployTempoSpend deployed)"
        );
        _line(
            r.handlerCurrent,
            "TS handler is this repo's build",
            "deployer: DeployTempoSpend, then admin: its adminRegisterHandler"
        );
        _line(r.clone != address(0), "program exists", "manager: createSpender(spenderId, destinations)");
        _line(
            r.programCanonical,
            "program's clone created for this ID",
            "manager: createSpender(spenderId, destinations). An ID added to an existing clone cannot spend"
        );
        _line(
            r.handlerUsable,
            "TS usable by the program",
            "governance: updateSpenderHandlerAllowlist(\"TS\", spenderId, true) (ProgramCalls)"
        );
        _line(
            r.destinationAuthorized,
            "settlement destination authorized",
            "governance: add the destination to the program"
        );
        _line(
            r.programWalletAllowedByPolicy,
            r.tokenIsEarnShare
                ? "vault asset's policy lets the program wallet send"
                : "token policy lets the program wallet send",
            r.tokenIsEarnShare
                ? "policy admin: authorize the program wallet under the vault asset's TIP-403 policy"
                : "policy admin: authorize the program wallet under the token's TIP-403 policy"
        );
        _line(
            r.settlementAllowedByPolicy,
            r.tokenIsEarnShare
                ? "vault asset's policy lets the settlement wallet receive"
                : "token policy lets the settlement wallet receive",
            r.tokenIsEarnShare
                ? "policy admin: authorize the settlement wallet under the vault asset's TIP-403 policy"
                : "policy admin: authorize the settlement wallet under the token's TIP-403 policy"
        );
        _line(!r.paused, "factory not paused", "governance: unpause");
        // Bridge's trust anchors: Bridge holds them, so each warn is a question for Bridge before going live.
        _warn(
            r.adminIsTimelock,
            string.concat(
                "factory default admin ",
                vm.toString(r.defaultAdmin),
                " is a TimelockController, min delay ",
                vm.toString(r.adminMinDelay),
                "s"
            ),
            "Bridge: its default admin upgrades the factory and grants every role at once; ask for a timelock"
        );
        console.log(
            string.concat("info  default admin transfer delay ", vm.toString(uint256(r.defaultAdminDelay)), "s")
        );
        _line(
            r.factoryImplementation.code.length != 0,
            string.concat("factory ERC-1967 implementation ", vm.toString(r.factoryImplementation)),
            "check FACTORY: it is not an ERC-1967 proxy with an implementation"
        );
        _line(
            r.delegatorCurrent,
            string.concat("factory's delegator ", vm.toString(r.delegator), " is this repo's SpenderDelegator"),
            "Bridge: review the delegator factory.implementation() names, which every clone runs"
        );
        _line(
            r.cloneBeaconIsFactory,
            "clone's ERC-1967 beacon is the factory",
            "Bridge default admin: migrateBeacons([clone])"
        );
        if (r.settlementVirtual) {
            _line(
                r.settlementPayee != address(0),
                string.concat("settlement is a TIP-1022 virtual address of ", vm.toString(r.settlementPayee)),
                "settlement owner: register its virtual master, or authorize another destination"
            );
        } else {
            console.log("info  settlement is not a TIP-1022 virtual address");
        }
        _line(r.portal != address(0), "Zone has a registered portal", "check ZONE_ID");
        _line(r.tokenEnabled, "token enabled on the Zone portal", "Zone admin: enableToken(token)");
        _line(
            r.depositsActive,
            "portal takes deposits of the token",
            "Zone admin: unpause the portal or resumeDeposits(token)"
        );
        _line(
            r.routerFromFactory,
            "router deployed by the router factory",
            "deployer: DeployZoneRouter, then use its router and factory"
        );
        _line(
            r.routerMatches,
            "router takes this Zone's spends through this program's CardSpender",
            "deployer: DeployZoneRouter for this program and Zone"
        );
        _warn(
            r.programAtRelease,
            "CardSpender is the release program for FACTORY, SPENDER_ID and ROUTER_FACTORY",
            "deployer: DeployZoneRouter with the release ROUTER_FACTORY, then use its router"
        );
        _line(
            r.programRouterFactory,
            "CardSpender takes spendFrom only from ROUTER_FACTORY's routers",
            "deployer: DeployZoneRouter with this ROUTER_FACTORY, then use its router"
        );
        _line(
            r.programCurrent,
            "CardSpender and BridgeProvider are this repo's build",
            "deployer: DeployZoneRouter, then grant the new router its Zone role and use it"
        );
        _line(
            r.routerAdmitted,
            "router has its Zone role",
            r.gatewayOpen
                ? "Zone admin: setAllowedAccount(router, true)"
                : "Zone admin: setGateway(router, true), after setAllowedAccount(router, false) if it holds the account role"
        );
        _line(
            r.routerAllowedByPolicy,
            "token policy lets the router receive and send",
            "policy admin: authorize the router under the token's TIP-403 policy"
        );
        _line(
            r.programAllowedByPolicy,
            "token policy lets the CardSpender receive and send",
            "policy admin: authorize the CardSpender under the token's (and vault asset's) TIP-403 policy"
        );
        _line(
            r.refundRecipientAdmitted,
            "refund recipient admitted",
            "Zone admin: setAllowedAccount(refundRecipient, true)"
        );
        _line(
            r.programWalletAdmitted,
            "program wallet can deposit refunds into the Zone",
            "Zone admin: setAllowedAccount(programWallet, true)"
        );
        _line(
            r.refundRecipientAllowedByPolicy,
            "token policy lets the refund recipient receive",
            "policy admin: authorize the refund recipient under the token's TIP-403 policy"
        );
        if (r.tokenIsEarnShare) {
            _line(
                r.cloneAllowedByPolicy,
                "share policy lets the clone receive and send",
                "policy admin: authorize the clone under the share's TIP-403 policy"
            );
            // A virtual settlement is paid through the clone: it redeems the asset to itself and forwards it.
            if (r.settlementVirtual) {
                _line(
                    r.cloneAssetAllowedByPolicy,
                    "vault asset's policy lets the clone receive and send",
                    "policy admin: authorize the clone under the vault asset's TIP-403 policy"
                );
            }
            _line(
                r.vaultAllowedByPolicy,
                "share policy lets the vault receive",
                "policy admin: authorize the vault under the share's TIP-403 policy"
            );
        }
        _line(
            r.portalAllowedByPolicy,
            "token policy lets the portal send and receive",
            "policy admin: authorize the portal under the token's TIP-403 policy"
        );
        _line(
            r.zoneAdminAllowedByPolicy,
            "token policy lets the Zone admin receive the deposit fee",
            "policy admin: authorize the Zone admin under the token's TIP-403 policy"
        );
        if (r.tokenIsEarnShare) {
            _line(
                r.assetRefundsAllowedByPolicy,
                "vault asset's policy lets private refunds reach the Zone",
                "policy admin: authorize the portal, Zone admin and refund recipient under the vault asset's TIP-403 policy"
            );
            _line(
                r.assetDepositsActive,
                "portal takes deposits of the vault asset, which refunds are paid in",
                "Zone admin: enableToken(asset), or unpause the portal or resumeDeposits(asset)"
            );
        }
        _line(
            r.messengerAllowedByPolicy,
            "token policy lets the Zone messenger send and receive",
            "policy admin: authorize the portal's messenger under the token's TIP-403 policy"
        );
        _printGas(r, vaults);
        for (uint256 i; i < vaults.length; ++i) {
            _line(
                r.vaultsAllowed[i],
                string.concat("vault allowed ", vm.toString(vaults[i])),
                "governance: ProgramCalls' governanceAllowVaults"
            );
            _line(
                r.vaultsSpendable[i],
                string.concat("vault engine has exact withdrawals and redeem previews ", vm.toString(vaults[i])),
                "use a vault whose engine supports both"
            );
        }
    }

    /// @dev The warm-ups and seeds step 6 of docs/cards/bridge/deploy.md describes, and the callback gas to
    ///      request until they are all done.
    function _printGas(Report memory r, address[] memory vaults) private pure {
        _warn(
            r.settlementFunded,
            r.tokenIsEarnShare ? "settlement wallet holds the vault asset" : "settlement wallet holds the token",
            "Bridge: send the settlement wallet 1 unit, and never sweep it to zero"
        );
        _warn(r.programWarm, "program's standing approval of the token to its clone", "anyone: program.warm(TOKEN)");
        _warn(r.routerWarm, "router's standing approval of the token to the portal", "anyone: router.warm(TOKEN)");
        _warn(r.programSeeded, "program holds a seed of the token", "anyone: send the program 1 unit of TOKEN");
        _warn(r.routerSeeded, "router holds a seed of the token", "anyone: send the router 1 unit of TOKEN");
        bool ready = r.settlementFunded && r.programWarm && r.routerWarm && r.programSeeded && r.routerSeeded;
        if (r.tokenIsEarnShare) {
            _warn(r.cloneSeeded, "clone holds a seed of the share", "anyone: send the clone 1 unit of the share");
            ready = ready && r.cloneSeeded;
            if (r.settlementVirtual) {
                _warn(
                    r.cloneAssetSeeded,
                    "clone holds a seed of the vault asset, which a virtual settlement is paid through",
                    "anyone: send the clone 1 unit of the vault asset"
                );
                ready = ready && r.cloneAssetSeeded;
            }
        }
        for (uint256 i; i < vaults.length; ++i) {
            _warn(
                r.cloneVaultApproved[i],
                string.concat("clone's standing share approval to vault ", vm.toString(vaults[i])),
                "governance: ProgramCalls' governanceAllowVaults, which sets it"
            );
            ready = ready && r.cloneVaultApproved[i];
            if (!r.paysDirect) continue;
            _warn(
                r.programVaultApproved[i],
                string.concat("program's standing share approval to vault ", vm.toString(vaults[i])),
                "anyone: program.warmVault(vault)"
            );
            ready = ready && r.programVaultApproved[i];
        }
        if (ready) console.log("ok    every warm-up is done, so the prepared callback gas figures apply");
        else console.log("warn  a warm-up is missing: request 3M callback gas until every one above is done");
    }

    /// @dev Finds the `CardSpender` ROUTER lists for this program: one whose provider is a `BridgeProvider`
    ///      for this factory and spender ID. Only a router ROUTER_FACTORY deployed is read, so an
    ///      arbitrary address cannot make the report look complete.
    function _checkRouter(
        Report memory r,
        address factory,
        bytes32 spenderId,
        uint32 zoneId,
        ZoneRouterFactory routerFactory,
        address router
    ) private {
        if (address(routerFactory).code.length == 0 || router == address(0)) return;
        try routerFactory.isRouter(router) returns (bool deployed) {
            r.routerFromFactory = deployed;
        } catch { }
        if (!r.routerFromFactory) return;
        ZoneRouter zoneRouter = ZoneRouter(router);
        if (zoneRouter.allowedZoneId() != zoneId || zoneRouter.enabledOps() & zoneRouter.OP_SPEND() == 0) return;
        address[] memory spenders = zoneRouter.spenders();
        for (uint256 i; i < spenders.length; ++i) {
            (bool providerOk, address provider) =
                ProgramChecks.readAddress(spenders[i], bytes4(keccak256("PROVIDER()")));
            if (!providerOk) continue;
            (bool factoryOk, address providerFactory) =
                ProgramChecks.readAddress(provider, bytes4(keccak256("FACTORY()")));
            (bool ok, bytes memory id) = provider.staticcall(abi.encodeWithSignature("SPENDER_ID()"));
            if (!factoryOk || providerFactory != factory || !ok || id.length != 32) continue;
            if (abi.decode(id, (bytes32)) != spenderId) continue;
            r.routerMatches = true;
            r.program = spenders[i];
            r.programAtRelease = spenders[i] == bridgeProgramAddress(factory, spenderId, address(routerFactory));
            (bool routerFactoryOk, address programRouterFactory) =
                ProgramChecks.readAddress(spenders[i], bytes4(keccak256("ROUTER_FACTORY()")));
            r.programRouterFactory = routerFactoryOk && programRouterFactory == address(routerFactory);
            // Copies from the artifacts, so this script does not carry their creation code.
            r.programCurrent = ProgramChecks.sameLogic(
                provider, vm.deployCode("BridgeProvider.sol:BridgeProvider", abi.encode(factory, spenderId))
            )
            && ProgramChecks.sameLogic(
                spenders[i], vm.deployCode("CardSpender.sol:CardSpender", abi.encode(provider, address(routerFactory)))
            );
            return;
        }
    }

    /// @dev An Earn program's refunds are in the vault asset, so its policy and the portal's
    ///      deposits are checked for the asset as well, including the refund recipient that
    ///      receives a bounced refund (an unset one is reported by its own check). The program
    ///      wallet that sends them is checked by `programWalletAllowedByPolicy`.
    function _checkAssetRefunds(
        Report memory r,
        IZonePortal portal,
        address asset,
        address admin,
        address refundRecipient
    ) private view {
        (bool ok, uint64 policy) = _policy(asset);
        r.assetRefundsAllowedByPolicy = ok
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(policy, address(portal))
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(policy, address(portal))
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(policy, admin)
            && (refundRecipient == address(0)
                || StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(policy, refundRecipient));
        r.assetDepositsActive = portal.isTokenEnabled(asset) && portal.areDepositsActive(asset);
    }

    /// @dev Each vault's engine supports Earn spends, and the program allows it (`GV`) once "TS" is usable.
    function _checkVaults(Report memory r, address[] memory vaults) private view {
        r.vaultsSpendable = new bool[](vaults.length);
        for (uint256 i; i < vaults.length; ++i) {
            r.vaultsSpendable[i] = ProgramChecks.supportsEarnSpend(vaults[i]);
        }
        r.vaultsAllowed = new bool[](vaults.length);
        for (uint256 i; i < vaults.length && r.clone != address(0) && r.handlerUsable; ++i) {
            (bool ok, bytes memory data) = r.clone
                .staticcall(
                    abi.encodeWithSignature("publicGetCall(bytes)", abi.encodePacked(PREFIX, bytes2("GV"), vaults[i]))
                );
            r.vaultsAllowed[i] = ok && abi.decode(abi.decode(data, (bytes)), (bool));
        }
    }

    /// @dev Bridge's trust anchors: who upgrades the factory and grants its roles, the factory's
    ///      implementation, and the delegator and beacon every clone's logic comes from.
    function _checkTrust(Report memory r, SpenderFactory factory) private {
        try factory.defaultAdmin() returns (address admin) {
            r.defaultAdmin = admin;
        } catch { }
        if (r.defaultAdmin.code.length != 0) {
            (bool ok, bytes memory delay) = r.defaultAdmin.staticcall(abi.encodeWithSignature("getMinDelay()"));
            if (ok && delay.length == 32) {
                r.adminIsTimelock = true;
                r.adminMinDelay = abi.decode(delay, (uint256));
            }
        }
        try factory.defaultAdminDelay() returns (uint48 delay) {
            r.defaultAdminDelay = delay;
        } catch { }
        r.factoryImplementation = _slotAddress(address(factory), ERC1967Utils.IMPLEMENTATION_SLOT);
        try factory.implementation() returns (address delegator) {
            r.delegator = delegator;
        } catch { }
        r.delegatorCurrent = r.delegator.code.length != 0
            && ProgramChecks.sameLogic(r.delegator, address(new SpenderDelegator(IFactory(address(factory)))));
        r.cloneBeaconIsFactory =
            r.clone != address(0) && _slotAddress(r.clone, ERC1967Utils.BEACON_SLOT) == address(factory);
    }

    /// @dev The warm-ups and seeds the prepared callback gas figures assume: each one missing makes a spend
    ///      create a storage slot (TIP-1000), about 250k more gas.
    function _checkGas(Report memory r, address token, address router, address[] memory vaults) private view {
        r.settlementFunded = r.settlementPayee != address(0) && _balance(r.stablecoin, r.settlementPayee) != 0;
        if (r.program != address(0)) {
            (bool ok, address target) = ProgramChecks.readAddress(r.program, bytes4(keccak256("PAYOUT_TARGET()")));
            r.paysDirect = ok && target == address(0);
            r.programWarm = ok && (target == address(0) || _allowance(token, r.program, target) >= type(uint128).max);
            r.programSeeded = _balance(token, r.program) != 0;
        }
        if (r.routerMatches) {
            // A standing approval is above `uint128`, as the router reads one.
            r.routerWarm = r.portal != address(0) && _allowance(token, router, r.portal) > type(uint128).max;
            r.routerSeeded = _balance(token, router) != 0;
        }
        r.cloneSeeded = r.tokenIsEarnShare && r.clone != address(0) && _balance(token, r.clone) != 0;
        r.cloneAssetSeeded = r.tokenIsEarnShare && r.clone != address(0) && _balance(r.stablecoin, r.clone) != 0;
        r.cloneVaultApproved = new bool[](vaults.length);
        r.programVaultApproved = new bool[](vaults.length);
        for (uint256 i; i < vaults.length; ++i) {
            (bool shareOk, address share) = ProgramChecks.readAddress(vaults[i], ITempoEarnVault.earnShare.selector);
            if (!shareOk) continue;
            r.cloneVaultApproved[i] =
                r.clone != address(0) && _allowance(share, r.clone, vaults[i]) >= type(uint128).max;
            r.programVaultApproved[i] =
                r.program != address(0) && _allowance(share, r.program, vaults[i]) >= type(uint128).max;
        }
    }

    /// @dev Who a transfer to `account` credits under TIP-1022: its registered master when it is a virtual
    ///      address (zero when it has none, as the transfer would revert), else itself. A chain without the
    ///      registry has no virtual addresses.
    function _payee(address account) private view returns (bool isVirtual, address payee) {
        address registry = StdPrecompiles.ADDRESS_REGISTRY_ADDRESS;
        (bool ok, bytes memory data) = registry.staticcall(abi.encodeCall(IAddressRegistry.isVirtualAddress, (account)));
        isVirtual = ok && data.length == 32 && abi.decode(data, (bool));
        if (!isVirtual) return (false, account);
        (ok, data) = registry.staticcall(abi.encodeCall(IAddressRegistry.resolveRecipient, (account)));
        if (ok && data.length == 32) payee = abi.decode(data, (address));
    }

    function _balance(address token, address account) private view returns (uint256 balance) {
        (, balance) = ProgramChecks.readUint(token, abi.encodeCall(ITIP20.balanceOf, (account)));
    }

    function _allowance(address token, address owner, address spender) private view returns (uint256 allowance) {
        (, allowance) = ProgramChecks.readUint(token, abi.encodeCall(ITIP20.allowance, (owner, spender)));
    }

    function _slotAddress(address account, bytes32 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(account, slot))));
    }

    /// @dev `token` is a TIP-20 whose policy lets `account` receive and send it.
    function _movesThrough(address token, address account) private view returns (bool) {
        (bool ok, uint64 policy) = _policy(token);
        return ok && _sendsAndReceives(policy, account);
    }

    function _sendsAndReceives(uint64 policy, address account) private view returns (bool) {
        return account != address(0) && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(policy, account)
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(policy, account);
    }

    /// @dev `try` cannot catch a call to an address without code, so that is checked first.
    function _policy(address t) private view returns (bool ok, uint64 id) {
        if (t.code.length == 0) return (false, 0);
        try ITIP20(t).transferPolicyId() returns (uint64 policyId) {
            return (true, policyId);
        } catch { }
    }

    function _line(bool ok, string memory what, string memory fix) private pure {
        if (ok) console.log(string.concat("ok    ", what));
        else console.log(string.concat("todo  ", what, ": ", fix));
    }

    /// @dev Like `_line`, for advice that does not stop a spend: a missing warm-up only needs more callback gas,
    ///      and Bridge's governance and release provenance are questions for Bridge, not failures.
    function _warn(bool ok, string memory what, string memory fix) private pure {
        if (ok) console.log(string.concat("ok    ", what));
        else console.log(string.concat("warn  ", what, ": ", fix));
    }
}
