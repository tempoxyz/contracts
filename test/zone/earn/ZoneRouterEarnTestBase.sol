// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ZoneRouter } from "../../../src/zone/ZoneRouter.sol";
import { ZoneRouterFactory } from "../../../src/zone/ZoneRouterFactory.sol";
import { ISpender } from "../../../src/interfaces/zone/ISpender.sol";
import { ZoneRouterTestBase, IRouterPropAMMPool } from "../helpers/ZoneRouterTestBase.sol";

/// @dev A listed spender that the Earn-op suites never reach; it only makes a mode with Spend valid.
contract IdleSpender is ISpender {
    error Unexpected();

    function spendFrom(address, uint256, bytes calldata) external pure {
        revert Unexpected();
    }
}

/// @dev Runs the Earn-op suites against ZoneRouter in its Earn mode. Routers come from ZoneRouterFactory,
///      and ZoneRouterTestBase's helpers drive them through `router`. A suite that overrides `_withSpend`
///      repeats every case with Spend also enabled (ops 7).
abstract contract ZoneRouterEarnTestBase is ZoneRouterTestBase {
    ZoneRouterFactory internal factory;
    IdleSpender internal idleSpender;
    ZoneRouter internal zoneRouter;

    /// @dev Earn owns the pinned DirectPropAMM fixture; this project reads it from there.
    function _propAMMArtifact() internal pure override returns (string memory) {
        return "test/earn/fixtures/propamm/DirectPropAMM.json";
    }

    function setUp() public virtual override {
        super.setUp();
        factory = new ZoneRouterFactory();
        idleSpender = new IdleSpender();
    }

    /// @dev Whether this suite's routers also enable Spend.
    function _withSpend() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev A Zone `zoneId` Earn mode over earnVaultA, converting through `pool` unless the asset matches.
    function _earnMode(uint32 zoneId, address privateAsset, address pool, bytes32 customerId)
        internal
        view
        returns (ZoneRouter.Mode memory mode)
    {
        bool spends = _withSpend();
        mode.zoneId = zoneId;
        mode.enabledOps = spends ? uint8(7) : uint8(3);
        mode.earnVault = address(earnVaultA);
        mode.privateAsset = privateAsset;
        mode.pool = pool;
        mode.customerId = customerId;
        mode.spenders = new address[](spends ? 1 : 0);
        if (spends) mode.spenders[0] = address(idleSpender);
    }

    /// @dev Deploys a Zone A Earn-mode router through the factory and points the base helpers at it.
    function _deployZoneRouter(address privateAsset, address pool, bytes32 customerId)
        internal
        returns (ZoneRouter zr)
    {
        zr = ZoneRouter(factory.deploy(_earnMode(ZONE_A, privateAsset, pool, customerId)));
        _use(zr);
    }

    /// @dev A converting router admitted to `pool`.
    function _admittedZoneRouter(IRouterPropAMMPool pool) internal returns (ZoneRouter zr) {
        zr = _deployZoneRouter(address(alternate), address(pool), CUSTOMER_ID);
        pool.setTakerAllowed(address(zr), true);
        pool.setRecipientAllowed(address(zr), true);
    }

    function _use(ZoneRouter zr) internal {
        zoneRouter = zr;
        router = zr;
    }
}
