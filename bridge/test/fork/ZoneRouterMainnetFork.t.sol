// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ISpenderHandler, SpenderStatus } from "bridge-spender/src/ISpenderHandler.sol";
import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IPropAMMVenue } from "tempo-earn/interfaces/external/propamm/IPropAMMVenue.sol";
import { EncryptedDepositPayload } from "tempo-earn/interfaces/external/tempo/IZone.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ZoneRouter } from "zone-router/ZoneRouter.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";
import { BridgeSettler } from "zone-router/settlers/BridgeSettler.sol";
import { SendSettler } from "zone-router/settlers/SendSettler.sol";

import { Spend, SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { ITempoEarnVault } from "../../src/interfaces/ITempoEarnVault.sol";

/// @dev Zone 2 on Tempo mainnet (chain 4217): its portal, private stablecoin and par pool, and the two
///      production SingleZoneEarnRouters (stacks A and B) whose setup this suite reproduces.
library Zone2 {
    uint256 internal constant CHAIN_ID = 4217;
    uint32 internal constant ZONE_ID = 2;
    address internal constant PORTAL = 0x5Ad0000000000000000000000000000000000002;
    /// @dev The Zone's private stablecoin and the pool's base token.
    address internal constant DLUSD = 0x20c0000000000000000000006fD9A167923ba194;
    /// @dev OUSD, both stacks' vault asset and the pool's quote token.
    address internal constant OUSD = 0x20c0000000000000000000006a37DA5C996874BE;
    /// @dev The production DirectPropAMM pool both stacks convert through at par.
    address internal constant POOL = 0x1E3423c85FE006D27091b9482cAa9520c250f4C6;
    address internal constant ROUTER_A = 0x39E222a35FD3248866Fa3edf22A2aA4b7E067c24;
    address internal constant ROUTER_B = 0x91Bd2e92325DBCa34d64877F19e2a55a2916DC25;
    /// @dev Each stack's refund wallet: a Tempo account with the portal Account role and share-policy membership.
    address internal constant REFUND_A = 0x445F7a27b4C6c9337ba3326264eb97aDa7588Dc9;
    address internal constant REFUND_B = 0x08447533deb21d2f71Bde56C29196bc3d32Ba60B;
}

/// @dev The production router's getters this suite copies its configuration from.
interface ISourceRouter {
    function allowedZoneId() external view returns (uint32);
    function earnVault() external view returns (address);
    function privateAsset() external view returns (address);
    function earnShare() external view returns (address);
    function pool() external view returns (address);
    function customerId() external view returns (bytes32);
    function liquidityStatus()
        external
        view
        returns (bool paused, bool admitted, bool atPar, uint256 depositLiquidity, uint256 redeemLiquidity);
}

interface IZone2Portal {
    function admin() external view returns (address);
    function setGateway(address account, bool allowed) external;
    function isAccessEnforced() external view returns (bool);
    function encryptionKeyCount() external view returns (uint256);
    function calculateDepositFee() external view returns (uint128);
    function currentDepositQueueHash() external view returns (bytes32);
    function depositEncrypted(
        address token,
        uint128 amount,
        uint256 keyIndex,
        EncryptedDepositPayload calldata encrypted,
        address bouncebackRecipient
    ) external returns (bytes32);
    function deliverWithdrawal(
        address token,
        address target,
        uint128 amount,
        bytes32 senderTag,
        uint64 gasLimit,
        bytes calldata data
    ) external;
}

interface IPropAMMAdmin {
    function owner() external view returns (address);
    function guardian() external view returns (address);
    function maxOracleAge() external view returns (uint256);
    function setTakerAllowed(address taker, bool allowed) external;
    function setRecipientAllowed(address recipient, bool allowed) external;
    function pause() external;
}

interface IBridgeClone {
    function publicCall(bytes calldata data) external;
}

/// @notice Delivers a withdrawal as the sequencer's batch does: the portal's own deliverWithdrawal escrows the
///         input to the messenger, relays the capped callback and, on an access-enforced portal, requires a
///         deposit back. A revert here is a bounce back to the Zone.
contract PortalDriver {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 internal constant SENDER_TAG = keccak256("fork.zone2.sender-tag");

    function deliver(address target, address token, uint128 amount, uint64 gasLimit, bytes calldata data)
        external
        returns (bool ok, bytes memory revertData, uint256 gasUsed)
    {
        vm.prank(Zone2.PORTAL);
        uint256 before = gasleft();
        try IZone2Portal(Zone2.PORTAL).deliverWithdrawal(token, target, amount, SENDER_TAG, gasLimit, data) {
            ok = true;
        } catch (bytes memory reason) {
            revertData = reason;
        }
        gasUsed = before - gasleft();
    }
}

/// @notice Every major ZoneRouter flow on a Tempo mainnet fork, with a router set up as each of Zone 2's
///         production Earn stacks is and its live SingleZoneEarnRouter as the reference:
///         - Earn deposit and redeem through the production DirectPropAMM pool at par;
///         - Bridge card spends, private through the router and public through Bridge's clone;
///         - sends to a public address through SendSettler, as is, redeemed or converted at par;
///         - refunds into the Zone;
///         - the pool's guards and Zone 2's closed loop.
/// @dev Inert unless forked to Tempo mainnet: pass --fork-url, or set FORK_URL. Needs mainnet's active
///      hardfork for its TIP-403 state:
///      forge test --match-path test/fork/ZoneRouterMainnetFork.t.sol --fork-url https://rpc.tempo.xyz --hardfork tempo:T12 -vv
contract ZoneRouterMainnetForkTest is Test {
    /// @dev Bridge's callback gas, used for every op so each flow runs under the cap cards use.
    uint64 internal constant CALLBACK_GAS = 3_000_000;
    bytes32 internal constant SPENDER_ID = keccak256("bridge.card-program.zone2-fork");
    bytes2 internal constant PREFIX_TEMPO_SPEND = "TS";
    /// @dev Input each spend or send carries above what it pays, returned to the Zone as change.
    uint256 internal constant CHANGE = 10_000; // 0.01
    /// @dev How far a ZoneRouter Earn op's delivery gas may differ from the production router's.
    uint256 internal constant GAS_TOLERANCE = 10_000;

    struct Stack {
        string name;
        ISourceRouter source;
        ZoneRouter router;
        SendSettler sender;
        address refund;
        address vault;
        address share;
    }

    struct Delivery {
        bool ok;
        bytes revertData;
        uint256 gasUsed;
        int256 portalIn;
        int256 portalOut;
        int256 poolDlusd;
        int256 poolOusd;
    }

    bool internal forked;
    Stack[] internal stacks;

    SpenderFactory internal bridgeFactory;
    address internal clone;
    BridgeSettler internal settler;
    ZoneRouterFactory internal routerFactory;
    PortalDriver internal driver;

    address internal bridgeAdmin = makeAddr("bridge.admin");
    address internal bridgeGovernor = makeAddr("bridge.governor");
    address internal bridgeManager = makeAddr("bridge.manager");
    address internal bridgePauser = makeAddr("bridge.pauser");
    address internal settlement = makeAddr("bridge.settlement");
    address internal cardholder = makeAddr("public.cardholder");
    address internal recipient = makeAddr("send.recipient");
    uint256 internal actionSeq;

    function setUp() public {
        if (block.chainid != Zone2.CHAIN_ID) {
            string memory url = vm.envOr("FORK_URL", string(""));
            if (bytes(url).length == 0) return;
            vm.createSelectFork(url);
        }
        forked = true;

        driver = new PortalDriver();
        _deployBridge();
        settler = new BridgeSettler(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID);
        routerFactory = ZoneRouterFactory(deployCode("ZoneRouterFactory.sol:ZoneRouterFactory"));
        _addStack("A", ISourceRouter(Zone2.ROUTER_A), Zone2.REFUND_A);
        _addStack("B", ISourceRouter(Zone2.ROUTER_B), Zone2.REFUND_B);

        vm.label(Zone2.PORTAL, "Zone2Portal");
        vm.label(Zone2.POOL, "DirectPropAMM");
        vm.label(Zone2.DLUSD, "DLUSD");
        vm.label(Zone2.OUSD, "OUSD");
        vm.label(address(settler), "BridgeSettler");
        vm.label(clone, "Bridge.SpenderClone");
    }

    // ------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------

    function test_setup_matchesProduction() public {
        if (!forked) vm.skip(true);
        assertTrue(IZone2Portal(Zone2.PORTAL).isAccessEnforced(), "Zone 2 is closed-loop");
        for (uint256 i; i < stacks.length; ++i) {
            Stack storage s = stacks[i];
            assertEq(s.router.allowedZoneId(), s.source.allowedZoneId(), "zone");
            assertEq(s.router.earnVault(), s.source.earnVault(), "vault");
            assertEq(s.router.privateAsset(), s.source.privateAsset(), "private asset");
            assertEq(s.router.earnShare(), s.source.earnShare(), "share");
            assertEq(address(s.router.pool()), s.source.pool(), "pool");
            assertEq(s.router.customerId(), s.source.customerId(), "customer ID");
            assertTrue(s.router.supportsFlow(0) && s.router.supportsFlow(1) && s.router.supportsFlow(2), "ops");
            address[] memory listed = s.router.settlers();
            assertEq(listed.length, 2, "settlers");
            assertEq(listed[0], address(settler), "BridgeSettler");
            assertEq(listed[1], address(s.sender), "SendSettler");

            (bool paused, bool admitted, bool atPar, uint256 depositLiquidity, uint256 redeemLiquidity) =
                s.router.liquidityStatus();
            (bool srcPaused, bool srcAdmitted, bool srcAtPar, uint256 srcDeposit, uint256 srcRedeem) =
                s.source.liquidityStatus();
            assertEq(paused, srcPaused, "paused");
            assertTrue(admitted && srcAdmitted, "admitted");
            assertEq(atPar, srcAtPar, "par");
            assertTrue(atPar && !paused, "pool live at par");
            assertEq(depositLiquidity, srcDeposit, "deposit liquidity");
            assertEq(redeemLiquidity, srcRedeem, "redeem liquidity");
        }
    }

    // ------------------------------------------------------------------
    // Earn: ops 0 and 1 do exactly what the production router does
    // ------------------------------------------------------------------

    function test_earn_depositMatchesProduction() public {
        if (!forked) vm.skip(true);
        uint256[3] memory dollars = [uint256(1), 250, 25_000];
        for (uint256 i; i < stacks.length; ++i) {
            Stack storage s = stacks[i];
            for (uint256 j; j < dollars.length; ++j) {
                uint128 amount = uint128(dollars[j] * 1e6);
                bytes memory data = _earnData(ZoneRouter.Op.Deposit, amount, s);

                uint256 snapshot = vm.snapshotState();
                Delivery memory old = _deliver(address(s.source), Zone2.DLUSD, s.share, amount, data);
                vm.revertToState(snapshot);
                Delivery memory neu = _deliver(address(s.router), Zone2.DLUSD, s.share, amount, data);
                vm.revertToState(snapshot);

                assertTrue(old.ok, _reason("production deposit", old));
                assertTrue(neu.ok, _reason("ZoneRouter deposit", neu));
                _assertSame(old, neu);
                assertApproxEqAbs(neu.gasUsed, old.gasUsed, GAS_TOLERANCE, "deposit gas matches production");
                assertEq(neu.portalIn, -int256(uint256(amount)), "DLUSD left the portal");
                // The vault has no deposit preview: the returned shares must redeem for the deposit, less rounding.
                assertGt(neu.portalOut, 0, "shares returned to the Zone");
                assertApproxEqAbs(
                    IEarnVault(s.vault).previewRedeem(uint256(neu.portalOut)), amount, 2, "shares worth the deposit"
                );
                // Par: the pool takes every DLUSD unit and pays exactly as many OUSD units.
                assertEq(neu.poolDlusd, int256(uint256(amount)), "pool DLUSD in");
                assertEq(neu.poolOusd, -int256(uint256(amount)), "pool OUSD out");
                _logGas("Earn deposit", s, dollars[j], neu.gasUsed, old.gasUsed);
            }
        }
    }

    function test_earn_redeemMatchesProduction() public {
        if (!forked) vm.skip(true);
        uint256[3] memory dollars = [uint256(1), 250, 25_000];
        for (uint256 i; i < stacks.length; ++i) {
            Stack storage s = stacks[i];
            for (uint256 j; j < dollars.length; ++j) {
                uint256 snapshot = vm.snapshotState();
                // A deposit first, so the portal escrows the shares the redeem withdraws.
                uint128 shares = _depositThroughRouter(s, uint128(dollars[j] * 1e6));
                uint256 expectedOut = IEarnVault(s.vault).previewRedeem(shares);
                bytes memory data = _earnData(ZoneRouter.Op.Redeem, shares, s, uint128(expectedOut));

                uint256 afterDeposit = vm.snapshotState();
                Delivery memory old = _deliver(address(s.source), s.share, Zone2.DLUSD, shares, data);
                vm.revertToState(afterDeposit);
                Delivery memory neu = _deliver(address(s.router), s.share, Zone2.DLUSD, shares, data);
                vm.revertToState(snapshot);

                assertTrue(old.ok, _reason("production redeem", old));
                assertTrue(neu.ok, _reason("ZoneRouter redeem", neu));
                _assertSame(old, neu);
                assertApproxEqAbs(neu.gasUsed, old.gasUsed, GAS_TOLERANCE, "redeem gas matches production");
                assertEq(neu.portalIn, -int256(uint256(shares)), "shares left the portal");
                assertEq(neu.portalOut, int256(expectedOut), "DLUSD returned to the Zone");
                assertEq(neu.poolOusd, int256(expectedOut), "pool OUSD in");
                assertEq(neu.poolDlusd, -int256(expectedOut), "pool DLUSD out");
                assertApproxEqAbs(expectedOut, dollars[j] * 1e6, 2, "round trip at par");
                _logGas("Earn redeem", s, dollars[j], neu.gasUsed, old.gasUsed);
            }
        }
    }

    // ------------------------------------------------------------------
    // Card spends: private through the router, public through Bridge's clone
    // ------------------------------------------------------------------

    function test_cardSpend_privateStablecoin() public {
        if (!forked) vm.skip(true);
        uint256 amount = 42_500_000; // 42.50
        for (uint256 i; i < stacks.length; ++i) {
            Stack storage s = stacks[i];
            uint256 snapshot = vm.snapshotState();
            bytes memory data = _cardData(s, amount, address(0), 0, amount);
            uint256 paidBefore = ITIP20(Zone2.DLUSD).balanceOf(settlement);

            Delivery memory d = _deliver(address(s.router), Zone2.DLUSD, Zone2.DLUSD, uint128(amount + CHANGE), data);
            assertTrue(d.ok, _reason("DLUSD card spend", d));
            assertEq(ITIP20(Zone2.DLUSD).balanceOf(settlement) - paidBefore, amount, "settlement paid in DLUSD");
            assertEq(d.portalIn, -int256(amount), "only the spend left the Zone");
            assertEq(d.poolDlusd, 0, "no conversion");
            _assertNothingHeld(s);
            _logGas("Card spend, private DLUSD", s, amount / 1e6, d.gasUsed, 0);
            vm.revertToState(snapshot);
        }
    }

    function test_cardSpend_privateEarn() public {
        if (!forked) vm.skip(true);
        uint256 amount = 42_500_000; // 42.50
        for (uint256 i; i < stacks.length; ++i) {
            Stack storage s = stacks[i];
            uint256 snapshot = vm.snapshotState();
            _depositThroughRouter(s, 100e6);
            uint256 maxShares = _maxShares(s, amount);
            bytes memory data = _cardData(s, amount, s.vault, maxShares, maxShares);
            uint256 paidBefore = ITIP20(Zone2.OUSD).balanceOf(settlement);

            Delivery memory d = _deliver(address(s.router), s.share, s.share, uint128(maxShares + CHANGE), data);
            assertTrue(d.ok, _reason("Earn card spend", d));
            assertEq(ITIP20(Zone2.OUSD).balanceOf(settlement) - paidBefore, amount, "settlement paid in OUSD");
            assertLe(-d.portalIn, int256(maxShares), "no more than maxShares left the Zone");
            assertEq(d.poolOusd, 0, "no pool conversion");
            _assertNothingHeld(s);
            _logGas("Card spend, private Earn", s, amount / 1e6, d.gasUsed, 0);
            vm.revertToState(snapshot);
        }
    }

    /// @dev The public path: the cardholder's own account pays through the clone's PS call, as Bridge's
    ///      access-key transaction does. The router is not involved.
    function test_cardSpend_publicStablecoinAndEarn() public {
        if (!forked) vm.skip(true);
        Stack storage s = stacks[0];
        _whitelistShareHolder(s, cardholder);
        vm.prank(Zone2.PORTAL);
        ITIP20(Zone2.DLUSD).transfer(cardholder, 100e6);
        _publicEarnDeposit(s, cardholder, 100e6);

        vm.startPrank(cardholder);
        ITIP20(Zone2.DLUSD).approve(clone, type(uint256).max);
        ITIP20(s.share).approve(clone, type(uint256).max);
        vm.stopPrank();

        uint256 dlusdBefore = ITIP20(Zone2.DLUSD).balanceOf(settlement);
        _publicSpend(_spend(Zone2.DLUSD, 30e6, address(0), 0));
        assertEq(ITIP20(Zone2.DLUSD).balanceOf(settlement) - dlusdBefore, 30e6, "paid from DLUSD");

        uint256 ousdBefore = ITIP20(Zone2.OUSD).balanceOf(settlement);
        uint256 sharesBefore = ITIP20(s.share).balanceOf(cardholder);
        uint256 required = ITempoEarnVault(s.vault).previewWithdraw(30e6);
        _publicSpend(_spend(Zone2.OUSD, 30e6, s.vault, _maxShares(s, 30e6)));
        assertEq(ITIP20(Zone2.OUSD).balanceOf(settlement) - ousdBefore, 30e6, "paid from Earn");
        assertEq(sharesBefore - ITIP20(s.share).balanceOf(cardholder), required, "burned only what it cost");
        assertEq(ITIP20(s.share).balanceOf(clone), 0, "clone keeps no shares");
    }

    // ------------------------------------------------------------------
    // Sends: a Zone balance paid to a public address through SendSettler
    // ------------------------------------------------------------------

    function test_send_stablecoin() public {
        if (!forked) vm.skip(true);
        Stack storage s = stacks[0];
        uint128 amount = 25e6;
        bytes memory data = _sendData(s, Zone2.DLUSD, amount, address(0), amount);
        Delivery memory d = _deliver(address(s.router), Zone2.DLUSD, Zone2.DLUSD, uint128(amount + CHANGE), data);
        assertTrue(d.ok, _reason("DLUSD send", d));
        assertEq(ITIP20(Zone2.DLUSD).balanceOf(recipient), amount, "recipient paid");
        assertEq(d.portalIn, -int256(uint256(amount)), "change returned");
        _assertNothingHeld(s);
        _logGas("Send, DLUSD", s, amount / 1e6, d.gasUsed, 0);
    }

    function test_send_earnShare() public {
        if (!forked) vm.skip(true);
        Stack storage s = stacks[0];
        _whitelistShareHolder(s, recipient);
        uint128 shares = _depositThroughRouter(s, 50e6);
        uint128 amount = shares / 2;
        bytes memory data = _sendData(s, s.share, amount, address(0), amount);
        Delivery memory d = _deliver(address(s.router), s.share, s.share, shares, data);
        assertTrue(d.ok, _reason("EarnShare send", d));
        assertEq(ITIP20(s.share).balanceOf(recipient), amount, "recipient holds the shares");
        assertEq(d.portalIn, -int256(uint256(amount)), "change returned");
        _assertNothingHeld(s);
        _logGas("Send, EarnShare", s, 25, d.gasUsed, 0);
    }

    function test_send_earnRedeemedToVaultAsset() public {
        if (!forked) vm.skip(true);
        Stack storage s = stacks[0];
        _depositThroughRouter(s, 50e6);
        uint128 amount = 20e6;
        uint256 maxShares = _maxShares(s, amount);
        bytes memory data = _sendData(s, Zone2.OUSD, amount, s.vault, maxShares);
        Delivery memory d = _deliver(address(s.router), s.share, s.share, uint128(maxShares + CHANGE), data);
        assertTrue(d.ok, _reason("Earn send as OUSD", d));
        assertEq(ITIP20(Zone2.OUSD).balanceOf(recipient), amount, "recipient paid OUSD");
        assertLe(-d.portalIn, int256(maxShares), "no more than maxShares left the Zone");
        assertEq(d.poolOusd, 0, "no conversion");
        _assertNothingHeld(s);
        _logGas("Send, Earn as OUSD", s, amount / 1e6, d.gasUsed, 0);
    }

    function test_send_earnConvertedAtPar() public {
        if (!forked) vm.skip(true);
        Stack storage s = stacks[0];
        _depositThroughRouter(s, 50e6);
        uint128 amount = 20e6;
        uint256 maxShares = _maxShares(s, amount);
        bytes memory data = _sendData(s, Zone2.DLUSD, amount, s.vault, maxShares);
        Delivery memory d = _deliver(address(s.router), s.share, s.share, uint128(maxShares + CHANGE), data);
        assertTrue(d.ok, _reason("Earn send as DLUSD", d));
        assertEq(ITIP20(Zone2.DLUSD).balanceOf(recipient), amount, "recipient paid DLUSD");
        assertEq(d.poolOusd, int256(uint256(amount)), "pool OUSD in");
        assertEq(d.poolDlusd, -int256(uint256(amount)), "pool DLUSD out at par");
        _assertNothingHeld(s);
        _logGas("Send, Earn as DLUSD", s, amount / 1e6, d.gasUsed, 0);
    }

    // ------------------------------------------------------------------
    // Refunds: an admitted wallet deposits back into the Zone, with no router
    // ------------------------------------------------------------------

    function test_refund_depositsIntoZone() public {
        if (!forked) vm.skip(true);
        Stack storage s = stacks[0];
        uint128 amount = 12_340_000; // 12.34
        vm.prank(Zone2.PORTAL);
        ITIP20(Zone2.DLUSD).transfer(s.refund, amount);

        IZone2Portal portal = IZone2Portal(Zone2.PORTAL);
        uint256 escrowBefore = ITIP20(Zone2.DLUSD).balanceOf(Zone2.PORTAL);
        bytes32 queueBefore = portal.currentDepositQueueHash();
        uint256 keyIndex = portal.encryptionKeyCount() - 1;
        vm.startPrank(s.refund);
        ITIP20(Zone2.DLUSD).approve(Zone2.PORTAL, amount);
        portal.depositEncrypted(Zone2.DLUSD, amount, keyIndex, _encrypted(), s.refund);
        vm.stopPrank();

        assertEq(ITIP20(Zone2.DLUSD).balanceOf(Zone2.PORTAL) - escrowBefore, amount, "escrowed for the Zone");
        assertTrue(portal.currentDepositQueueHash() != queueBefore, "deposit queued");
    }

    function test_refund_unadmittedWalletRejected() public {
        if (!forked) vm.skip(true);
        address stranger = makeAddr("refund.stranger");
        vm.prank(Zone2.PORTAL);
        ITIP20(Zone2.DLUSD).transfer(stranger, 1e6);
        IZone2Portal portal = IZone2Portal(Zone2.PORTAL);
        uint256 keyIndex = portal.encryptionKeyCount() - 1;
        vm.startPrank(stranger);
        ITIP20(Zone2.DLUSD).approve(Zone2.PORTAL, 1e6);
        vm.expectRevert();
        portal.depositEncrypted(Zone2.DLUSD, 1e6, keyIndex, _encrypted(), stranger);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Guards: the pool's and the Zone's bounce both routers alike
    // ------------------------------------------------------------------

    function test_guard_pausedPool() public {
        if (!forked) vm.skip(true);
        IPropAMMAdmin pool = IPropAMMAdmin(Zone2.POOL);
        vm.prank(pool.guardian());
        pool.pause();
        _assertPoolGuardBounces();
    }

    function test_guard_staleOracle() public {
        if (!forked) vm.skip(true);
        vm.warp(block.timestamp + IPropAMMAdmin(Zone2.POOL).maxOracleAge() + 1);
        _assertPoolGuardBounces();
    }

    function test_guard_unadmittedRouter() public {
        if (!forked) vm.skip(true);
        Stack storage s = stacks[0];
        vm.prank(IPropAMMAdmin(Zone2.POOL).owner());
        IPropAMMAdmin(Zone2.POOL).setTakerAllowed(address(s.router), false);
        (, bool admitted,,,) = s.router.liquidityStatus();
        assertFalse(admitted, "readiness reports it");
        uint128 amount = 10e6;
        bytes memory data = _earnData(ZoneRouter.Op.Deposit, amount, s);
        Delivery memory d = _deliver(address(s.router), Zone2.DLUSD, s.share, amount, data);
        assertFalse(d.ok, "deposit bounces");
    }

    /// @dev Zone 2 enforces its closed loop: a callback that returns nothing to the Zone bounces, so a spend
    ///      must carry change above what it pays.
    function test_guard_closedLoopNeedsChange() public {
        if (!forked) vm.skip(true);
        Stack storage s = stacks[0];
        uint256 amount = 10e6;
        bytes memory data = _cardData(s, amount, address(0), 0, amount);
        Delivery memory d = _deliver(address(s.router), Zone2.DLUSD, Zone2.DLUSD, uint128(amount), data);
        assertFalse(d.ok, "exact spend bounces");
        assertEq(bytes4(d.revertData), bytes4(keccak256("CallbackDidNotReturnToZone()")), "closed loop");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev With the pool unusable, Earn ops bounce on both routers with the same error, while a stablecoin
    ///      card spend, which needs no conversion, still settles.
    function _assertPoolGuardBounces() internal {
        for (uint256 i; i < stacks.length; ++i) {
            Stack storage s = stacks[i];
            uint128 amount = 10e6;
            bytes memory data = _earnData(ZoneRouter.Op.Deposit, amount, s);
            uint256 snapshot = vm.snapshotState();
            Delivery memory old = _deliver(address(s.source), Zone2.DLUSD, s.share, amount, data);
            vm.revertToState(snapshot);
            Delivery memory neu = _deliver(address(s.router), Zone2.DLUSD, s.share, amount, data);
            vm.revertToState(snapshot);
            assertFalse(old.ok, "production router bounces");
            assertFalse(neu.ok, "ZoneRouter bounces");
            assertEq(neu.revertData, old.revertData, "same revert");

            bytes memory spendData = _cardData(s, amount, address(0), 0, amount);
            Delivery memory spend =
                _deliver(address(s.router), Zone2.DLUSD, Zone2.DLUSD, uint128(amount + CHANGE), spendData);
            assertTrue(spend.ok, _reason("DLUSD card spend under a pool guard", spend));
            vm.revertToState(snapshot);
        }
    }

    /// @dev What each production stack has, done for its ZoneRouter, plus what sends need: Zone 2's admin
    ///      registers the router as a callback gateway, the pool operator admits the router and the
    ///      SendSettler as taker and recipient, and the share policy admits every contract that holds shares
    ///      within a callback.
    function _addStack(string memory name, ISourceRouter source, address refund) internal {
        address vault = source.earnVault();
        SendSettler sender = new SendSettler(
            IEarnVault(vault), IPropAMMVenue(source.pool()), keccak256(abi.encode("fork.send-settler", name))
        );

        ZoneRouter.Mode memory mode;
        mode.zoneId = source.allowedZoneId();
        mode.enabledOps = uint8((1 << 0) | (1 << 1) | (1 << 2));
        mode.earnVault = vault;
        mode.privateAsset = source.privateAsset();
        mode.pool = source.pool();
        mode.customerId = source.customerId();
        mode.settlers = new address[](2);
        mode.settlers[0] = address(settler);
        mode.settlers[1] = address(sender);
        ZoneRouter router = ZoneRouter(routerFactory.deploy(mode));

        // The production routers hold a small private-asset balance so the token's balance slot for them
        // stays allocated; without it every op pays Tempo's ~250k slot creation. Seed the same.
        uint256 seed = ITIP20(mode.privateAsset).balanceOf(address(source));
        assertGt(seed, 0, "production router keeps a private-asset seed");
        vm.prank(Zone2.PORTAL);
        ITIP20(mode.privateAsset).transfer(address(router), seed);

        IZone2Portal portal = IZone2Portal(Zone2.PORTAL);
        vm.prank(portal.admin());
        portal.setGateway(address(router), true);

        IPropAMMAdmin pool = IPropAMMAdmin(mode.pool);
        vm.startPrank(pool.owner());
        pool.setTakerAllowed(address(router), true);
        pool.setRecipientAllowed(address(router), true);
        pool.setTakerAllowed(address(sender), true);
        pool.setRecipientAllowed(address(sender), true);
        vm.stopPrank();

        stacks.push();
        Stack storage s = stacks[stacks.length - 1];
        s.name = name;
        s.source = source;
        s.router = router;
        s.sender = sender;
        s.refund = refund;
        s.vault = vault;
        s.share = source.earnShare();
        _whitelistShareHolder(s, address(router));
        _whitelistShareHolder(s, address(settler));
        _whitelistShareHolder(s, address(sender));
        _whitelistShareHolder(s, clone);

        vm.prank(bridgeGovernor);
        bridgeFactory.governorCall(SPENDER_ID, abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(1), vault));

        vm.label(address(router), string.concat("ZoneRouter.", name));
        vm.label(address(sender), string.concat("SendSettler.", name));
        vm.label(address(source), string.concat("SingleZoneEarnRouter.", name));
    }

    function _whitelistShareHolder(Stack storage s, address account) internal {
        uint64 policy = ITIP20(s.share).transferPolicyId();
        (, address policyAdmin) = StdPrecompiles.TIP403_REGISTRY.policyData(policy);
        vm.prank(policyAdmin);
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyWhitelist(policy, account, true);
    }

    /// @dev A public Earn deposit: OUSD from the pool's inventory, deposited into the vault by account.
    function _publicEarnDeposit(Stack storage s, address account, uint256 assets) internal {
        vm.prank(Zone2.POOL);
        ITIP20(Zone2.OUSD).transfer(account, assets);
        vm.startPrank(account);
        ITIP20(Zone2.OUSD).approve(s.vault, assets);
        IEarnVault(s.vault).deposit(assets, account, 1);
        vm.stopPrank();
    }

    function _publicSpend(Spend memory spend) internal {
        vm.prank(cardholder);
        IBridgeClone(clone).publicCall(abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("PS"), abi.encode(spend)));
    }

    /// @return shares The EarnShares a deposit of amount DLUSD through the stack's router returned to the Zone.
    function _depositThroughRouter(Stack storage s, uint128 amount) internal returns (uint128 shares) {
        bytes memory data = _earnData(ZoneRouter.Op.Deposit, amount, s);
        Delivery memory d = _deliver(address(s.router), Zone2.DLUSD, s.share, amount, data);
        assertTrue(d.ok, _reason("setup deposit", d));
        shares = uint128(uint256(d.portalOut));
    }

    function _deliver(address target, address tokenIn, address tokenOut, uint128 amount, bytes memory data)
        internal
        returns (Delivery memory d)
    {
        uint256 inBefore = ITIP20(tokenIn).balanceOf(Zone2.PORTAL);
        uint256 outBefore = ITIP20(tokenOut).balanceOf(Zone2.PORTAL);
        uint256 dlusdBefore = ITIP20(Zone2.DLUSD).balanceOf(Zone2.POOL);
        uint256 ousdBefore = ITIP20(Zone2.OUSD).balanceOf(Zone2.POOL);
        (d.ok, d.revertData, d.gasUsed) = driver.deliver(target, tokenIn, amount, CALLBACK_GAS, data);
        d.portalIn = int256(ITIP20(tokenIn).balanceOf(Zone2.PORTAL)) - int256(inBefore);
        d.portalOut = int256(ITIP20(tokenOut).balanceOf(Zone2.PORTAL)) - int256(outBefore);
        d.poolDlusd = int256(ITIP20(Zone2.DLUSD).balanceOf(Zone2.POOL)) - int256(dlusdBefore);
        d.poolOusd = int256(ITIP20(Zone2.OUSD).balanceOf(Zone2.POOL)) - int256(ousdBefore);
    }

    function _assertSame(Delivery memory old, Delivery memory neu) internal pure {
        assertEq(neu.portalIn, old.portalIn, "same input");
        assertEq(neu.portalOut, old.portalOut, "same return");
        assertEq(neu.poolDlusd, old.poolDlusd, "same pool DLUSD");
        assertEq(neu.poolOusd, old.poolOusd, "same pool OUSD");
    }

    /// @dev No router or settler keeps anything beyond the router's private-asset seed, which equals the
    ///      production router's.
    function _assertNothingHeld(Stack storage s) internal view {
        address[3] memory tokens = [Zone2.DLUSD, Zone2.OUSD, s.share];
        for (uint256 i; i < tokens.length; ++i) {
            uint256 seed = ITIP20(tokens[i]).balanceOf(address(s.source));
            assertEq(ITIP20(tokens[i]).balanceOf(address(s.router)), seed, "router holds only its seed");
            assertEq(ITIP20(tokens[i]).balanceOf(address(settler)), 0, "BridgeSettler holds nothing");
            assertEq(ITIP20(tokens[i]).balanceOf(address(s.sender)), 0, "SendSettler holds nothing");
        }
    }

    /// @dev Bridge's buffer for price moves between its quote and settlement: 10 bps.
    function _maxShares(Stack storage s, uint256 assets) internal view returns (uint256) {
        return ITempoEarnVault(s.vault).previewWithdraw(assets) * 10_010 / 10_000 + 1;
    }

    /// @dev Ops 0 and 1, byte for byte as the production router takes them, for a deposit at par.
    function _earnData(ZoneRouter.Op op, uint128 amount, Stack storage s) internal returns (bytes memory) {
        return _earnData(op, amount, s, amount);
    }

    /// @dev EarnVault rejects a zero minimum, so the vault leg's minimum is the deposit or the expected output.
    function _earnData(ZoneRouter.Op op, uint128 amount, Stack storage s, uint128 minOut)
        internal
        returns (bytes memory)
    {
        bool deposit = op == ZoneRouter.Op.Deposit;
        IZone2Portal portal = IZone2Portal(Zone2.PORTAL);
        return abi.encode(
            ZoneRouter.CallbackData({
                op: op,
                minVaultAssets: deposit ? amount : minOut,
                minEarnShares: deposit ? 1 : 0,
                minOutputAmount: deposit ? 0 : minOut,
                actionId: keccak256(abi.encode("fork.zone2.action", ++actionSeq)),
                zoneReturn: ZoneRouter.ZoneReturn({
                    keyIndex: portal.encryptionKeyCount() - 1, encrypted: _encrypted(), refundRecipient: s.refund
                })
            })
        );
    }

    /// @dev A card spend: from DLUSD when vault is zero, otherwise redeemed from the vault's shares into OUSD.
    function _cardData(Stack storage s, uint256 amount, address vault, uint256 maxShares, uint256 maxInput)
        internal
        returns (bytes memory)
    {
        Spend memory spend = _spend(vault == address(0) ? Zone2.DLUSD : Zone2.OUSD, amount, vault, maxShares);
        return _spendData(s, address(settler), maxInput, abi.encode(spend));
    }

    /// @dev A send of amount token to the public recipient, redeemed from vault's shares when vault is set.
    function _sendData(Stack storage s, address token, uint128 amount, address vault, uint256 maxInput)
        internal
        returns (bytes memory)
    {
        SendSettler.Send memory send = SendSettler.Send({
            to: recipient,
            token: token,
            amount: amount,
            vault: vault,
            ref: keccak256(abi.encode("fork.zone2.send", ++actionSeq))
        });
        return _spendData(s, address(s.sender), maxInput, abi.encode(send));
    }

    function _spendData(Stack storage s, address target, uint256 maxInput, bytes memory settlerData)
        internal
        view
        returns (bytes memory)
    {
        IZone2Portal portal = IZone2Portal(Zone2.PORTAL);
        return abi.encode(
            ZoneRouter.SpendData({
                op: ZoneRouter.Op.Spend,
                settler: target,
                maxInput: uint128(maxInput),
                settlerData: settlerData,
                zoneReturn: ZoneRouter.SpendReturn({
                    keyIndex: portal.encryptionKeyCount() - 1,
                    encrypted: _encrypted(),
                    refundRecipient: s.refund,
                    maxDepositFee: portal.calculateDepositFee()
                })
            })
        );
    }

    function _spend(address token, uint256 amount, address vault, uint256 maxShares) internal returns (Spend memory) {
        return Spend({
            spenderId: SPENDER_ID,
            token: token,
            amount: amount,
            destination: settlement,
            vault: vault,
            fromVault: vault == address(0) ? 0 : amount,
            maxShares: maxShares,
            ref: keccak256(abi.encode("fork.zone2.ref", ++actionSeq))
        });
    }

    /// @dev A payload the portal accepts: a valid secp256k1 X (the generator's) and a 64-byte ciphertext.
    function _encrypted() internal pure returns (EncryptedDepositPayload memory) {
        return EncryptedDepositPayload({
            ephemeralPubkeyX: 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
            ephemeralPubkeyYParity: 0x02,
            ciphertext: abi.encodePacked(keccak256("ciphertext.0"), keccak256("ciphertext.1")),
            nonce: bytes12(keccak256("nonce")),
            tag: bytes16(keccak256("tag"))
        });
    }

    function _reason(string memory flow, Delivery memory d) internal pure returns (string memory) {
        return string.concat(flow, " bounced: ", vm.toString(d.revertData));
    }

    /// @dev One line per flow: delivery gas through the portal, and the production router's when compared.
    function _logGas(string memory flow, Stack storage s, uint256 dollars, uint256 gas, uint256 productionGas)
        internal
        view
    {
        string memory line =
            string.concat(flow, ", stack ", s.name, ", ", vm.toString(dollars), " USD: gas ", vm.toString(gas));
        if (productionGas != 0) line = string.concat(line, " (production ", vm.toString(productionGas), ")");
        console.log(line);
    }

    /// @dev Bridge's factory and a program clone with the TS handler, its settlement wallet as destination.
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
        address[] memory destinations = new address[](1);
        destinations[0] = settlement;
        vm.prank(bridgeManager);
        clone = bridgeFactory.createSpender(SPENDER_ID, destinations);
    }
}
