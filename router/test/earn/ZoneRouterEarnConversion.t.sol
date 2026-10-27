// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test fixtures use bounded uint128 amounts.
// forge-lint: disable-start(unsafe-typecast)

import { ZoneRouter } from "../../src/ZoneRouter.sol";
import { ZoneRouterEarnTestBase } from "./ZoneRouterEarnTestBase.sol";
import { IRouterPropAMMPool } from "earn-test/helpers/EarnRouterTestBase.sol";
import { MemoMockToken } from "earn-test/helpers/PropAMMEngineMocks.sol";
import { ZONE_MESSENGER_ADDRESS } from "tempo-earn/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "tempo-earn/router/SingleZoneEarnRouter.sol";

/// @dev Port of Earn's SingleZoneEarnRouterConversionTest to ZoneRouter's Earn mode, against the pinned
///      DirectPropAMM artifact.
contract ZoneRouterEarnConversionTest is ZoneRouterEarnTestBase {
    uint256 private constant INVENTORY = POOL_INVENTORY;

    IRouterPropAMMPool private pool;

    function setUp() public override {
        super.setUp();
        pool = _routerPool(address(alternate), address(assetA));
        _admittedZoneRouter(pool);
    }

    /// @dev Adapted: the constructor takes a Mode, deployed through the factory, which bubbles its revert.
    function testConstructorRejectsMismatchedPairAndUnits() public {
        IRouterPropAMMPool otherPair = _routerPool(address(alternate), address(assetB));
        ZoneRouter.Mode memory mode = _earnMode(ZONE_A, address(alternate), address(otherPair), CUSTOMER_ID);
        vm.expectRevert(ZoneRouter.InvalidRoutePair.selector);
        factory.deploy(mode);

        MemoMockToken coarse = new MemoMockToken("Coarse", "CRS", 2);
        IRouterPropAMMPool mixedUnits = _routerPool(address(coarse), address(assetA));
        mode = _earnMode(ZONE_A, address(coarse), address(mixedUnits), CUSTOMER_ID);
        vm.expectRevert(ZoneRouter.InvalidRoutePair.selector);
        factory.deploy(mode);
    }

    function testRejectsOffParPriceAtomically() public {
        oracle.set(PAR + 1, vm.getBlockTimestamp());
        _expectDepositRevert(
            ONE, ONE, abi.encodeWithSignature("OraclePriceToleranceExceeded(uint256,uint256,uint256)", PAR, PAR + 1, 0)
        );

        oracle.set(PAR - 1, vm.getBlockTimestamp());
        _expectDepositRevert(
            ONE, ONE, abi.encodeWithSignature("OraclePriceToleranceExceeded(uint256,uint256,uint256)", PAR, PAR - 1, 0)
        );

        oracle.set(PAR, vm.getBlockTimestamp());
        _deposit(ONE, ONE, ONE);
        assertEq(earnA.balanceOf(address(portalA)), ONE);
    }

    function testPoolPauseAdmissionStalenessAndInventoryFailClosed() public {
        pool.pause();
        _expectDepositRevert(ONE, ONE, abi.encodeWithSignature("Paused()"));
        pool.unpause();

        pool.setTakerAllowed(address(router), false);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSignature("TakerNotAllowed(address)", address(router)));
        pool.setTakerAllowed(address(router), true);

        pool.setRecipientAllowed(address(router), false);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSignature("RecipientNotAllowed(address)", address(router)));
        pool.setRecipientAllowed(address(router), true);

        registry.setRedirect(address(router), address(this));
        pool.setRecipientAllowed(address(this), true);
        // The pool rejects output that does not reach the resolved recipient; a redirect never strands assets.
        _expectDepositRevert(
            ONE,
            ONE,
            abi.encodeWithSignature("ExactBalanceDeltaFailed(address,uint256,uint256)", address(assetA), ONE, 0)
        );
        registry.setRedirect(address(router), address(0));

        uint256 observedAt = oracle.updatedAt();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSignature("StaleOraclePrice(uint256,uint256)", observedAt, 1 days));
        oracle.set(PAR, vm.getBlockTimestamp());

        pool.pause();
        pool.withdraw(address(assetA), address(this), INVENTORY - ONE + 1, bytes32(0));
        pool.unpause();
        _expectDepositRevert(
            ONE,
            ONE,
            abi.encodeWithSignature("InsufficientInventory(address,uint256,uint256)", address(assetA), ONE - 1, ONE)
        );

        _deposit(ONE - 1, ONE - 1, ONE - 1);
        assertEq(assetA.balanceOf(address(pool)), 0);
    }

    function testRedemptionWithoutPrivateInventoryRevertsAndPreservesShares() public {
        _deposit(5 * ONE, 5 * ONE, 5 * ONE);
        pool.pause();
        pool.withdraw(address(alternate), address(this), alternate.balanceOf(address(pool)), bytes32(0));
        pool.unpause();

        portalA.release(address(earnA), address(router), 5 * ONE);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(
            abi.encodeWithSignature("InsufficientInventory(address,uint256,uint256)", address(alternate), 0, 5 * ONE)
        );
        router.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            address(earnA),
            uint128(5 * ONE),
            _callback(SingleZoneEarnRouter.Flow.Redeem, uint128(5 * ONE), 0, uint128(5 * ONE))
        );

        assertEq(earnA.balanceOf(address(router)), 5 * ONE);
        assertEq(earnA.totalSupply(), 5 * ONE);
        assertEq(assetA.balanceOf(address(router)), 0);
    }

    function testPreservesForcedBalances() public {
        alternate.mint(address(router), 2 * ONE);
        assetA.mint(address(router), 3 * ONE);

        _deposit(ONE, ONE, ONE);

        _assertRouterState(2 * ONE, 3 * ONE, 0);
    }
}

/// @dev The same cases with Spend also enabled.
contract ZoneRouterEarnConversionWithSpendTest is ZoneRouterEarnConversionTest {
    function _withSpend() internal pure override returns (bool) {
        return true;
    }
}
