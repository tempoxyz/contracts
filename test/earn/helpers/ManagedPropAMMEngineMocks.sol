// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ManagedPropAMMEngine } from "../../../src/earn/engines/propamm/ManagedPropAMMEngine.sol";
import { IManagedPropAMMVenue } from "../../../src/interfaces/external/propamm/IManagedPropAMMVenue.sol";
import { PropAMMTestOracle, PropAMMTestToken } from "./PropAMMEngineMocks.sol";

/// @dev Independent behavioral fixture of a managed pool, not a reproduction of its implementation. It keeps
/// the semantics an engine depends on: many pairs by index, a pair's access mode, the home list and sponsor
/// lists, the deny list, the pool-wide pause, the pool's refusal errors and their order, quotes that check no
/// access, and swaps that pull from and pay the caller. Tokens have six decimals and the oracle eight.
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
    error UnknownPair(uint16 pairIndex);
    error TakerNotAllowed(address taker);
    error TakerDenied(address taker);
    error UnknownSponsor(uint64 sponsorId);
    error SponsorDisabled(uint64 sponsorId);
    error SponsorNotAdmitted(uint16 pairIndex, uint64 sponsorId);

    uint256 private constant PRICE_SCALE = 1e8;

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

    function swapExactInput(
        uint16 pairIndex,
        bool sell,
        uint256 amount,
        uint256 minOut,
        uint64 sponsorId,
        bytes32 customer,
        bytes32,
        uint256 deadline,
        uint256 price,
        uint256 tolerance,
        uint256 timestamp
    ) external returns (uint256 out) {
        PairState storage state = _admit(pairIndex, sponsorId, deadline);
        require(customer != bytes32(0) && amount != 0 && tolerance == 0, "bad route");
        uint256 p = _boundPrice(state, price, timestamp);
        bytes32 key = roundingRouteKey(pairIndex, msg.sender, customer);
        uint256 value = amount * (sell ? p : PRICE_SCALE) + roundingCredit[key];
        uint256 divisor = sell ? PRICE_SCALE : p;
        out = value / divisor;
        roundingCredit[key] = value - out * divisor;
        require(out >= minOut && out > 0, "limit");
        (sell ? state.base : state.quote).transferFrom(msg.sender, address(this), amount);
        if (reentryVault != address(0)) {
            callbackAttempted = true;
            (reentrySucceeded,) =
                reentryVault.call(abi.encodeWithSignature("redeem(uint256,address,uint256)", 1e12, msg.sender, 0));
            (readSucceeded,) = msg.sender.staticcall(abi.encodeWithSignature("totalAssets()"));
        }
        (sell ? state.quote : state.base).transfer(_payee(), out);
    }

    function swapExactOutput(
        uint16 pairIndex,
        bool sell,
        uint256 amount,
        uint256 maxIn,
        uint64 sponsorId,
        bytes32 customer,
        bytes32,
        uint256 deadline,
        uint256 price,
        uint256 tolerance,
        uint256 timestamp
    ) external returns (uint256 input) {
        PairState storage state = _admit(pairIndex, sponsorId, deadline);
        require(sell && customer != bytes32(0) && amount != 0 && tolerance == 0, "bad route");
        uint256 p = _boundPrice(state, price, timestamp);
        bytes32 key = roundingRouteKey(pairIndex, msg.sender, customer);
        uint256 cost = amount * PRICE_SCALE;
        uint256 credit = roundingCredit[key];
        input = credit >= cost ? 0 : (cost - credit + p - 1) / p;
        roundingCredit[key] = credit + input * p - cost;
        require(input <= maxIn, "limit");
        state.base.transferFrom(msg.sender, address(this), input);
        state.quote.transfer(_payee(), amount);
    }

    /// @dev The pool's order: the pause, the deadline, then access, each refusal with the pool's error.
    function _admit(uint16 pairIndex, uint64 sponsorId, uint256 deadline) private returns (PairState storage state) {
        if (paused) revert Paused();
        require(block.timestamp <= deadline, "deadline");
        TakerAccess outcome = takerAccess(pairIndex, msg.sender, sponsorId);
        if (outcome == TakerAccess.UnknownPair) revert UnknownPair(pairIndex);
        if (outcome == TakerAccess.Denied) revert TakerDenied(msg.sender);
        if (outcome == TakerAccess.UnknownSponsor) revert UnknownSponsor(sponsorId);
        if (outcome == TakerAccess.SponsorDisabled) revert SponsorDisabled(sponsorId);
        if (outcome == TakerAccess.SponsorNotAdmitted) revert SponsorNotAdmitted(pairIndex, sponsorId);
        if (outcome != TakerAccess.Allowed) revert TakerNotAllowed(msg.sender);
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

    function _payee() private view returns (address) {
        return payee == address(0) ? msg.sender : payee;
    }

    function _live(uint16 pairIndex) private view returns (PairState storage state) {
        state = _pairs[pairIndex];
        if (address(state.base) == address(0)) revert UnknownPair(pairIndex);
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

    function redeem(uint256 shares, address receiver, uint256 minimum) external returns (uint256) {
        return engine.redeem(shares, receiver, minimum);
    }

    function withdraw(uint256 amount, address receiver) external returns (uint256) {
        return engine.withdraw(amount, receiver);
    }
}
