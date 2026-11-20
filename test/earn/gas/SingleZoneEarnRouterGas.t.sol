// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test fixtures use bounded uint128 amounts.
// forge-lint: disable-start(unsafe-typecast)

import { ZONE_FACTORY_ADDRESS, ZONE_MESSENGER_ADDRESS } from "../../../src/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "../../../src/earn/router/SingleZoneEarnRouter.sol";
import { EarnRouterTestBase, IRouterPropAMMPool } from "../helpers/EarnRouterTestBase.sol";
import { MemoMockToken } from "../helpers/PropAMMEngineMocks.sol";

/// @notice Steady-state router callbacks: a first deposit and redemption set the standing allowances,
///         then every touched account is cooled so the measured callback is priced as its own transaction.
abstract contract SingleZoneEarnRouterGasBase is EarnRouterTestBase {
    function _warm() internal {
        _deposit(10 * ONE, 10 * ONE, 10 * ONE);
        portalA.release(address(earnA), address(router), 2 * ONE);
        _redeem(ONE, ONE, ONE);
    }

    function _cool() internal {
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
        vm.cool(address(earnVaultA.earnFees()));
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

contract SingleZoneEarnRouterSameAssetGas is SingleZoneEarnRouterGasBase {
    function setUp() public override {
        super.setUp();
        router = new SingleZoneEarnRouter(ZONE_A, address(earnVaultA), address(assetA), address(0), bytes32(0));
    }

    function testGasRouterSameAssetDeposit() public {
        _measureDeposit();
    }

    function testGasRouterSameAssetRedeem() public {
        _measureRedeem();
    }
}

contract SingleZoneEarnRouterConversionGas is SingleZoneEarnRouterGasBase {
    function setUp() public override {
        super.setUp();
        IRouterPropAMMPool pool = _routerPool(address(alternate), address(assetA));
        router = _admittedRouter(pool);
    }

    function testGasRouterConversionDeposit() public {
        _measureDeposit();
    }

    function testGasRouterConversionRedeem() public {
        _measureRedeem();
    }
}
