// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ManagedPropAMMEngine } from "../../../src/earn/engines/propamm/ManagedPropAMMEngine.sol";
import { IManagedPropAMMVenue } from "../../../src/interfaces/external/propamm/IManagedPropAMMVenue.sol";
import { PropAMMTestOracle, PropAMMTestToken } from "./PropAMMEngineMocks.sol";

/// @dev The pinned PoolFactory, which deploys the pool implementation and the Settler its pools start on.
interface IManagedPropAMMTestFactory {
    function implementation() external view returns (address);
    function defaultSettler() external view returns (address);
    function createPool(address owner, bytes32 salt) external returns (address pool);
    function isPool(address pool) external view returns (bool);
}

/// @dev The pinned Settler's views beside its swap.
interface IManagedPropAMMTestSettler {
    function factory() external view returns (address);
    function implementation() external view returns (address);
}

/// @dev A six-decimal test token with the memo pull the Settler moves a swap's input with.
contract ManagedPropAMMTestToken is PropAMMTestToken {
    constructor(string memory label) PropAMMTestToken(label) { }

    function transferFromWithMemo(address from, address to, uint256 amount, bytes32) external returns (bool) {
        return transferFrom(from, to, amount);
    }
}

/// @dev Independent behavioral fixture of a managed pool, not a reproduction of its implementation. It keeps
/// the semantics an engine depends on: many pairs by index, a pair's access mode, the home list and sponsor
/// lists, the deny list, the pool-wide pause, the pool's refusal errors and their order, quotes that check no
/// access, and settler-only fills over input the settler already paid in, which pay the taker. Tokens have six
/// decimals and the oracle eight.
/// A test installs this code at the pinned PoolFactory's implementation address before creating the pool, so
/// the pool is a clone that factory created and the pinned Settler accepts it and fills it.
contract ManagedPropAMMTestVenue {
    /// @dev The pool's `TakerAccess`, with its ordinals.
    enum TakerAccess {
        None,
        Allowed,
        UnknownPair,
        Closed,
        Denied,
        UnknownSponsor,
        SponsorDisabled,
        SponsorNotAdmitted,
        NotListed
    }

    struct PairState {
        PropAMMTestToken base;
        PropAMMTestToken quote;
        PropAMMTestOracle oracle;
        IManagedPropAMMVenue.AccessMode access;
        address hook;
    }

    error Paused();
    error NotSettler();
    error UnknownPair(uint16 pairIndex);
    error TakerNotAllowed(address taker);
    error TakerDenied(address taker);
    error UnknownSponsor(uint64 sponsorId);
    error SponsorDisabled(uint64 sponsorId);
    error SponsorNotAdmitted(uint16 pairIndex, uint64 sponsorId);

    uint256 private constant PRICE_SCALE = 1e8;

    /// @dev The factory that initialized this clone; zero for a pool deployed on its own.
    address public factory;
    address public settler;
    bool public paused;
    uint16 public pairCount;
    mapping(uint16 pairIndex => PairState) private _pairs;
    mapping(bytes32 routeKey => uint256) public roundingCredit;
    mapping(address account => bool) public denied;
    mapping(uint64 sponsorId => bool) public sponsorRegistered;
    mapping(uint64 sponsorId => bool) public sponsorEnabled;
    mapping(uint16 pairIndex => mapping(uint64 sponsorId => bool)) public pairSponsor;
    mapping(uint16 pairIndex => mapping(uint64 sponsorId => mapping(address account => bool))) public isMember;

    /// @dev Adversarial switches: pay a swap's output to another account, and reenter a vault mid-swap.
    address public payee;
    address public reentryVault;
    bool public reentrySucceeded;
    bool public readSucceeded;
    bool public callbackAttempted;
    /// @dev The last swap's pair and sponsor, as the pool saw them.
    uint16 public lastPairIndex;
    uint64 public lastSponsorId;

    /// @dev The factory initializes each clone it creates with the pool's owner and its default Settler.
    function initialize(address, address settler_) external {
        require(factory == address(0), "initialized");
        factory = msg.sender;
        settler = settler_;
    }

    /// @dev The pool's owner can replace the settler; fills from the previous one then revert.
    function setSettler(address settler_) external {
        settler = settler_;
    }

    function addPair(PropAMMTestToken base, PropAMMTestToken quote, PropAMMTestOracle oracle)
        external
        returns (uint16 pairIndex)
    {
        pairIndex = pairCount++;
        _pairs[pairIndex] = PairState(base, quote, oracle, IManagedPropAMMVenue.AccessMode.Closed, address(0));
    }

    /// @dev A removed pair reads all zero and its index is never reused.
    function removePair(uint16 pairIndex) external {
        _live(pairIndex);
        delete _pairs[pairIndex];
    }

    function setPairAccess(uint16 pairIndex, IManagedPropAMMVenue.AccessMode mode) external {
        _live(pairIndex);
        require(mode != IManagedPropAMMVenue.AccessMode.None, "mode");
        _pairs[pairIndex].access = mode;
    }

    function setPairHook(uint16 pairIndex, address hook) external {
        _live(pairIndex);
        _pairs[pairIndex].hook = hook;
    }

    function replaceOracle(uint16 pairIndex, PropAMMTestOracle oracle) external {
        _live(pairIndex);
        _pairs[pairIndex].oracle = oracle;
    }

    function setMember(uint16 pairIndex, uint64 sponsorId, address account, bool allowed) external {
        isMember[pairIndex][sponsorId][account] = allowed;
    }

    function addSponsor(uint64 sponsorId) external {
        require(sponsorId != 0, "home");
        sponsorRegistered[sponsorId] = true;
        sponsorEnabled[sponsorId] = true;
    }

    function setSponsorEnabled(uint64 sponsorId, bool enabled) external {
        sponsorEnabled[sponsorId] = enabled;
    }

    function setPairSponsor(uint16 pairIndex, uint64 sponsorId, bool admitted) external {
        pairSponsor[pairIndex][sponsorId] = admitted;
    }

    function setDenied(address account, bool deny) external {
        denied[account] = deny;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setPayee(address account) external {
        payee = account;
    }

    function setCallback(address vault) external {
        reentryVault = vault;
    }

    function pair(uint16 pairIndex) external view returns (IManagedPropAMMVenue.Pair memory info) {
        PairState storage state = _pairs[pairIndex];
        if (address(state.base) == address(0)) return info;
        info = IManagedPropAMMVenue.Pair({
            base: address(state.base),
            quote: address(state.quote),
            oracle: address(state.oracle),
            baseDecimals: 6,
            quoteDecimals: 6,
            oracleDecimals: 8,
            priceScale: PRICE_SCALE,
            maxOracleAge: 1 days,
            maxPriceDeviationBps: 0,
            access: state.access
        });
    }

    function pairHook(uint16 pairIndex) external view returns (address hook, uint8 flags) {
        hook = _live(pairIndex).hook;
        flags = hook == address(0) ? 0 : 1;
    }

    function roundingRouteKey(uint16 pairIndex, address taker, bytes32 customer) public pure returns (bytes32) {
        return keccak256(abi.encode(pairIndex, taker, customer));
    }

    function takerAllowed(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (bool) {
        return takerAccess(pairIndex, taker, sponsorId) == TakerAccess.Allowed;
    }

    /// @dev The pool's access check, in its order.
    function takerAccess(uint16 pairIndex, address taker, uint64 sponsorId) public view returns (TakerAccess) {
        IManagedPropAMMVenue.AccessMode mode = _pairs[pairIndex].access;
        if (mode == IManagedPropAMMVenue.AccessMode.None) return TakerAccess.UnknownPair;
        if (mode == IManagedPropAMMVenue.AccessMode.Closed) return TakerAccess.Closed;
        if (denied[taker]) return TakerAccess.Denied;
        if (mode == IManagedPropAMMVenue.AccessMode.Open) return TakerAccess.Allowed;
        if (sponsorId != 0) {
            if (!sponsorRegistered[sponsorId]) return TakerAccess.UnknownSponsor;
            if (!sponsorEnabled[sponsorId]) return TakerAccess.SponsorDisabled;
            if (!pairSponsor[pairIndex][sponsorId]) return TakerAccess.SponsorNotAdmitted;
        }
        return isMember[pairIndex][sponsorId][taker] ? TakerAccess.Allowed : TakerAccess.NotListed;
    }

    /// @dev Quotes check no access or pause, as the pool's do.
    function quoteExactInputFor(uint16 pairIndex, address taker, bytes32 customer, bool sell, uint256 amount)
        external
        view
        returns (uint256 out, uint256 p, uint256 t, uint256 afterCredit)
    {
        (p, t) = _live(pairIndex).oracle.latestPrice();
        uint256 value = amount * (sell ? p : PRICE_SCALE) + roundingCredit[roundingRouteKey(pairIndex, taker, customer)];
        uint256 divisor = sell ? PRICE_SCALE : p;
        out = value / divisor;
        afterCredit = value - out * divisor;
    }

    function quoteExactOutputFor(uint16 pairIndex, address taker, bytes32 customer, bool sell, uint256 amount)
        external
        view
        returns (uint256 input, uint256 p, uint256 t, uint256 afterCredit)
    {
        require(sell);
        (p, t) = _live(pairIndex).oracle.latestPrice();
        uint256 credit = roundingCredit[roundingRouteKey(pairIndex, taker, customer)];
        uint256 cost = amount * PRICE_SCALE;
        input = credit >= cost ? 0 : (cost - credit + p - 1) / p;
        afterCredit = credit + input * p - cost;
    }

    /// @dev Settler-only execution over input the settler already moved into the pool. `taker` is the settler's
    /// caller: its access, its rounding route and its payout.
    function fill(IManagedPropAMMVenue.SwapParams calldata params, address taker) external returns (uint256) {
        if (msg.sender != settler) revert NotSettler();
        PairState storage state = _admit(params.pairIndex, taker, params.sponsorId, params.deadline);
        require(params.customerId != bytes32(0) && params.amount != 0, "bad route");
        require(params.oraclePriceToleranceBps == 0, "bad route");
        uint256 p = _boundPrice(state, params.expectedOraclePrice, params.minimumOracleUpdatedAt);
        bytes32 key = roundingRouteKey(params.pairIndex, taker, params.customerId);
        bool sell = params.baseToQuote;
        if (!params.exactInput) {
            require(sell, "bad route");
            uint256 cost = params.amount * PRICE_SCALE;
            uint256 credit = roundingCredit[key];
            uint256 input = credit >= cost ? 0 : (cost - credit + p - 1) / p;
            roundingCredit[key] = credit + input * p - cost;
            require(input <= params.limit, "limit");
            state.quote.transfer(_payee(taker), params.amount);
            return input;
        }
        uint256 value = params.amount * (sell ? p : PRICE_SCALE) + roundingCredit[key];
        uint256 divisor = sell ? PRICE_SCALE : p;
        uint256 out = value / divisor;
        roundingCredit[key] = value - out * divisor;
        require(out >= params.limit && out > 0, "limit");
        if (reentryVault != address(0)) {
            callbackAttempted = true;
            (reentrySucceeded,) =
                reentryVault.call(abi.encodeWithSignature("redeem(uint256,address,uint256)", 1e12, taker, 0));
            (readSucceeded,) = taker.staticcall(abi.encodeWithSignature("totalAssets()"));
        }
        (sell ? state.quote : state.base).transfer(_payee(taker), out);
        return out;
    }

    /// @dev The pool's order: the pause, the deadline, then access, each refusal with the pool's error.
    function _admit(uint16 pairIndex, address taker, uint64 sponsorId, uint256 deadline)
        private
        returns (PairState storage state)
    {
        if (paused) revert Paused();
        require(block.timestamp <= deadline, "deadline");
        TakerAccess outcome = takerAccess(pairIndex, taker, sponsorId);
        if (outcome == TakerAccess.UnknownPair) revert UnknownPair(pairIndex);
        if (outcome == TakerAccess.Denied) revert TakerDenied(taker);
        if (outcome == TakerAccess.UnknownSponsor) revert UnknownSponsor(sponsorId);
        if (outcome == TakerAccess.SponsorDisabled) revert SponsorDisabled(sponsorId);
        if (outcome == TakerAccess.SponsorNotAdmitted) revert SponsorNotAdmitted(pairIndex, sponsorId);
        if (outcome != TakerAccess.Allowed) revert TakerNotAllowed(taker);
        lastPairIndex = pairIndex;
        lastSponsorId = sponsorId;
        state = _pairs[pairIndex];
    }

    function _boundPrice(PairState storage state, uint256 price, uint256 timestamp) private view returns (uint256 p) {
        uint256 t;
        (p, t) = state.oracle.latestPrice();
        require(price == p && timestamp == t, "quote mismatch");
        require(block.timestamp - t <= 1 days, "stale");
    }

    function _payee(address taker) private view returns (address) {
        return payee == address(0) ? taker : payee;
    }

    function _live(uint16 pairIndex) private view returns (PairState storage state) {
        state = _pairs[pairIndex];
        if (address(state.base) == address(0)) revert UnknownPair(pairIndex);
    }
}

/// @dev A settler that moves the input and fills as the pinned Settler does but checks no balance, so a test
/// that installs it at the Settler's address reaches the engine's own measured-balance checks.
contract ManagedPropAMMUncheckedSettler {
    function swap(address pool, IManagedPropAMMVenue.SwapParams calldata params) external returns (uint256) {
        IManagedPropAMMVenue.Pair memory traded = IManagedPropAMMVenue(pool).pair(params.pairIndex);
        uint256 amountIn = params.amount;
        if (!params.exactInput) {
            (amountIn,,,) = IManagedPropAMMVenue(pool)
                .quoteExactOutputFor(params.pairIndex, msg.sender, params.customerId, params.baseToQuote, params.amount);
        }
        PropAMMTestToken(params.baseToQuote ? traded.base : traded.quote).transferFrom(msg.sender, pool, amountIn);
        return ManagedPropAMMTestVenue(pool).fill(params, msg.sender);
    }
}

contract ManagedPropAMMTestEarnVault {
    ManagedPropAMMEngine public engine;
    PropAMMTestToken public asset;

    constructor(ManagedPropAMMEngine e, PropAMMTestToken a) {
        engine = e;
        asset = a;
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), amount);
        asset.approve(address(engine), amount);
        shares = engine.deposit(amount);
        asset.approve(address(engine), 0);
    }

    /// @dev A held deposit: the assets go straight to the engine, which then deposits what it holds.
    function depositHeld(uint256 amount) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(engine), amount);
        shares = engine.depositHeld(amount);
    }

    function redeem(uint256 shares, address receiver, uint256 minimum) external returns (uint256) {
        return engine.redeem(shares, receiver, minimum);
    }

    function withdraw(uint256 amount, address receiver) external returns (uint256) {
        return engine.withdraw(amount, receiver);
    }
}
