// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// forge-lint: disable-start(unsafe-typecast)

import { EncryptedDepositPayload, ZONE_MESSENGER_ADDRESS } from "../../src/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "../../src/router/SingleZoneEarnRouter.sol";
import { EarnRouterTestBase, IRouterPropAMMPool } from "../helpers/EarnRouterTestBase.sol";

contract SingleZoneEarnRouterTest is EarnRouterTestBase {
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
        SingleZoneEarnRouter.Flow flow;
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
        router = _admittedRouter(pool);
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

        vm.expectRevert(SingleZoneEarnRouter.NotZoneMessenger.selector);
        router.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), data);

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(SingleZoneEarnRouter.InvalidSourcePortal.selector);
        router.onWithdrawalReceived(ZONE_A, address(portalB), bytes32(0), address(alternate), uint128(ONE), data);

        zoneFactory.setPortal(address(portalA), false);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(SingleZoneEarnRouter.InvalidSourcePortal.selector);
        router.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), data);
    }

    function testRejectsDifferentCanonicalZone() public {
        alternate.mint(address(router), ONE);
        bytes memory data = _callback(SingleZoneEarnRouter.Flow.Deposit, uint128(ONE), uint128(ONE), 0);

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(SingleZoneEarnRouter.WrongSourceZone.selector);
        router.onWithdrawalReceived(ZONE_B, address(portalB), bytes32(0), address(alternate), uint128(ONE), data);

        assertEq(earnA.totalSupply(), 0);
        assertEq(alternate.balanceOf(address(router)), ONE);
    }

    function testZeroZoneBindingIsFailClosed() public {
        SingleZoneEarnRouter disabledRouter = new SingleZoneEarnRouter(
            0,
            address(earnVaultA),
            address(alternate),
            address(pool),
            CUSTOMER_ID,
            SingleZoneEarnRouter.PoolKind.Direct,
            0,
            0
        );
        bytes memory data = _callback(SingleZoneEarnRouter.Flow.Deposit, uint128(ONE), uint128(ONE), 0);

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(SingleZoneEarnRouter.WrongSourceZone.selector);
        disabledRouter.onWithdrawalReceived(0, address(portalA), bytes32(0), address(alternate), uint128(ONE), data);
    }

    function testCannotSelectAnotherEarnVault() public {
        alternate.mint(address(router), ONE);
        bytes memory callerSelectedVaultData = abi.encode(
            SingleZoneEarnRouter.Flow.Deposit,
            address(earnVaultB),
            uint128(ONE),
            uint128(ONE),
            uint128(0),
            keccak256("fake-vault-attempt"),
            SingleZoneEarnRouter.ZoneReturn({ keyIndex: 1, encrypted: _encrypted(), refundRecipient: refundRecipient })
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
        vm.expectRevert(SingleZoneEarnRouter.WrongInputToken.selector);
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
                flow: SingleZoneEarnRouter.Flow.Deposit,
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
