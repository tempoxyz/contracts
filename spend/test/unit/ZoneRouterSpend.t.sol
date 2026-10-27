// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ISpenderHandler } from "bridge-spender/src/ISpenderHandler.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { EncryptedDepositPayload } from "tempo-earn/interfaces/external/tempo/IZone.sol";
import { ZoneRouter } from "tempo-router/ZoneRouter.sol";
import { ZoneRouterFactory } from "tempo-router/ZoneRouterFactory.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";

import { Spend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { IZoneOutbox } from "../../src/interfaces/IZoneOutbox.sol";
import { BridgeSettler } from "../../src/settler/BridgeSettler.sol";
import { ChangeKeepingSpendHandler } from "../harness/Mocks.sol";
import { PrivateSpendFixture } from "../harness/PrivateSpendFixture.sol";
import { TxCall } from "../harness/lib/TempoTx.sol";

/// @notice Private card spend through a factory-deployed ZoneRouter and BridgeSettler, on a
///         closed-loop Zone with portal and outbox fees on: the docs/router/zone-router.md prototype.
contract ZoneRouterSpendTest is PrivateSpendFixture {
    ZoneRouter internal zoneRouter;
    BridgeSettler internal settler;

    function setUp() public {
        _setUpPrivateSpend();
        settler = new BridgeSettler(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID);
        ZoneRouter.Mode memory mode;
        mode.zoneId = ZONE_ID;
        mode.enabledOps = uint8(1 << 2);
        mode.settlers = new address[](1);
        mode.settlers[0] = address(settler);
        zoneRouter = ZoneRouter(new ZoneRouterFactory().deploy(mode));
        _zoneRegisterGateway(address(zoneRouter));
    }

    function test_stablecoinSpendSettlesAndReturnsChange() public {
        uint256 withdrawalFee = zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS);
        uint256 before = usd.balanceOf(settlement);
        uint256 zoneBefore = _zoneBalance(address(usd), alice);

        Spend memory spend = _spend(40e6, settlement);
        spend.token = address(usd);
        assertTrue(_requestSpend(alice, address(usd), 40e6 + _change(), 40e6, spend));
        _zoneSettle();

        assertTrue(lastCallbackResults[0], "callback settled");
        assertEq(usd.balanceOf(settlement) - before, 40e6, "destination paid");
        assertEq(
            zoneBefore - _zoneBalance(address(usd), alice),
            40e6 + withdrawalFee + portal.calculateDepositFee(),
            "amount plus fees"
        );
        _assertNothingHeld(address(usd));
        assertTrue(_lastSettlementLogged(ZoneRouter.Spent.selector), "router logged");
        assertTrue(_lastSettlementLogged(BridgeSettler.SpendSettled.selector), "settler logged");
    }

    function test_earnSpendBurnsAtMostMaxShares() public {
        uint256 shares = _enrollEarnInZone(alice, 200e6);
        uint256 maxShares = earnVault.previewWithdraw(40e6) + 1;
        uint256 before = usd.balanceOf(settlement);
        uint256 zoneBefore = _zoneBalance(address(earnShare), alice);

        Spend memory spend = _earnSpend(40e6, settlement, maxShares);
        spend.token = address(usd);
        uint256 input = maxShares + _change();
        assertLe(input, shares);
        assertTrue(_requestSpend(alice, address(earnShare), input, maxShares, spend));
        _zoneSettle();

        assertTrue(lastCallbackResults[0], "callback settled");
        assertEq(usd.balanceOf(settlement) - before, 40e6, "destination paid in the vault asset");
        uint256 burned = zoneBefore - _zoneBalance(address(earnShare), alice);
        assertLe(burned, maxShares + zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS) + portal.calculateDepositFee());
        _assertNothingHeld(address(earnShare));
    }

    /// @notice The Cyclops finding: a replaced "TS" handler that pays the destination exactly and
    ///         takes the rest of its approval. ZoneSpendReceiver approves the whole input, change
    ///         included; the router caps the settler at the cardholder's maxInput, so the change
    ///         still returns to the Zone and the handler gets nothing extra.
    function test_replacedHandlerCannotKeepTheChange() public {
        address thief = makeAddr("thief");
        ISpenderHandler keeping =
            ISpenderHandler(address(new ChangeKeepingSpendHandler(IFactory(address(bridgeFactory)), thief)));
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler("TS", keeping);

        uint256 extra = 25e6;
        uint256 withdrawalFee = zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS);
        uint256 zoneBefore = _zoneBalance(address(usd), alice);
        Spend memory spend = _spend(40e6, settlement);
        spend.token = address(usd);
        assertTrue(_requestSpend(alice, address(usd), 40e6 + _change() + extra, 40e6, spend));
        _zoneSettle();

        assertTrue(lastCallbackResults[0], "callback settled");
        assertEq(usd.balanceOf(thief), 0, "handler kept nothing");
        assertEq(
            zoneBefore - _zoneBalance(address(usd), alice),
            40e6 + withdrawalFee + portal.calculateDepositFee(),
            "the change came back"
        );
        _assertNothingHeld(address(usd));
    }

    function test_unlistedSettlerBounces() public {
        BridgeSettler other = new BridgeSettler(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID);
        Spend memory spend = _spend(40e6, settlement);
        spend.token = address(usd);
        uint256 before = usd.balanceOf(settlement);
        bytes memory data = _spendData(address(other), 40e6, spend);
        assertTrue(_requestTo(alice, address(usd), 40e6 + _change(), data));
        _zoneSettle();
        assertFalse(lastCallbackResults[0], "callback rejected");
        assertEq(lastCallbackErrors[0], abi.encodeWithSelector(ZoneRouter.UnknownSettler.selector));
        assertEq(usd.balanceOf(settlement), before, "nothing paid");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _requestSpend(address user, address token, uint256 input, uint256 maxInput, Spend memory spend)
        internal
        returns (bool)
    {
        return _requestTo(user, token, input, _spendData(address(settler), maxInput, spend));
    }

    function _spendData(address settler_, uint256 maxInput, Spend memory spend) internal returns (bytes memory) {
        EncryptedDepositPayload memory encrypted =
            abi.decode(abi.encode(_encryptedTo(alice)), (EncryptedDepositPayload));
        return abi.encode(
            ZoneRouter.SpendData({
                op: ZoneRouter.Op.Spend,
                settler: settler_,
                maxInput: uint128(maxInput),
                settlerData: abi.encode(spend),
                zoneReturn: ZoneRouter.SpendReturn({
                    keyIndex: 0,
                    encrypted: encrypted,
                    refundRecipient: programRefundRecipient,
                    maxDepositFee: portal.calculateDepositFee()
                })
            })
        );
    }

    function _requestTo(address user, address token, uint256 input, bytes memory callbackData) internal returns (bool) {
        if (keychain.getKey(user, bridgeKey).keyId == address(0)) _authorizeZoneKey(user);
        address zoneToken = address(_zoneTokenOf(token));
        uint256 total = input + zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS);
        TxCall[] memory calls = new TxCall[](2);
        calls[0] = TxCall(zoneToken, 0, abi.encodeCall(ITIP20.approve, (address(zoneOutbox), total)));
        calls[1] = TxCall(
            address(zoneOutbox),
            0,
            abi.encodeCall(
                IZoneOutbox.requestWithdrawal,
                (token, address(zoneRouter), uint128(input), bytes32(0), CALLBACK_GAS, user, callbackData, "")
            )
        );
        return _execAsAccessKey(user, calls);
    }

    function _assertNothingHeld(address token) internal view {
        assertEq(ITIP20(token).balanceOf(address(zoneRouter)), 0, "nothing left in the router");
        assertEq(ITIP20(token).balanceOf(address(settler)), 0, "nothing left in the settler");
        assertEq(ITIP20(token).balanceOf(spender), 0, "nothing left in the clone");
        assertEq(ITIP20(token).allowance(address(zoneRouter), address(settler)), 0, "router -> settler");
        assertEq(ITIP20(token).allowance(address(zoneRouter), address(portal)), 0, "router -> portal");
        assertEq(ITIP20(token).allowance(address(settler), spender), 0, "settler -> clone");
    }
}
