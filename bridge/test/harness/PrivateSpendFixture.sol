// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { EncryptedDepositPayload } from "tempo-earn/interfaces/external/tempo/IZone.sol";
import { IAccountKeychain } from "tempo-std/interfaces/IAccountKeychain.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ZoneRouter } from "zone-router/ZoneRouter.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";

import { Spend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { IZoneOutbox } from "../../src/interfaces/IZoneOutbox.sol";
import { AccessKeys } from "./AccessKeys.sol";
import { isStandingOrNone } from "./StandingApproval.sol";
import { TxCall } from "./lib/TempoTx.sol";
import { BridgeSettler } from "zone-router/settlers/BridgeSettler.sol";

/// @notice A Zone with portal and outbox fees switched on, the program's BridgeSettler behind a
///         factory-deployed Spend-mode ZoneRouter registered as the Zone's callback gateway, and
///         cardholders enrolled with Bridge's Zone key, for private spend tests.
abstract contract PrivateSpendFixture is AccessKeys {
    /// @dev The callback gas Bridge requests (docs/bridge/bridge-integration.md).
    uint64 internal callbackGas = 3_000_000;
    /// @dev Tempo base fee, which prices the portal's bounce-back fee.
    uint256 internal constant BASE_FEE = 20 gwei;

    ZoneRouterFactory internal routerFactory;
    ZoneRouter internal zoneRouter;
    BridgeSettler internal settler;
    address internal alice = makeAddr("alice");
    address internal mallory = makeAddr("mallory");
    /// @dev Bridge-controlled Tempo account, one per program and admitted on the Zone, that
    ///      receives a Zone return the Zone rejects. The cardholder is the fallbackRecipient.
    address internal programRefundRecipient = makeAddr("bridge.zone-refund-recipient");

    /// @notice A closed-loop Zone.
    function _setUpPrivateSpend() internal {
        _setUpPrivateSpend(true);
    }

    function _setUpPrivateSpend(bool closedLoop) internal {
        _deployTempo();
        _deployZone(closedLoop);
        settler = new BridgeSettler(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID);
        // From its artifact: inlining the factory, which nests the router, would bloat every test.
        routerFactory = ZoneRouterFactory(deployCode("ZoneRouterFactory.sol:ZoneRouterFactory"));
        zoneRouter = _deployRouter(_settlers(address(settler)));

        vm.fee(BASE_FEE);
        vm.startPrank(zoneAdmin);
        portal.setZoneGasRate(10);
        portal.setBouncebackGas(50_000);
        vm.stopPrank();
        zoneOutbox.setTempoGasRate(1);

        _enrollInZone(alice, 1000e6);
        _enrollInZone(mallory, 100e6);
        _zoneAllowAccount(programRefundRecipient);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @notice Deploys the Spend-mode router for this Zone and `settlers` through the factory and
    ///         registers it as the Zone's callback gateway.
    function _deployRouter(address[] memory settlers) internal returns (ZoneRouter router) {
        ZoneRouter.Mode memory mode;
        mode.zoneId = ZONE_ID;
        mode.enabledOps = uint8(1 << 2);
        mode.settlers = settlers;
        router = ZoneRouter(routerFactory.deploy(mode));
        _zoneRegisterGateway(address(router));
    }

    function _settlers(address one) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = one;
    }

    function _enrollInZone(address user, uint256 amount) internal {
        _zoneAllowAccount(user);
        _mintUsd(user, amount);
        _zoneDeposit(user, address(usd), amount, user);
        _zoneSequence();
    }

    /// @notice `user` deposits `assets` into Tempo Earn and moves the shares into the Zone.
    function _enrollEarnInZone(address user, uint256 assets) internal returns (uint256 shares) {
        _zoneAllowAccount(user);
        _mintUsd(user, assets);
        shares = _depositEarn(user, assets);
        _zoneDeposit(user, address(earnShare), shares, user);
        _zoneSequence();
    }

    /// @notice The least change a withdrawal can carry above `maxInput`: the portal's deposit and
    ///         bounce-back fees plus one unit.
    function _change() internal view returns (uint256) {
        return uint256(portal.calculateDepositFee()) + portal.calculateBouncebackFee() + 1;
    }

    function _spend(uint256 amount, address destination) internal pure returns (Spend memory) {
        return Spend({
            spenderId: SPENDER_ID,
            token: address(0),
            amount: amount,
            destination: destination,
            vault: address(0),
            fromVault: 0,
            maxShares: 0,
            ref: bytes32(0)
        });
    }

    /// @notice A spend of `amount` paid entirely from the Earn vault, burning at most `maxShares`.
    function _earnSpend(uint256 amount, address destination, uint256 maxShares) internal view returns (Spend memory s) {
        s = _spend(amount, destination);
        s.vault = address(earnVault);
        s.fromVault = amount;
        s.maxShares = maxShares;
    }

    /// @notice Callback data for `spend` in the stablecoin, through the program's settler.
    function _callback(Spend memory spend) internal returns (bytes memory) {
        spend.token = address(usd);
        return _callbackAsIs(spend);
    }

    /// @notice Callback data carrying `spend` unchanged through the program's settler, with
    ///         `maxInput` the spend's amount, or its `maxShares` for an Earn spend, and unused input
    ///         returned to alice.
    function _callbackAsIs(Spend memory spend) internal returns (bytes memory) {
        uint256 maxInput = spend.fromVault == 0 ? spend.amount : spend.maxShares;
        return _spendData(address(settler), maxInput, spend);
    }

    /// @notice Spend-op callback data: `settler_` may use at most `maxInput` to settle `spend`, and
    ///         the router returns the rest of the withdrawal to alice in the Zone.
    function _spendData(address settler_, uint256 maxInput, Spend memory spend) internal returns (bytes memory) {
        return abi.encode(
            ZoneRouter.SpendData({
                op: ZoneRouter.Op.Spend,
                settler: settler_,
                maxInput: uint128(maxInput),
                settlerData: abi.encode(spend),
                zoneReturn: _zoneReturn(alice)
            })
        );
    }

    function _zoneReturn(address user) internal returns (ZoneRouter.SpendReturn memory) {
        // The vendored Zone payload and Earn's are the same struct under two names.
        EncryptedDepositPayload memory encrypted = abi.decode(abi.encode(_encryptedTo(user)), (EncryptedDepositPayload));
        return ZoneRouter.SpendReturn({
            keyIndex: 0,
            encrypted: encrypted,
            refundRecipient: programRefundRecipient,
            maxDepositFee: portal.calculateDepositFee()
        });
    }

    /// @notice Moves `input` of `token` from the portal's escrow into the router, as the messenger
    ///         does before it calls `onWithdrawalReceived`.
    function _fundRouter(address token, uint256 input) internal {
        vm.prank(address(portal));
        ITIP20(token).transfer(address(zoneRouter), input);
    }

    /// @notice The router, settler and clone hold none of `token`, the approvals a spend makes are
    ///         none or standing (router to portal, settler to clone, clone to vault), and the router,
    ///         which transfers the settler its input, never approves it.
    function _assertNothingHeld(address token) internal view {
        assertEq(ITIP20(token).balanceOf(address(zoneRouter)), 0, "nothing left in the router");
        assertEq(ITIP20(token).balanceOf(address(settler)), 0, "nothing left in the settler");
        assertEq(ITIP20(token).balanceOf(spender), 0, "nothing left in the clone");
        assertEq(ITIP20(token).allowance(address(zoneRouter), address(settler)), 0, "router -> settler");
        assertTrue(isStandingOrNone(ITIP20(token).allowance(address(zoneRouter), address(portal))), "router -> portal");
        assertTrue(isStandingOrNone(ITIP20(token).allowance(address(settler), spender)), "settler -> clone");
        assertTrue(isStandingOrNone(earnShare.allowance(spender, address(earnVault))), "clone -> vault");
    }

    /// @dev Bridge's Zone key requests the spend for `user` from the outbox.
    function _request(address user, uint256 input, bytes memory callbackData) internal returns (bool) {
        return _request(user, address(usd), input, callbackData);
    }

    /// @dev As `_request`, withdrawing `token` from the Zone.
    function _request(address user, address token, uint256 input, bytes memory callbackData) internal returns (bool) {
        if (keychain.getKey(user, bridgeKey).keyId == address(0)) _authorizeZoneKey(user);
        return _execAsAccessKey(user, _calls(user, token, input, callbackData));
    }

    /// @dev The user signs directly, as any Zone account can.
    function _requestAsSelf(address user, uint256 input, bytes memory callbackData) internal {
        TxCall[] memory calls = _calls(user, address(usd), input, callbackData);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(user);
            (bool ok,) = calls[i].to.call(calls[i].data);
            require(ok, "self request");
        }
    }

    function _calls(address user, address token, uint256 input, bytes memory callbackData)
        internal
        view
        returns (TxCall[] memory calls)
    {
        address zoneToken = address(_zoneTokenOf(token));
        uint256 total = input + zoneOutbox.calculateWithdrawalFee(callbackGas);
        calls = new TxCall[](2);
        calls[0] = TxCall(zoneToken, 0, abi.encodeCall(ITIP20.approve, (address(zoneOutbox), total)));
        calls[1] = TxCall(
            address(zoneOutbox),
            0,
            abi.encodeCall(
                IZoneOutbox.requestWithdrawal,
                (token, address(zoneRouter), uint128(input), bytes32(0), callbackGas, user, callbackData, "")
            )
        );
    }

    function _authorizeZoneKey(address user) internal {
        address[] memory tokens = new address[](2);
        uint256[] memory limits = new uint256[](2);
        tokens[0] = address(_zoneTokenOf(address(usd)));
        tokens[1] = address(_zoneTokenOf(address(earnShare)));
        limits[0] = 1000e6;
        limits[1] = 1000e6;
        IAccountKeychain.CallScope[] memory scopes = new IAccountKeychain.CallScope[](3);
        scopes[0] = _scope(tokens[0], ITIP20.approve.selector, address(zoneOutbox));
        scopes[1] = _scope(tokens[1], ITIP20.approve.selector, address(zoneOutbox));
        scopes[2] = _scope(address(zoneOutbox), IZoneOutbox.requestWithdrawal.selector, address(0));
        _authorizeBridgeKey(user, tokens, limits, scopes);
    }
}
