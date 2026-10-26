// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test fixtures use bounded uint128 amounts.
// forge-lint: disable-start(erc20-unchecked-transfer,unsafe-typecast)

import { ZONE_MESSENGER_ADDRESS } from "../../src/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "../../src/router/SingleZoneEarnRouter.sol";
import { EarnRouterTestBase } from "../helpers/EarnRouterTestBase.sol";
import { MemoMockToken } from "../helpers/PropAMMEngineMocks.sol";

/// @dev Pool stand-in that settles a par swap incorrectly in one configurable way.
contract MisbehavingParPool {
    enum Mode {
        Exact,
        PayShort,
        PayExtra,
        PayNothing,
        PullShort
    }

    address public immutable baseToken;
    address public immutable quoteToken;
    address public immutable oracle;
    Mode public mode;

    constructor(address base, address quote, address oracle_) {
        baseToken = base;
        quoteToken = quote;
        oracle = oracle_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function takerAllowed(address) external pure returns (bool) {
        return true;
    }

    function recipientAllowed(address) external pure returns (bool) {
        return true;
    }

    function resolveRecipient(address recipient) external pure returns (address) {
        return recipient;
    }

    function swapExactInput(
        bool baseToQuote,
        uint256 amountIn,
        uint256,
        address recipient,
        bytes32,
        bytes32,
        uint256,
        uint256,
        uint256,
        uint256
    ) external returns (uint256 amountOut) {
        (address tokenIn, address tokenOut) = baseToQuote ? (baseToken, quoteToken) : (quoteToken, baseToken);
        uint256 pulled = mode == Mode.PullShort ? amountIn - 1 : amountIn;
        MemoMockToken(tokenIn).transferFrom(msg.sender, address(this), pulled);
        if (mode == Mode.PayShort) amountOut = amountIn - 1;
        else if (mode == Mode.PayExtra) amountOut = amountIn + 1;
        else if (mode == Mode.PayNothing) amountOut = 0;
        else amountOut = amountIn;
        if (amountOut != 0) MemoMockToken(tokenOut).transfer(recipient, amountOut);
        // Reports the requested amount regardless of what it actually paid.
        return amountIn;
    }
}

/// @dev Proves the router's measured-delta custody checks, independent of any honest pool.
contract SingleZoneEarnRouterCustodyTest is EarnRouterTestBase {
    MisbehavingParPool private pool;

    function setUp() public override {
        super.setUp();
        pool = new MisbehavingParPool(address(alternate), address(assetA), address(oracle));
        alternate.mint(address(pool), POOL_INVENTORY);
        assetA.mint(address(pool), POOL_INVENTORY);
        router = new SingleZoneEarnRouter(ZONE_A, address(earnVaultA), address(alternate), address(pool), CUSTOMER_ID);
    }

    function testDepositRejectsShortOverpaidOrMissingOutput() public {
        pool.setMode(MisbehavingParPool.Mode.PayShort);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSelector(SingleZoneEarnRouter.InsufficientOutput.selector));
        pool.setMode(MisbehavingParPool.Mode.PayExtra);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSelector(SingleZoneEarnRouter.InsufficientOutput.selector));
        pool.setMode(MisbehavingParPool.Mode.PayNothing);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSelector(SingleZoneEarnRouter.InsufficientOutput.selector));
    }

    function testDepositRejectsUnconsumedInput() public {
        pool.setMode(MisbehavingParPool.Mode.PullShort);
        _expectDepositRevert(ONE, ONE, abi.encodeWithSelector(SingleZoneEarnRouter.ResidualBalance.selector));
    }

    function testRedemptionRejectsShortOutput() public {
        _deposit(2 * ONE, 2 * ONE, 2 * ONE);
        portalA.release(address(earnA), address(router), ONE);
        pool.setMode(MisbehavingParPool.Mode.PayShort);
        uint256 sharesBefore = earnA.balanceOf(address(router));
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(SingleZoneEarnRouter.InsufficientOutput.selector);
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
