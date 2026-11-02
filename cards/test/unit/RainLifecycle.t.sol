// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardSpend } from "../../src/CardSpend.sol";
import { CardsEnv } from "../harness/CardsEnv.sol";

/// @notice What happens to card money after a Tempo spend lands in Rain's collateral, with Rain's own
///         contracts unchanged: Rain's daily payment moves it to Rain's treasury with its controller
///         admin's signature, a refund or reversal goes back through a Rain-signed withdrawal, and nothing
///         leaves a collateral contract without Rain's signature.
contract RainLifecycleTest is CardsEnv {
    address internal rainBackend = makeAddr("rain.backend");

    function setUp() public {
        _deployWorld();
        usd.mint(alice, 1000e6);
    }

    function test_spendThenRainSettlesToTreasury() public {
        _publicSpend(alice, _stableSpend(aliceCollateral, aliceIndex, 60e6, "auth.1"));
        uint256 expiresAt = block.timestamp + 30 minutes;
        bytes memory sig = _signPay(rainBackend, aliceCollateral, address(usd), 60e6, expiresAt, "pay.1");
        vm.prank(rainBackend);
        rain.controller.makePayment(aliceCollateral, _one(address(usd)), _one(60e6), expiresAt, "pay.1", sig);
        assertEq(usd.balanceOf(rainTreasury), 60e6, "Rain's treasury paid");
        assertEq(usd.balanceOf(aliceCollateral), 0);
        assertEq(rain.controller.nonce(aliceCollateral), 1);
    }

    function test_pooledCollateral_settlesPrivateSpendsTogether() public {
        address router = makeAddr("zone-router");
        usd.mint(router, 100e6);
        _routerSettle(router, address(usd), 10e6, _stableSpend(programCollateral, programCollateralIndex, 10e6, "p.1"));
        _routerSettle(router, address(usd), 15e6, _stableSpend(programCollateral, programCollateralIndex, 15e6, "p.2"));
        uint256 expiresAt = block.timestamp + 1 hours;
        bytes memory sig = _signPay(rainBackend, programCollateral, address(usd), 25e6, expiresAt, "pay.pool");
        vm.prank(rainBackend);
        rain.controller.makePayment(programCollateral, _one(address(usd)), _one(25e6), expiresAt, "pay.pool", sig);
        assertEq(usd.balanceOf(rainTreasury), 25e6);
    }

    function test_refund_rainSignedWithdrawalByCollateralAdmin() public {
        _publicSpend(alice, _stableSpend(aliceCollateral, aliceIndex, 40e6, "auth.2"));
        uint256 expiresAt = block.timestamp + 30 minutes;
        bytes memory sig = _signWithdraw(alice, aliceCollateral, address(usd), 15e6, alice, expiresAt, "wd.1");
        vm.prank(alice);
        rain.controller.withdrawAsset(aliceCollateral, address(usd), 15e6, alice, expiresAt, "wd.1", sig);
        assertEq(usd.balanceOf(alice), 1000e6 - 40e6 + 15e6);
        assertEq(usd.balanceOf(aliceCollateral), 25e6);
    }

    function test_revert_withdrawWithoutRainSignature() public {
        _publicSpend(alice, _stableSpend(aliceCollateral, aliceIndex, 40e6, "auth.3"));
        uint256 expiresAt = block.timestamp + 30 minutes;
        // Signed by Alice, not Rain's controller admin.
        bytes32 digest = keccak256("anything");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(keccak256("alice.key")), digest);
        vm.prank(alice);
        vm.expectRevert(bytes("Invalid signature"));
        rain.controller
            .withdrawAsset(aliceCollateral, address(usd), 40e6, alice, expiresAt, "wd", abi.encodePacked(r, s, v));
        // And the collateral itself only answers its controller.
        vm.prank(alice);
        vm.expectRevert(bytes("Unauthorized"));
        (bool ok,) = aliceCollateral.call(
            abi.encodeWithSignature("withdrawAsset(address,address,uint256)", address(usd), alice, 40e6)
        );
        ok;
    }

    function test_revert_replayedOrExpiredSignature() public {
        _publicSpend(alice, _stableSpend(aliceCollateral, aliceIndex, 40e6, "auth.4"));
        uint256 expiresAt = block.timestamp + 30 minutes;
        bytes memory sig = _signPay(rainBackend, aliceCollateral, address(usd), 10e6, expiresAt, "pay");
        vm.prank(rainBackend);
        rain.controller.makePayment(aliceCollateral, _one(address(usd)), _one(10e6), expiresAt, "pay", sig);
        vm.prank(rainBackend);
        vm.expectRevert(bytes("Invalid signature"));
        rain.controller.makePayment(aliceCollateral, _one(address(usd)), _one(10e6), expiresAt, "pay", sig);

        bytes memory late = _signPay(rainBackend, aliceCollateral, address(usd), 10e6, expiresAt, "pay.2");
        vm.warp(expiresAt);
        vm.prank(rainBackend);
        vm.expectRevert(bytes("Expired signature"));
        rain.controller.makePayment(aliceCollateral, _one(address(usd)), _one(10e6), expiresAt, "pay.2", late);
    }

    function test_rainCanLiquidate() public {
        _publicSpend(alice, _stableSpend(aliceCollateral, aliceIndex, 40e6, "auth.5"));
        vm.prank(rainAdmin);
        rain.controller.liquidateAsset(aliceCollateral, _one(address(usd)), _one(40e6));
        assertEq(usd.balanceOf(rainTreasury), 40e6);
    }

    /// @dev A spend from Earn lands in the collateral as the vault's asset, which Rain settles as usual.
    function test_spendFromEarn_thenRainSettles() public {
        _depositEarn(alice, 300e6);
        CardSpend memory s = _earnSpend(aliceCollateral, aliceIndex, 25e6, 25e6, "auth.earn");
        _publicSpend(alice, s);
        uint256 expiresAt = block.timestamp + 30 minutes;
        bytes memory sig = _signPay(rainBackend, aliceCollateral, address(usd), 25e6, expiresAt, "pay.earn");
        vm.prank(rainBackend);
        rain.controller.makePayment(aliceCollateral, _one(address(usd)), _one(25e6), expiresAt, "pay.earn", sig);
        assertEq(usd.balanceOf(rainTreasury), 25e6);
    }
}
