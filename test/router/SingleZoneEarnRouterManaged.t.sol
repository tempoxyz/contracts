// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test fixtures use bounded uint128 amounts.
// forge-lint: disable-start(erc20-unchecked-transfer,unsafe-typecast)

import { ZONE_MESSENGER_ADDRESS } from "../../src/interfaces/external/tempo/IZone.sol";
import { IManagedPropAMMVenue } from "../../src/interfaces/external/propamm/IManagedPropAMMVenue.sol";
import { SingleZoneEarnRouter } from "../../src/router/SingleZoneEarnRouter.sol";
import { EarnRouterTestBase, IRouterPropAMMPool } from "../helpers/EarnRouterTestBase.sol";
import { MemoMockToken } from "../helpers/PropAMMEngineMocks.sol";

interface IRouterManagedPool is IManagedPropAMMVenue {
    function addPair(address base, address quote, address oracle, uint256 maxOracleAge, uint256 maxPriceDeviationBps)
        external
        returns (uint16 pairIndex);
    function setPairAccess(uint16 pairIndex, uint8 mode) external;
    function closePair(uint16 pairIndex) external;
    function addSponsor(uint64 sponsorId, address admin) external;
    function setSponsorEnabled(uint64 sponsorId, bool enabled) external;
    function setPairSponsor(uint16 pairIndex, uint64 sponsorId, bool admitted) external;
    function setMembers(uint16 pairIndex, uint64 sponsorId, address[] calldata accounts, bool allowed) external;
    function pause() external;
    function unpause() external;
}

