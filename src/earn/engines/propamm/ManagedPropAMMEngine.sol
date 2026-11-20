// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IPropAMMPriceOracle } from "../../../interfaces/external/propamm/IPropAMMVenue.sol";
import { IManagedPropAMMVenue } from "../../../interfaces/external/propamm/IManagedPropAMMVenue.sol";

import { IEarnEngine } from "../../../interfaces/earn/engines/IEarnEngine.sol";
import { IEarnEngineExactWithdraw } from "../../../interfaces/earn/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineRedeem } from "../../../interfaces/earn/engines/IEarnEngineRedeem.sol";
import { IEarnEngineFeeValuation } from "../../../interfaces/earn/engines/IEarnEngineFeeValuation.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IEarnVault } from "../../../interfaces/earn/IEarnVault.sol";

/// @notice Single-position PropAMM engine over one pair of a managed pool, denominated in the pair's quote asset.
/// @dev The managed counterpart of PropAMMEngine, with the same Earn-facing behaviour. A managed pool holds many
/// pairs, so every swap and quote names this engine's immutable pair, every swap names the immutable access
/// list the engine trades under, and the pool pays a swap's output to its caller, the engine: there is no
/// recipient to check. Pool, pair, sponsor, tokens and oracle are immutable. Only the bound EarnVault can move
/// collateral.
/// The engine values and trades its base tokens at the oracle price, so it refuses a pair with a hook: a hook
/// can charge an input-token fee, which the oracle valuation would not reflect.
/// Specs for solar-verify (docs/earn/modules/propamm.md, docs/earn/integrations/engines.md):
/// Every fund flow is nonReentrant through the transient `_entered` flag.
/// @custom:reentrancy-guard _entered
/// Owner calls that stay open under the lock cannot unbind or rebind the EarnVault.
/// @custom:lock-stable earnVault != address(0)
/// The pair trades two distinct tokens; the oracle age bound and route are nonzero.
/// @custom:invariant baseToken != asset && maxOracleAge > 0 && customerId != bytes32(0)
/// Ghost record of the last oracle observation _price accepted.
/// @custom:ghost uint256 lastPrice
/// @custom:ghost uint256 lastObservedAt
/// Ghost record of the engine's base-token holding (its engine shares) measured before and after each trade.
/// @custom:ghost uint256 heldBefore
/// @custom:ghost uint256 heldAfter
/// Solvency: every deposit, redemption and exact withdrawal reports exactly the measured change in the base
/// tokens the engine holds, so the EarnVault's engine-share ledger moves with the holding (see their ensures).
/// Not proved: that the holding never falls below the engine shares the EarnVault records; tokens can leave or
/// arrive outside these calls, which the vault ledger does not see.
/// Not proved: an upper bound on maxOracleAge. The constructor accepts any nonzero age; no named maximum
/// limits how old an observation deposits may price against.
/// Not proved: a bound on the oracle price's deviation. The engine requires the pool's quote and the
/// execution to use the observation it read, but bounds neither the price's move between observations nor
/// its distance from any reference; any deviation limit is the pool's.
contract ManagedPropAMMEngine is
    IEarnEngine,
    IEarnEngineExactWithdraw,
    IEarnEngineRedeem,
    IEarnEngineFeeValuation,
    Ownable2Step
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
    error ReentrantCall();

    event EarnVaultInitialized(address indexed earnVault);
    event Deposited(address indexed earnVault, uint256 assets, uint256 engineShares);
    event Redeemed(address indexed receiver, uint256 engineShares, uint256 assets);
    event WithdrewExact(address indexed receiver, uint256 assets, uint256 engineSharesBurned);

    address public immutable asset;
    address public immutable baseToken;
    IManagedPropAMMVenue public immutable pool;
    /// @notice The pair of the pool this engine trades. A pair's index and tokens never change.
    uint16 public immutable pairIndex;
    /// @notice The access list the engine trades under: 0 for the pair's home list, or a registered sponsor's.
    uint64 public immutable sponsorId;
    IPropAMMPriceOracle public immutable priceOracle;
    uint256 public immutable maxOracleAge;
    uint256 public immutable priceScale;
    bytes32 public immutable customerId;
    uint256 public immutable shareScale;
    uint8 public immutable oracleDecimals;
    string public constant name = "Managed PropAMM Engine";
    string public constant symbol = "managed-propAMM-engine";
    address public earnVault;
    /// @dev Packed beside `earnVault`, which is nonzero before the first trade, so the first trade ID
    ///      never writes a slot from zero.
    uint96 private tradeNonce;
    bool private transient _entered;

    modifier onlyEarnVault() {
        if (msg.sender != earnVault || earnVault == address(0)) revert NotEarnVault();
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    /// @notice Binds the engine to one live pair of a managed pool.
    /// @dev Fails closed unless the pool's pair at `pairIndex_` is live, trades exactly `baseToken_`
    /// against `asset_`, records the decimals the tokens and the oracle report, and has no hook. An unknown or
    /// removed pair reads all zero, so it matches no token.
    /// @custom:ensures address(pool) == pool_ && pairIndex == pairIndex_ && sponsorId == sponsorId_
    /// @custom:ensures asset == asset_ && baseToken == baseToken_
    /// @custom:ensures maxOracleAge == maxAge_ && customerId == route_ && earnVault == address(0)
    constructor(
        address pool_,
        uint16 pairIndex_,
        uint64 sponsorId_,
        address asset_,
        address baseToken_,
        address owner_,
        uint256 maxAge_,
        bytes32 route_
    ) Ownable(owner_) {
        if (pool_.code.length == 0 || maxAge_ == 0 || route_ == bytes32(0)) {
            revert InvalidConfiguration();
        }
        if (baseToken_.code.length == 0 || asset_.code.length == 0 || baseToken_ == asset_) {
            revert InvalidConfiguration();
        }
        IManagedPropAMMVenue venue = IManagedPropAMMVenue(pool_);
        IManagedPropAMMVenue.Pair memory traded = venue.pair(pairIndex_);
        if (traded.base != baseToken_ || traded.quote != asset_) revert InvalidConfiguration();
        IPropAMMPriceOracle source = IPropAMMPriceOracle(traded.oracle);
        if (address(source).code.length == 0) revert InvalidConfiguration();
        uint8 baseDecimals = IERC20Metadata(baseToken_).decimals();
        uint8 quoteDecimals = IERC20Metadata(asset_).decimals();
        uint8 precision = source.decimals();
        uint16 exponent = uint16(baseDecimals) + uint16(precision);
        if (baseDecimals > 77 || exponent < quoteDecimals || exponent - quoteDecimals > 77) {
            revert InvalidConfiguration();
        }
        uint256 scale = 10 ** (exponent - quoteDecimals);
        // The pool prices the pair with the decimals it recorded; the engine values with the same ones or not at all.
        if (
            traded.baseDecimals != baseDecimals || traded.quoteDecimals != quoteDecimals
                || traded.oracleDecimals != precision || traded.priceScale != scale
        ) revert InvalidConfiguration();
        (address hook,) = venue.pairHook(pairIndex_);
        if (hook != address(0)) revert InvalidConfiguration();
        asset = asset_;
        baseToken = baseToken_;
        pool = venue;
        pairIndex = pairIndex_;
        sponsorId = sponsorId_;
        priceOracle = source;
        oracleDecimals = precision;
        maxOracleAge = maxAge_;
        shareScale = 10 ** uint256(baseDecimals);
        priceScale = scale;
        customerId = route_;
        // One-unit standing allowances keep both allowance slots nonzero between trades. Each swap approves
        // one unit above its amount, and the measured balance checks keep every pull exact.
        IERC20(asset_).forceApprove(pool_, 1);
        IERC20(baseToken_).forceApprove(pool_, 1);
    }

    /// Only the owner binds, once, to an EarnVault with code and the same asset; ownership is unchanged.
    /// @custom:ensures old(owner()) == msg.sender && old(earnVault) == address(0) && earnVault == vault_
    /// @custom:ensures owner() == old(owner()) && pendingOwner() == old(pendingOwner())
    function initializeEarnVault(address vault_) external onlyOwner {
        _bind(vault_);
    }

    /// Only the owner binds, once, to an EarnVault with code, and hands ownership to a nonzero final owner.
    /// @custom:ensures old(owner()) == msg.sender && old(earnVault) == address(0) && earnVault == vault_
    /// @custom:ensures owner() == finalOwner_ && finalOwner_ != address(0) && pendingOwner() == address(0)
    function initializeEarnVault(address vault_, address finalOwner_) external onlyOwner {
        if (finalOwner_ == address(0)) revert InvalidConfiguration();
        _bind(vault_);
        _transferOwnership(finalOwner_);
    }

    /// @custom:ensures old(earnVault) == address(0) && earnVault == vault_
    function _bind(address vault_) private {
        if (earnVault != address(0)) revert AlreadyBound();
        if (vault_.code.length == 0 || IEarnVault(vault_).asset() != asset) revert InvalidConfiguration();
        earnVault = vault_;
        emit EarnVaultInitialized(vault_);
    }

    /// Advertises ERC-165, the engine, exact withdraw, redeem and fee valuation, and nothing else.
    /// @custom:ensures id == type(IERC165).interfaceId ==> result
    /// @custom:ensures id == type(IEarnEngine).interfaceId ==> result
    /// @custom:ensures id == type(IEarnEngineExactWithdraw).interfaceId ==> result
    /// @custom:ensures id == type(IEarnEngineRedeem).interfaceId ==> result
    /// @custom:ensures id == type(IEarnEngineFeeValuation).interfaceId ==> result
    /// @custom:ensures result ==> (id == type(IERC165).interfaceId || id == type(IEarnEngine).interfaceId || id == type(IEarnEngineExactWithdraw).interfaceId || id == type(IEarnEngineRedeem).interfaceId || id == type(IEarnEngineFeeValuation).interfaceId)
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

    /// Valuation reverts mid-settlement and rounds down, in the vault's favour: shares * price / priceScale.
    /// @custom:ensures !_entered && lastPrice > 0
    /// @custom:ensures result * priceScale <= shares * lastPrice && shares * lastPrice < (result + 1) * priceScale
    function valueOf(uint256 shares) public view returns (uint256) {
        if (_entered) revert ReadDuringSettlement();
        (uint256 price,) = _price();
        return Math.mulDiv(shares, price, priceScale);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return valueOf(shares);
    }

    /// @custom:ensures !_entered && assets > 0 && shares > 0
    function previewWithdraw(uint256 assets) public view returns (uint256 shares) {
        if (_entered) revert ReadDuringSettlement();
        if (assets == 0) revert InvalidAmount();
        (shares,,,) = pool.quoteExactOutputFor(pairIndex, address(this), customerId, true, assets);
        if (shares == 0) revert InvalidAmount();
    }

    /// A hook's fee is not in the oracle valuation, so the valuation is not fee-grade while one is installed.
    function isFeeValuationFresh() external view returns (bool) {
        try this.oracleObservationTime() returns (uint256 observedAt) {
            if (block.timestamp - observedAt > maxOracleAge) return false;
        } catch {
            return false;
        }
        try pool.pairHook(pairIndex) returns (address hook, uint8) {
            return hook == address(0);
        } catch {
            return false;
        }
    }

    /// @custom:ensures 0 < observedAt && observedAt <= block.timestamp
    function oracleObservationTime() external view returns (uint256 observedAt) {
        (, observedAt) = _price();
    }

    /// Only the bound EarnVault calls it; the binding survives, and each trade gets a fresh trade ID.
    /// @custom:ensures old(earnVault) != address(0) && msg.sender == old(earnVault) && earnVault != address(0)
    /// @custom:ensures tradeNonce == old(tradeNonce) + 1
    /// A deposit of positive assets credits positive shares, admitted only with a fresh oracle observation.
    /// @custom:ensures assets > 0 && shares > 0
    /// @custom:ensures 0 < lastObservedAt && lastObservedAt <= block.timestamp && block.timestamp - lastObservedAt <= maxOracleAge
    /// The shares credited are exactly the measured increase in the base tokens the engine holds.
    /// @custom:ensures heldAfter == heldBefore + shares
    /// Not proved: liveness. A deposit also needs the token pull, the pool's quote and swap, and a fresh
    /// oracle observation, all outside this contract.
    function deposit(uint256 assets) external nonReentrant onlyEarnVault returns (uint256 shares) {
        if (assets == 0) revert InvalidAmount();
        (uint256 price, uint256 observedAt) = _price();
        // Enforce the same age used by fee valuation even when the pool accepts an older report.
        // Keep this admission check out of exit paths so stale fee valuation alone cannot trap holders.
        if (block.timestamp - observedAt > maxOracleAge) revert InvalidOracle();
        uint256 cashBefore = IERC20(asset).balanceOf(address(this));
        uint256 baseBefore = totalShares();
        /// @custom:ghost heldBefore = baseBefore
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        if (IERC20(asset).balanceOf(address(this)) != cashBefore + assets) revert InexactTransfer();
        // _buy measures the base holding as exactly `baseBefore + shares`, so it is not read again here.
        shares = _buy(assets, price, observedAt, cashBefore + assets, baseBefore);
        _samePrice(price, observedAt);
        /// @custom:ghost heldAfter = baseBefore + shares
        if (shares == 0) revert InvalidAmount();
        emit Deposited(msg.sender, assets, shares);
    }

    /// Only the bound EarnVault calls it; the binding survives, and each trade gets a fresh trade ID.
    /// @custom:ensures old(earnVault) != address(0) && msg.sender == old(earnVault) && earnVault != address(0)
    /// @custom:ensures tradeNonce == old(tradeNonce) + 1
    /// A redemption burns positive shares and pays positive assets, at least the minimum, to a valid receiver.
    /// @custom:ensures shares > 0 && assets > 0 && assets >= minAssets
    /// The shares redeemed are exactly the measured decrease in the base tokens the engine holds.
    /// @custom:ensures heldAfter + shares == heldBefore
    /// @custom:ensures receiver != address(0) && receiver != address(this) && receiver != address(pool)
    function redeem(uint256 shares, address receiver, uint256 minAssets)
        external
        nonReentrant
        onlyEarnVault
        returns (uint256 assets)
    {
        uint256 baseBefore = totalShares();
        if (shares == 0 || shares > baseBefore) revert InvalidAmount();
        _routeExit();
        (uint256 price, uint256 observedAt) = _price();
        /// @custom:ghost heldBefore = baseBefore
        uint256 cashBefore = IERC20(asset).balanceOf(address(this));
        // Exact input: the measured holding below proves the pool pulled `shares`, leaving the standing unit.
        IERC20(baseToken).forceApprove(address(pool), shares + 1);
        // The pool pays its caller: the measured cash below is what the engine received.
        pool.swapExactInput(
            pairIndex,
            true,
            shares,
            minAssets,
            sponsorId,
            customerId,
            bytes32(uint256(++tradeNonce)),
            block.timestamp,
            price,
            0,
            observedAt
        );
        /// @custom:ghost heldAfter = totalShares()
        if (totalShares() != baseBefore - shares) revert InexactTransfer();
        uint256 cashAfter = IERC20(asset).balanceOf(address(this));
        assets = cashAfter - cashBefore;
        if (assets == 0 || assets < minAssets) revert InsufficientBacking();
        _samePrice(price, observedAt);
        _pay(assets, receiver, cashAfter);
        emit Redeemed(receiver, shares, assets);
    }

    /// Only the bound EarnVault calls it; the binding survives, and each trade gets a fresh trade ID.
    /// @custom:ensures old(earnVault) != address(0) && msg.sender == old(earnVault) && earnVault != address(0)
    /// @custom:ensures tradeNonce == old(tradeNonce) + 1
    /// An exact withdrawal pays positive assets to a valid receiver for positive shares.
    /// @custom:ensures assets > 0 && shares > 0
    /// @custom:ensures receiver != address(0) && receiver != address(this) && receiver != address(pool)
    /// The shares burned are exactly the measured decrease in the base tokens the engine holds.
    /// @custom:ensures heldAfter + shares == heldBefore
    function withdraw(uint256 assets, address receiver) external nonReentrant onlyEarnVault returns (uint256 shares) {
        if (assets == 0) revert InvalidAmount();
        _routeExit();
        (uint256 price, uint256 observedAt) = _price();
        (uint256 maximum, uint256 quotedPrice, uint256 quotedAt,) =
            pool.quoteExactOutputFor(pairIndex, address(this), customerId, true, assets);
        if (maximum == 0) revert InvalidAmount();
        if (quotedPrice != price || quotedAt != observedAt) revert QuoteMismatch();
        uint256 baseBefore = totalShares();
        /// @custom:ghost heldBefore = baseBefore
        uint256 cashBefore = IERC20(asset).balanceOf(address(this));
        IERC20(baseToken).forceApprove(address(pool), maximum + 1);
        _executeSell(assets, maximum, price, observedAt);
        shares = baseBefore - totalShares();
        /// @custom:ghost heldAfter = baseBefore - shares
        if (shares == 0 || shares > maximum || IERC20(asset).balanceOf(address(this)) != cashBefore + assets) {
            revert InexactTransfer();
        }
        // Exact output may pull less than `maximum`; bring the leftover back to the standing unit.
        if (shares != maximum) IERC20(baseToken).forceApprove(address(pool), 1);
        _samePrice(price, observedAt);
        _pay(assets, receiver, cashBefore + assets);
        emit WithdrewExact(receiver, assets, shares);
    }

    /// @notice Inventory and admission snapshot, not a guaranteed executable withdrawal limit.
    /// @dev Quotes also depend on oracle freshness, directional price anchors and token policy. The pool's
    /// inventory of a token is shared by every pair that trades it.
    function liquidityStatus()
        external
        view
        returns (bool paused, bool admitted, uint256 idleCash, uint256 venueCash, uint256 venueBase)
    {
        paused = pool.paused();
        admitted = _admitted();
        idleCash = IERC20(asset).balanceOf(address(this));
        venueCash = IERC20(asset).balanceOf(address(pool));
        venueBase = IERC20(baseToken).balanceOf(address(pool));
    }

    /// The oracle is the pair's current one with the recorded decimals, and its observation is nonzero
    /// and not in the future. A removed pair reads no oracle, so it fails here.
    /// @custom:ensures price > 0 && 0 < observedAt && observedAt <= block.timestamp
    /// @custom:ensures price == lastPrice && observedAt == lastObservedAt
    function _price() private view returns (uint256 price, uint256 observedAt) {
        if (pool.pair(pairIndex).oracle != address(priceOracle) || priceOracle.decimals() != oracleDecimals) {
            revert InvalidOracle();
        }
        (price, observedAt) = priceOracle.latestPrice();
        /// @custom:ghost lastPrice = price
        /// @custom:ghost lastObservedAt = observedAt
        if (price == 0 || observedAt == 0 || observedAt > block.timestamp) {
            revert InvalidOracle();
        }
    }

    /// The oracle observation has not moved since the trade was priced.
    /// @custom:ensures lastPrice == price && lastObservedAt == observedAt
    function _samePrice(uint256 price, uint256 observedAt) private view {
        (uint256 currentPrice, uint256 currentObservedAt) = _price();
        if (price != currentPrice || observedAt != currentObservedAt) revert QuoteMismatch();
    }

    /// @dev `cashBefore` and `baseBefore` are the engine's measured balances when the swap starts.
    function _buy(uint256 assets, uint256 price, uint256 observedAt, uint256 cashBefore, uint256 baseBefore)
        private
        returns (uint256 received)
    {
        _routeEntry();
        (uint256 minimum, uint256 quotedPrice, uint256 quotedAt,) =
            pool.quoteExactInputFor(pairIndex, address(this), customerId, false, assets);
        if (quotedPrice != price || quotedAt != observedAt || minimum == 0) revert QuoteMismatch();
        // Exact input: the measured cash below proves the pool pulled `assets`, leaving the standing unit.
        IERC20(asset).forceApprove(address(pool), assets + 1);
        received = _executeBuy(assets, minimum, price, observedAt);
        // The pool pays its caller: the measured base holding proves the engine received the output.
        if (
            received < minimum || IERC20(asset).balanceOf(address(this)) != cashBefore - assets
                || IERC20(baseToken).balanceOf(address(this)) != baseBefore + received
        ) revert InexactTransfer();
    }

    /// @dev `beforeEngine` is the engine's measured quote-asset balance before the payment.
    function _pay(uint256 assets, address receiver, uint256 beforeEngine) private {
        if (receiver == address(0) || receiver == address(this) || receiver == address(pool)) {
            revert InvalidReceiver();
        }
        uint256 beforeRecipient = IERC20(asset).balanceOf(receiver);
        IERC20(asset).safeTransfer(receiver, assets);
        if (
            IERC20(asset).balanceOf(receiver) != beforeRecipient + assets
                || IERC20(asset).balanceOf(address(this)) != beforeEngine - assets
        ) revert InexactTransfer();
    }

    function _executeBuy(uint256 assets, uint256 minimum, uint256 price, uint256 observedAt) private returns (uint256) {
        return pool.swapExactInput(
            pairIndex,
            false,
            assets,
            minimum,
            sponsorId,
            customerId,
            bytes32(uint256(++tradeNonce)),
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
            pairIndex,
            true,
            assets,
            maximum,
            sponsorId,
            customerId,
            bytes32(uint256(++tradeNonce)),
            block.timestamp,
            price,
            0,
            observedAt
        );
    }

    /// @dev The pool admits the engine on its pair under its sponsor. An unknown or removed pair admits nobody.
    function _listed() private view returns (bool) {
        return pool.takerAllowed(pairIndex, address(this), sponsorId);
    }

    /// @dev Deposit admission: the pool admits the engine and the pair has no hook. A hook can charge a fee the
    /// oracle valuation does not reflect, so the engine takes no new deposits through a hooked pair.
    function _admitted() private view returns (bool) {
        if (!_listed()) return false;
        (address hook,) = pool.pairHook(pairIndex);
        return hook == address(0);
    }

    function _routeEntry() private view {
        if (pool.paused() || !_admitted()) revert InvalidConfiguration();
    }

    /// @dev Exits stop only where the pool itself refuses the swap. The hook rule is a deposit admission check
    /// and stays out of exit paths, so a hook installed after holders entered cannot trap them: an exit through
    /// a hooked pair pays the pool's fee-inclusive price, bounded by the caller's minimum (redeem) or by the
    /// quoted maximum and the vault's share limit (exact withdrawal).
    function _routeExit() private view {
        if (pool.paused() || !_listed()) revert InvalidConfiguration();
    }
}
