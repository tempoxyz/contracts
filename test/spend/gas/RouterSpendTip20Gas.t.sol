// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import {
    EncryptedDepositPayload,
    IZoneFactory,
    ZONE_FACTORY_ADDRESS,
    ZONE_MESSENGER_ADDRESS,
    ZoneInfo
} from "../../../src/interfaces/external/tempo/IZone.sol";
import { IEarnVault } from "../../../src/interfaces/earn/IEarnVault.sol";
import { IPropAMMVenue } from "../../../src/interfaces/external/propamm/IPropAMMVenue.sol";
import { ZoneRouter } from "../../../src/zone/ZoneRouter.sol";
import { ZoneRouterFactory } from "../../../src/zone/ZoneRouterFactory.sol";
import { SendSpender } from "../../../src/zone/spenders/SendSpender.sol";
import { CardSpend } from "../../../src/spend/CardSpend.sol";
import { CardSpender } from "../../../src/spend/CardSpender.sol";
import { ICardProvider } from "../../../src/interfaces/spend/ICardProvider.sol";

import { CoreEnv } from "../core/harness/CoreEnv.sol";
import { GasPortal } from "./RouterTip20Gas.t.sol";

/// @notice A Zone router's Spend op end to end on real TIP-20: the Portal's transfer, the messenger's callback,
///         a real spender (SendSpender or a CardSpender) authenticating the router through its real factory.
contract RouterSpendTip20GasTest is CoreEnv {
    uint32 internal constant ZONE = 7;
    GasPortal internal portal;
    ZoneRouterFactory internal zrf;
    ZoneRouter internal zr;
    SendSpender internal sender;
    CardSpender internal card;

    function setUp() public {
        _deployCore();
        _deployMockProgram(false);
        portal = new GasPortal();
        vm.etch(ZONE_FACTORY_ADDRESS, hex"00");
        ZoneInfo memory info;
        info.portal = address(portal);
        vm.mockCall(ZONE_FACTORY_ADDRESS, abi.encodeWithSelector(IZoneFactory.zones.selector, ZONE), abi.encode(info));
        vm.mockCall(
            ZONE_FACTORY_ADDRESS,
            abi.encodeWithSelector(IZoneFactory.isZonePortal.selector, address(portal)),
            abi.encode(true)
        );
        usd.mint(address(portal), 1_000_000e6);
        zrf = new ZoneRouterFactory();
        sender = new SendSpender(address(zrf), IEarnVault(address(0)), IPropAMMVenue(address(0)), bytes32(0));
        card = new CardSpender(ICardProvider(address(mock)), address(zrf));
        ZoneRouter.Mode memory mode;
        mode.zoneId = ZONE;
        mode.enabledOps = 4;
        mode.spenders = new address[](2);
        mode.spenders[0] = address(sender);
        mode.spenders[1] = address(card);
        zr = ZoneRouter(zrf.deploy(mode));
        // Seeds and existing destination balances: steady state.
        usd.mint(address(zr), 1);
        usd.mint(address(sender), 1);
        usd.mint(address(card), 1);
        usd.mint(bob, 1);
        usd.mint(pooledWallet, 1);
        zr.warm(address(usd));
    }

    function _op(uint128 amount, bytes memory data) internal returns (uint256 used) {
        uint256 before = gasleft();
        portal.send(address(usd), address(zr), amount);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        zr.onWithdrawalReceived(ZONE, address(portal), bytes32(0), address(usd), amount, data);
        used = before - gasleft();
    }

    function _spendData(address spender, uint128 maxInput, bytes memory spenderData)
        internal
        view
        returns (bytes memory)
    {
        EncryptedDepositPayload memory e;
        e.ciphertext = hex"01";
        return abi.encode(
            ZoneRouter.SpendData({
                op: ZoneRouter.Op.Spend,
                spender: spender,
                maxInput: maxInput,
                spenderData: spenderData,
                zoneReturn: ZoneRouter.SpendReturn({
                    keyIndex: 0, encrypted: e, refundRecipient: alice, maxDepositFee: 0
                })
            })
        );
    }

    function _send(uint128 amount, bytes32 ref) internal view returns (bytes memory) {
        return
            abi.encode(SendSpender.Send({ to: bob, token: address(usd), amount: amount, vault: address(0), ref: ref }));
    }

    function _card(uint256 amount, bytes32 ref) internal view returns (bytes memory) {
        CardSpend memory s;
        s.program = address(card);
        s.token = address(usd);
        s.amount = amount;
        s.destination = pooledWallet;
        s.ref = ref;
        return abi.encode(s);
    }

    function test_gasRouterSendExact() public {
        _op(100e6, _spendData(address(sender), 100e6, _send(100e6, "1")));
        uint256 used = _op(100e6, _spendData(address(sender), 100e6, _send(100e6, "2")));
        vm.snapshotValue("router-spend-tip20", "send.exact", used);
    }

    function test_gasRouterSendChange() public {
        _op(100e6, _spendData(address(sender), 100e6, _send(60e6, "1")));
        uint256 used = _op(100e6, _spendData(address(sender), 100e6, _send(60e6, "2")));
        vm.snapshotValue("router-spend-tip20", "send.change", used);
    }

    function test_gasRouterCardExact() public {
        _op(100e6, _spendData(address(card), 100e6, _card(100e6, "1")));
        uint256 used = _op(100e6, _spendData(address(card), 100e6, _card(100e6, "2")));
        vm.snapshotValue("router-spend-tip20", "card.exact", used);
    }

    function test_gasRouterCardChange() public {
        _op(100e6, _spendData(address(card), 80e6, _card(60e6, "1")));
        uint256 used = _op(100e6, _spendData(address(card), 80e6, _card(60e6, "2")));
        vm.snapshotValue("router-spend-tip20", "card.change", used);
    }

    function test_gasRouterDeployTwoSpenders() public {
        ZoneRouter.Mode memory mode;
        mode.zoneId = ZONE;
        mode.enabledOps = 4;
        mode.spenders = new address[](2);
        mode.spenders[0] = address(card);
        mode.spenders[1] = address(sender);
        uint256 before = gasleft();
        zrf.deploy(mode);
        vm.snapshotValue("router-spend-tip20", "deploy.two-spenders", before - gasleft());
    }

    /// @dev A router that also redeems: its constructor's standing Portal approval covers the private asset.
    function test_gasRouterSendChangeRedeemRouter() public {
        ZoneRouter.Mode memory mode;
        mode.zoneId = ZONE;
        mode.enabledOps = 6;
        mode.earnVault = address(earnVault);
        mode.privateAsset = address(usd);
        mode.spenders = new address[](1);
        mode.spenders[0] = address(sender);
        zr = ZoneRouter(zrf.deploy(mode));
        usd.mint(address(zr), 1);
        _op(100e6, _spendData(address(sender), 100e6, _send(60e6, "1")));
        uint256 used = _op(100e6, _spendData(address(sender), 100e6, _send(60e6, "2")));
        vm.snapshotValue("router-spend-tip20", "send.change.redeem-router", used);
    }
}
