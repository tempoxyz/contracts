// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// forge-lint: disable-start(unsafe-typecast)

import { ZoneRouter } from "../../src/ZoneRouter.sol";
import { ZoneRouterEarnTestBase } from "./ZoneRouterEarnTestBase.sol";
import { IRouterPropAMMPool } from "earn-test/helpers/EarnRouterTestBase.sol";
import { EncryptedDepositPayload, ZONE_MESSENGER_ADDRESS } from "tempo-earn/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "tempo-earn/router/SingleZoneEarnRouter.sol";

/// @dev Port of Earn's SingleZoneEarnRouterTest to ZoneRouter's Earn mode.
contract ZoneRouterEarnTest is ZoneRouterEarnTestBase {
    enum ArbitraryDestination {
        Zone,
        Public
    }

    struct ArbitraryZoneDelivery {
        address portal;
        uint256 keyIndex;
        EncryptedDepositPayload encrypted;
        address refundRecipient;
    }

    struct ArbitraryCallbackData {
        ZoneRouter.Op op;
        address earnVault;
        ArbitraryDestination destination;
        address outputToken;
        uint128 minVaultAssets;
        uint128 minEarnShares;
        uint128 minOutputAmount;
        bytes32 actionId;
        bytes destinationData;
    }

    IRouterPropAMMPool internal pool;

    function setUp() public override {
        super.setUp();
        pool = _routerPool(address(alternate), address(assetA));
        _admittedZoneRouter(pool);
    }

    function testCannotEncodePublicOrCrossZoneDestination() public {
        alternate.mint(address(router), 2 * ONE);

        bytes memory publicDestination =
            _arbitraryDestinationCallback(ArbitraryDestination.Public, abi.encode(recipient));
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert();
        router.onWithdrawalReceived(
            ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), publicDestination
        );

        ArbitraryZoneDelivery memory otherZone = ArbitraryZoneDelivery({
            portal: address(portalB), keyIndex: 1, encrypted: _encrypted(), refundRecipient: refundRecipient
        });
        bytes memory otherZoneDestination =
            _arbitraryDestinationCallback(ArbitraryDestination.Zone, abi.encode(otherZone));
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert();
        router.onWithdrawalReceived(
            ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), otherZoneDestination
        );

        assertEq(earnA.balanceOf(recipient), 0);
        assertEq(earnA.balanceOf(address(portalA)), 0);
        assertEq(earnA.balanceOf(address(portalB)), 0);
        assertEq(earnA.totalSupply(), 0);
    }

    function testRejectsSpoofedMessengerAndMismatchedSourcePortal() public {
        alternate.mint(address(router), ONE);
        bytes memory data = _callback(SingleZoneEarnRouter.Flow.Deposit, uint128(ONE), uint128(ONE), 0);

        vm.expectRevert(ZoneRouter.NotZoneMessenger.selector);
        router.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), data);

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.InvalidSourcePortal.selector);
        router.onWithdrawalReceived(ZONE_A, address(portalB), bytes32(0), address(alternate), uint128(ONE), data);

        zoneFactory.setPortal(address(portalA), false);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.InvalidSourcePortal.selector);
        router.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), data);
    }

    function testRejectsDifferentCanonicalZone() public {
        alternate.mint(address(router), ONE);
        bytes memory data = _callback(SingleZoneEarnRouter.Flow.Deposit, uint128(ONE), uint128(ONE), 0);

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.WrongSourceZone.selector);
        router.onWithdrawalReceived(ZONE_B, address(portalB), bytes32(0), address(alternate), uint128(ONE), data);

        assertEq(earnA.totalSupply(), 0);
        assertEq(alternate.balanceOf(address(router)), ONE);
    }

    /// @dev Adapted: SingleZoneEarnRouter deploys with Zone 0 and rejects every callback at runtime;
    ///      ZoneRouter refuses to deploy one, so no Zone 0 router can exist, and a Zone 0 callback to a
    ///      deployed router fails as any other Zone's would.
    function testZeroZoneBindingIsFailClosed() public {
        ZoneRouter.Mode memory mode = _earnMode(0, address(alternate), address(pool), CUSTOMER_ID);
        address predicted = factory.predict(mode);
        vm.expectRevert(ZoneRouter.WrongSourceZone.selector);
        factory.deploy(mode);
        assertEq(predicted.code.length, 0);
        assertFalse(factory.isRouter(predicted));

        bytes memory data = _callback(SingleZoneEarnRouter.Flow.Deposit, uint128(ONE), uint128(ONE), 0);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.WrongSourceZone.selector);
        router.onWithdrawalReceived(0, address(portalA), bytes32(0), address(alternate), uint128(ONE), data);
    }

    function testCannotSelectAnotherEarnVault() public {
        alternate.mint(address(router), ONE);
        bytes memory callerSelectedVaultData = abi.encode(
            ZoneRouter.Op.Deposit,
            address(earnVaultB),
            uint128(ONE),
            uint128(ONE),
            uint128(0),
            keccak256("fake-vault-attempt"),
            ZoneRouter.ZoneReturn({ keyIndex: 1, encrypted: _encrypted(), refundRecipient: refundRecipient })
        );

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert();
        router.onWithdrawalReceived(
            ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), callerSelectedVaultData
        );

        assertEq(earnA.totalSupply(), 0);
        assertEq(earnB.totalSupply(), 0);
        assertEq(alternate.balanceOf(address(router)), ONE);
    }

    function testHasOnlyClosedLoopCallbackSurface() public {
        (bool depositOk,) = address(router)
            .call(
                abi.encodeWithSignature(
                    "deposit(address,uint256,uint256,address)", address(earnVaultA), ONE, ONE, recipient
                )
            );
        (bool redeemOk,) = address(router)
            .call(
                abi.encodeWithSignature(
                    "redeem(address,uint256,uint256,address)", address(earnVaultA), ONE, ONE, recipient
                )
            );
        (bool mutableBackendGetterOk,) = address(router).staticcall(abi.encodeWithSignature("swapBackend()"));

        assertFalse(depositOk);
        assertFalse(redeemOk);
        assertFalse(mutableBackendGetterOk);
    }

    function testRejectsVaultAssetWhenRouterIsBoundToDifferentPrivateAsset() public {
        assetA.mint(address(router), ONE);

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.WrongInputToken.selector);
        router.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            address(assetA),
            uint128(ONE),
            _callback(SingleZoneEarnRouter.Flow.Deposit, uint128(ONE), uint128(ONE), 0)
        );

        assertEq(assetA.balanceOf(address(router)), ONE);
        assertEq(earnA.totalSupply(), 0);
    }

    function _arbitraryDestinationCallback(ArbitraryDestination destination, bytes memory destinationData)
        private
        view
        returns (bytes memory)
    {
        return abi.encode(
            ArbitraryCallbackData({
                op: ZoneRouter.Op.Deposit,
                earnVault: address(earnVaultA),
                destination: destination,
                outputToken: address(earnA),
                minVaultAssets: uint128(ONE),
                minEarnShares: uint128(ONE),
                minOutputAmount: 0,
                actionId: keccak256("escape-attempt"),
                destinationData: destinationData
            })
        );
    }
}

/// @dev The same cases with Spend also enabled.
contract ZoneRouterEarnWithSpendTest is ZoneRouterEarnTest {
    function _withSpend() internal pure override returns (bool) {
        return true;
    }
}
