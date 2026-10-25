// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import {
    IZoneFactory,
    IZonePortal,
    Role,
    ZONE_FACTORY_ADDRESS,
    ZONE_MESSENGER_ADDRESS,
    ZoneInfo
} from "tempo-zones/interfaces/IZone.sol";

import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";

import { SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { ZoneSpendReceiver } from "../../src/ZoneSpendReceiver.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { ITempoEarnVault } from "../../src/interfaces/ITempoEarnVault.sol";
import { ProgramChecks } from "./ProgramChecks.sol";

/// @notice Read-only check of one card program before private spend goes live: the "TS" handler,
///         the program and its destination, the Zone's portal and token, and the receiver and
///         refund account's Zone roles. Nothing is sent: the script deploys copies of the handler
///         and receiver only in its own simulation, to compare their code. `run` reads FACTORY, SPENDER_ID,
///         SETTLEMENT, TOKEN, ZONE_ID, RECEIVER (optional), REFUND_RECIPIENT (optional),
///         PROGRAM_WALLET (optional) and VAULTS (comma separated, optional), and prints each
///         missing step with who submits it. For an Earn spend, TOKEN is the EarnShare of one of
///         VAULTS, and the settlement wallet and program wallet are checked against its asset.
contract Preflight is Script {
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
        /// @dev The wallet that pays private refunds is a program destination, which
        ///      `refundPrivate` requires of its caller.
        bool programWalletAuthorized;
        bool paused;
        /// @dev TOKEN is the EarnShare of one of VAULTS.
        bool tokenIsEarnShare;
        /// @dev The policy of the stablecoin the destination receives lets the settlement wallet
        ///      receive it: TOKEN's, or the vault asset's when TOKEN is an EarnShare.
        bool settlementAllowedByPolicy;
        /// @dev The policy lets the receiver receive the withdrawal and send it on.
        bool receiverAllowedByPolicy;
        /// @dev The policy lets the refund recipient receive a rejected Zone return.
        bool refundRecipientAllowedByPolicy;
        /// @dev The stablecoin's policy lets the program wallet send, which `refundPrivate`'s pull
        ///      needs.
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
        ///      Zone: the receiver and portal receive and send, and the Zone admin receives.
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
        /// @dev A receiver exists at RECEIVER for this factory, program and Zone.
        bool receiverMatches;
        /// @dev The receiver runs this repo's code, ignoring solc's metadata. An older receiver
        ///      still decodes newer callback data and skips the checks it lacks.
        bool receiverCurrent;
        /// @dev The receiver has the Zone role its callbacks need: callback gateway when the
        ///      gateway is closed, the account role when it is open and access is enforced.
        bool receiverAdmitted;
        bool refundRecipientAdmitted;
        /// @dev The portal's messenger is the canonical one and the token's policy lets it send and
        ///      receive, since every withdrawal passes through it.
        bool messengerAllowedByPolicy;
        bool[] vaultsAllowed;
        /// @dev Each vault's engine supports the exact withdrawals a spend makes and the redeem
        ///      previews `availableBalance` uses.
        bool[] vaultsSpendable;
    }

    function run() external {
        address[] memory vaults = vm.envOr("VAULTS", ",", new address[](0));
        Report memory r = check(
            SpenderFactory(vm.envAddress("FACTORY")),
            vm.envBytes32("SPENDER_ID"),
            vm.envAddress("SETTLEMENT"),
            vm.envAddress("TOKEN"),
            ProgramChecks.zoneId(vm.envUint("ZONE_ID")),
            vm.envOr("RECEIVER", address(0)),
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
        address receiver,
        address refundRecipient,
        address programWallet,
        address[] memory vaults
    ) public returns (Report memory r) {
        try factory.getSpenderAddress(spenderId) returns (address clone) {
            r.clone = clone;
        } catch { }
        r.programCanonical = ProgramChecks.isCanonical(address(factory), spenderId, r.clone);
        r.handler = address(factory.getSpenderHandler(PREFIX));
        (bool factoryOk, address handlerFactory) =
            ProgramChecks.readAddress(r.handler, bytes4(keccak256("FACTORY()")));
        r.handlerValid = factoryOk && handlerFactory == address(factory);
        r.handlerCurrent = r.handlerValid
            && ProgramChecks.sameLogic(
                r.handler, address(new SpenderTempoSpend(IFactory(address(factory))))
            );
        if (r.clone != address(0) && r.handler != address(0)) {
            try factory.getSpenderHandlerWithCheckedPermissions(PREFIX, r.clone) {
                r.handlerUsable = true;
            } catch { }
        }
        r.destinationAuthorized =
            r.clone != address(0) && factory.isAuthorizedDestination(spenderId, settlement);
        r.programWalletAuthorized = r.clone != address(0) && programWallet != address(0)
            && factory.isAuthorizedDestination(spenderId, programWallet);
        r.paused = factory.paused();

        address stablecoin = token;
        address earnVault;
        for (uint256 i; i < vaults.length; ++i) {
            (bool shareOk, address share) =
                ProgramChecks.readAddress(vaults[i], ITempoEarnVault.earnShare.selector);
            if (!shareOk || share != token) continue;
            (bool assetOk, address asset) =
                ProgramChecks.readAddress(vaults[i], ITempoEarnVault.asset.selector);
            if (assetOk) {
                r.tokenIsEarnShare = true;
                stablecoin = asset;
                earnVault = vaults[i];
            }
            break;
        }

        // A token that is not a TIP-20 leaves its policy checks false instead of ending the report.
        (bool stableOk, uint64 stablePolicy) = _policy(stablecoin);
        if (stableOk) {
            r.settlementAllowedByPolicy =
                StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(stablePolicy, settlement);
            r.programWalletAllowedByPolicy = programWallet != address(0)
                && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(stablePolicy, programWallet);
        }
        (bool tokenOk, uint64 tokenPolicy) = _policy(token);
        if (tokenOk) {
            r.receiverAllowedByPolicy = receiver != address(0)
                && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(tokenPolicy, receiver)
                && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(tokenPolicy, receiver);
            r.refundRecipientAllowedByPolicy = refundRecipient != address(0)
                && StdPrecompiles.TIP403_REGISTRY
                .isAuthorizedRecipient(tokenPolicy, refundRecipient);
            r.cloneAllowedByPolicy = r.clone != address(0)
                && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(tokenPolicy, r.clone)
                && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(tokenPolicy, r.clone);
            r.vaultAllowedByPolicy = earnVault != address(0)
                && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(tokenPolicy, earnVault);
        }

        r.vaultsSpendable = new bool[](vaults.length);
        for (uint256 i; i < vaults.length; ++i) {
            r.vaultsSpendable[i] = ProgramChecks.supportsEarnSpend(vaults[i]);
        }
        r.vaultsAllowed = new bool[](vaults.length);
        for (uint256 i; i < vaults.length && r.clone != address(0) && r.handlerUsable; ++i) {
            (bool ok, bytes memory data) = r.clone
                .staticcall(
                    abi.encodeWithSignature(
                        "publicGetCall(bytes)", abi.encodePacked(PREFIX, bytes2("GV"), vaults[i])
                    )
                );
            r.vaultsAllowed[i] = ok && abi.decode(abi.decode(data, (bytes)), (bool));
        }

        if (receiver.code.length != 0) {
            ZoneSpendReceiver deployed = ZoneSpendReceiver(receiver);
            r.receiverMatches = address(deployed.FACTORY()) == address(factory)
                && deployed.SPENDER_ID() == spenderId && deployed.ZONE_ID() == zoneId;
            r.receiverCurrent = r.receiverMatches
                && ProgramChecks.sameLogic(
                    receiver,
                    address(
                        new ZoneSpendReceiver(
                            IBridgeSpenderFactory(address(factory)), spenderId, zoneId
                        )
                    )
                );
        }

        ZoneInfo memory zone = IZoneFactory(ZONE_FACTORY_ADDRESS).zones(zoneId);
        if (
            zone.portal == address(0)
                || !IZoneFactory(ZONE_FACTORY_ADDRESS).isZonePortal(zone.portal)
        ) {
            return r;
        }
        r.portal = zone.portal;
        IZonePortal portal = IZonePortal(zone.portal);
        r.tokenEnabled = portal.isTokenEnabled(token);
        r.depositsActive = portal.areDepositsActive(token);
        r.accessEnforced = portal.isAccessEnforced();
        r.gatewayOpen = portal.isGatewayOpen();
        r.portalAllowedByPolicy = tokenOk
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(tokenPolicy, zone.portal)
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(tokenPolicy, zone.portal);
        address admin = portal.admin();
        r.zoneAdminAllowedByPolicy =
            tokenOk && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(tokenPolicy, admin);
        if (r.tokenIsEarnShare) _checkAssetRefunds(r, portal, stablecoin, receiver, admin);
        address messenger = portal.messenger();
        r.messengerAllowedByPolicy = tokenOk && messenger == ZONE_MESSENGER_ADDRESS
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(tokenPolicy, messenger)
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(tokenPolicy, messenger);

        if (r.receiverMatches) {
            if (!r.gatewayOpen) {
                r.receiverAdmitted = portal.hasRole(receiver, Role.CallbackGateway);
            } else {
                r.receiverAdmitted = !r.accessEnforced || portal.hasRole(receiver, Role.Account);
            }
        }
        r.refundRecipientAdmitted = refundRecipient != address(0)
            && (!r.accessEnforced || portal.hasRole(refundRecipient, Role.Account));
    }

    function print(Report memory r, address[] memory vaults) public view {
        _line(
            r.handler != address(0),
            "TS handler registered",
            "admin: DeployTempoSpend's adminRegisterHandler"
        );
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
        _line(
            r.clone != address(0),
            "program exists",
            "manager: createSpender(spenderId, destinations)"
        );
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
            r.programWalletAuthorized,
            "program wallet can pay private refunds",
            "governance: updateSpenderDestination(spenderId, programWallet, true)"
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
        _line(r.portal != address(0), "Zone has a registered portal", "check ZONE_ID");
        _line(r.tokenEnabled, "token enabled on the Zone portal", "Zone admin: enableToken(token)");
        _line(
            r.depositsActive,
            "portal takes deposits of the token",
            "Zone admin: unpause the portal or resumeDeposits(token)"
        );
        _line(
            r.receiverMatches,
            "receiver deployed for this program and Zone",
            "deployer: DeployZoneReceiver"
        );
        _line(
            r.receiverCurrent,
            "receiver is this repo's build",
            "deployer: DeployZoneReceiver, then grant the new receiver its Zone role and use it"
        );
        _line(
            r.receiverAdmitted,
            "receiver has its Zone role",
            r.gatewayOpen
                ? "Zone admin: setAllowedAccount(receiver, true)"
                : "Zone admin: setGateway(receiver, true), after setAllowedAccount(receiver, false) if it holds the account role"
        );
        _line(
            r.receiverAllowedByPolicy,
            "token policy lets the receiver receive and send",
            "policy admin: authorize the receiver under the token's TIP-403 policy"
        );
        _line(
            r.refundRecipientAdmitted,
            "refund recipient admitted",
            "Zone admin: setAllowedAccount(refundRecipient, true)"
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
                "policy admin: authorize the receiver, portal and Zone admin under the vault asset's TIP-403 policy"
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
        for (uint256 i; i < vaults.length; ++i) {
            _line(
                r.vaultsAllowed[i],
                string.concat("vault allowed ", vm.toString(vaults[i])),
                "governance: ProgramCalls' governanceAllowVaults"
            );
            _line(
                r.vaultsSpendable[i],
                string.concat(
                    "vault engine has exact withdrawals and redeem previews ",
                    vm.toString(vaults[i])
                ),
                "use a vault whose engine supports both"
            );
        }
    }

    /// @dev An Earn program's refunds are in the vault asset, so its policy and the portal's
    ///      deposits are checked for the asset as well.
    function _checkAssetRefunds(
        Report memory r,
        IZonePortal portal,
        address asset,
        address receiver,
        address admin
    ) private view {
        (bool ok, uint64 policy) = _policy(asset);
        r.assetRefundsAllowedByPolicy = ok && receiver != address(0)
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(policy, receiver)
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(policy, receiver)
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(policy, address(portal))
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedSender(policy, address(portal))
            && StdPrecompiles.TIP403_REGISTRY.isAuthorizedRecipient(policy, admin);
        r.assetDepositsActive = portal.isTokenEnabled(asset) && portal.areDepositsActive(asset);
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
}
