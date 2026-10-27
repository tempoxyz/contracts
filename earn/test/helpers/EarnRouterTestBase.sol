// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test-only mocks intentionally use simple ERC-20 calls and bounded uint128 fixtures.
// forge-lint: disable-start(erc20-unchecked-transfer,unsafe-typecast)

import { Test } from "forge-std/Test.sol";

import { EarnVault } from "../../src/core/EarnVault.sol";
import { Simple4626Vault } from "../../src/demo/Simple4626Vault.sol";
import { ERC4626Engine, IERC4626Vault } from "../../src/engines/ERC4626Engine.sol";
import { FeeConfig } from "../../src/interfaces/core/EarnFeeTypes.sol";
import { IPropAMMVenue } from "../../src/interfaces/external/propamm/IPropAMMVenue.sol";
import {
    EncryptedDepositPayload,
    ZONE_FACTORY_ADDRESS,
    ZONE_MESSENGER_ADDRESS,
    ZoneInfo
} from "../../src/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "../../src/router/SingleZoneEarnRouter.sol";
import { EarnVaultTestDeployer } from "./EarnVaultTestDeployer.sol";
import { MemoMockToken, MockRecipientRegistry, PropAMMTestOracle } from "./PropAMMEngineMocks.sol";

interface IRouterPropAMMPool is IPropAMMVenue {
    function roundingCredit(bytes32 routeKey) external view returns (uint256);
    function roundingRouteKey(address taker, address recipient, bytes32 customerId) external view returns (bytes32);
    function setTakerAllowed(address taker, bool allowed) external;
    function setRecipientAllowed(address recipient, bool allowed) external;
    function pause() external;
    function unpause() external;
    function withdraw(address token, address recipient, uint256 amount, bytes32 memo) external;
}

contract RouterMockZoneFactory {
    mapping(uint32 => address) public portalForZone;
    mapping(address => bool) public validPortal;

    function setZone(uint32 zoneId, address portal) external {
        portalForZone[zoneId] = portal;
        validPortal[portal] = true;
    }

    function setPortal(address portal, bool valid) external {
        validPortal[portal] = valid;
    }

    function zones(uint32 zoneId) external view returns (ZoneInfo memory info) {
        info.zoneId = zoneId;
        info.portal = portalForZone[zoneId];
        info.sequencers = new address[](0);
    }

    function isZonePortal(address portal) external view returns (bool) {
        return validPortal[portal];
    }
}

contract RouterMockZonePortal {
    mapping(address => bool) public enabled;
    mapping(address => bool) public depositsActive;
    address public lastToken;
    uint128 public lastAmount;
    address public lastRefundRecipient;
    uint256 public depositCount;
    uint128 public depositFee;

    function setDepositFee(uint128 fee) external {
        depositFee = fee;
    }

    function calculateDepositFee() external view returns (uint128) {
        return depositFee;
    }

    function setToken(address token, bool enabled_, bool active_) external {
        enabled[token] = enabled_;
        depositsActive[token] = active_;
    }

    function isTokenEnabled(address token) external view returns (bool) {
        return enabled[token];
    }

    function areDepositsActive(address token) external view returns (bool) {
        return depositsActive[token];
    }

    function depositEncrypted(
        address token,
        uint128 amount,
        uint256,
        EncryptedDepositPayload calldata,
        address refundRecipient
    ) external returns (bytes32 hash) {
        require(enabled[token] && depositsActive[token], "TOKEN_DISABLED");
        MemoMockToken(token).transferFrom(msg.sender, address(this), amount);
        lastToken = token;
        lastAmount = amount;
        lastRefundRecipient = refundRecipient;
        depositCount += 1;
        hash = keccak256(abi.encode(address(this), token, amount, depositCount));
    }

    function release(address token, address to, uint256 amount) external {
        MemoMockToken(token).transfer(to, amount);
    }
}