/// @dev Exercises the router against the unmodified pinned ManagedDirectPropAMM artifact.
contract SingleZoneEarnRouterManagedTest is EarnRouterTestBase {
    uint8 private constant LISTED = 2;
    uint64 private constant SPONSOR = 5;

    IRouterManagedPool private managed;
    uint16 private pairIndex;

    function setUp() public override {
        super.setUp();
        // PropAMM pins solc 0.8.30; deploy its unmodified artifact alongside Earn's 0.8.36 code.
        managed = IRouterManagedPool(
            deployCode("test/fixtures/propamm/ManagedDirectPropAMM.json", abi.encode(address(this), address(this)))
        );
        managed.unpause();
        pairIndex = _openPair(address(alternate), address(assetA));
        alternate.mint(address(managed), POOL_INVENTORY);
        assetA.mint(address(managed), POOL_INVENTORY);
        router = _managedRouter(pairIndex, 0);
        _list(pairIndex, 0, address(router), true);
    }

    function testDepositAndRedeemConvertAtParThroughThePair() public {
        _deposit(5 * ONE, 5 * ONE, 5 * ONE);
        assertEq(earnA.balanceOf(address(portalA)), 5 * ONE);
        assertEq(alternate.balanceOf(address(managed)), POOL_INVENTORY + 5 * ONE);
        assertEq(assetA.balanceOf(address(managed)), POOL_INVENTORY - 5 * ONE);
        _assertRouterState(0, 0, 0);

        portalA.release(address(earnA), address(router), 2 * ONE);
        _redeem(2 * ONE, 2 * ONE, 2 * ONE);
        assertEq(alternate.balanceOf(address(portalA)), 2 * ONE);
        assertEq(alternate.balanceOf(address(managed)), POOL_INVENTORY + 3 * ONE);
        _assertRouterState(0, 0, 0);
    }

    function testConvertsWhenThePrivateAssetIsTheQuote() public {
        uint16 reversed = _openPair(address(assetA), address(alternate));
        router = _managedRouter(reversed, 0);
        _list(reversed, 0, address(router), true);
        assertFalse(router.privateAssetIsBase());

        _deposit(ONE, ONE, ONE);
        assertEq(earnA.balanceOf(address(portalA)), ONE);
    }

    function testTradesUnderASponsorList() public {
        managed.addSponsor(SPONSOR, address(this));
        managed.setPairSponsor(pairIndex, SPONSOR, true);
        router = _managedRouter(pairIndex, SPONSOR);
        _list(pairIndex, SPONSOR, address(router), true);

        _deposit(ONE, ONE, ONE);
        assertEq(earnA.balanceOf(address(portalA)), ONE);

        managed.setSponsorEnabled(SPONSOR, false);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSignature("SponsorDisabled(uint64)", SPONSOR));
    }

    function testAccessPauseAndPriceFailClosed() public {
        _list(pairIndex, 0, address(router), false);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSignature("TakerNotAllowed(address)", address(router)));
        _list(pairIndex, 0, address(router), true);

        managed.closePair(pairIndex);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSignature("TakerNotAllowed(address)", address(router)));
        managed.setPairAccess(pairIndex, LISTED);

        managed.pause();
        _expectDepositRevert(ONE, ONE, abi.encodeWithSignature("Paused()"));
        managed.unpause();

        oracle.set(PAR + 1, vm.getBlockTimestamp());
        _expectDepositRevert(
            ONE, ONE, abi.encodeWithSignature("OraclePriceToleranceExceeded(uint256,uint256,uint256)", PAR, PAR + 1, 0)
        );
        oracle.set(PAR, vm.getBlockTimestamp());

        _deposit(ONE, ONE, ONE);
        assertEq(earnA.balanceOf(address(portalA)), ONE);
    }

    function testLiquidityStatusReadsThePairAndTheRoutersList() public {
        (bool paused, bool admitted, bool atPar, uint256 depositLiquidity, uint256 redeemLiquidity) =
            router.liquidityStatus();
        assertFalse(paused);
        assertTrue(admitted);
        assertTrue(atPar);
        assertEq(depositLiquidity, POOL_INVENTORY);
        assertEq(redeemLiquidity, POOL_INVENTORY);
        assertEq(router.parPrice(), PAR);

        _list(pairIndex, 0, address(router), false);
        (, admitted,,,) = router.liquidityStatus();
        assertFalse(admitted);

        managed.closePair(pairIndex);
        (paused,,,,) = router.liquidityStatus();
        assertTrue(paused);
    }

    function testConstructorRejectsBadManagedBindings() public {
        vm.expectRevert(SingleZoneEarnRouter.InvalidPool.selector);
        this.deployRouter(address(alternate), address(managed), SingleZoneEarnRouter.PoolKind.Managed, 9, 0);

        uint16 otherPair = _openPair(address(alternate), address(assetB));
        vm.expectRevert(SingleZoneEarnRouter.InvalidRoutePair.selector);
        this.deployRouter(address(alternate), address(managed), SingleZoneEarnRouter.PoolKind.Managed, otherPair, 0);

        MemoMockToken coarse = new MemoMockToken("Coarse", "CRS", 2);
        uint16 mixedUnits = managed.addPair(address(coarse), address(assetA), address(oracle), 1 days, 50);
        vm.expectRevert(SingleZoneEarnRouter.InvalidRoutePair.selector);
        this.deployRouter(address(coarse), address(managed), SingleZoneEarnRouter.PoolKind.Managed, mixedUnits, 0);

        IRouterPropAMMPool direct = _routerPool(address(alternate), address(assetA));
        vm.expectRevert(SingleZoneEarnRouter.InvalidPool.selector);
        this.deployRouter(address(alternate), address(direct), SingleZoneEarnRouter.PoolKind.Direct, 1, 0);
        vm.expectRevert(SingleZoneEarnRouter.InvalidPool.selector);
        this.deployRouter(address(alternate), address(direct), SingleZoneEarnRouter.PoolKind.Direct, 0, 1);
        // A Direct pool has no `pair`, so a Managed binding to it cannot construct.
        vm.expectRevert();
        this.deployRouter(address(alternate), address(direct), SingleZoneEarnRouter.PoolKind.Managed, 0, 0);

        vm.expectRevert(SingleZoneEarnRouter.InvalidPrivateAsset.selector);
        new SingleZoneEarnRouter(
            ZONE_A,
            address(earnVaultA),
            address(assetA),
            address(0),
            bytes32(0),
            SingleZoneEarnRouter.PoolKind.Managed,
            0,
            0
        );
        vm.expectRevert(SingleZoneEarnRouter.InvalidPrivateAsset.selector);
        new SingleZoneEarnRouter(
            ZONE_A,
            address(earnVaultA),
            address(assetA),
            address(0),
            bytes32(0),
            SingleZoneEarnRouter.PoolKind.Direct,
            1,
            0
        );
    }

    function testRecordsItsManagedBinding() public view {
        assertEq(address(router.pool()), address(managed));
        assertEq(uint8(router.poolKind()), uint8(SingleZoneEarnRouter.PoolKind.Managed));
        assertEq(router.pairIndex(), pairIndex);
        assertEq(router.sponsorId(), 0);
        assertTrue(router.privateAssetIsBase());
    }

    /// @dev External so each constructor revert is a separate call that `vm.expectRevert` can match.
    function deployRouter(
        address privateAsset,
        address pool_,
        SingleZoneEarnRouter.PoolKind kind,
        uint16 pairIndex_,
        uint64 sponsorId_
    ) external returns (SingleZoneEarnRouter) {
        return new SingleZoneEarnRouter(
            ZONE_A, address(earnVaultA), privateAsset, pool_, CUSTOMER_ID, kind, pairIndex_, sponsorId_
        );
    }

    function _managedRouter(uint16 pairIndex_, uint64 sponsorId_) private returns (SingleZoneEarnRouter) {
        return new SingleZoneEarnRouter(
            ZONE_A,
            address(earnVaultA),
            address(alternate),
            address(managed),
            CUSTOMER_ID,
            SingleZoneEarnRouter.PoolKind.Managed,
            pairIndex_,
            sponsorId_
        );
    }

    /// @dev Adds a pair, which starts `Closed`, and opens it to listed takers.
    function _openPair(address base, address quote) private returns (uint16 index) {
        index = managed.addPair(base, quote, address(oracle), 1 days, 50);
        managed.setPairAccess(index, LISTED);
    }

    function _list(uint16 pairIndex_, uint64 sponsorId_, address account, bool allowed) private {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        managed.setMembers(pairIndex_, sponsorId_, accounts, allowed);
    }
}
