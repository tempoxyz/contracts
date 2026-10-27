// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ZoneRouter } from "../../src/ZoneRouter.sol";
import { ZoneRouterFactory } from "../../src/ZoneRouterFactory.sol";
import { ISpendSettler } from "../../src/interfaces/ISpendSettler.sol";
import { EarnRouterTestBase, IRouterPropAMMPool } from "earn-test/helpers/EarnRouterTestBase.sol";
import { SingleZoneEarnRouter } from "tempo-earn/router/SingleZoneEarnRouter.sol";

/// @dev A listed settler that the Earn-op suites never reach; it only makes a mode with Spend valid.
contract IdleSettler is ISpendSettler {
    error Unexpected();

    function settle(address, uint256, bytes calldata) external pure {
        revert Unexpected();
    }
}

/// @dev Runs SingleZoneEarnRouter's suites against ZoneRouter in its Earn mode. Routers come from
///      ZoneRouterFactory, and EarnRouterTestBase's helpers drive them through SingleZoneEarnRouter's
///      ABI (`router`), which ZoneRouter keeps for ops 0 and 1, so callbacks are encoded with
///      SingleZoneEarnRouter's own structs. A suite that overrides `_withSpend` repeats every case with
///      Spend also enabled (ops 7).
abstract contract ZoneRouterEarnTestBase is EarnRouterTestBase {
    ZoneRouterFactory internal factory;
    IdleSettler internal idleSettler;
    ZoneRouter internal zoneRouter;

    /// @dev Earn owns the pinned DirectPropAMM fixture; this project reads it from there.
    function _propAMMArtifact() internal pure override returns (string memory) {
        return "../earn/test/fixtures/propamm/DirectPropAMM.json";
    }

    function setUp() public virtual override {
        super.setUp();
        factory = new ZoneRouterFactory();
        idleSettler = new IdleSettler();
    }

    /// @dev Whether this suite's routers also enable Spend.
    function _withSpend() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev The Earn mode SingleZoneEarnRouter(zoneId, earnVaultA, privateAsset, pool, customerId) maps to.
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
        mode.settlers = new address[](spends ? 1 : 0);
        if (spends) mode.settlers[0] = address(idleSettler);
    }

    /// @dev Deploys a Zone A Earn-mode router through the factory and points the base helpers at it.
    function _deployZoneRouter(address privateAsset, address pool, bytes32 customerId)
        internal
        returns (ZoneRouter zr)
    {
        zr = ZoneRouter(factory.deploy(_earnMode(ZONE_A, privateAsset, pool, customerId)));
        _use(zr);
    }

    /// @dev The ZoneRouter counterpart of `_admittedRouter`: a converting router admitted to `pool`.
    function _admittedZoneRouter(IRouterPropAMMPool pool) internal returns (ZoneRouter zr) {
        zr = _deployZoneRouter(address(alternate), address(pool), CUSTOMER_ID);
        pool.setTakerAllowed(address(zr), true);
        pool.setRecipientAllowed(address(zr), true);
    }

    function _use(ZoneRouter zr) internal {
        zoneRouter = zr;
        router = SingleZoneEarnRouter(address(zr));
    }
}
