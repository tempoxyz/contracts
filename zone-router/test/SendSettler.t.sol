// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test-only mocks use simple ERC-20 calls and bounded uint128 fixtures.
// forge-lint: disable-start(erc20-unchecked-transfer,unsafe-typecast)

import { ZoneRouter } from "../src/ZoneRouter.sol";
import { ZoneRouterFactory } from "../src/ZoneRouterFactory.sol";
import { ADDRESS_REGISTRY_ADDRESS, IAddressRegistry } from "../src/interfaces/IAddressRegistry.sol";
import { SendSettler } from "../src/settlers/SendSettler.sol";
import { EarnRouterTestBase, IRouterPropAMMPool } from "earn-test/helpers/EarnRouterTestBase.sol";
import { MemoMockToken } from "earn-test/helpers/PropAMMEngineMocks.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IPropAMMVenue } from "tempo-earn/interfaces/external/propamm/IPropAMMVenue.sol";
import { ZONE_MESSENGER_ADDRESS } from "tempo-earn/interfaces/external/tempo/IZone.sol";

/// @dev Reports itself as the EarnShare's vault but pays nobody, keeping what it pulls.
contract ThievingVault {
    address public immutable earnShare;
    address public immutable asset;

    constructor(address earnShare_, address asset_) {
        earnShare = earnShare_;
        asset = asset_;
    }

    function withdrawExact(uint256, address, uint256 maxEarnShares) external returns (uint256) {
        MemoMockToken(earnShare).transferFrom(msg.sender, address(this), maxEarnShares);
        return maxEarnShares;
    }
}

/// @dev A caller-made "vault" that takes its EarnShare input and pays its asset from its own funds: with a
///      pair of its choosing it would turn a converting settler into an open par swap through the pool.
contract PassThroughVault {
    address public immutable earnShare;
    address public immutable asset;

    constructor(address earnShare_, address asset_) {
        earnShare = earnShare_;
        asset = asset_;
    }

    function withdrawExact(uint256 assets, address receiver, uint256 maxEarnShares) external returns (uint256) {
        MemoMockToken(earnShare).transferFrom(msg.sender, address(this), maxEarnShares);
        MemoMockToken(asset).transfer(receiver, assets);
        return maxEarnShares;
    }
}

/// @dev TIP-1022's registry: virtual addresses (bytes 4..14 the magic) resolve to their master's.
contract MockAddressRegistry is IAddressRegistry {
    error VirtualAddressUnregistered();

    mapping(bytes4 masterId => address master) public masters;

    function setMaster(bytes4 masterId, address master) external {
        masters[masterId] = master;
    }

    function resolveRecipient(address to) external view returns (address) {
        if ((uint160(to) >> 48) & type(uint80).max != 0xFDFDFDFDFDFDFDFDFDFD) return to;
        address master = masters[bytes4(bytes20(to))];
        if (master == address(0)) revert VirtualAddressUnregistered();
        return master;
    }
}

/// @dev A token that, like a TIP-20, credits a virtual recipient's master.
contract VirtualAwareToken is MemoMockToken {
    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        MemoMockToken(name_, symbol_, decimals_)
    { }

    function _transfer(address from, address to, uint256 value) internal override {
        super._transfer(from, IAddressRegistry(ADDRESS_REGISTRY_ADDRESS).resolveRecipient(to), value);
    }
}

