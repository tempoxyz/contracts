// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IStablecoinDEX } from "tempo-std/interfaces/IStablecoinDEX.sol";

/// @notice A DirectPropAMM pool: one base token quoted against one quote token at an oracle price.
interface IPropAmmPool {
    function quoteExactInput(bool baseToQuote, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 price, uint256 updatedAt);

    function quoteExactOutput(bool baseToQuote, uint256 amountOut)
        external
        view
        returns (uint256 amountIn, uint256 price, uint256 updatedAt);

    function swapExactInput(
        bool baseToQuote,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external returns (uint256 amountOut);

    function swapExactOutput(
        bool baseToQuote,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external returns (uint256 amountIn);
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @title Conversion
/// @notice Converts one stablecoin into another for card programs: quotes and swaps on the Stablecoin DEX or a
///         DirectPropAMM pool, routing through the hub token when a pair has no venue of its own. Each token has a
///         reference rate in hub units, against which a quote's conversion cost is measured. Owners set how far the
///         market may move from a rate a purchase locked before its capture lets the lock lapse.
/// @dev Swaps hold no balance between calls: a swap pulls what it spends from the caller and pays the recipient in
///      full. The only balance is the float that refunds convert out of at the reference rates.
contract Conversion {
    using FixedPointMathLib for uint256;

    /// @notice Rates carry 18 decimals: units of the output token per unit of the input token.
    uint256 public constant RATE_ONE = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @dev Amount a rate is measured on; venues price linearly, so a large probe keeps rounding out of the rate.
    uint256 internal constant PROBE = 1e10;
    IStablecoinDEX internal constant DEX = IStablecoinDEX(0xDEc0000000000000000000000000000000000000);

    /// @notice A pair's venue: a DirectPropAMM pool and the direction it trades, or the Stablecoin DEX for a zero pool.
    struct Venue {
        address pool;
        bool baseToQuote;
        bool exists;
    }

    address public immutable HUB;
    address public owner;
    uint256 internal nonce;

    mapping(address tokenIn => mapping(address tokenOut => Venue)) internal venues;
    /// @dev Hub units per token unit at the market's reference rate, with 18 decimals. The hub is always one.
    mapping(address token => uint256) internal mids;
    /// @notice Basis points the market may move from a rate a program's purchase locked; zero keeps every lock.
    mapping(address owner => mapping(address program => uint32)) public rateToleranceBps;
    /// @notice Programs that may convert at the reference rate out of this contract's float (refunds and reversals).
    mapping(address program => bool) public trusted;

    event OwnerSet(address owner);
    event VenueSet(address indexed tokenIn, address indexed tokenOut, address pool, bool baseToQuote);
    event ReferenceRateSet(address indexed token, uint256 rate);
    event RateToleranceSet(address indexed owner, address indexed program, uint32 toleranceBps);
    event TrustedSet(address indexed program, bool trusted);
    event ConvertedAtMid(
        address indexed program, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event Swapped(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    error Unauthorized();
    error NoVenue(address tokenIn, address tokenOut);
    error NoReferenceRate(address token);
    error Slippage(uint256 amount, uint256 bound);
    error InvalidAmount();
    error InsufficientFloat(uint256 needed, uint256 available);

    /// @custom:ensures HUB == hub && owner == owner_
    // A zero hub routes nothing through a hub, and a zero owner leaves the venues fixed.
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address hub, address owner_) {
        HUB = hub;
        owner = owner_;
        emit OwnerSet(owner_);
    }

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    // Configuration.

    // Setting a zero owner fixes the venues for good.
    // forge-lint: disable-next-item(missing-zero-check)
    function setOwner(address owner_) external onlyOwner {
        owner = owner_;
        emit OwnerSet(owner_);
    }

    /// @notice Trades tokenIn for tokenOut on a DirectPropAMM pool in one direction, or on the Stablecoin DEX for a
    ///         zero pool. A pool's owner must admit this contract as taker and recipient.
    function setVenue(address tokenIn, address tokenOut, address pool, bool baseToQuote) external onlyOwner {
        if (tokenIn == tokenOut) revert InvalidAmount();
        venues[tokenIn][tokenOut] = Venue({ pool: pool, baseToQuote: baseToQuote, exists: true });
        if (pool != address(0)) SafeTransferLib.safeApprove(tokenIn, pool, type(uint256).max);
        emit VenueSet(tokenIn, tokenOut, pool, baseToQuote);
    }

    function setReferenceRate(address token, uint256 rate_) external onlyOwner {
        if (token == HUB || rate_ == 0) revert InvalidAmount();
        mids[token] = rate_;
        emit ReferenceRateSet(token, rate_);
    }

    /// @notice The caller's tolerance for every rate a program's purchases lock on its funds.
    function setRateTolerance(address program, uint32 toleranceBps) external {
        if (toleranceBps > BPS) revert InvalidAmount();
        rateToleranceBps[msg.sender][program] = toleranceBps;
        emit RateToleranceSet(msg.sender, program, toleranceBps);
    }

    function setTrusted(address program, bool trusted_) external onlyOwner {
        trusted[program] = trusted_;
        emit TrustedSet(program, trusted_);
    }

    /// @notice Withdraws float the owner rebalances on the venues.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    // Quotes.

    function venueOf(address tokenIn, address tokenOut) external view returns (Venue memory) {
        return venues[tokenIn][tokenOut];
    }

    /// @notice Hub units per token unit at the reference rate, with 18 decimals.
    function referenceRate(address token) public view returns (uint256 rate_) {
        if (token == HUB) return RATE_ONE;
        rate_ = mids[token];
        if (rate_ == 0) revert NoReferenceRate(token);
    }

    /// @notice Units of tokenOut one unit of tokenIn is worth at the reference rates, with 18 decimals.
    function mid(address tokenIn, address tokenOut) external view returns (uint256) {
        if (tokenIn == tokenOut) return RATE_ONE;
        return referenceRate(tokenIn).mulDiv(RATE_ONE, referenceRate(tokenOut));
    }

    /// @notice Whether the pair converts, directly or through the hub.
    function converts(address tokenIn, address tokenOut) public view returns (bool) {
        if (tokenIn == tokenOut || venues[tokenIn][tokenOut].exists) return true;
        return tokenIn != HUB && tokenOut != HUB && venues[tokenIn][HUB].exists && venues[HUB][tokenOut].exists;
    }

    /// @notice What exactly amountIn of tokenIn fetches in tokenOut.
    function quoteIn(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        if (tokenIn == tokenOut || amountIn == 0) return amountIn;
        if (venues[tokenIn][tokenOut].exists) return _quoteIn(tokenIn, tokenOut, amountIn);
        return _quoteIn(HUB, tokenOut, _quoteIn(tokenIn, HUB, amountIn));
    }

    /// @notice What tokenIn exactly amountOut of tokenOut costs.
    function quoteOut(address tokenIn, address tokenOut, uint256 amountOut) public view returns (uint256) {
        if (tokenIn == tokenOut || amountOut == 0) return amountOut;
        if (venues[tokenIn][tokenOut].exists) return _quoteOut(tokenIn, tokenOut, amountOut);
        return _quoteOut(tokenIn, HUB, _quoteOut(HUB, tokenOut, amountOut));
    }

    /// @notice Units of tokenOut one unit of tokenIn fetches now, with 18 decimals.
    function rate(address tokenIn, address tokenOut) public view returns (uint256) {
        if (tokenIn == tokenOut) return RATE_ONE;
        return quoteIn(tokenIn, tokenOut, PROBE).mulDiv(RATE_ONE, PROBE);
    }

    /// @notice What a conversion at rate_ loses against the reference rates, in basis points; zero for a gain.
    function costBps(address tokenIn, address tokenOut, uint256 rate_) public view returns (uint256) {
        if (tokenIn == tokenOut) return 0;
        // Hub value of what one unit fetches, against the hub value of that unit.
        uint256 fair = referenceRate(tokenIn);
        uint256 got = rate_.mulDiv(referenceRate(tokenOut), RATE_ONE);
        return got >= fair ? 0 : (fair - got).mulDivUp(BPS, fair);
    }

    /// @notice Whether the market moved from locked to current by more than the owner's tolerance for the calling
    ///         program.
    function lapsed(address owner_, uint256 locked, uint256 current) external view returns (bool) {
        uint256 tolerance = rateToleranceBps[owner_][msg.sender];
        if (tolerance == 0 || locked == 0) return false;
        uint256 moved = current > locked ? current - locked : locked - current;
        return moved * BPS > locked * tolerance;
    }

    // Swaps.

    /// @notice Spends exactly amountIn of the caller's tokenIn for at least minOut of tokenOut, paid to recipient.
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out)
    {
        if (amountIn == 0) return 0;
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        if (tokenIn == tokenOut) {
            out = amountIn;
        } else if (venues[tokenIn][tokenOut].exists) {
            out = _swapIn(tokenIn, tokenOut, amountIn);
        } else {
            out = _swapIn(HUB, tokenOut, _swapIn(tokenIn, HUB, amountIn));
        }
        if (out < minOut) revert Slippage(out, minOut);
        SafeTransferLib.safeTransfer(tokenOut, recipient, out);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, out, recipient);
    }

    /// @notice Buys exactly amountOut of tokenOut for recipient with at most maxIn of the caller's tokenIn.
    function swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxIn, address recipient)
        external
        returns (uint256 spent)
    {
        if (amountOut == 0) return 0;
        spent = quoteOut(tokenIn, tokenOut, amountOut);
        if (spent > maxIn) revert Slippage(spent, maxIn);
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), spent);
        if (tokenIn == tokenOut) {
            // Nothing to trade.
        } else if (venues[tokenIn][tokenOut].exists) {
            _swapOut(tokenIn, tokenOut, amountOut, spent);
        } else {
            uint256 hub = quoteOut(HUB, tokenOut, amountOut);
            _swapOut(tokenIn, HUB, hub, spent);
            _swapOut(HUB, tokenOut, amountOut, hub);
        }
        SafeTransferLib.safeTransfer(tokenOut, recipient, amountOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, spent, amountOut, recipient);
    }

    /// @notice Converts exactly amountIn of a trusted program's tokenIn into tokenOut at the reference rates, without
    ///         conversion cost, paid from the float to recipient. Rounds down.
    function convertAtMid(address tokenIn, address tokenOut, uint256 amountIn, address recipient)
        external
        returns (uint256 out)
    {
        if (!trusted[msg.sender]) revert Unauthorized();
        if (amountIn == 0) return 0;
        out = tokenIn == tokenOut ? amountIn : amountIn.mulDiv(referenceRate(tokenIn), referenceRate(tokenOut));
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        uint256 float_ = IERC20Balance(tokenOut).balanceOf(address(this));
        if (float_ < out) revert InsufficientFloat(out, float_);
        SafeTransferLib.safeTransfer(tokenOut, recipient, out);
        emit ConvertedAtMid(msg.sender, tokenIn, tokenOut, amountIn, out);
    }

    // Internals.

    function _onlyOwner() private view {
        if (msg.sender != owner) revert Unauthorized();
    }

    function _venue(address tokenIn, address tokenOut) private view returns (Venue memory v) {
        v = venues[tokenIn][tokenOut];
        if (!v.exists) revert NoVenue(tokenIn, tokenOut);
    }

    function _quoteIn(address tokenIn, address tokenOut, uint256 amountIn) private view returns (uint256 out) {
        Venue memory v = _venue(tokenIn, tokenOut);
        if (v.pool == address(0)) return DEX.quoteSwapExactAmountIn(tokenIn, tokenOut, _u128(amountIn));
        (out,,) = IPropAmmPool(v.pool).quoteExactInput(v.baseToQuote, amountIn);
    }

    function _quoteOut(address tokenIn, address tokenOut, uint256 amountOut) private view returns (uint256 amountIn) {
        Venue memory v = _venue(tokenIn, tokenOut);
        if (v.pool == address(0)) return DEX.quoteSwapExactAmountOut(tokenIn, tokenOut, _u128(amountOut));
        (amountIn,,) = IPropAmmPool(v.pool).quoteExactOutput(v.baseToQuote, amountOut);
    }

    // The nonce only names each trade; it moves before the swap, so a reentered trade gets its own.
    // forge-lint: disable-start(reentrancy-no-eth)
    function _swapIn(address tokenIn, address tokenOut, uint256 amountIn) private returns (uint256 out) {
        Venue memory v = _venue(tokenIn, tokenOut);
        if (v.pool == address(0)) return DEX.swapExactAmountIn(tokenIn, tokenOut, _u128(amountIn), 0);
        (, uint256 price,) = IPropAmmPool(v.pool).quoteExactInput(v.baseToQuote, amountIn);
        bytes32 id = _tradeId();
        out = IPropAmmPool(v.pool)
            .swapExactInput(v.baseToQuote, amountIn, 0, address(this), id, id, block.timestamp, price, 0, 0);
    }

    function _swapOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxIn) private {
        Venue memory v = _venue(tokenIn, tokenOut);
        if (v.pool == address(0)) {
            DEX.swapExactAmountOut(tokenIn, tokenOut, _u128(amountOut), _u128(maxIn));
            return;
        }
        (, uint256 price,) = IPropAmmPool(v.pool).quoteExactOutput(v.baseToQuote, amountOut);
        bytes32 id = _tradeId();
        IPropAmmPool(v.pool)
            .swapExactOutput(v.baseToQuote, amountOut, maxIn, address(this), id, id, block.timestamp, price, 0, 0);
    }

    // forge-lint: disable-end(reentrancy-no-eth)

    /// @dev A fresh trade and customer id per trade, so no pool rounding credit carries from one trade to the next.
    function _tradeId() private returns (bytes32) {
        return keccak256(abi.encode(address(this), ++nonce));
    }

    function _u128(uint256 amount) private pure returns (uint128) {
        if (amount > type(uint128).max) revert InvalidAmount();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(amount);
    }
}
