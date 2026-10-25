// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { SpenderBase } from "bridge-spender/src/spenders/SpenderBase.sol";
import { ERC20 } from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";

import { Spend } from "../../src/SpenderTempoSpend.sol";
import { ITempoEarnVault } from "../../src/interfaces/ITempoEarnVault.sol";

/// @notice Plain ERC-20 anyone can mint.
contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Burns 1% of every transfer, so a recipient gets less than was sent.
contract FeeOnTransferToken is MockToken {
    constructor() MockToken("Fee USD", "FUSD") { }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fee = from == address(0) || to == address(0) ? 0 : value / 100;
        super._update(from, to, value - fee);
        if (fee != 0) super._update(from, address(0), fee);
    }
}

/// @notice Makes one call from inside `transferFrom` and keeps what it reverted with.
contract ReentrantToken is MockToken {
    address public target;
    bytes public reentry;
    bytes public reentryError;
    bool public reentered;

    constructor() MockToken("Reentrant USD", "RUSD") { }

    function arm(address target_, bytes calldata reentry_) external {
        target = target_;
        reentry = reentry_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (target != address(0) && !reentered) {
            reentered = true;
            (bool ok, bytes memory err) = target.call(reentry);
            require(!ok, "reentry succeeded");
            reentryError = err;
        }
        return super.transferFrom(from, to, value);
    }
}

/// @notice An Earn vault that quotes a withdrawal at two shares per asset but burns `burnBps` of
///         the quote, as a vault whose price moves in the payer's favor between quote and burn.
contract PartialBurnEarnVault is ITempoEarnVault {
    address public immutable override asset;
    MockToken public immutable SHARE;
    uint256 public immutable BURN_BPS;

    constructor(address asset_, uint256 burnBps) {
        asset = asset_;
        SHARE = new MockToken("Partial EarnShare", "pES");
        BURN_BPS = burnBps;
    }

    function earnShare() external view override returns (address) {
        return address(SHARE);
    }

    function previewWithdraw(uint256 assets) public pure override returns (uint256) {
        return assets * 2;
    }

    function previewRedeem(uint256 earnShares) external pure override returns (uint256) {
        return earnShares / 2;
    }

    function deposit(uint256, address, uint256) external pure override returns (uint256) {
        revert("deposit unsupported");
    }

    function withdrawExact(uint256 assets, address receiver, uint256 maxEarnShares)
        external
        override
        returns (uint256 burned)
    {
        burned = previewWithdraw(assets) * BURN_BPS / 10_000;
        require(burned <= maxEarnShares, "max shares");
        SHARE.transferFrom(msg.sender, address(0xdead), burned);
        IERC20(asset).transfer(receiver, assets);
    }
}

/// @notice Fronts a real Tempo Earn vault but quotes 10% more shares than it burns, as an engine
///         whose preview overestimates would. The shares it does not burn stay with the payer.
contract OverQuotingEarnVault is ITempoEarnVault {
    ITempoEarnVault internal immutable VAULT;

    constructor(ITempoEarnVault vault) {
        VAULT = vault;
    }

    function asset() external view override returns (address) {
        return VAULT.asset();
    }

    function earnShare() external view override returns (address) {
        return VAULT.earnShare();
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return VAULT.previewWithdraw(assets) * 11 / 10;
    }

    function previewRedeem(uint256 earnShares) external view override returns (uint256) {
        return VAULT.previewRedeem(earnShares);
    }

    function deposit(uint256, address, uint256) external pure override returns (uint256) {
        revert("deposit unsupported");
    }

    function withdrawExact(uint256 assets, address receiver, uint256)
        external
        override
        returns (uint256 burned)
    {
        uint256 needed = VAULT.previewWithdraw(assets);
        IERC20 share = IERC20(VAULT.earnShare());
        share.transferFrom(msg.sender, address(this), needed);
        share.approve(address(VAULT), needed);
        burned = VAULT.withdrawExact(assets, receiver, needed);
        share.approve(address(VAULT), 0);
    }
}

/// @notice A handler that accepts every public call and moves nothing.
contract NoopSpendHandler is SpenderBase {
    constructor(IFactory factory_) SpenderBase(factory_) { }

    function transferToDestination(address, bytes calldata) external pure override { }

    function transferToDestinationStrict(address, bytes calldata) external pure override { }

    function availableBalance(bytes calldata) external pure override returns (uint256) {
        return 0;
    }

    function publicCall(bytes calldata) external pure override { }
}

/// @notice A replacement handler that takes a spend's amount from the payer and pays `thief`.
contract DivertingSpendHandler is SpenderBase {
    address internal immutable THIEF;

    constructor(IFactory factory_, address thief) SpenderBase(factory_) {
        THIEF = thief;
    }

    function transferToDestination(address, bytes calldata) external pure override { }

    function transferToDestinationStrict(address, bytes calldata) external pure override { }

    function availableBalance(bytes calldata) external pure override returns (uint256) {
        return 0;
    }

    function publicCall(bytes calldata data) external override {
        Spend memory spend = abi.decode(data[2:], (Spend));
        IERC20(spend.token).transferFrom(msg.sender, THIEF, spend.amount);
    }
}

/// @notice A replacement handler that pays the destination from the clone's own balance and hands
///         the payer one unit more than it was given.
contract OverReturningSpendHandler is SpenderBase {
    constructor(IFactory factory_) SpenderBase(factory_) { }

    function transferToDestination(address, bytes calldata) external pure override { }

    function transferToDestinationStrict(address, bytes calldata) external pure override { }

    function availableBalance(bytes calldata) external pure override returns (uint256) {
        return 0;
    }

    function publicCall(bytes calldata data) external override {
        Spend memory spend = abi.decode(data[2:], (Spend));
        IERC20(spend.token).transfer(spend.destination, spend.amount);
        IERC20(spend.token).transfer(msg.sender, 1);
    }
}

/// @notice Answers a receiver's identity getters with different code, as an older build would.
contract OlderZoneSpendReceiver {
    address public immutable FACTORY;
    bytes32 public immutable SPENDER_ID;
    uint32 public immutable ZONE_ID;

    constructor(address factory_, bytes32 spenderId_, uint32 zoneId_) {
        FACTORY = factory_;
        SPENDER_ID = spenderId_;
        ZONE_ID = zoneId_;
    }
}
