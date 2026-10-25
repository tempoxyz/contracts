// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test fixtures use bounded uint128 amounts.
// forge-lint: disable-start(unsafe-typecast)

import { EarnVault } from "../../src/core/EarnVault.sol";
import { ERC4626Engine } from "../../src/engines/ERC4626Engine.sol";
import { ZONE_MESSENGER_ADDRESS } from "../../src/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "../../src/router/SingleZoneEarnRouter.sol";
import { EarnRouterTestBase } from "../helpers/EarnRouterTestBase.sol";

/// @dev A router whose private asset is the vault asset deposits and redeems it without a pool.
contract SingleZoneEarnRouterSameAssetTest is EarnRouterTestBase {
    function setUp() public override {
        super.setUp();
        router = new SingleZoneEarnRouter(ZONE_A, address(earnVaultA), address(assetA), address(0), bytes32(0));
    }

    function testOutputBoundsAndEarnVaultFailuresRevertAtomically() public {
        _expectDepositRevert(ONE + 1, ONE, abi.encodeWithSelector(SingleZoneEarnRouter.InsufficientOutput.selector));
        _expectDepositRevert(
            ONE, ONE + 1, abi.encodeWithSelector(EarnVault.MinimumEarnSharesNotMet.selector, ONE + 1, ONE)
        );

        earnVaultA.setDepositsPaused(true);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSelector(EarnVault.DepositsPaused.selector));
        earnVaultA.setDepositsPaused(false);

        _deposit(2 * ONE, 2 * ONE, 2 * ONE);
        portalA.release(address(earnA), address(router), ONE);

        vm.startPrank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(SingleZoneEarnRouter.InsufficientOutput.selector);
        router.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            address(earnA),
            uint128(ONE),
            _callback(SingleZoneEarnRouter.Flow.Redeem, uint128(ONE), 0, uint128(ONE + 1))
        );
        vm.expectRevert(abi.encodeWithSelector(ERC4626Engine.InsufficientAssetsReceived.selector, ONE + 1, ONE));
        router.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            address(earnA),
            uint128(ONE),
            _callback(SingleZoneEarnRouter.Flow.Redeem, uint128(ONE + 1), 0, uint128(ONE))
        );
        vm.stopPrank();

        assertEq(earnA.balanceOf(address(router)), ONE);
        assertEq(earnA.totalSupply(), 2 * ONE);
        assertEq(assetA.balanceOf(address(portalA)), 0);
    }

    function testRejectsMismatchedTokens() public {
        assetA.mint(address(router), ONE);
        bytes memory data = _callback(SingleZoneEarnRouter.Flow.Deposit, uint128(ONE), uint128(ONE), 0);

        vm.startPrank(ZONE_MESSENGER_ADDRESS);
        alternate.mint(address(router), ONE);
        vm.expectRevert(SingleZoneEarnRouter.WrongInputToken.selector);
        router.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), data);

        vm.expectRevert(SingleZoneEarnRouter.WrongInputToken.selector);
        router.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            address(assetA),
            uint128(ONE),
            _callback(SingleZoneEarnRouter.Flow.Redeem, uint128(ONE), 0, uint128(ONE))
        );

        portalA.setToken(address(earnA), false, false);
        vm.expectRevert(SingleZoneEarnRouter.InvalidReturnToken.selector);
        router.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(assetA), uint128(ONE), data);
        vm.stopPrank();

        assertEq(earnA.totalSupply(), 0);
        assertEq(assetA.balanceOf(address(router)), ONE);
    }

    function testPreservesForcedBalances() public {
        assetA.mint(address(router), 3 * ONE);

        _deposit(ONE, ONE, ONE);
        _assertRouterState(0, 3 * ONE, 0);

        portalA.release(address(earnA), address(router), ONE);
        _redeem(ONE, ONE, ONE);
        _assertRouterState(0, 3 * ONE, 0);
        assertEq(assetA.balanceOf(address(portalA)), ONE);
    }
}
