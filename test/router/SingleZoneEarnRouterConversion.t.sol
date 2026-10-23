// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test fixtures use bounded uint128 amounts.
// forge-lint: disable-start(erc20-unchecked-transfer,unsafe-typecast)

import { ZONE_MESSENGER_ADDRESS } from "../../src/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "../../src/router/SingleZoneEarnRouter.sol";
import { EarnRouterTestBase, IRouterPropAMMPool } from "../helpers/EarnRouterTestBase.sol";
import { MemoMockToken } from "../helpers/PropAMMEngineMocks.sol";

contract SingleZoneEarnRouterConversionTest is EarnRouterTestBase {
    uint256 private constant INVENTORY = POOL_INVENTORY;

    IRouterPropAMMPool private pool;

    function setUp() public override {
        super.setUp();
        pool = _routerPool(address(alternate), address(assetA));
        router = _admittedRouter(pool);
    }

    function testConstructorRejectsMismatchedPairAndUnits() public {
        IRouterPropAMMPool otherPair = _routerPool(address(alternate), address(assetB));
        vm.expectRevert(SingleZoneEarnRouter.InvalidRoutePair.selector);
        this.deployRouter(address(earnVaultA), address(alternate), address(otherPair), CUSTOMER_ID);

        MemoMockToken coarse = new MemoMockToken("Coarse", "CRS", 2);
        IRouterPropAMMPool mixedUnits = _routerPool(address(coarse), address(assetA));
        vm.expectRevert(SingleZoneEarnRouter.InvalidRoutePair.selector);
        this.deployRouter(address(earnVaultA), address(coarse), address(mixedUnits), CUSTOMER_ID);
    }

    /// @dev External so each constructor revert is a separate call that `vm.expectRevert` can match.
    function deployRouter(address earnVault, address privateAsset, address pool_, bytes32 customerId)
        external
        returns (SingleZoneEarnRouter)
    {
        return new SingleZoneEarnRouter(
            ZONE_A, earnVault, privateAsset, pool_, customerId, SingleZoneEarnRouter.PoolKind.Direct, 0, 0
        );
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
