// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test fixtures use bounded uint128 amounts.
// forge-lint: disable-start(unsafe-typecast)

import { ZoneRouter } from "../../src/ZoneRouter.sol";
import { ZoneRouterEarnTestBase } from "./ZoneRouterEarnTestBase.sol";
import { MisbehavingParPool } from "earn-test/router/SingleZoneEarnRouterCustody.t.sol";
import { ZONE_MESSENGER_ADDRESS } from "tempo-earn/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "tempo-earn/router/SingleZoneEarnRouter.sol";

/// @dev Port of Earn's SingleZoneEarnRouterCustodyTest: ZoneRouter's measured-delta custody checks against
///      Earn's own misbehaving pool, independent of any honest pool.
contract ZoneRouterEarnCustodyTest is ZoneRouterEarnTestBase {
    MisbehavingParPool private pool;

    function setUp() public override {
        super.setUp();
        pool = new MisbehavingParPool(address(alternate), address(assetA), address(oracle));
        alternate.mint(address(pool), POOL_INVENTORY);
        assetA.mint(address(pool), POOL_INVENTORY);
        _deployZoneRouter(address(alternate), address(pool), CUSTOMER_ID);
    }

    function testDepositRejectsShortOverpaidOrMissingOutput() public {
        pool.setMode(MisbehavingParPool.Mode.PayShort);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSelector(ZoneRouter.InsufficientOutput.selector));
        pool.setMode(MisbehavingParPool.Mode.PayExtra);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSelector(ZoneRouter.InsufficientOutput.selector));
        pool.setMode(MisbehavingParPool.Mode.PayNothing);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSelector(ZoneRouter.InsufficientOutput.selector));
    }

    function testDepositRejectsUnconsumedInput() public {
        pool.setMode(MisbehavingParPool.Mode.PullShort);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSelector(ZoneRouter.ResidualBalance.selector));
    }

    function testRedemptionRejectsShortOutput() public {
        _deposit(2 * ONE, 2 * ONE, 2 * ONE);
        portalA.release(address(earnA), address(router), ONE);
        pool.setMode(MisbehavingParPool.Mode.PayShort);
        uint256 sharesBefore = earnA.balanceOf(address(router));
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.InsufficientOutput.selector);
        router.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            address(earnA),
            uint128(ONE),
            _callback(SingleZoneEarnRouter.Flow.Redeem, uint128(ONE), 0, 0)
        );
        assertEq(earnA.balanceOf(address(router)), sharesBefore);
    }
}

/// @dev The same cases with Spend also enabled.
contract ZoneRouterEarnCustodyWithSpendTest is ZoneRouterEarnCustodyTest {
    function _withSpend() internal pure override returns (bool) {
        return true;
    }
}
