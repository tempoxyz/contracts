// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { PropAMMEngine } from "../../src/engines/propamm/PropAMMEngine.sol";
import { CoreMockToken } from "./EarnVaultMocks.sol";

contract PropAMMTestToken is ERC20 {
    bool public chargeFee;

    constructor(string memory label) ERC20(label, label) { }

    function setChargeFee(bool value) external {
        chargeFee = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (chargeFee && from != address(0) && to != address(0) && value > 0) {
            super._update(from, address(0), 1);
            super._update(from, to, value - 1);
        } else {
            super._update(from, to, value);
        }
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PropAMMTestOracle {
    uint256 public price = 105_000_000;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (price, updatedAt);
    }

    function set(uint256 p, uint256 t) external {
        price = p;
        updatedAt = t;
    }
}

/// @dev A TIP-20-style token with the memo transfers PropAMM pools use; it can reject one receiver.
contract MemoMockToken is CoreMockToken {
    address public blockedReceiver;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        CoreMockToken(name_, symbol_, decimals_)
    { }

    function blockReceiver(address receiver) external {
        blockedReceiver = receiver;
    }

    function transferWithMemo(address to, uint256 amount, bytes32) external {
        require(to != blockedReceiver, "BLOCKED");
        _transfer(msg.sender, to, amount);
    }

    function transferFromWithMemo(address from, address to, uint256 amount, bytes32) external returns (bool) {
        require(to != blockedReceiver, "BLOCKED");
        return transferFrom(from, to, amount);
    }
}

/// @dev PropAMM recipient registry that can redirect a recipient's output.
contract MockRecipientRegistry {
    mapping(address recipient => address resolved) public redirect;

    function setRedirect(address recipient, address resolved) external {
        redirect[recipient] = resolved;
    }

    function resolveRecipient(address recipient) external view returns (address) {
        address resolved = redirect[recipient];
        return resolved == address(0) ? recipient : resolved;
    }
}

/// @dev Independent behavioral fixture, not a reproduction of the PropAMM implementation.

contract PropAMMTestVenue {
    PropAMMTestToken public baseToken;
    PropAMMTestToken public quoteToken;
    PropAMMTestOracle public oracle;
    bool public paused;
    mapping(bytes32 => uint256) public roundingCredit;

    function roundingRouteKey(address taker, address recipient, bytes32 customer) public pure returns (bytes32) {
        return keccak256(abi.encode(taker, recipient, customer));
    }

    bool public allowed = true;
    bool public redirect;

    function setRedirect(bool value) external {
        redirect = value;
    }

    address public reentryVault;
    bool public reentrySucceeded;
    bool public readSucceeded;
    bool public callbackAttempted;

    function setCallback(address v) external {
        reentryVault = v;
    }

    constructor(PropAMMTestToken b, PropAMMTestToken q, PropAMMTestOracle o) {
        baseToken = b;
        quoteToken = q;
        oracle = o;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function replaceOracle(PropAMMTestOracle o) external {
        oracle = o;
    }

    function takerAllowed(address) external view returns (bool) {
        return allowed;
    }

    function recipientAllowed(address) external view returns (bool) {
        return allowed;
    }

    function resolveRecipient(address a) external view returns (address) {
        return redirect ? address(0xbad) : a;
    }

    function quoteExactInputFor(address taker, address recipient, bytes32 customer, bool sell, uint256 amount)
        external
        view
        returns (uint256 out, uint256 p, uint256 t, uint256 afterCredit)
    {
        (p, t) = oracle.latestPrice();
        uint256 value = amount * (sell ? p : 1e8) + roundingCredit[roundingRouteKey(taker, recipient, customer)];
        uint256 divisor = sell ? 1e8 : p;
        out = value / divisor;
        afterCredit = value - out * divisor;
    }

    function quoteExactOutputFor(address taker, address recipient, bytes32 customer, bool sell, uint256 amount)
        external
        view
        returns (uint256 input, uint256 p, uint256 t, uint256 afterCredit)
    {
        require(sell);
        (p, t) = oracle.latestPrice();
        uint256 credit = roundingCredit[roundingRouteKey(taker, recipient, customer)];
        uint256 cost = amount * 1e8;
        input = credit >= cost ? 0 : (cost - credit + p - 1) / p;
        afterCredit = credit + input * p - cost;
    }

    function _buyCredit(uint256 amount, uint256 p, address recipient, bytes32 customer) private returns (uint256 out) {
        bytes32 key = roundingRouteKey(msg.sender, recipient, customer);
        uint256 value = amount * 1e8 + roundingCredit[key];
        out = value / p;
        roundingCredit[key] = value - out * p;
    }

    function _sellCredit(uint256 amount, uint256 p, address recipient, bytes32 customer)
        private
        returns (uint256 input)
    {
        bytes32 key = roundingRouteKey(msg.sender, recipient, customer);
        uint256 cost = amount * 1e8;
        uint256 credit = roundingCredit[key];
        input = credit >= cost ? 0 : (cost - credit + p - 1) / p;
        roundingCredit[key] = credit + input * p - cost;
    }

    function swapExactInput(
        bool sell,
        uint256 amount,
        uint256 minOut,
        address recipient,
        bytes32 customer,
        bytes32,
        uint256 deadline,
        uint256 price,
        uint256 tolerance,
        uint256 timestamp
    ) external returns (uint256 out) {
        require(!paused && allowed, "unavailable");
        require(deadline == block.timestamp && tolerance == 0, "bad route");
        (uint256 p, uint256 t) = oracle.latestPrice();
        require(price == p && timestamp == t, "quote mismatch");
        require(block.timestamp - t <= 1 days, "stale");
        if (sell) {
            bytes32 key = roundingRouteKey(msg.sender, recipient, customer);
            uint256 value = amount * p + roundingCredit[key];
            out = value / 1e8;
            roundingCredit[key] = value % 1e8;
        } else {
            out = _buyCredit(amount, p, recipient, customer);
        }
        require(out >= minOut && out > 0, "limit");
        (sell ? baseToken : quoteToken).transferFrom(msg.sender, address(this), amount);
        if (reentryVault != address(0)) {
            callbackAttempted = true;
            (reentrySucceeded,) =
                reentryVault.call(abi.encodeWithSignature("redeem(uint256,address,uint256)", 1e12, recipient, 0));
            (readSucceeded,) = msg.sender.staticcall(abi.encodeWithSignature("totalAssets()"));
        }
        (sell ? quoteToken : baseToken).transfer(recipient, out);
    }

    function swapExactOutput(
        bool sell,
        uint256 amount,
        uint256 maxIn,
        address recipient,
        bytes32 customer,
        bytes32,
        uint256 deadline,
        uint256 price,
        uint256 tolerance,
        uint256 timestamp
    ) external returns (uint256 input) {
        require(!paused && allowed, "unavailable");
        require(sell && deadline == block.timestamp && tolerance == 0, "bad route");
        (uint256 p, uint256 t) = oracle.latestPrice();
        require(price == p && timestamp == t, "quote mismatch");
        require(block.timestamp - t <= 1 days, "stale");
        input = _sellCredit(amount, p, recipient, customer);
        require(input <= maxIn, "limit");
        baseToken.transferFrom(msg.sender, address(this), input);
        quoteToken.transfer(recipient, amount);
    }
}

contract PropAMMTestEarnVault {
    PropAMMEngine public engine;
    PropAMMTestToken public asset;

    constructor(PropAMMEngine e, PropAMMTestToken a) {
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
