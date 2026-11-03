// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test-only mocks use simple ERC-20 calls and bounded uint128 fixtures.
// forge-lint: disable-start(erc20-unchecked-transfer,unsafe-typecast)

import { ZoneRouter } from "../src/ZoneRouter.sol";
import { ZoneRouterFactory } from "../src/ZoneRouterFactory.sol";
import { ADDRESS_REGISTRY_ADDRESS, IAddressRegistry } from "../src/interfaces/IAddressRegistry.sol";
import { SendSpender } from "../src/spenders/SendSpender.sol";
import { ZoneRouterMockPortal } from "./helpers/ZoneRouterMockPortal.sol";
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
///      pair of its choosing it would turn a converting spender into an open par swap through the pool.
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

contract SendSpenderTest is EarnRouterTestBase {
    bytes32 private constant REF = keccak256("send");
    bytes4 private constant MASTER_ID = 0x12345678;
    address private constant VIRTUAL_TO = address(uint160(0x12345678fDFDfDFdFDfdFdfdFDFd000000000001));
    address private constant UNREGISTERED_VIRTUAL_TO = address(uint160(0x87654321fDfdFdFDfdFDfDfDfdfD000000000001));

    IRouterPropAMMPool internal pool;
    ZoneRouterFactory internal factory;
    SendSpender internal sends;
    SendSpender internal plainSends;
    /// @dev A factory router listing both spenders: the only kind of caller a spender accepts.
    ZoneRouter internal sendRouter;
    address internal to = makeAddr("to");

    /// @dev Earn owns the pinned DirectPropAMM fixture; this project reads it from there.
    function _propAMMArtifact() internal pure override returns (string memory) {
        return "../earn/test/fixtures/propamm/DirectPropAMM.json";
    }

    function setUp() public override {
        super.setUp();
        vm.etch(address(portalA), address(new ZoneRouterMockPortal()).code);
        pool = _routerPool(address(alternate), address(assetA));
        factory = new ZoneRouterFactory();
        sends = new SendSpender(
            address(factory), IEarnVault(address(earnVaultA)), IPropAMMVenue(address(pool)), CUSTOMER_ID
        );
        pool.setTakerAllowed(address(sends), true);
        pool.setRecipientAllowed(address(sends), true);
        plainSends = new SendSpender(address(factory), IEarnVault(address(0)), IPropAMMVenue(address(0)), bytes32(0));
        sendRouter = ZoneRouter(factory.deploy(_mode(address(sends), address(plainSends))));
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
            SendSpender.Send({ to: recipient_, token: token, amount: uint128(amount), vault: vault, ref: REF })
        );
    }

    /// @dev Calls `spendFrom` as `sendRouter`, after the test sent the spender its input as the router would.
    function _spendAsRouter(SendSpender spender, address token, uint256 maxInput, bytes memory data) internal {
        vm.prank(address(sendRouter));
        spender.spendFrom(token, maxInput, data);
    }

    /// @dev Delivers a Spend callback of `amount` of `token`, which the test already sent to `zr` as the Portal
    ///      would, naming `spender` with `maxInput`.
    function _deliver(
        ZoneRouter zr,
        SendSpender spender,
        address token,
        uint256 amount,
        uint256 maxInput,
        bytes memory data
    ) internal {
        vm.prank(ZONE_MESSENGER_ADDRESS);
        zr.onWithdrawalReceived(
            ZONE_A, address(portalA), bytes32(0), token, uint128(amount), _spendData(spender, maxInput, data)
        );
    }

    function _spendData(SendSpender spender, uint256 maxInput, bytes memory data) internal view returns (bytes memory) {
        return abi.encode(
            ZoneRouter.SpendData({
                op: ZoneRouter.Op.Spend,
                spender: address(spender),
                maxInput: uint128(maxInput),
                spenderData: data,
                zoneReturn: ZoneRouter.SpendReturn({
                    keyIndex: 1, encrypted: _encrypted(), refundRecipient: refundRecipient, maxDepositFee: 0
                })
            })
        );
    }

    function _mode(address first, address second) internal pure returns (ZoneRouter.Mode memory mode) {
        mode.zoneId = ZONE_A;
        mode.enabledOps = uint8(1 << 2);
        mode.spenders = new address[](second == address(0) ? 1 : 2);
        mode.spenders[0] = first;
        if (second != address(0)) mode.spenders[1] = second;
    }

    /// @dev Installs a TIP-1022 registry with VIRTUAL_TO's master, and makes the stablecoins credit masters.
    function _virtualRecipients() internal returns (address master) {
        master = makeAddr("master");
        _virtualRecipients(master);
    }

    function _virtualRecipients(address master) internal {
        vm.etch(ADDRESS_REGISTRY_ADDRESS, address(new MockAddressRegistry()).code);
        MockAddressRegistry(ADDRESS_REGISTRY_ADDRESS).setMaster(MASTER_ID, master);
        bytes memory code = address(new VirtualAwareToken("", "", 6)).code;
        vm.etch(address(alternate), code);
        vm.etch(address(assetA), code);
    }

    function _shares(uint256 amount) internal {
        _publicDeposit(address(this), amount);
    }

    function _assertEmpty(SendSpender spender) internal view {
        MemoMockToken[3] memory tokens = [alternate, assetA, earnA];
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(tokens[i].balanceOf(address(spender)), 0);
            assertEq(tokens[i].allowance(address(spender), address(earnVaultA)), 0);
            assertEq(tokens[i].allowance(address(spender), address(pool)), 0);
        }
    }

    function testBindsTheConversionToOneVaultAssetAndItsPairedStablecoin() public view {
        assertEq(sends.ROUTER_FACTORY(), address(factory));
        assertEq(address(sends.convertVault()), address(earnVaultA));
        assertEq(sends.convertAsset(), address(assetA));
        assertEq(sends.parToken(), address(alternate));
        assertEq(address(plainSends.convertVault()), address(0));
        assertEq(plainSends.parToken(), address(0));
        assertEq(plainSends.parPrice(), 0);
    }

    function testRejectsAPartialConversionBinding() public {
        address f = address(factory);
        IEarnVault vault = IEarnVault(address(earnVaultA));
        IPropAMMVenue venue = IPropAMMVenue(address(pool));
        vm.expectRevert(SendSpender.InvalidPool.selector);
        new SendSpender(f, vault, venue, bytes32(0));
        vm.expectRevert(SendSpender.InvalidPool.selector);
        new SendSpender(f, vault, IPropAMMVenue(address(0)), CUSTOMER_ID);
        vm.expectRevert(SendSpender.InvalidPool.selector);
        new SendSpender(f, IEarnVault(address(0)), venue, CUSTOMER_ID);
        vm.expectRevert(SendSpender.InvalidPool.selector);
        new SendSpender(f, IEarnVault(address(0)), IPropAMMVenue(address(0)), CUSTOMER_ID);
        vm.expectRevert(SendSpender.InvalidVault.selector);
        new SendSpender(f, IEarnVault(makeAddr("noVault")), venue, CUSTOMER_ID);
    }

    function testRequiresARouterFactoryWithCode() public {
        vm.expectRevert(SendSpender.InvalidRouterFactory.selector);
        new SendSpender(address(0), IEarnVault(address(0)), IPropAMMVenue(address(0)), bytes32(0));
        vm.expectRevert(SendSpender.InvalidRouterFactory.selector);
        new SendSpender(makeAddr("noFactory"), IEarnVault(address(0)), IPropAMMVenue(address(0)), bytes32(0));
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
            vm.expectRevert(SendSpender.InvalidRoutePair.selector);
            new SendSpender(address(factory), vault, IPropAMMVenue(pools[i]), CUSTOMER_ID);
        }
        // Either side of the pool may be the vault asset.
        IPropAMMVenue quoteSide = IPropAMMVenue(address(_routerPool(address(assetA), address(alternate))));
        assertEq(new SendSpender(address(factory), vault, quoteSide, CUSTOMER_ID).parToken(), address(alternate));
    }

    // ---------------------------------------------------------------------------------------------
    // Caller authentication
    // ---------------------------------------------------------------------------------------------

    /// @notice Without router authentication anyone could claim the balance here as their input and send it.
    function testRefusesACallerThatIsNotARouter() public {
        alternate.mint(address(sends), ONE);
        vm.expectRevert(SendSpender.NotRouter.selector);
        sends.spendFrom(address(alternate), ONE, _send(address(alternate), ONE, address(0)));
    }

    /// @notice A ZoneRouter the spender's factory did not deploy is refused, even with the spender in its mode.
    function testRefusesARouterFromAnotherFactory() public {
        ZoneRouter stranger = new ZoneRouter(_mode(address(sends), address(0)));
        alternate.mint(address(stranger), ONE);
        vm.expectRevert(SendSpender.NotRouter.selector);
        _deliver(stranger, sends, address(alternate), ONE, ONE, _send(address(alternate), ONE, address(0)));

        ZoneRouterFactory otherFactory = new ZoneRouterFactory();
        ZoneRouter other = ZoneRouter(otherFactory.deploy(_mode(address(sends), address(0))));
        alternate.mint(address(other), ONE);
        vm.expectRevert(SendSpender.NotRouter.selector);
        _deliver(other, sends, address(alternate), ONE, ONE, _send(address(alternate), ONE, address(0)));
    }

    /// @notice A router from the spender's own factory is refused unless its mode lists the spender.
    function testRefusesAFactoryRouterThatDoesNotListIt() public {
        ZoneRouter unlisted = ZoneRouter(factory.deploy(_mode(address(plainSends), address(0))));
        assertTrue(factory.isRouter(address(unlisted)));
        alternate.mint(address(sends), ONE);
        vm.prank(address(unlisted));
        vm.expectRevert(SendSpender.NotRouter.selector);
        sends.spendFrom(address(alternate), ONE, _send(address(alternate), ONE, address(0)));
    }

    // ---------------------------------------------------------------------------------------------
    // Sends
    // ---------------------------------------------------------------------------------------------

    function testSendsAStablecoinAndHandsBackTheRest() public {
        alternate.mint(address(this), 5 * ONE);
        alternate.transfer(address(sends), 5 * ONE);
        vm.expectEmit(true, true, false, true, address(sends));
        emit SendSpender.Sent(REF, to, address(alternate), address(alternate), 3 * ONE, 3 * ONE, 2 * ONE);
        _spendAsRouter(sends, address(alternate), 5 * ONE, _send(address(alternate), 3 * ONE, address(0)));
        assertEq(alternate.balanceOf(to), 3 * ONE);
        assertEq(alternate.balanceOf(address(sendRouter)), 2 * ONE);
        _assertEmpty(sends);
    }

    function testSendsEarnShareAsIs() public {
        _shares(4 * ONE);
        earnA.transfer(address(plainSends), 4 * ONE);
        _spendAsRouter(plainSends, address(earnA), 4 * ONE, _send(address(earnA), 4 * ONE, address(0)));
        assertEq(earnA.balanceOf(to), 4 * ONE);
        _assertEmpty(plainSends);
    }

    function testRedeemsEarnShareIntoTheVaultAsset() public {
        _shares(10 * ONE);
        uint256 maxShares = earnVaultA.previewWithdraw(3 * ONE) + 2;
        earnA.transfer(address(plainSends), maxShares);
        _spendAsRouter(plainSends, address(earnA), maxShares, _send(address(assetA), 3 * ONE, address(earnVaultA)));
        assertEq(assetA.balanceOf(to), 3 * ONE);
        assertEq(earnA.balanceOf(address(sendRouter)), 2);
        _assertEmpty(plainSends);
    }

    function testRedeemsEarnShareIntoAParStablecoin() public {
        _shares(10 * ONE);
        uint256 maxShares = earnVaultA.previewWithdraw(3 * ONE) + 2;
        earnA.transfer(address(sends), maxShares);
        _spendAsRouter(sends, address(earnA), maxShares, _send(address(alternate), 3 * ONE, address(earnVaultA)));
        assertEq(alternate.balanceOf(to), 3 * ONE);
        assertEq(assetA.balanceOf(to), 0);
        _assertEmpty(sends);
    }

    function testCannotConvertWithoutAPool() public {
        _shares(10 * ONE);
        earnA.transfer(address(plainSends), 4 * ONE);
        vm.expectRevert(SendSpender.ConversionNotAllowed.selector);
        _spendAsRouter(plainSends, address(earnA), 4 * ONE, _send(address(alternate), 3 * ONE, address(earnVaultA)));
    }

    function testAFakeVaultCannotConvertThroughThePool() public {
        MemoMockToken junk = new MemoMockToken("Junk", "JUNK", 6);
        PassThroughVault fake = new PassThroughVault(address(junk), address(assetA));
        assetA.mint(address(fake), 3 * ONE);
        junk.mint(address(sends), 3 * ONE);
        vm.expectRevert(SendSpender.ConversionNotAllowed.selector);
        _spendAsRouter(sends, address(junk), 3 * ONE, _send(address(alternate), 3 * ONE, address(fake)));
    }

    function testCannotConvertTheStablecoinBackIntoTheVaultAsset() public {
        MemoMockToken junk = new MemoMockToken("Junk", "JUNK", 6);
        PassThroughVault fake = new PassThroughVault(address(junk), address(alternate));
        alternate.mint(address(fake), 3 * ONE);
        junk.mint(address(sends), 3 * ONE);
        vm.expectRevert(SendSpender.ConversionNotAllowed.selector);
        _spendAsRouter(sends, address(junk), 3 * ONE, _send(address(assetA), 3 * ONE, address(fake)));
    }

    function testAnotherVaultCannotConvert() public {
        assetB.mint(address(this), 10 * ONE);
        assetB.approve(address(earnVaultB), 10 * ONE);
        earnVaultB.deposit(10 * ONE, address(this), 10 * ONE);
        earnB.transfer(address(sends), 4 * ONE);
        vm.expectRevert(SendSpender.ConversionNotAllowed.selector);
        _spendAsRouter(sends, address(earnB), 4 * ONE, _send(address(alternate), 3 * ONE, address(earnVaultB)));
        // Its own asset still redeems without the pool.
        uint256 maxShares = earnVaultB.previewWithdraw(3 * ONE) + 2;
        earnB.transfer(address(plainSends), maxShares);
        _spendAsRouter(plainSends, address(earnB), maxShares, _send(address(assetB), 3 * ONE, address(earnVaultB)));
        assertEq(assetB.balanceOf(to), 3 * ONE);
    }

    function testPaysAVirtualRecipientThroughItsMasterOnEveryPath() public {
        _shares(10 * ONE);
        address master = _virtualRecipients();

        alternate.mint(address(sends), 2 * ONE);
        _spendAsRouter(sends, address(alternate), 2 * ONE, _sendTo(VIRTUAL_TO, address(alternate), 2 * ONE, address(0)));
        assertEq(alternate.balanceOf(master), 2 * ONE);

        uint256 maxShares = earnVaultA.previewWithdraw(3 * ONE) + 2;
        earnA.transfer(address(plainSends), maxShares);
        _spendAsRouter(
            plainSends, address(earnA), maxShares, _sendTo(VIRTUAL_TO, address(assetA), 3 * ONE, address(earnVaultA))
        );
        assertEq(assetA.balanceOf(master), 3 * ONE);

        maxShares = earnVaultA.previewWithdraw(ONE) + 2;
        earnA.transfer(address(sends), maxShares);
        _spendAsRouter(
            sends, address(earnA), maxShares, _sendTo(VIRTUAL_TO, address(alternate), ONE, address(earnVaultA))
        );
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
        _spendAsRouter(
            sends, address(alternate), ONE, _sendTo(UNREGISTERED_VIRTUAL_TO, address(alternate), ONE, address(0))
        );
    }

    /// @notice A send to the calling router, directly or through a virtual address it masters, would strand
    ///         the output there (the router returns only the input token), so it reverts on every path.
    function testRefusesToPayTheRouter() public {
        _shares(10 * ONE);
        uint256 maxShares = earnVaultA.previewWithdraw(3 * ONE) + 2;
        bytes[3] memory sendsToRouter = [
            _sendTo(address(sendRouter), address(earnA), ONE, address(0)),
            _sendTo(address(sendRouter), address(assetA), 3 * ONE, address(earnVaultA)),
            _sendTo(address(sendRouter), address(alternate), 3 * ONE, address(earnVaultA))
        ];
        // Each rejected callback leaves the delivered input with the router, as a bounce would find it.
        earnA.transfer(address(sendRouter), maxShares);
        for (uint256 i = 0; i < sendsToRouter.length; i++) {
            vm.expectRevert(SendSpender.InvalidRecipient.selector);
            _deliver(sendRouter, sends, address(earnA), maxShares, maxShares, sendsToRouter[i]);
        }

        _virtualRecipients(address(sendRouter));
        vm.expectRevert(SendSpender.InvalidRecipient.selector);
        _deliver(
            sendRouter,
            sends,
            address(earnA),
            maxShares,
            maxShares,
            _sendTo(VIRTUAL_TO, address(alternate), 3 * ONE, address(earnVaultA))
        );

        alternate.mint(address(sends), ONE);
        vm.expectRevert(SendSpender.InvalidRecipient.selector);
        _spendAsRouter(sends, address(alternate), ONE, _sendTo(address(sends), address(alternate), ONE, address(0)));
    }

    function testRejectsAnInputThatIsNotTheSentTokenOrTheVaultShare() public {
        alternate.mint(address(sends), ONE);
        vm.expectRevert(abi.encodeWithSelector(SendSpender.WrongInputToken.selector, address(alternate)));
        _spendAsRouter(sends, address(alternate), ONE, _send(address(assetA), ONE, address(0)));
        vm.expectRevert(abi.encodeWithSelector(SendSpender.WrongInputToken.selector, address(alternate)));
        _spendAsRouter(sends, address(alternate), ONE, _send(address(assetA), ONE, address(earnVaultA)));
    }

    function testRejectsASendAboveMaxInputOrWithoutInput() public {
        alternate.mint(address(sends), ONE);
        vm.expectRevert(SendSpender.InvalidAmount.selector);
        _spendAsRouter(sends, address(alternate), ONE, _send(address(alternate), 2 * ONE, address(0)));
        vm.expectRevert(SendSpender.InsufficientInput.selector);
        _spendAsRouter(sends, address(alternate), 2 * ONE, _send(address(alternate), ONE, address(0)));
    }

    function testAVaultThatDoesNotPayCannotSettle() public {
        ThievingVault thief = new ThievingVault(address(earnA), address(assetA));
        _shares(4 * ONE);
        earnA.transfer(address(plainSends), 4 * ONE);
        vm.expectRevert(SendSpender.DestinationNotPaid.selector);
        _spendAsRouter(plainSends, address(earnA), 4 * ONE, _send(address(assetA), 3 * ONE, address(thief)));
    }

    function testSendsThroughARouterAndReturnsTheChangeToTheZone() public {
        alternate.mint(address(sendRouter), 5 * ONE);
        bytes32 depositHash =
            keccak256(abi.encode(address(portalA), address(alternate), 2 * ONE, portalA.depositCount() + 1));
        vm.expectEmit(true, true, false, true, address(sendRouter));
        emit ZoneRouter.Spent(address(sends), address(alternate), 3 * ONE, 2 * ONE, depositHash);
        _deliver(
            sendRouter, sends, address(alternate), 5 * ONE, 4 * ONE, _send(address(alternate), 3 * ONE, address(0))
        );
        assertEq(alternate.balanceOf(to), 3 * ONE);
        assertEq(alternate.balanceOf(address(portalA)), 2 * ONE);
        assertEq(alternate.balanceOf(address(sendRouter)), 0);
        _assertEmpty(sends);
    }

    /// @notice Through a real router on every path, the spender ends at the balance it held before (tokens
    ///         sent to it outside a spend stay put) and with no allowance to the vault or pool.
    function testFuzzEndsAtItsBaselineWithNoAllowance(uint8 path, uint64 stray, uint64 amount, uint64 slack) public {
        path = uint8(bound(path, 0, 2));
        stray = uint64(bound(stray, 0, 1e12));
        amount = uint64(bound(amount, 1, 50 * ONE));
        slack = uint64(bound(slack, 0, 10 * ONE));
        alternate.mint(address(sends), stray);
        assetA.mint(address(sends), stray);
        if (stray != 0) {
            _shares(stray);
            earnA.transfer(address(sends), stray);
        }

        if (path == 0) {
            alternate.mint(address(sendRouter), uint256(amount) + slack);
            _deliver(
                sendRouter,
                sends,
                address(alternate),
                uint256(amount) + slack,
                uint256(amount) + slack,
                _send(address(alternate), amount, address(0))
            );
            assertEq(alternate.balanceOf(to), amount);
        } else {
            // Redeems into the vault asset, or converts into the par stablecoin (within the pool's inventory).
            _shares(uint256(amount) + slack + 2);
            uint256 input = earnVaultA.previewWithdraw(amount) + 2 + slack;
            earnA.transfer(address(sendRouter), input);
            address output = path == 1 ? address(assetA) : address(alternate);
            _deliver(sendRouter, sends, address(earnA), input, input, _send(output, amount, address(earnVaultA)));
            assertEq(MemoMockToken(output).balanceOf(to), amount);
        }

        MemoMockToken[3] memory tokens = [alternate, assetA, earnA];
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(tokens[i].balanceOf(address(sends)), stray, "baseline");
            assertEq(tokens[i].allowance(address(sends), address(earnVaultA)), 0, "vault allowance");
            assertEq(tokens[i].allowance(address(sends), address(pool)), 0, "pool allowance");
            assertEq(tokens[i].balanceOf(address(sendRouter)), 0, "router balance");
        }
    }
}
