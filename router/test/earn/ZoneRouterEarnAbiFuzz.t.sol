// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Fuzz fixtures are explicitly bounded before narrowing to uint128; the low-level call is the ABI fuzz target.
// forge-lint: disable-start(unsafe-typecast,low-level-calls)

import { ZoneRouter } from "../../src/ZoneRouter.sol";
import { ZoneRouterEarnTestBase } from "./ZoneRouterEarnTestBase.sol";
import { IRouterPropAMMPool, RouterMockZonePortal } from "earn-test/helpers/EarnRouterTestBase.sol";
import { IWithdrawalReceiver, ZONE_MESSENGER_ADDRESS } from "tempo-earn/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "tempo-earn/router/SingleZoneEarnRouter.sol";

/// @dev Port of Earn's SingleZoneEarnRouterAbiFuzzTest to ZoneRouter's Earn mode. Callbacks are encoded with
///      SingleZoneEarnRouter's own structs; events are ZoneRouter's, which share their topics.
contract ZoneRouterEarnAbiFuzzTest is ZoneRouterEarnTestBase {
    uint256 private constant LIMIT = 10 * ONE;

    IRouterPropAMMPool private pool;

    function setUp() public override {
        super.setUp();
        pool = _routerPool(address(alternate), address(assetA));
        _admittedZoneRouter(pool);
    }

    /// @dev Canonical callback ABI round-trips both ops without leaving balances or allowances behind.
    function testFuzzCanonicalCallbackAbiRoundTrips(
        bool redeemFlow,
        uint128 rawAmount,
        uint128 rawMinVaultAssets,
        uint128 rawMinEarnShares,
        uint128 rawMinOutputAmount,
        bytes32 actionId,
        uint256 keyIndex,
        address refund
    ) public {
        uint128 amount = uint128(bound(rawAmount, 1, LIMIT));
        uint128 minVaultAssets = uint128(bound(rawMinVaultAssets, 1, amount));
        uint128 minEarnShares = uint128(bound(rawMinEarnShares, 1, amount));
        uint128 minOutputAmount = uint128(bound(rawMinOutputAmount, 0, amount));
        vm.assume(refund != address(0));

        SingleZoneEarnRouter.Flow flow =
            redeemFlow ? SingleZoneEarnRouter.Flow.Redeem : SingleZoneEarnRouter.Flow.Deposit;
        address token;
        if (redeemFlow) {
            _publicDeposit(user, amount);
            vm.prank(user);
            assertTrue(earnA.transfer(address(router), amount));
            token = address(earnA);
        } else {
            alternate.mint(address(router), amount);
            token = address(alternate);
        }

        bytes32 zoneDepositHash = keccak256(
            abi.encode(address(portalA), redeemFlow ? address(alternate) : address(earnA), amount, uint256(1))
        );
        vm.expectEmit(true, true, true, true, address(router));
        if (redeemFlow) {
            emit ZoneRouter.EarnRedeem(
                actionId, address(earnVaultA), address(alternate), amount, amount, amount, zoneDepositHash
            );
        } else {
            emit ZoneRouter.EarnDeposit(
                actionId, address(earnVaultA), address(alternate), amount, amount, amount, zoneDepositHash
            );
        }
        vm.expectCall(
            address(portalA),
            abi.encodeCall(
                RouterMockZonePortal.depositEncrypted,
                (redeemFlow ? address(alternate) : address(earnA), amount, keyIndex, _encrypted(), refund)
            )
        );

        vm.prank(ZONE_MESSENGER_ADDRESS);
        bytes4 result = router.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            token,
            amount,
            abi.encode(
                SingleZoneEarnRouter.CallbackData({
                    flow: flow,
                    minVaultAssets: minVaultAssets,
                    minEarnShares: minEarnShares,
                    minOutputAmount: minOutputAmount,
                    actionId: actionId,
                    zoneReturn: SingleZoneEarnRouter.ZoneReturn({
                        keyIndex: keyIndex, encrypted: _encrypted(), refundRecipient: refund
                    })
                })
            )
        );

        assertEq(result, IWithdrawalReceiver.onWithdrawalReceived.selector);
        assertEq(portalA.depositCount(), 1);
        assertEq(portalA.lastToken(), redeemFlow ? address(alternate) : address(earnA));
        assertEq(portalA.lastAmount(), amount);
        assertEq(portalA.lastRefundRecipient(), refund);
        _assertRouterState(0, 0, 0);
    }

    /// @dev A router without conversion returns the complete EarnVault output for any bounds it can meet.
    function testFuzzSameAssetCallbackRoundTrips(
        bool redeemFlow,
        uint128 rawAmount,
        uint128 rawMinVaultAssets,
        uint128 rawMinSecondLeg,
        bytes32 actionId
    ) public {
        _deployZoneRouter(address(assetA), address(0), bytes32(0));
        uint128 amount = uint128(bound(rawAmount, 1, LIMIT));
        uint128 minVaultAssets = uint128(bound(rawMinVaultAssets, 1, amount));
        uint128 minSecondLeg = uint128(bound(rawMinSecondLeg, 1, amount));

        address token;
        if (redeemFlow) {
            _publicDeposit(user, amount);
            vm.prank(user);
            assertTrue(earnA.transfer(address(router), amount));
            token = address(earnA);
        } else {
            assetA.mint(address(router), amount);
            token = address(assetA);
        }
        address outputToken = redeemFlow ? address(assetA) : address(earnA);
        vm.expectCall(
            address(portalA),
            abi.encodeCall(RouterMockZonePortal.depositEncrypted, (outputToken, amount, 1, _encrypted(), user))
        );

        vm.prank(ZONE_MESSENGER_ADDRESS);
        router.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            token,
            amount,
            abi.encode(
                SingleZoneEarnRouter.CallbackData({
                    flow: redeemFlow ? SingleZoneEarnRouter.Flow.Redeem : SingleZoneEarnRouter.Flow.Deposit,
                    minVaultAssets: minVaultAssets,
                    minEarnShares: redeemFlow ? 0 : minSecondLeg,
                    minOutputAmount: redeemFlow ? minSecondLeg : 0,
                    actionId: actionId,
                    zoneReturn: SingleZoneEarnRouter.ZoneReturn({
                        keyIndex: 1, encrypted: _encrypted(), refundRecipient: user
                    })
                })
            )
        );

        assertEq(portalA.lastToken(), outputToken);
        assertEq(portalA.lastAmount(), amount);
        _assertRouterState(0, 0, 0);
    }

    /// @dev Arbitrary callback bytes either complete the closed route or revert without partial effects.
    function testFuzzArbitraryCallbackAbiIsAtomic(bytes calldata callbackData) public {
        alternate.mint(address(router), ONE);

        vm.prank(ZONE_MESSENGER_ADDRESS);
        (bool ok, bytes memory returnData) = address(router)
            .call(
                abi.encodeCall(
                    router.onWithdrawalReceived,
                    (ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), callbackData)
                )
            );

        if (ok) {
            assertEq(abi.decode(returnData, (bytes4)), IWithdrawalReceiver.onWithdrawalReceived.selector);
            assertEq(portalA.depositCount(), 1);
            assertEq(portalA.lastToken(), address(earnA));
            assertEq(portalA.lastAmount(), ONE);
            _assertRouterState(0, 0, 0);
        } else {
            assertEq(earnA.totalSupply(), 0);
            assertEq(portalA.depositCount(), 0);
            _assertRouterState(ONE, 0, 0);
        }
    }
}

/// @dev The same cases with Spend also enabled.
contract ZoneRouterEarnAbiFuzzWithSpendTest is ZoneRouterEarnAbiFuzzTest {
    function _withSpend() internal pure override returns (bool) {
        return true;
    }
}