abstract contract EarnRouterTestBase is Test {
    uint256 internal constant ONE = 1e6;
    uint32 internal constant ZONE_A = 7;
    uint32 internal constant ZONE_B = 8;
    uint256 internal constant PAR = 1e8;
    uint256 internal constant POOL_INVENTORY = 100 * ONE;
    bytes32 internal constant CUSTOMER_ID = keccak256("earn-router-test");
    bytes32 internal constant ACTION_ID = keccak256("earn-router-action");

    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");
    address internal refundRecipient = makeAddr("refundRecipient");

    RouterMockZoneFactory internal zoneFactory;
    RouterMockZonePortal internal portalA;
    RouterMockZonePortal internal portalB;
    PropAMMTestOracle internal oracle;
    MockRecipientRegistry internal registry;
    MemoMockToken internal assetA;
    MemoMockToken internal earnA;
    Simple4626Vault internal venueA;
    ERC4626Engine internal engineA;
    EarnVault internal earnVaultA;
    MemoMockToken internal assetB;
    MemoMockToken internal earnB;
    EarnVault internal earnVaultB;
    MemoMockToken internal alternate;
    SingleZoneEarnRouter internal router;

    function setUp() public virtual {
        RouterMockZoneFactory factoryImplementation = new RouterMockZoneFactory();
        vm.etch(ZONE_FACTORY_ADDRESS, address(factoryImplementation).code);
        vm.mockFunction(
            ZONE_FACTORY_ADDRESS,
            address(factoryImplementation),
            abi.encodeWithSelector(RouterMockZoneFactory.setZone.selector)
        );
        vm.mockFunction(
            ZONE_FACTORY_ADDRESS,
            address(factoryImplementation),
            abi.encodeWithSelector(RouterMockZoneFactory.setPortal.selector)
        );
        vm.mockFunction(
            ZONE_FACTORY_ADDRESS,
            address(factoryImplementation),
            abi.encodeWithSelector(RouterMockZoneFactory.zones.selector)
        );
        vm.mockFunction(
            ZONE_FACTORY_ADDRESS,
            address(factoryImplementation),
            abi.encodeWithSelector(RouterMockZoneFactory.isZonePortal.selector)
        );
        zoneFactory = RouterMockZoneFactory(ZONE_FACTORY_ADDRESS);
        portalA = new RouterMockZonePortal();
        portalB = new RouterMockZonePortal();
        zoneFactory.setZone(ZONE_A, address(portalA));
        zoneFactory.setZone(ZONE_B, address(portalB));

        alternate = new MemoMockToken("Alternate", "ALT", 6);
        (assetA, earnA, venueA, engineA, earnVaultA) = _deployStack("A");
        (assetB, earnB,,, earnVaultB) = _deployStack("B");
        _enableEveryToken(portalA);
        _enableEveryToken(portalB);

        assetA.mint(user, 1_000 * ONE);
        assetB.mint(user, 1_000 * ONE);
        alternate.mint(user, 1_000 * ONE);

        vm.warp(1_800_000_000);
        oracle = new PropAMMTestOracle();
        oracle.set(PAR, block.timestamp);
        registry = new MockRecipientRegistry();
    }

    /// @dev Deploys the unmodified pinned DirectPropAMM artifact with funded inventory on both sides.
    function _routerPool(address base, address quote) internal returns (IRouterPropAMMPool pool) {
        // PropAMM pins solc 0.8.30; deploy its unmodified artifact alongside Earn's 0.8.36 code.
        pool = IRouterPropAMMPool(
            deployCode(
                "test/fixtures/propamm/DirectPropAMM.json",
                abi.encode(base, quote, address(oracle), address(registry), address(this), address(this), 1 days, 50)
            )
        );
        MemoMockToken(base).mint(address(pool), POOL_INVENTORY);
        MemoMockToken(quote).mint(address(pool), POOL_INVENTORY);
        pool.unpause();
    }

    /// @dev Deploys a Zone A router for the private asset and admits it to the pool.
    function _admittedRouter(IRouterPropAMMPool pool) internal returns (SingleZoneEarnRouter router) {
        router = new SingleZoneEarnRouter(ZONE_A, address(earnVaultA), address(alternate), address(pool), CUSTOMER_ID);
        pool.setTakerAllowed(address(router), true);
        pool.setRecipientAllowed(address(router), true);
    }

    function _deployStack(string memory suffix)
        private
        returns (
            MemoMockToken asset,
            MemoMockToken earn,
            Simple4626Vault venue,
            ERC4626Engine engine,
            EarnVault earnVault
        )
    {
        asset = new MemoMockToken(string.concat("Asset ", suffix), string.concat("A", suffix), 6);
        earn = new MemoMockToken(string.concat("Earn ", suffix), string.concat("E", suffix), 6);
        venue = new Simple4626Vault(address(asset), string.concat("Venue ", suffix), string.concat("V", suffix), 6);
        engine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        FeeConfig memory noFees;
        earnVault = EarnVaultTestDeployer.deploy(address(engine), address(earn), address(this), noFees);
        engine.initializeEarnVault(address(earnVault));
    }

    function _enableEveryToken(RouterMockZonePortal portal) private {
        portal.setToken(address(assetA), true, true);
        portal.setToken(address(earnA), true, true);
        portal.setToken(address(assetB), true, true);
        portal.setToken(address(earnB), true, true);
        portal.setToken(address(alternate), true, true);
    }

    function _publicDeposit(address account, uint256 amount) internal {
        assetA.mint(account, amount);
        vm.startPrank(account);
        assetA.approve(address(earnVaultA), amount);
        earnVaultA.deposit(amount, account, amount);
        vm.stopPrank();
    }

    function _encrypted() internal pure returns (EncryptedDepositPayload memory encrypted) {
        encrypted.ephemeralPubkeyX = bytes32(uint256(1));
        encrypted.ephemeralPubkeyYParity = 1;
        encrypted.ciphertext = hex"01020304";
        encrypted.nonce = bytes12(uint96(2));
        encrypted.tag = bytes16(uint128(3));
    }

    /// @dev Encodes a canonical callback that returns to Zone A's refund recipient.
    function _callback(
        SingleZoneEarnRouter.Flow flow,
        uint128 minVaultAssets,
        uint128 minEarnShares,
        uint128 minOutputAmount
    ) internal view returns (bytes memory) {
        return abi.encode(
            SingleZoneEarnRouter.CallbackData({
                flow: flow,
                minVaultAssets: minVaultAssets,
                minEarnShares: minEarnShares,
                minOutputAmount: minOutputAmount,
                actionId: ACTION_ID,
                zoneReturn: SingleZoneEarnRouter.ZoneReturn({
                    keyIndex: 1, encrypted: _encrypted(), refundRecipient: refundRecipient
                })
            })
        );
    }

    /// @dev Delivers `amount` of the router's private asset from Zone A as a deposit.
    function _deposit(uint256 amount, uint256 minVaultAssets, uint256 minEarnShares) internal {
        address input = router.privateAsset();
        MemoMockToken(input).mint(address(router), amount);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        router.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            input,
            uint128(amount),
            _callback(SingleZoneEarnRouter.Flow.Deposit, uint128(minVaultAssets), uint128(minEarnShares), 0)
        );
    }

    /// @dev Delivers EarnShare the router already holds from Zone A as a redemption.
    function _redeem(uint256 shares, uint256 minVaultAssets, uint256 minOutputAmount) internal {
        vm.prank(ZONE_MESSENGER_ADDRESS);
        router.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            address(earnA),
            uint128(shares),
            _callback(SingleZoneEarnRouter.Flow.Redeem, uint128(minVaultAssets), 0, uint128(minOutputAmount))
        );
    }

    /// @dev A rejected deposit of `ONE` reverts with exactly `reason`, mints no EarnShare, sends nothing to the
    /// Zone, and leaves only the delivered input behind.
    function _expectDepositRevert(uint256 minVaultAssets, uint256 minEarnShares, bytes memory reason) internal {
        address input = router.privateAsset();
        bool sameAsset = input == address(assetA);
        uint256 alternateBefore = alternate.balanceOf(address(router));
        uint256 assetBefore = assetA.balanceOf(address(router));
        uint256 earnBefore = earnA.balanceOf(address(router));
        uint256 supplyBefore = earnA.totalSupply();
        uint256 zoneDepositsBefore = portalA.depositCount();

        MemoMockToken(input).mint(address(router), ONE);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(reason);
        router.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            input,
            uint128(ONE),
            _callback(SingleZoneEarnRouter.Flow.Deposit, uint128(minVaultAssets), uint128(minEarnShares), 0)
        );

        assertEq(earnA.totalSupply(), supplyBefore);
        assertEq(portalA.depositCount(), zoneDepositsBefore);
        _assertRouterState(alternateBefore + (sameAsset ? 0 : ONE), assetBefore + (sameAsset ? ONE : 0), earnBefore);
    }

    /// @dev Asserts the router's exact balances and that it left no allowance to the pool, EarnVault, or portal.
    function _assertRouterState(uint256 alternateBalance, uint256 assetBalance, uint256 earnBalance) internal view {
        assertEq(alternate.balanceOf(address(router)), alternateBalance);
        assertEq(assetA.balanceOf(address(router)), assetBalance);
        assertEq(earnA.balanceOf(address(router)), earnBalance);
        MemoMockToken[3] memory tokens = [alternate, assetA, earnA];
        address[3] memory spenders = [address(router.pool()), address(earnVaultA), address(portalA)];
        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < spenders.length; j++) {
                assertEq(tokens[i].allowance(address(router), spenders[j]), 0);
            }
        }
    }
}