contract SendSettlerTest is EarnRouterTestBase {
    bytes32 private constant REF = keccak256("send");
    bytes4 private constant MASTER_ID = 0x12345678;
    address private constant VIRTUAL_TO = address(uint160(0x12345678fDFDfDFdFDfdFdfdFDFd000000000001));
    address private constant UNREGISTERED_VIRTUAL_TO = address(uint160(0x87654321fDfdFdFDfdFDfDfDfdfD000000000001));

    IRouterPropAMMPool internal pool;
    SendSettler internal sends;
    SendSettler internal plainSends;
    address internal to = makeAddr("to");

    /// @dev Earn owns the pinned DirectPropAMM fixture; this project reads it from there.
    function _propAMMArtifact() internal pure override returns (string memory) {
        return "../earn/test/fixtures/propamm/DirectPropAMM.json";
    }

    function setUp() public override {
        super.setUp();
        pool = _routerPool(address(alternate), address(assetA));
        sends = new SendSettler(IEarnVault(address(earnVaultA)), IPropAMMVenue(address(pool)), CUSTOMER_ID);
        pool.setTakerAllowed(address(sends), true);
        pool.setRecipientAllowed(address(sends), true);
        plainSends = new SendSettler(IEarnVault(address(0)), IPropAMMVenue(address(0)), bytes32(0));
    }

    function _send(address token, uint256 amount, address vault) internal view returns (bytes memory) {
        return _sendTo(to, token, amount, vault);
    }

    function _sendTo(address recipient_, address token, uint256 amount, address vault)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            SendSettler.Send({ to: recipient_, token: token, amount: uint128(amount), vault: vault, ref: REF })
        );
    }

    /// @dev Installs a TIP-1022 registry with VIRTUAL_TO's master, and makes the stablecoins credit masters.
    function _virtualRecipients() internal returns (address master) {
        vm.etch(ADDRESS_REGISTRY_ADDRESS, address(new MockAddressRegistry()).code);
        master = makeAddr("master");
        MockAddressRegistry(ADDRESS_REGISTRY_ADDRESS).setMaster(MASTER_ID, master);
        bytes memory code = address(new VirtualAwareToken("", "", 6)).code;
        vm.etch(address(alternate), code);
        vm.etch(address(assetA), code);
    }

    function _shares(uint256 amount) internal {
        _publicDeposit(address(this), amount);
    }

    function _assertEmpty(SendSettler settler) internal view {
        MemoMockToken[3] memory tokens = [alternate, assetA, earnA];
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(tokens[i].balanceOf(address(settler)), 0);
            assertEq(tokens[i].allowance(address(settler), address(earnVaultA)), 0);
            assertEq(tokens[i].allowance(address(settler), address(pool)), 0);
        }
    }

    function testBindsTheConversionToOneVaultAssetAndItsPairedStablecoin() public view {
        assertEq(address(sends.convertVault()), address(earnVaultA));
        assertEq(sends.convertAsset(), address(assetA));
        assertEq(sends.parToken(), address(alternate));
        assertEq(address(plainSends.convertVault()), address(0));
        assertEq(plainSends.parToken(), address(0));
        assertEq(plainSends.parPrice(), 0);
    }

    function testRejectsAPartialConversionBinding() public {
        IEarnVault vault = IEarnVault(address(earnVaultA));
        IPropAMMVenue venue = IPropAMMVenue(address(pool));
        vm.expectRevert(SendSettler.InvalidPool.selector);
        new SendSettler(vault, venue, bytes32(0));
        vm.expectRevert(SendSettler.InvalidPool.selector);
        new SendSettler(vault, IPropAMMVenue(address(0)), CUSTOMER_ID);
        vm.expectRevert(SendSettler.InvalidPool.selector);
        new SendSettler(IEarnVault(address(0)), venue, CUSTOMER_ID);
        vm.expectRevert(SendSettler.InvalidPool.selector);
        new SendSettler(IEarnVault(address(0)), IPropAMMVenue(address(0)), CUSTOMER_ID);
        vm.expectRevert(SendSettler.InvalidVault.selector);
        new SendSettler(IEarnVault(makeAddr("noVault")), venue, CUSTOMER_ID);
    }

    function testRejectsAPoolThatDoesNotPairTheVaultAssetWithAnotherEqualUnitStablecoin() public {
        IEarnVault vault = IEarnVault(address(earnVaultA));
        MemoMockToken wide = new MemoMockToken("Wide", "WIDE", 18);
        address[3] memory pools = [
            address(_routerPool(address(alternate), address(assetB))),
            address(_routerPool(address(earnA), address(assetA))),
            address(_routerPool(address(wide), address(assetA)))
        ];
        for (uint256 i = 0; i < pools.length; i++) {
            vm.expectRevert(SendSettler.InvalidRoutePair.selector);
            new SendSettler(vault, IPropAMMVenue(pools[i]), CUSTOMER_ID);
        }
        // Either side of the pool may be the vault asset.
        IPropAMMVenue quoteSide = IPropAMMVenue(address(_routerPool(address(assetA), address(alternate))));
        assertEq(new SendSettler(vault, quoteSide, CUSTOMER_ID).parToken(), address(alternate));
    }

    function testSendsAStablecoinAndHandsBackTheRest() public {
        alternate.mint(address(this), 5 * ONE);
        alternate.transfer(address(sends), 5 * ONE);
        vm.expectEmit(true, true, false, true, address(sends));
        emit SendSettler.SendSettled(REF, to, address(alternate), address(alternate), 3 * ONE, 3 * ONE, 2 * ONE);
        sends.settle(address(alternate), 5 * ONE, _send(address(alternate), 3 * ONE, address(0)));
        assertEq(alternate.balanceOf(to), 3 * ONE);
        assertEq(alternate.balanceOf(address(this)), 2 * ONE);
        _assertEmpty(sends);
    }

    function testSendsEarnShareAsIs() public {
        _shares(4 * ONE);
        earnA.transfer(address(plainSends), 4 * ONE);
        plainSends.settle(address(earnA), 4 * ONE, _send(address(earnA), 4 * ONE, address(0)));
        assertEq(earnA.balanceOf(to), 4 * ONE);
        _assertEmpty(plainSends);
    }

    function testRedeemsEarnShareIntoTheVaultAsset() public {
        _shares(10 * ONE);
        uint256 maxShares = earnVaultA.previewWithdraw(3 * ONE) + 2;
        earnA.transfer(address(plainSends), maxShares);
        plainSends.settle(address(earnA), maxShares, _send(address(assetA), 3 * ONE, address(earnVaultA)));
        assertEq(assetA.balanceOf(to), 3 * ONE);
        assertEq(earnA.balanceOf(address(this)), 10 * ONE - maxShares + 2);
        _assertEmpty(plainSends);
    }

    function testRedeemsEarnShareIntoAParStablecoin() public {
        _shares(10 * ONE);
        uint256 maxShares = earnVaultA.previewWithdraw(3 * ONE) + 2;
        earnA.transfer(address(sends), maxShares);
        sends.settle(address(earnA), maxShares, _send(address(alternate), 3 * ONE, address(earnVaultA)));
        assertEq(alternate.balanceOf(to), 3 * ONE);
        assertEq(assetA.balanceOf(to), 0);
        _assertEmpty(sends);
    }

    function testCannotConvertWithoutAPool() public {
        _shares(10 * ONE);
        earnA.transfer(address(plainSends), 4 * ONE);
        vm.expectRevert(SendSettler.ConversionNotAllowed.selector);
        plainSends.settle(address(earnA), 4 * ONE, _send(address(alternate), 3 * ONE, address(earnVaultA)));
    }

    function testAFakeVaultCannotConvertThroughThePool() public {
        MemoMockToken junk = new MemoMockToken("Junk", "JUNK", 6);
        PassThroughVault fake = new PassThroughVault(address(junk), address(assetA));
        assetA.mint(address(fake), 3 * ONE);
        junk.mint(address(sends), 3 * ONE);
        vm.expectRevert(SendSettler.ConversionNotAllowed.selector);
        sends.settle(address(junk), 3 * ONE, _send(address(alternate), 3 * ONE, address(fake)));
    }

    function testCannotConvertTheStablecoinBackIntoTheVaultAsset() public {
        MemoMockToken junk = new MemoMockToken("Junk", "JUNK", 6);
        PassThroughVault fake = new PassThroughVault(address(junk), address(alternate));
        alternate.mint(address(fake), 3 * ONE);
        junk.mint(address(sends), 3 * ONE);
        vm.expectRevert(SendSettler.ConversionNotAllowed.selector);
        sends.settle(address(junk), 3 * ONE, _send(address(assetA), 3 * ONE, address(fake)));
    }

    function testAnotherVaultCannotConvert() public {
        assetB.mint(address(this), 10 * ONE);
        assetB.approve(address(earnVaultB), 10 * ONE);
        earnVaultB.deposit(10 * ONE, address(this), 10 * ONE);
        earnB.transfer(address(sends), 4 * ONE);
        vm.expectRevert(SendSettler.ConversionNotAllowed.selector);
        sends.settle(address(earnB), 4 * ONE, _send(address(alternate), 3 * ONE, address(earnVaultB)));
        // Its own asset still redeems without the pool.
        uint256 maxShares = earnVaultB.previewWithdraw(3 * ONE) + 2;
        earnB.transfer(address(plainSends), maxShares);
        plainSends.settle(address(earnB), maxShares, _send(address(assetB), 3 * ONE, address(earnVaultB)));
        assertEq(assetB.balanceOf(to), 3 * ONE);
    }

    function testPaysAVirtualRecipientThroughItsMasterOnEveryPath() public {
        _shares(10 * ONE);
        address master = _virtualRecipients();

        alternate.mint(address(sends), 2 * ONE);
        sends.settle(address(alternate), 2 * ONE, _sendTo(VIRTUAL_TO, address(alternate), 2 * ONE, address(0)));
        assertEq(alternate.balanceOf(master), 2 * ONE);

        uint256 maxShares = earnVaultA.previewWithdraw(3 * ONE) + 2;
        earnA.transfer(address(plainSends), maxShares);
        plainSends.settle(address(earnA), maxShares, _sendTo(VIRTUAL_TO, address(assetA), 3 * ONE, address(earnVaultA)));
        assertEq(assetA.balanceOf(master), 3 * ONE);

        maxShares = earnVaultA.previewWithdraw(ONE) + 2;
        earnA.transfer(address(sends), maxShares);
        sends.settle(address(earnA), maxShares, _sendTo(VIRTUAL_TO, address(alternate), ONE, address(earnVaultA)));
        assertEq(alternate.balanceOf(master), 3 * ONE);

        assertEq(alternate.balanceOf(VIRTUAL_TO), 0);
        assertEq(assetA.balanceOf(VIRTUAL_TO), 0);
        _assertEmpty(sends);
        _assertEmpty(plainSends);
    }

    function testAnUnregisteredVirtualRecipientReverts() public {
        _virtualRecipients();
        alternate.mint(address(sends), ONE);
        vm.expectRevert(MockAddressRegistry.VirtualAddressUnregistered.selector);
        sends.settle(address(alternate), ONE, _sendTo(UNREGISTERED_VIRTUAL_TO, address(alternate), ONE, address(0)));
    }

    function testRejectsAnInputThatIsNotTheSentTokenOrTheVaultShare() public {
        alternate.mint(address(sends), ONE);
        vm.expectRevert(abi.encodeWithSelector(SendSettler.WrongInputToken.selector, address(alternate)));
        sends.settle(address(alternate), ONE, _send(address(assetA), ONE, address(0)));
        vm.expectRevert(abi.encodeWithSelector(SendSettler.WrongInputToken.selector, address(alternate)));
        sends.settle(address(alternate), ONE, _send(address(assetA), ONE, address(earnVaultA)));
    }

    function testRejectsASendAboveMaxInputOrWithoutInput() public {
        alternate.mint(address(sends), ONE);
        vm.expectRevert(SendSettler.InvalidAmount.selector);
        sends.settle(address(alternate), ONE, _send(address(alternate), 2 * ONE, address(0)));
        vm.expectRevert(SendSettler.InsufficientInput.selector);
        sends.settle(address(alternate), 2 * ONE, _send(address(alternate), ONE, address(0)));
    }

    function testAVaultThatDoesNotPayCannotSettle() public {
        ThievingVault thief = new ThievingVault(address(earnA), address(assetA));
        _shares(4 * ONE);
        earnA.transfer(address(plainSends), 4 * ONE);
        vm.expectRevert(SendSettler.DestinationNotPaid.selector);
        plainSends.settle(address(earnA), 4 * ONE, _send(address(assetA), 3 * ONE, address(thief)));
    }

    function testSendsThroughARouterAndReturnsTheChangeToTheZone() public {
        ZoneRouterFactory factory = new ZoneRouterFactory();
        ZoneRouter.Mode memory mode;
        mode.zoneId = ZONE_A;
        mode.enabledOps = uint8(1 << 2);
        mode.settlers = new address[](1);
        mode.settlers[0] = address(sends);
        ZoneRouter zr = ZoneRouter(factory.deploy(mode));

        alternate.mint(address(zr), 5 * ONE);
        bytes memory data = abi.encode(
            ZoneRouter.SpendData({
                op: ZoneRouter.Op.Spend,
                settler: address(sends),
                maxInput: uint128(4 * ONE),
                settlerData: _send(address(alternate), 3 * ONE, address(0)),
                zoneReturn: ZoneRouter.SpendReturn({
                    keyIndex: 1, encrypted: _encrypted(), refundRecipient: refundRecipient, maxDepositFee: 0
                })
            })
        );
        vm.expectEmit(true, true, false, false, address(zr));
        emit ZoneRouter.Spent(address(sends), address(alternate), 3 * ONE, 2 * ONE, bytes32(0));
        vm.prank(ZONE_MESSENGER_ADDRESS);
        zr.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(5 * ONE), data);
        assertEq(alternate.balanceOf(to), 3 * ONE);
        assertEq(alternate.balanceOf(address(portalA)), 2 * ONE);
        assertEq(alternate.balanceOf(address(zr)), 0);
        _assertEmpty(sends);
    }
}
