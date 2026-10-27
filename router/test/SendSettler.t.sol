// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test-only mocks use simple ERC-20 calls and bounded uint128 fixtures.
// forge-lint: disable-start(erc20-unchecked-transfer,unsafe-typecast)

import { SendSettler } from "../src/SendSettler.sol";
import { ZoneRouter } from "../src/ZoneRouter.sol";
import { ZoneRouterFactory } from "../src/ZoneRouterFactory.sol";
import { EarnRouterTestBase, IRouterPropAMMPool } from "earn-test/helpers/EarnRouterTestBase.sol";
import { MemoMockToken } from "earn-test/helpers/PropAMMEngineMocks.sol";
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

contract SendSettlerTest is EarnRouterTestBase {
    bytes32 private constant REF = keccak256("send");

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
        sends = new SendSettler(IPropAMMVenue(address(pool)), CUSTOMER_ID);
        pool.setTakerAllowed(address(sends), true);
        pool.setRecipientAllowed(address(sends), true);
        plainSends = new SendSettler(IPropAMMVenue(address(0)), bytes32(0));
    }

    function _send(address token, uint256 amount, address vault) internal view returns (bytes memory) {
        return abi.encode(SendSettler.Send({ to: to, token: token, amount: uint128(amount), vault: vault, ref: REF }));
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

    function testRejectsAHalfConfiguredPool() public {
        vm.expectRevert(SendSettler.InvalidPool.selector);
        new SendSettler(IPropAMMVenue(address(pool)), bytes32(0));
        vm.expectRevert(SendSettler.InvalidPool.selector);
        new SendSettler(IPropAMMVenue(address(0)), CUSTOMER_ID);
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
        vm.expectRevert(SendSettler.InvalidPool.selector);
        plainSends.settle(address(earnA), 4 * ONE, _send(address(alternate), 3 * ONE, address(earnVaultA)));
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
