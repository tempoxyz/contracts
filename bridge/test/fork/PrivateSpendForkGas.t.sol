// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ISpenderHandler, SpenderStatus } from "bridge-spender/src/ISpenderHandler.sol";
import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { EncryptedDepositPayload, ZONE_MESSENGER_ADDRESS } from "tempo-earn/interfaces/external/tempo/IZone.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ZoneRouter } from "zone-router/ZoneRouter.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";

import { Spend, SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { ITempoEarnVault } from "../../src/interfaces/ITempoEarnVault.sol";
import { BridgeSettler } from "zone-router/settlers/BridgeSettler.sol";

/// @dev Tempo mainnet (chain 4217) production addresses this measurement runs against.
library Mainnet {
    uint256 internal constant CHAIN_ID = 4217;
    /// @dev OUSD (tempoxyz/tempo crates/hardfork/src/constants.rs OUSD_ADDRESS), the Earn vault's asset.
    address internal constant OUSD = 0x20c0000000000000000000006a37DA5C996874BE;
    /// @dev DLUSD, Zone 2's private stablecoin (enabled on its portal).
    address internal constant DLUSD = 0x20c0000000000000000000006fD9A167923ba194;
    /// @dev "Sentora OUSD Main" EarnVault (ERC-1967 proxy to the official EarnVault 0xFa07…D94a).
    address internal constant EARN_VAULT = 0x23D26636B00195204D25F85Bb3FF692Cd68DD7ce;
    /// @dev Its EarnShare (senOUSDmainE), enabled on Zone 2's portal.
    address internal constant EARN_SHARE = 0x20C000000000000000000000d0b63F23bb6CE50c;
    uint32 internal constant ZONE_ID = 2;
    address internal constant PORTAL = 0x5Ad0000000000000000000000000000000000002;
}

interface IPortalAdmin {
    function admin() external view returns (address);
    function setGateway(address account, bool allowed) external;
    function setAllowedAccount(address account, bool allowed) external;
    function encryptionKeyCount() external view returns (uint256);
    function calculateDepositFee() external view returns (uint128);
    function calculateBouncebackFee() external view returns (uint128);
    function deliverWithdrawal(
        address token,
        address target,
        uint128 amount,
        bytes32 senderTag,
        uint64 gasLimit,
        bytes calldata data
    ) external;
}

/// @notice Runs one withdrawal per top-level call, so with --isolate each is its own transaction with
///         cold accounts and the Zone's own delivery order: the portal's escrow moves the input to the
///         router, then the messenger calls it with Bridge's callback gas.
contract CallbackDriver {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint64 internal constant CALLBACK_GAS = 3_000_000;
    bytes32 internal constant SENDER_TAG = keccak256("fork.sender-tag");

    /// @return used Gas the router's callback frame used, called as the messenger does with a 3M cap.
    function callback(address router, address token, uint128 amount, bytes calldata data)
        external
        returns (uint256 used)
    {
        vm.prank(Mainnet.PORTAL);
        ITIP20(token).transfer(router, amount);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        uint256 before = gasleft();
        bytes4 selector = ZoneRouter(router).onWithdrawalReceived{ gas: CALLBACK_GAS }(
            Mainnet.ZONE_ID, Mainnet.PORTAL, SENDER_TAG, token, amount, data
        );
        used = before - gasleft();
        require(selector == ZoneRouter.onWithdrawalReceived.selector, "selector");
    }

    /// @return used Gas of the real portal's whole delivery: escrow to messenger, messenger checks
    ///         and transfer, the 3M-capped callback, and the portal's returned-deposit check.
    function deliver(address router, address token, uint128 amount, bytes calldata data)
        external
        returns (uint256 used)
    {
        vm.prank(Mainnet.PORTAL);
        uint256 before = gasleft();
        IPortalAdmin(Mainnet.PORTAL).deliverWithdrawal(token, router, amount, SENDER_TAG, CALLBACK_GAS, data);
        used = before - gasleft();
    }
}

/// @notice Private-spend callback gas through a Spend-mode ZoneRouter, BridgeSettler and Bridge's
///         clone with the TS handler, on a Tempo mainnet fork against the production OUSD EarnVault
///         and Zone 2's real portal and messenger.
/// @dev Inert unless forked to Tempo mainnet: pass --fork-url, or set FORK_URL. Needs mainnet's active
///      hardfork (tempo_forkSchedule: T12 at block 46.08M); under this project's tempo:T8 the fork's
///      TIP-403 state does not apply. Each spend is its own transaction (isolate is on by default
///      here; --isolate makes it explicit):
///      forge test --match-path 'test/fork/*' --fork-url https://rpc.tempo.xyz --hardfork tempo:T12 -vv
///      The table is also written to reports/fork-callback-gas.md.
contract PrivateSpendForkGasTest is Test {
    uint64 internal constant CALLBACK_GAS = 3_000_000;
    bytes32 internal constant SPENDER_ID = keccak256("bridge.card-program.fork-gas");
    bytes2 internal constant PREFIX_TEMPO_SPEND = "TS";
    /// @dev Unused input each withdrawal carries above maxInput, returned through the portal.
    uint256 internal constant CHANGE = 10_000; // 0.01

    bool internal forked;

    SpenderFactory internal bridgeFactory;
    address internal clone;
    address internal bridgeAdmin = makeAddr("bridge.admin");
    address internal bridgeGovernor = makeAddr("bridge.governor");
    address internal bridgeManager = makeAddr("bridge.manager");
    address internal bridgePauser = makeAddr("bridge.pauser");
    address internal programRefundRecipient = makeAddr("bridge.zone-refund-recipient");
    address internal zoneUser = makeAddr("zone.cardholder");

    BridgeSettler internal settler;
    ZoneRouterFactory internal routerFactory;
    ZoneRouter internal router;
    CallbackDriver internal driver;

    struct Row {
        string kind;
        uint256 dollars;
        uint256 firstGas;
        uint256 secondGas;
        uint256 firstDeliver;
        uint256 secondDeliver;
        uint256 dataBytes;
    }

    Row[] internal rows;
    uint256 internal destinationSeq;

    function setUp() public {
        if (block.chainid != Mainnet.CHAIN_ID) {
            string memory url = vm.envOr("FORK_URL", string(""));
            if (bytes(url).length == 0) return;
            vm.createSelectFork(url);
        }
        forked = true;

        _deployBridge();
        settler = new BridgeSettler(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID);
        routerFactory = ZoneRouterFactory(deployCode("ZoneRouterFactory.sol:ZoneRouterFactory"));
        ZoneRouter.Mode memory mode;
        mode.zoneId = Mainnet.ZONE_ID;
        mode.enabledOps = uint8(1 << 2);
        mode.settlers = new address[](1);
        mode.settlers[0] = address(settler);
        router = ZoneRouter(routerFactory.deploy(mode));
        driver = new CallbackDriver();

        // What Zone 2's portal admin does for a card program: admit the router as a callback gateway
        // and the program's refund recipient as an account.
        IPortalAdmin portal = IPortalAdmin(Mainnet.PORTAL);
        vm.startPrank(portal.admin());
        portal.setGateway(address(router), true);
        portal.setAllowedAccount(programRefundRecipient, true);
        vm.stopPrank();

        // The EarnShare's transfer policy is a whitelist: its admin must admit the program's router,
        // settler and clone, which hold shares within a spend, and its Zone refund recipient, which
        // the portal checks on every returned deposit.
        uint64 sharePolicy = ITIP20(Mainnet.EARN_SHARE).transferPolicyId();
        (, address policyAdmin) = StdPrecompiles.TIP403_REGISTRY.policyData(sharePolicy);
        vm.startPrank(policyAdmin);
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(sharePolicy, address(router), true);
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(sharePolicy, address(settler), true);
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(sharePolicy, clone, true);
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(sharePolicy, programRefundRecipient, true);
        vm.stopPrank();

        vm.label(address(router), "ZoneRouter");
        vm.label(address(settler), "BridgeSettler");
        vm.label(clone, "Bridge.SpenderClone");
        vm.label(Mainnet.PORTAL, "Zone2Portal");
        vm.label(Mainnet.EARN_VAULT, "EarnVault.OUSD");
        vm.label(Mainnet.EARN_SHARE, "EarnShare.senOUSDmainE");
        vm.label(Mainnet.OUSD, "OUSD");
        vm.label(Mainnet.DLUSD, "DLUSD");
    }

    function test_privateSpendCallbackGas() public {
        if (!forked) vm.skip(true);
        uint256[3] memory dollars = [uint256(10), 100, 10_000];
        for (uint256 i; i < dollars.length; ++i) {
            _measure(true, dollars[i]);
            _measure(false, dollars[i]);
        }
        _report();
    }

    // ------------------------------------------------------------------
    // Measurement
    // ------------------------------------------------------------------

    /// @dev From the freshly deployed program each time: a first spend to a settlement wallet that holds
    ///      none of the token, then a second to the same wallet. Measured once as the bare callback and
    ///      once through the portal's own delivery, each from the same starting state.
    function _measure(bool earn, uint256 dollars) internal {
        Row memory row;
        row.kind = earn ? "Earn (EarnShare -> OUSD)" : "Stablecoin (DLUSD)";
        row.dollars = dollars;
        uint256 amount = dollars * 1e6;

        uint256 snapshot = vm.snapshotState();
        address destination = _newDestination();
        (address token, uint128 input, bytes memory data) = _withdrawal(earn, amount, destination);
        row.dataBytes = data.length;
        uint256 destBefore = ITIP20(_paid(earn)).balanceOf(destination);
        assertEq(destBefore, 0, "settlement wallet starts empty");
        row.firstGas = driver.callback(address(router), token, input, data);
        assertEq(ITIP20(_paid(earn)).balanceOf(destination), amount, "first spend paid");
        _assertNothingHeld(token);
        (token, input, data) = _withdrawal(earn, amount, destination);
        row.secondGas = driver.callback(address(router), token, input, data);
        assertEq(ITIP20(_paid(earn)).balanceOf(destination), 2 * amount, "second spend paid");
        _assertNothingHeld(token);
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        destination = _newDestination();
        (token, input, data) = _withdrawal(earn, amount, destination);
        row.firstDeliver = driver.deliver(address(router), token, input, data);
        assertEq(ITIP20(_paid(earn)).balanceOf(destination), amount, "delivered first spend paid");
        (token, input, data) = _withdrawal(earn, amount, destination);
        row.secondDeliver = driver.deliver(address(router), token, input, data);
        assertEq(ITIP20(_paid(earn)).balanceOf(destination), 2 * amount, "delivered second spend paid");
        _assertNothingHeld(token);
        vm.revertToState(snapshot);

        rows.push(row);
    }

    /// @return token The withdrawn token. @return input The withdrawal amount: maxInput plus CHANGE.
    function _withdrawal(bool earn, uint256 amount, address destination)
        internal
        view
        returns (address token, uint128 input, bytes memory data)
    {
        Spend memory spend = Spend({
            spenderId: SPENDER_ID,
            token: earn ? Mainnet.OUSD : Mainnet.DLUSD,
            amount: amount,
            destination: destination,
            vault: earn ? Mainnet.EARN_VAULT : address(0),
            fromVault: earn ? amount : 0,
            maxShares: 0,
            ref: keccak256(abi.encode("fork.ref", amount, destination))
        });
        uint256 maxInput = amount;
        token = Mainnet.DLUSD;
        if (earn) {
            // Bridge's buffer for price moves between its quote and settlement: 10 bps.
            spend.maxShares = ITempoEarnVault(Mainnet.EARN_VAULT).previewWithdraw(amount) * 10_010 / 10_000 + 1;
            maxInput = spend.maxShares;
            token = Mainnet.EARN_SHARE;
        }
        input = uint128(maxInput + CHANGE + _portalFees());
        data = abi.encode(
            ZoneRouter.SpendData({
                op: ZoneRouter.Op.Spend,
                settler: address(settler),
                maxInput: uint128(maxInput),
                settlerData: abi.encode(spend),
                zoneReturn: ZoneRouter.SpendReturn({
                    keyIndex: IPortalAdmin(Mainnet.PORTAL).encryptionKeyCount() - 1,
                    encrypted: _encrypted(),
                    refundRecipient: programRefundRecipient,
                    maxDepositFee: IPortalAdmin(Mainnet.PORTAL).calculateDepositFee()
                })
            })
        );
    }

    function _paid(bool earn) internal pure returns (address) {
        return earn ? Mainnet.OUSD : Mainnet.DLUSD;
    }

    function _portalFees() internal view returns (uint256) {
        IPortalAdmin portal = IPortalAdmin(Mainnet.PORTAL);
        return uint256(portal.calculateDepositFee()) + portal.calculateBouncebackFee();
    }

    /// @dev A payload the portal accepts: a valid secp256k1 X (the generator's) and a 64-byte
    ///      ciphertext. The sequencer would fail to decrypt it, which does not change Tempo-side gas.
    function _encrypted() internal pure returns (EncryptedDepositPayload memory) {
        return EncryptedDepositPayload({
            ephemeralPubkeyX: 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
            ephemeralPubkeyYParity: 0x02,
            ciphertext: abi.encodePacked(keccak256("ciphertext.0"), keccak256("ciphertext.1")),
            nonce: bytes12(keccak256("nonce")),
            tag: bytes16(keccak256("tag"))
        });
    }

    function _newDestination() internal returns (address destination) {
        destination = makeAddr(string.concat("bridge.settlement.", vm.toString(++destinationSeq)));
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderDestination(SPENDER_ID, destination, true);
    }

    function _assertNothingHeld(address token) internal view {
        assertEq(ITIP20(token).balanceOf(address(router)), 0, "router");
        assertEq(ITIP20(token).balanceOf(address(settler)), 0, "settler");
        assertEq(ITIP20(token).balanceOf(clone), 0, "clone");
    }

    // ------------------------------------------------------------------
    // Bridge program (as test/harness/TempoEnv.sol, TS handler only)
    // ------------------------------------------------------------------

    function _deployBridge() internal {
        SpenderFactory impl = new SpenderFactory();
        bridgeFactory = SpenderFactory(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(SpenderFactory.initialize, (bridgeAdmin, bridgeGovernor, bridgePauser))
                )
            )
        );
        ISpenderHandler ts = ISpenderHandler(address(new SpenderTempoSpend(IFactory(address(bridgeFactory)))));
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, ts);
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderHandlerStatus(PREFIX_TEMPO_SPEND, SpenderStatus.Enabled);
        bytes32 managerRole = bridgeFactory.MANAGER_ROLE();
        vm.prank(bridgeGovernor);
        bridgeFactory.grantRole(managerRole, bridgeManager);

        // The program's clone starts with one unrelated destination; each case adds its own empty wallet.
        address[] memory destinations = new address[](1);
        destinations[0] = makeAddr("bridge.program-wallet");
        vm.prank(bridgeManager);
        clone = bridgeFactory.createSpender(SPENDER_ID, destinations);
        vm.prank(bridgeGovernor);
        bridgeFactory.governorCall(
            SPENDER_ID, abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(1), Mainnet.EARN_VAULT)
        );
    }

    // ------------------------------------------------------------------
    // Report
    // ------------------------------------------------------------------

    function _report() internal {
        string memory out = string.concat(
            "# Private spend callback gas, Tempo mainnet fork\n\n",
            "Block ",
            vm.toString(block.number),
            ", chain ",
            vm.toString(block.chainid),
            ". Callback cap ",
            vm.toString(uint256(CALLBACK_GAS)),
            ". Change returned per spend: ",
            vm.toString(CHANGE),
            " units plus portal fees.\n\n",
            "| Spend | USD | Callback, first | Callback, second | Portal delivery, first | Portal delivery, second | Callback data bytes |\n",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n"
        );
        for (uint256 i; i < rows.length; ++i) {
            Row memory r = rows[i];
            out = string.concat(
                out,
                "| ",
                r.kind,
                " | ",
                vm.toString(r.dollars),
                " | ",
                vm.toString(r.firstGas),
                " | ",
                vm.toString(r.secondGas),
                " | ",
                vm.toString(r.firstDeliver),
                " | ",
                vm.toString(r.secondDeliver),
                " | ",
                vm.toString(r.dataBytes),
                " |\n"
            );
        }
        console.log(out);
        vm.writeFile("reports/fork-callback-gas.md", out);
    }
}
