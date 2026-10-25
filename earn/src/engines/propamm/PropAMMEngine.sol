// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPropAMMVenue, IPropAMMPriceOracle } from "../../interfaces/external/propamm/IPropAMMVenue.sol";

import { IEarnEngine } from "../../interfaces/engines/IEarnEngine.sol";
import { IEarnEngineExactWithdraw } from "../../interfaces/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineRedeem } from "../../interfaces/engines/IEarnEngineRedeem.sol";
import { IEarnEngineFeeValuation } from "../../interfaces/engines/IEarnEngineFeeValuation.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IEarnVault } from "../../interfaces/core/IEarnVault.sol";

/// @notice Single-position PropAMM engine denominated in its immutable quote asset.
/// @dev Pool and oracle are immutable. Only the bound EarnVault can move collateral.
contract PropAMMEngine is
    IEarnEngine,
    IEarnEngineExactWithdraw,
    IEarnEngineRedeem,
    IEarnEngineFeeValuation,
    Ownable2Step,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error NotEarnVault();
    error AlreadyBound();
    error InvalidAmount();
    error InvalidReceiver();
    error InvalidOracle();
    error InexactTransfer();
    error InsufficientBacking();
    error QuoteMismatch();
    error ReadDuringSettlement();

    event EarnVaultInitialized(address indexed earnVault);
    event Deposited(address indexed earnVault, uint256 assets, uint256 engineShares);
    event Redeemed(address indexed receiver, uint256 engineShares, uint256 assets);
    event WithdrewExact(address indexed receiver, uint256 assets, uint256 engineSharesBurned);

    address public immutable asset;
    address public immutable baseToken;
    IPropAMMVenue public immutable pool;
    IPropAMMPriceOracle public immutable priceOracle;
    uint256 public immutable maxOracleAge;
    uint256 public immutable priceScale;
    bytes32 public immutable customerId;
    uint256 public immutable shareScale;
    uint8 public immutable oracleDecimals;
    string public constant name = "PropAMM Engine";
    string public constant symbol = "propAMM-engine";
    address public earnVault;
    uint256 private tradeNonce;

    modifier onlyEarnVault() {
        if (msg.sender != earnVault || earnVault == address(0)) revert NotEarnVault();
        _;
    }

    constructor(address pool_, address owner_, uint256 maxAge_, bytes32 route_) Ownable(owner_) {
        if (pool_.code.length == 0 || maxAge_ == 0 || route_ == bytes32(0)) revert InvalidConfiguration();
        IPropAMMVenue venue = IPropAMMVenue(pool_);
        address base = venue.baseToken();
        address quote = venue.quoteToken();
        if (base.code.length == 0 || quote.code.length == 0 || base == quote) revert InvalidConfiguration();
        IPropAMMPriceOracle source = IPropAMMPriceOracle(venue.oracle());
        if (address(source).code.length == 0) revert InvalidConfiguration();
        uint8 baseDecimals = IERC20Metadata(base).decimals();
        uint8 quoteDecimals = IERC20Metadata(quote).decimals();
        uint8 precision = source.decimals();
        uint16 exponent = uint16(baseDecimals) + uint16(precision);
        if (baseDecimals > 77 || exponent < quoteDecimals || exponent - quoteDecimals > 77) {
            revert InvalidConfiguration();
        }
        asset = quote;
        baseToken = base;
        pool = venue;
        priceOracle = source;
        oracleDecimals = precision;
        maxOracleAge = maxAge_;
        shareScale = 10 ** uint256(baseDecimals);
        priceScale = 10 ** (exponent - quoteDecimals);
        customerId = route_;
    }

    function initializeEarnVault(address vault_) external onlyOwner {
        _bind(vault_);
    }

    function initializeEarnVault(address vault_, address finalOwner_) external onlyOwner {
        if (finalOwner_ == address(0)) revert InvalidConfiguration();
        _bind(vault_);
        _transferOwnership(finalOwner_);
    }

    function _bind(address vault_) private {
        if (earnVault != address(0)) revert AlreadyBound();
        if (vault_.code.length == 0 || IEarnVault(vault_).asset() != asset) revert InvalidConfiguration();
        earnVault = vault_;
        emit EarnVaultInitialized(vault_);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IEarnEngine).interfaceId
            || id == type(IEarnEngineExactWithdraw).interfaceId || id == type(IEarnEngineRedeem).interfaceId
            || id == type(IEarnEngineFeeValuation).interfaceId;
    }

    function totalShares() public view returns (uint256) {
        return IERC20(baseToken).balanceOf(address(this));
    }

    function totalAssets() public view returns (uint256) {
        return valueOf(totalShares());
    }

    function valueOf(uint256 shares) public view returns (uint256) {
        if (_reentrancyGuardEntered()) revert ReadDuringSettlement();
        (uint256 price,) = _price();
        return Math.mulDiv(shares, price, priceScale);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return valueOf(shares);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256 shares) {
        if (_reentrancyGuardEntered()) revert ReadDuringSettlement();
        if (assets == 0) revert InvalidAmount();
        (shares,,,) = pool.quoteExactOutputFor(address(this), address(this), customerId, true, assets);
        if (shares == 0) revert InvalidAmount();
    }

    function isFeeValuationFresh() external view returns (bool) {
        try this.oracleObservationTime() returns (uint256 observedAt) {
            return block.timestamp - observedAt <= maxOracleAge;
        } catch {
            return false;
        }
    }

    function oracleObservationTime() external view returns (uint256 observedAt) {
        (, observedAt) = _price();
    }

    function deposit(uint256 assets) external nonReentrant onlyEarnVault returns (uint256 shares) {
        if (assets == 0) revert InvalidAmount();
        (uint256 price, uint256 observedAt) = _price();
        // Enforce the same age used by fee valuation even when the pool accepts an older report.
        // Keep this admission check out of exit paths so stale fee valuation alone cannot trap holders.
        if (block.timestamp - observedAt > maxOracleAge) revert InvalidOracle();
        uint256 cashBefore = IERC20(asset).balanceOf(address(this));
        uint256 baseBefore = totalShares();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        if (IERC20(asset).balanceOf(address(this)) != cashBefore + assets) revert InexactTransfer();
        _buy(assets, price, observedAt);
        _samePrice(price, observedAt);
        shares = totalShares() - baseBefore;
        if (shares == 0) revert InvalidAmount();
        emit Deposited(msg.sender, assets, shares);
    }

    function redeem(uint256 shares, address receiver, uint256 minAssets)
        external
        nonReentrant
        onlyEarnVault
        returns (uint256 assets)
    {
        if (shares == 0 || shares > totalShares()) revert InvalidAmount();
        _route();
        (uint256 price, uint256 observedAt) = _price();
        uint256 baseBefore = totalShares();
        uint256 cashBefore = IERC20(asset).balanceOf(address(this));
        IERC20(baseToken).forceApprove(address(pool), shares);
        pool.swapExactInput(
            true,
            shares,
            minAssets,
            address(this),
            customerId,
            bytes32(++tradeNonce),
            block.timestamp,
            price,
            0,
            observedAt
        );
        IERC20(baseToken).forceApprove(address(pool), 0);
        if (totalShares() != baseBefore - shares) revert InexactTransfer();
        assets = IERC20(asset).balanceOf(address(this)) - cashBefore;
        if (assets == 0 || assets < minAssets) revert InsufficientBacking();
        _samePrice(price, observedAt);
        _pay(assets, receiver);
        emit Redeemed(receiver, shares, assets);
    }

    function withdraw(uint256 assets, address receiver) external nonReentrant onlyEarnVault returns (uint256 shares) {
        if (assets == 0) revert InvalidAmount();
        _route();
        (uint256 price, uint256 observedAt) = _price();
        (uint256 maximum, uint256 quotedPrice, uint256 quotedAt,) =
            pool.quoteExactOutputFor(address(this), address(this), customerId, true, assets);
        if (maximum == 0) revert InvalidAmount();
        if (quotedPrice != price || quotedAt != observedAt) revert QuoteMismatch();
        uint256 baseBefore = totalShares();
        uint256 cashBefore = IERC20(asset).balanceOf(address(this));
        IERC20(baseToken).forceApprove(address(pool), maximum);
        _executeSell(assets, maximum, price, observedAt);
        IERC20(baseToken).forceApprove(address(pool), 0);
        shares = baseBefore - totalShares();
        if (shares == 0 || shares > maximum || IERC20(asset).balanceOf(address(this)) != cashBefore + assets) {
            revert InexactTransfer();
        }
        _samePrice(price, observedAt);
        _pay(assets, receiver);
        emit WithdrewExact(receiver, assets, shares);
    }

    /// @notice Inventory and admission snapshot, not a guaranteed executable withdrawal limit.
    /// @dev Quotes also depend on oracle freshness, directional price anchors and token policy.
    function liquidityStatus()
        external
        view
        returns (bool paused, bool admitted, uint256 idleCash, uint256 venueCash, uint256 venueBase)
    {
        paused = pool.paused();
        admitted = pool.takerAllowed(address(this)) && pool.recipientAllowed(address(this))
            && pool.resolveRecipient(address(this)) == address(this);
        idleCash = IERC20(asset).balanceOf(address(this));
        venueCash = IERC20(asset).balanceOf(address(pool));
        venueBase = IERC20(baseToken).balanceOf(address(pool));
    }

    function _price() private view returns (uint256 price, uint256 observedAt) {
        if (pool.oracle() != address(priceOracle) || priceOracle.decimals() != oracleDecimals) revert InvalidOracle();
        (price, observedAt) = priceOracle.latestPrice();
        if (price == 0 || observedAt == 0 || observedAt > block.timestamp) {
            revert InvalidOracle();
        }
    }

    function _samePrice(uint256 price, uint256 observedAt) private view {
        (uint256 currentPrice, uint256 currentObservedAt) = _price();
        if (price != currentPrice || observedAt != currentObservedAt) revert QuoteMismatch();
    }

    function _buy(uint256 assets, uint256 price, uint256 observedAt) private {
        _route();
        (uint256 minimum, uint256 quotedPrice, uint256 quotedAt,) =
            pool.quoteExactInputFor(address(this), address(this), customerId, false, assets);
        if (quotedPrice != price || quotedAt != observedAt || minimum == 0) revert QuoteMismatch();
        uint256 cashBefore = IERC20(asset).balanceOf(address(this));
        uint256 baseBefore = IERC20(baseToken).balanceOf(address(this));
        IERC20(asset).forceApprove(address(pool), assets);
        uint256 received = _executeBuy(assets, minimum, price, observedAt);
        IERC20(asset).forceApprove(address(pool), 0);
        if (
            received < minimum || IERC20(asset).balanceOf(address(this)) != cashBefore - assets
                || IERC20(baseToken).balanceOf(address(this)) != baseBefore + received
        ) revert InexactTransfer();
    }

    function _pay(uint256 assets, address receiver) private {
        if (receiver == address(0) || receiver == address(this) || receiver == address(pool)) {
            revert InvalidReceiver();
        }
        uint256 beforeRecipient = IERC20(asset).balanceOf(receiver);
        uint256 beforeEngine = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransfer(receiver, assets);
        if (
            IERC20(asset).balanceOf(receiver) != beforeRecipient + assets
                || IERC20(asset).balanceOf(address(this)) != beforeEngine - assets
        ) revert InexactTransfer();
    }

    function _executeBuy(uint256 assets, uint256 minimum, uint256 price, uint256 observedAt) private returns (uint256) {
        return pool.swapExactInput(
            false,
            assets,
            minimum,
            address(this),
            customerId,
            bytes32(++tradeNonce),
            block.timestamp,
            price,
            0,
            observedAt
        );
    }

    function _executeSell(uint256 assets, uint256 maximum, uint256 price, uint256 observedAt)
        private
        returns (uint256)
    {
        return pool.swapExactOutput(
            true,
            assets,
            maximum,
            address(this),
            customerId,
            bytes32(++tradeNonce),
            block.timestamp,
            price,
            0,
            observedAt
        );
    }

    function _route() private view {
        if (
            pool.paused() || !pool.takerAllowed(address(this)) || !pool.recipientAllowed(address(this))
                || pool.resolveRecipient(address(this)) != address(this)
        ) revert InvalidConfiguration();
    }
}
