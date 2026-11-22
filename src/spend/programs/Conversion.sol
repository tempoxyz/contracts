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
///         reference rate in hub units, against which a quote's conversion cost is measured. Quotes are the venue's
///         own and are refused while it strays more than MAX_SLIPPAGE_BPS from the reference rates. The owner moves a
///         reference rate at most MAX_RATE_STEP_BPS in a RATE_STEP_WINDOW at once; a larger move, or a token's first
///         rate, waits RATE_DELAY after it is scheduled. Owners set how far the market may move from a rate a purchase
///         locked before its capture lets the lock lapse.
/// @dev Swaps hold no balance between calls: a swap pulls what it spends from the caller and pays the recipient in
///      full. The only balance is the float that refunds convert out of.
contract Conversion {
    using FixedPointMathLib for uint256;

    /// @notice Rates carry 18 decimals: units of the output token per unit of the input token.
    uint256 public constant RATE_ONE = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @notice How long a reference rate prices conversions after it was set.
    uint64 public constant MAX_RATE_AGE = 7 days;
    /// @notice How far below the reference rates a swap may pay out, or above them it may spend, and how far a
    ///         venue's quote may stray from them either way, in basis points.
    uint256 public constant MAX_SLIPPAGE_BPS = 100;
    /// @notice How far a reference rate may move at once from where it stood when its window opened, in basis points.
    uint256 public constant MAX_RATE_STEP_BPS = 200;
    /// @notice How long a reference rate's window lasts: each opens at the first change after the last one closed.
    uint64 public constant RATE_STEP_WINDOW = 1 days;
    /// @notice How long a scheduled reference rate waits before it may be set.
    uint64 public constant RATE_DELAY = 2 days;
    /// @notice The widest band around an anchor the anchored quotes and swaps accept, in basis points.
    uint256 public constant MAX_ANCHOR_BAND_BPS = 2000;
    /// @dev Amount a rate is measured on; venues price linearly, so a large probe keeps rounding out of the rate.
    uint256 internal constant PROBE = 1e10;
    IStablecoinDEX internal constant DEX = IStablecoinDEX(0xDEc0000000000000000000000000000000000000);

    /// @notice A pair's venue: a DirectPropAMM pool and the direction it trades, or the Stablecoin DEX for a zero pool.
    struct Venue {
        address pool;
        bool baseToQuote;
        bool exists;
    }

    /// @notice Where a reference rate stood when its current window opened, and when that was.
    struct RateWindow {
        uint128 anchor;
        uint64 openedAt;
    }

    /// @notice A reference rate the owner scheduled, and when it may be set.
    struct ScheduledRate {
        uint128 rate;
        uint64 readyAt;
    }

    address public immutable HUB;
    address public owner;
    /// @notice The owner the current owner named, who becomes owner once it accepts.
    address public pendingOwner;
    uint256 internal nonce;

    mapping(address tokenIn => mapping(address tokenOut => Venue)) internal venues;
    /// @dev Hub units per token unit at the market's reference rate, with 18 decimals. The hub is always one.
    mapping(address token => uint256) internal mids;
    /// @notice When each token's reference rate was last set.
    mapping(address token => uint64) public rateUpdatedAt;
    mapping(address token => RateWindow) public rateWindowOf;
    mapping(address token => ScheduledRate) public scheduledRateOf;
    /// @notice Programs that may convert at the reference rate out of this contract's float (refunds and reversals).
    mapping(address program => bool) public trusted;

    event OwnerSet(address owner);
    event OwnerProposed(address owner);
    event ReferenceRateScheduled(address indexed token, uint256 rate, uint64 readyAt);
    event VenueSet(address indexed tokenIn, address indexed tokenOut, address pool, bool baseToQuote);
    event ReferenceRateSet(address indexed token, uint256 rate);
    event TrustedSet(address indexed program, bool trusted);
    event ConvertedAt(
        address indexed program, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
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
    /// @notice The token's reference rate is older than MAX_RATE_AGE.
    error RateStale(address token);
    /// @notice The change moves the rate more than MAX_RATE_STEP_BPS in its window, or the token has no rate yet;
    ///         schedule it instead.
    error RateStepTooLarge(address token, uint256 rate);
    /// @notice The venue's quote strays more than MAX_SLIPPAGE_BPS from the reference rates.
    error RateDeviates(address tokenIn, address tokenOut, uint256 quoted, uint256 fair);
    /// @notice An anchored quote or swap strays from the caller's anchor by more than the caller's band.
    error RateBeyondAnchor(address tokenIn, address tokenOut, uint256 quoted, uint256 fair);
    error BandTooWide(uint256 bandBps);
    error Slippage(uint256 amount, uint256 bound);
    error MinOutTooLow(uint256 minOut, uint256 floor);
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

    /// @notice Names the next owner, who takes over once it calls acceptOwner. A zero owner takes effect at once and
    ///         fixes the venues and rates for good.
    function setOwner(address owner_) external onlyOwner {
        if (owner_ == address(0)) {
            (owner, pendingOwner) = (address(0), address(0));
            emit OwnerSet(address(0));
            return;
        }
        pendingOwner = owner_;
        emit OwnerProposed(owner_);
    }

    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        (owner, pendingOwner) = (msg.sender, address(0));
        emit OwnerSet(msg.sender);
    }

    /// @notice Trades tokenIn for tokenOut on a DirectPropAMM pool in one direction, or on the Stablecoin DEX for a
    ///         zero pool. A pool's owner must admit this contract as taker and recipient.
    function setVenue(address tokenIn, address tokenOut, address pool, bool baseToQuote) external onlyOwner {
        if (tokenIn == tokenOut) revert InvalidAmount();
        venues[tokenIn][tokenOut] = Venue({ pool: pool, baseToQuote: baseToQuote, exists: true });
        if (pool != address(0)) SafeTransferLib.safeApprove(tokenIn, pool, type(uint256).max);
        emit VenueSet(tokenIn, tokenOut, pool, baseToQuote);
    }

    /// @notice Sets a token's reference rate: the rate scheduled for it once RATE_DELAY has passed, or a rate within
    ///         MAX_RATE_STEP_BPS of where it stood when its window opened. Setting the current rate only refreshes it.
    // Windows and delays are days long; a few seconds of validator skew does not change them.
    // forge-lint: disable-next-item(block-timestamp,unsafe-typecast)
    function setReferenceRate(address token, uint256 rate_) external onlyOwner {
        if (token == HUB || rate_ == 0 || rate_ > type(uint128).max) revert InvalidAmount();
        ScheduledRate memory s = scheduledRateOf[token];
        uint64 now_ = uint64(block.timestamp);
        if (s.readyAt != 0 && s.rate == rate_ && now_ >= s.readyAt) {
            delete scheduledRateOf[token];
            rateWindowOf[token] = RateWindow(uint128(rate_), now_);
        } else {
            uint256 current = mids[token];
            if (current == 0) revert RateStepTooLarge(token, rate_);
            RateWindow memory w = rateWindowOf[token];
            if (now_ >= w.openedAt + RATE_STEP_WINDOW) {
                w = RateWindow(uint128(current), now_);
                if (rate_ != current) rateWindowOf[token] = w;
            }
            uint256 moved = rate_ > w.anchor ? rate_ - w.anchor : w.anchor - rate_;
            if (moved * BPS > uint256(w.anchor) * MAX_RATE_STEP_BPS) revert RateStepTooLarge(token, rate_);
        }
        mids[token] = rate_;
        // Timestamps fit 64 bits for billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        rateUpdatedAt[token] = uint64(block.timestamp);
        emit ReferenceRateSet(token, rate_);
    }

    /// @notice Schedules a token's reference rate, which setReferenceRate may set once RATE_DELAY has passed; a zero
    ///         rate cancels what is scheduled.
    // forge-lint: disable-next-item(block-timestamp,unsafe-typecast)
    function scheduleReferenceRate(address token, uint256 rate_) external onlyOwner {
        if (token == HUB || rate_ > type(uint128).max) revert InvalidAmount();
        uint64 readyAt = rate_ == 0 ? 0 : uint64(block.timestamp) + RATE_DELAY;
        scheduledRateOf[token] = ScheduledRate(uint128(rate_), readyAt);
        emit ReferenceRateScheduled(token, rate_, readyAt);
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

    /// @notice Hub units per token unit at the reference rate, with 18 decimals. Reverts RateStale once the rate is
    ///         older than MAX_RATE_AGE, so nothing prices at a rate the owner stopped keeping current.
    function referenceRate(address token) public view returns (uint256 rate_) {
        if (token == HUB) return RATE_ONE;
        rate_ = mids[token];
        if (rate_ == 0) revert NoReferenceRate(token);
        // Rate ages are days long; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > rateUpdatedAt[token] + MAX_RATE_AGE) revert RateStale(token);
    }

    /// @notice Units of tokenOut one unit of tokenIn is worth at the reference rates, with 18 decimals.
    function mid(address tokenIn, address tokenOut) external view returns (uint256) {
        if (tokenIn == tokenOut) return RATE_ONE;
        return referenceRate(tokenIn).mulDiv(RATE_ONE, referenceRate(tokenOut));
    }

    /// @notice The least amountIn of tokenIn may fetch in tokenOut in a swap: its value at the reference rates less
    ///         MAX_SLIPPAGE_BPS, rounded up.
    function minOutFor(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        if (tokenIn == tokenOut) return amountIn;
        return amountIn.mulDiv(referenceRate(tokenIn), referenceRate(tokenOut)).mulDivUp(BPS - MAX_SLIPPAGE_BPS, BPS);
    }

    /// @notice The most exactly amountOut of tokenOut may cost in tokenIn in a swap: its cost at the reference rates
    ///         plus MAX_SLIPPAGE_BPS, rounded down.
    function maxInFor(address tokenIn, address tokenOut, uint256 amountOut) public view returns (uint256) {
        if (tokenIn == tokenOut) return amountOut;
        return amountOut.mulDivUp(referenceRate(tokenOut), referenceRate(tokenIn)).mulDiv(BPS + MAX_SLIPPAGE_BPS, BPS);
    }

    /// @notice Whether the pair converts, directly or through the hub.
    function converts(address tokenIn, address tokenOut) public view returns (bool) {
        if (tokenIn == tokenOut || venues[tokenIn][tokenOut].exists) return true;
        return tokenIn != HUB && tokenOut != HUB && venues[tokenIn][HUB].exists && venues[HUB][tokenOut].exists;
    }

    /// @notice What exactly amountIn of tokenIn fetches in tokenOut: the venue's quote. Reverts RateDeviates while it
    ///         strays more than MAX_SLIPPAGE_BPS from the value at the reference rates.
    function quoteIn(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256 out) {
        if (tokenIn == tokenOut || amountIn == 0) return amountIn;
        out = _routeIn(tokenIn, tokenOut, amountIn);
        _agrees(tokenIn, tokenOut, out, amountIn.mulDiv(referenceRate(tokenIn), referenceRate(tokenOut)));
    }

    /// @notice What tokenIn exactly amountOut of tokenOut costs: the venue's quote. Reverts RateDeviates while it
    ///         strays more than MAX_SLIPPAGE_BPS from the cost at the reference rates.
    function quoteOut(address tokenIn, address tokenOut, uint256 amountOut) public view returns (uint256 cost) {
        if (tokenIn == tokenOut || amountOut == 0) return amountOut;
        cost = _routeOut(tokenIn, tokenOut, amountOut);
        _agrees(tokenIn, tokenOut, cost, amountOut.mulDivUp(referenceRate(tokenOut), referenceRate(tokenIn)));
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

    /// @notice What tokenIn exactly amountOut of tokenOut costs at the venue, checked against `anchor` (units of
    ///         tokenOut per unit of tokenIn, 18 decimals) rather than the reference rates: reverts RateBeyondAnchor
    ///         while it strays more than bandBps from the cost at the anchor, and BandTooWide past MAX_ANCHOR_BAND_BPS.
    ///         Neither the reference rates nor their age bear on it.
    function quoteOutAnchored(address tokenIn, address tokenOut, uint256 amountOut, uint256 anchor, uint256 bandBps)
        public
        view
        returns (uint256 cost)
    {
        _checkBand(bandBps);
        if (tokenIn == tokenOut || amountOut == 0) return amountOut;
        if (anchor == 0) revert InvalidAmount();
        cost = _routeOut(tokenIn, tokenOut, amountOut);
        uint256 fair = amountOut.mulDivUp(RATE_ONE, anchor);
        uint256 moved = cost > fair ? cost - fair : fair - cost;
        if (moved > 1 && moved * BPS > fair * bandBps) revert RateBeyondAnchor(tokenIn, tokenOut, cost, fair);
    }

    // Swaps.

    /// @notice Spends exactly amountIn of the caller's tokenIn for at least minOut of tokenOut, paid to recipient.
    ///         minOut zero takes `minOutFor`; a nonzero minOut below it is refused.
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out)
    {
        if (amountIn == 0) return 0;
        uint256 floor = minOutFor(tokenIn, tokenOut, amountIn);
        if (minOut == 0) minOut = floor;
        else if (minOut < floor) revert MinOutTooLow(minOut, floor);
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        out = _swapRoute(tokenIn, tokenOut, amountIn);
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
        uint256 ceiling = maxInFor(tokenIn, tokenOut, amountOut);
        if (maxIn > ceiling) maxIn = ceiling;
        spent = _routeOut(tokenIn, tokenOut, amountOut);
        if (spent > maxIn) revert Slippage(spent, maxIn);
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), spent);
        _swapOutRoute(tokenIn, tokenOut, amountOut, spent);
        SafeTransferLib.safeTransfer(tokenOut, recipient, amountOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, spent, amountOut, recipient);
    }

    /// @notice Spends exactly amountIn of a trusted program's tokenIn for tokenOut, paid to recipient, at the venue's
    ///         price: reverts RateBeyondAnchor when it fetches less than amountIn at `anchor` less bandBps, and
    ///         BandTooWide past MAX_ANCHOR_BAND_BPS.
    function swapExactInAnchored(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 anchor,
        uint256 bandBps,
        address recipient
    ) external returns (uint256 out) {
        if (!trusted[msg.sender]) revert Unauthorized();
        _checkBand(bandBps);
        if (amountIn == 0) return 0;
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        out = _swapRoute(tokenIn, tokenOut, amountIn);
        uint256 fair = amountIn.mulDiv(anchor, RATE_ONE);
        if (out < fair.mulDiv(BPS - bandBps, BPS)) revert RateBeyondAnchor(tokenIn, tokenOut, out, fair);
        SafeTransferLib.safeTransfer(tokenOut, recipient, out);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, out, recipient);
    }

    /// @notice Buys exactly amountOut of tokenOut for recipient with at most maxIn of a trusted program's tokenIn, at
    ///         the venue's price: reverts RateBeyondAnchor when it costs more than amountOut at `anchor` plus bandBps,
    ///         and BandTooWide past MAX_ANCHOR_BAND_BPS.
    function swapExactOutAnchored(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxIn,
        uint256 anchor,
        uint256 bandBps,
        address recipient
    ) external returns (uint256 spent) {
        if (!trusted[msg.sender]) revert Unauthorized();
        _checkBand(bandBps);
        if (amountOut == 0) return 0;
        uint256 fair = amountOut.mulDivUp(RATE_ONE, anchor);
        spent = _routeOut(tokenIn, tokenOut, amountOut);
        if (spent > fair.mulDiv(BPS + bandBps, BPS)) revert RateBeyondAnchor(tokenIn, tokenOut, spent, fair);
        if (spent > maxIn) revert Slippage(spent, maxIn);
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), spent);
        _swapOutRoute(tokenIn, tokenOut, amountOut, spent);
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

    /// @notice Pays recipient exactly amountOut of tokenOut from the float for amountIn of a trusted program's tokenIn:
    ///         a rate the program fixed from what a purchase paid, so a refund returns what it took whatever the
    ///         market does. Trust only programs whose code fixes it so.
    function convertAt(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient)
        external
    {
        if (!trusted[msg.sender]) revert Unauthorized();
        if (tokenIn == tokenOut) revert InvalidAmount();
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        uint256 float_ = IERC20Balance(tokenOut).balanceOf(address(this));
        if (float_ < amountOut) revert InsufficientFloat(amountOut, float_);
        SafeTransferLib.safeTransfer(tokenOut, recipient, amountOut);
        emit ConvertedAt(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    // Internals.

    /// @dev Reverts RateDeviates when quoted strays from fair by more than MAX_SLIPPAGE_BPS, past a unit of rounding.
    function _agrees(address tokenIn, address tokenOut, uint256 quoted, uint256 fair) private pure {
        uint256 moved = quoted > fair ? quoted - fair : fair - quoted;
        if (moved > 1 && moved * BPS > fair * MAX_SLIPPAGE_BPS) revert RateDeviates(tokenIn, tokenOut, quoted, fair);
    }

    /// @dev Reverts BandTooWide past MAX_ANCHOR_BAND_BPS, so no anchored price goes without a floor.
    function _checkBand(uint256 bandBps) private pure {
        if (bandBps > MAX_ANCHOR_BAND_BPS) revert BandTooWide(bandBps);
    }

    function _onlyOwner() private view {
        if (msg.sender != owner) revert Unauthorized();
    }

    function _venue(address tokenIn, address tokenOut) private view returns (Venue memory v) {
        v = venues[tokenIn][tokenOut];
        if (!v.exists) revert NoVenue(tokenIn, tokenOut);
    }

    function _routeIn(address tokenIn, address tokenOut, uint256 amountIn) private view returns (uint256) {
        if (venues[tokenIn][tokenOut].exists) return _quoteIn(tokenIn, tokenOut, amountIn);
        return _quoteIn(HUB, tokenOut, _quoteIn(tokenIn, HUB, amountIn));
    }

    function _routeOut(address tokenIn, address tokenOut, uint256 amountOut) private view returns (uint256) {
        if (venues[tokenIn][tokenOut].exists) return _quoteOut(tokenIn, tokenOut, amountOut);
        return _quoteOut(tokenIn, HUB, _quoteOut(HUB, tokenOut, amountOut));
    }

    /// @dev Swaps exactly amountIn this contract holds, directly or through the hub; returns what it got.
    function _swapRoute(address tokenIn, address tokenOut, uint256 amountIn) private returns (uint256) {
        if (tokenIn == tokenOut) return amountIn;
        if (venues[tokenIn][tokenOut].exists) return _swapIn(tokenIn, tokenOut, amountIn);
        return _swapIn(HUB, tokenOut, _swapIn(tokenIn, HUB, amountIn));
    }

    /// @dev Buys exactly amountOut with the `spent` this contract holds, directly or through the hub.
    function _swapOutRoute(address tokenIn, address tokenOut, uint256 amountOut, uint256 spent) private {
        if (tokenIn == tokenOut) return;
        if (venues[tokenIn][tokenOut].exists) {
            _swapOut(tokenIn, tokenOut, amountOut, spent);
            return;
        }
        uint256 hub = _quoteOut(HUB, tokenOut, amountOut);
        _swapOut(tokenIn, HUB, hub, spent);
        _swapOut(HUB, tokenOut, amountOut, hub);
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
