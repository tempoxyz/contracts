// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test fixtures use bounded uint128 amounts.
// forge-lint: disable-start(unsafe-typecast)

import { ZONE_FACTORY_ADDRESS, ZONE_MESSENGER_ADDRESS } from "../../../src/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "../../../src/earn/router/SingleZoneEarnRouter.sol";
import { IRouterPropAMMPool } from "../../earn/helpers/EarnRouterTestBase.sol";
import { MemoMockToken } from "../../earn/helpers/PropAMMEngineMocks.sol";
import { ZoneRouterEarnTestBase } from "../earn/ZoneRouterEarnTestBase.sol";

/// @notice ZoneRouter's steady-state Earn callbacks, measured like the SingleZoneEarnRouter benchmarks: a
///         first deposit and redemption run, then every touched account is cooled so the measured callback
///         is priced as its own transaction.
abstract contract ZoneRouterEarnGasBase is ZoneRouterEarnTestBase {
    function _warm() internal {
        _deposit(10 * ONE, 10 * ONE, 10 * ONE);
        portalA.release(address(earnA), address(router), 2 * ONE);
        _redeem(ONE, ONE, ONE);
    }

    function _cool() internal {
        // Resolve getters first: calling them after cooling would warm the vault again.
        address fees = address(earnVaultA.earnFees());
        address[10] memory touched = [
            address(router),
            address(router.pool()),
            address(oracle),
            address(registry),
            address(alternate),
            address(assetA),
            address(earnA),
            address(earnVaultA),
            address(engineA),
            address(portalA)
        ];
        for (uint256 i = 0; i < touched.length; i++) {
            if (touched[i] != address(0)) vm.cool(touched[i]);
        }
        vm.cool(address(venueA));
        vm.cool(fees);
        vm.cool(ZONE_FACTORY_ADDRESS);
    }

    function _measureDeposit() internal {
        vm.pauseGasMetering();
        _warm();
        address input = router.privateAsset();
        bytes memory data = _callback(SingleZoneEarnRouter.Flow.Deposit, uint128(ONE), uint128(ONE), 0);
        MemoMockToken(input).mint(address(router), ONE);
        _cool();
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.resumeGasMetering();
        router.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), input, uint128(ONE), data);
    }

    function _measureRedeem() internal {
        vm.pauseGasMetering();
        _warm();
        bytes memory data = _callback(SingleZoneEarnRouter.Flow.Redeem, uint128(ONE), 0, uint128(ONE));
        _cool();
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.resumeGasMetering();
        router.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(earnA), uint128(ONE), data);
    }
}

contract ZoneRouterEarnSameAssetGas is ZoneRouterEarnGasBase {
    function setUp() public override {
        super.setUp();
        _deployZoneRouter(address(assetA), address(0), bytes32(0));
    }

    function testGasZoneRouterSameAssetDeposit() public {
        _measureDeposit();
    }

    function testGasZoneRouterSameAssetRedeem() public {
        _measureRedeem();
    }
}

contract ZoneRouterEarnConversionGas is ZoneRouterEarnGasBase {
    function setUp() public override {
        super.setUp();
        IRouterPropAMMPool pool = _routerPool(address(alternate), address(assetA));
        _admittedZoneRouter(pool);
    }

    function testGasZoneRouterConversionDeposit() public {
        _measureDeposit();
    }

    function testGasZoneRouterConversionRedeem() public {
        _measureRedeem();
    }
}
