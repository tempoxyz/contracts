// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IEarnVault } from "../../interfaces/earn/IEarnVault.sol";
import { IERC20Like } from "../../interfaces/external/IERC20Like.sol";
import { IERC20Allowance } from "../../interfaces/external/IERC20Allowance.sol";
import { IPropAMMPriceOracle, IPropAMMVenue } from "../../interfaces/external/propamm/IPropAMMVenue.sol";
import {
    EncryptedDepositPayload,
    IWithdrawalReceiver,
    IZoneFactory,
    IZonePortal,
    ZONE_FACTORY_ADDRESS,
    ZONE_MESSENGER_ADDRESS
} from "../../interfaces/external/tempo/IZone.sol";

/// @title SingleZoneEarnRouter
/// @notice Ownerless private Earn router scoped to one Zone, EarnVault, and private asset.
/// @dev A private asset other than the vault asset converts through one immutable DirectPropAMM pool at
///      the pool's exact par price, with measured output equal to input. A router whose private asset is
///      the vault asset has no pool and deposits and redeems that asset directly.
///      Only authenticated callbacks from the selected Zone can execute either route. Callback data
///      contains no route, token, vault, or destination selection, and every successful result returns
///      through the authenticated source Portal.
/// Specs for solar-verify (docs/earn/modules/zone-router.md, earn/src/AGENTS.md):
/// The only state-changing entry point, onWithdrawalReceived, is nonReentrant (`locked` is set while held).
/// @custom:reentrancy-guard locked
/// The route is fixed at construction: a nonzero vault, vault asset and EarnShare, and a nonzero private
/// asset that is never the EarnShare.
/// @custom:invariant earnVault != address(0) && vaultAsset != address(0) && earnShare != address(0)
/// @custom:invariant privateAsset != address(0) && privateAsset != earnShare
/// A same-asset router binds no pool and no customer ID; any other private asset has both.
/// @custom:invariant address(pool) == address(0) <==> privateAsset == vaultAsset
/// @custom:invariant address(pool) == address(0) <==> customerId == bytes32(0)
/// @custom:invariant address(pool) == address(0) ==> !privateAssetIsBase
/// Ghost record of every token and spender this router has given a standing allowance (set in _approveStanding).
/// @custom:ghost mapping(address => mapping(address => bool)) standingGhost
/// Ghost record of Portal deposits (set in _depositEncryptedToSourceZone): their count and the last one.
/// @custom:ghost uint256 portalDeposits
/// @custom:ghost address lastReturnPortal
/// @custom:ghost address lastReturnToken
/// @custom:ghost uint256 lastReturnAmount
/// @custom:ghost address lastRefundRecipient
/// Ghost record of the flow the last callback decoded.
/// @custom:ghost bool lastFlowWasDeposit
/// Ghost record of the last token call (set in _callOptionalReturn): success, returned data, and that data as a bool.
/// @custom:ghost bool lastCallOk
/// @custom:ghost bool lastCallReturnedData
/// @custom:ghost bool lastCallReturnedTrue
contract SingleZoneEarnRouter is IWithdrawalReceiver {
    enum Flow {
        Deposit,
        Redeem
    }

    /// @notice Encrypted return data without a caller-selected Portal.
    struct ZoneReturn {
        uint256 keyIndex;
        EncryptedDepositPayload encrypted;
        address refundRecipient;
    }

    struct CallbackData {
        Flow flow;
        uint128 minVaultAssets;
        uint128 minEarnShares;
        uint128 minOutputAmount;
        bytes32 actionId;
        ZoneReturn zoneReturn;
    }

    struct Operation {
        uint128 minVaultAssets;
        uint128 minEarnShares;
        uint128 minOutputAmount;
        bytes32 actionId;
    }

    /// @notice The only accepted source Zone. Zero permanently disables callbacks.
    uint32 public immutable allowedZoneId;
    /// @notice The only EarnVault this router can use.
    address public immutable earnVault;
    /// @notice The only private stablecoin accepted on deposit and returned on redemption.
    address public immutable privateAsset;
    /// @notice The immutable EarnVault base asset.
    address public immutable vaultAsset;
    /// @notice The immutable EarnShare accepted on redemption and returned on deposit.
    address public immutable earnShare;
    /// @notice The only DirectPropAMM pool allowed to convert the private asset pair.
    /// @dev Zero when the private asset is the vault asset and no conversion is needed.
    IPropAMMVenue public immutable pool;
    /// @notice The pool rounding route and trade-memo customer identifier; zero without a pool.
    bytes32 public immutable customerId;
    /// @notice Whether the private asset is the pool's base token; false without a pool.
    bool public immutable privateAssetIsBase;
    /// @dev The allowed Zone's Factory-registered Portal, read once at construction; zero for Zone zero.
    ///      A Zone's Portal never changes and the Factory never deregisters one.
    address private immutable zonePortal;

    bool private transient locked;

    event EarnDeposit(
        bytes32 indexed actionId,
        address indexed earnVault,
        address indexed inputToken,
        uint256 inputAmount,
        uint256 vaultAssets,
        uint256 earnShares,
        bytes32 zoneDepositHash
    );
    event EarnRedeem(
        bytes32 indexed actionId,
        address indexed earnVault,
        address indexed outputToken,
        uint256 earnShares,
        uint256 vaultAssets,
        uint256 outputAmount,
        bytes32 zoneDepositHash
    );

    error AmountOverflow();
    error BadFlow();
    error InsufficientOutput();
    error InvalidCustomerId();
    error InvalidEarnVault();
    error InvalidPool();
    error InvalidPrivateAsset();
    error InvalidReturnToken();
    error InvalidRoutePair();
    error InvalidSourcePortal();
    error NotZoneMessenger();
    error ReentrantCall();
    error ResidualBalance();
    error TokenCallFailed();
    error TokenCallFalse();
    error WrongInputToken();
    error WrongSourceZone();
    error ZeroAddress();
    error ZeroAmount();

    modifier nonReentrant() {
        if (locked) revert ReentrantCall();
        locked = true;
        _;
        locked = false;
    }

    /// @dev Pass `privateAsset_ == earnVault_.asset()` with a zero pool and customer ID for a router
    ///      without conversion. Any other private asset requires its DirectPropAMM pool and customer ID.
    /// @custom:ensures allowedZoneId == allowedZoneId_ && earnVault == earnVault_ && privateAsset == privateAsset_
    /// @custom:ensures address(pool) == pool_ && customerId == customerId_
    constructor(uint32 allowedZoneId_, address earnVault_, address privateAsset_, address pool_, bytes32 customerId_) {
        (address vaultAsset_, address earnShare_) = _earnVaultTokens(earnVault_);
        if (privateAsset_ == address(0) || privateAsset_ == earnShare_) revert InvalidPrivateAsset();

        bool privateIsBase;
        if (privateAsset_ == vaultAsset_) {
            // Nothing to convert: a pool or route identifier would be an unused, misleading binding. Keep
            // the earlier `InvalidPrivateAsset` rejection for every such input; only the pool-less form is new.
            if (pool_ != address(0) || customerId_ != bytes32(0)) revert InvalidPrivateAsset();
        } else {
            if (pool_ == address(0) || pool_.code.length == 0) revert InvalidPool();
            if (customerId_ == bytes32(0)) revert InvalidCustomerId();

            IPropAMMVenue venue = IPropAMMVenue(pool_);
            address base = venue.baseToken();
            address quote = venue.quoteToken();
            privateIsBase = base == privateAsset_ && quote == vaultAsset_;
            /// @custom:assert privateIsBase <==> (base == privateAsset_ && quote == vaultAsset_)
            if (!privateIsBase && !(base == vaultAsset_ && quote == privateAsset_)) revert InvalidRoutePair();
            /// The pool trades exactly the private asset against the vault asset, in one orientation.
            /// @custom:assert privateIsBase || (base == vaultAsset_ && quote == privateAsset_)
            // Equal units make the pool's par price an exact 1:1 conversion with no rounding remainder.
            if (IERC20Metadata(privateAsset_).decimals() != IERC20Metadata(vaultAsset_).decimals()) {
                revert InvalidRoutePair();
            }
        }

        address zonePortal_;
        if (allowedZoneId_ != 0) {
            zonePortal_ = IZoneFactory(ZONE_FACTORY_ADDRESS).zones(allowedZoneId_).portal;
            if (zonePortal_ == address(0) || !IZoneFactory(ZONE_FACTORY_ADDRESS).isZonePortal(zonePortal_)) {
                revert InvalidSourcePortal();
            }
        }

        allowedZoneId = allowedZoneId_;
        zonePortal = zonePortal_;
        earnVault = earnVault_;
        privateAsset = privateAsset_;
        vaultAsset = vaultAsset_;
        earnShare = earnShare_;
        pool = IPropAMMVenue(pool_);
        customerId = customerId_;
        privateAssetIsBase = privateIsBase;
    }

    /// Only the deposit and redeem flows exist.
    /// @custom:ensures result == (flow <= uint8(Flow.Redeem))
    function supportsFlow(uint8 flow) external pure returns (bool) {
        return flow <= uint8(Flow.Redeem);
    }

    /// @notice The oracle price at which one private-asset unit converts to exactly one vault-asset unit.
    /// @dev Zero for a router without a pool, which has no conversion price.
    /// @custom:ensures address(pool) == address(0) ==> result == 0
    function parPrice() public view returns (uint256) {
        if (!_converts()) return 0;
        return 10 ** uint256(IPropAMMPriceOracle(pool.oracle()).decimals());
    }

    /// @notice Pool state and output inventory for each flow, not a guaranteed executable conversion.
    /// @dev Execution also depends on the pool's oracle freshness and deviation guard and on token policy.
    ///      `depositLiquidity` is pool vault-asset inventory; `redeemLiquidity` is pool private-asset inventory.
    ///      A router without a pool reports an unpaused, admitted, at-par route with unlimited liquidity,
    ///      because conversion imposes no limit; EarnVault and Portal limits still apply.
    /// A router without a pool reports an unpaused, admitted, at-par route with unlimited liquidity.
    /// @custom:ensures address(pool) == address(0) ==> !paused && admitted && atPar
    /// @custom:ensures address(pool) == address(0) ==> depositLiquidity == type(uint256).max
    /// @custom:ensures address(pool) == address(0) ==> redeemLiquidity == type(uint256).max
    function liquidityStatus()
        external
        view
        returns (bool paused, bool admitted, bool atPar, uint256 depositLiquidity, uint256 redeemLiquidity)
    {
        if (!_converts()) return (false, true, true, type(uint256).max, type(uint256).max);
        paused = pool.paused();
        admitted = pool.takerAllowed(address(this)) && pool.recipientAllowed(address(this))
            && pool.resolveRecipient(address(this)) == address(this);
        try IPropAMMPriceOracle(pool.oracle()).latestPrice() returns (uint256 price, uint256) {
            atPar = price == parPrice();
        } catch { }
        depositLiquidity = IERC20Like(vaultAsset).balanceOf(address(pool));
        redeemLiquidity = IERC20Like(privateAsset).balanceOf(address(pool));
    }

    /// Callbacks are authenticated: only the Zone messenger, only from the one allowed nonzero Zone,
    /// only for a nonzero amount.
    /// @custom:ensures msg.sender == ZONE_MESSENGER_ADDRESS && amount > 0
    /// @custom:ensures allowedZoneId != 0 && sourceZoneId == allowedZoneId
    /// No caller-selected tokens: a deposit takes the private asset, a redemption the EarnShare.
    /// @custom:ensures token == privateAsset || token == earnShare
    /// Exactly one Portal deposit, to the authenticated source Portal, of a nonzero amount of the
    /// flow's counter-asset (EarnShare for a deposit, the private asset for a redemption).
    /// @custom:ensures portalDeposits == old(portalDeposits) + 1
    /// @custom:ensures lastReturnPortal == sourcePortal && lastReturnAmount > 0
    /// @custom:ensures lastFlowWasDeposit ==> token == privateAsset && lastReturnToken == earnShare
    /// @custom:ensures !lastFlowWasDeposit ==> token == earnShare && lastReturnToken == privateAsset
    /// Refunds of the returned deposit go to a nonzero recipient.
    /// @custom:ensures lastRefundRecipient != address(0)
    /// Standing approvals go only to the EarnVault, for the vault asset or EarnShare, to the pool, for a route token, or to the source Zone's Portal.
    /// @custom:ensures forall address t, address spender :: standingGhost[t][spender] && !old(standingGhost[t][spender]) ==> (spender == earnVault && (t == vaultAsset || t == earnShare)) || (spender == address(pool) && address(pool) != address(0) && (t == privateAsset || t == vaultAsset)) || spender == sourcePortal
    /// @custom:ensures !locked && result == IWithdrawalReceiver.onWithdrawalReceived.selector
    function onWithdrawalReceived(
        uint32 sourceZoneId,
        address sourcePortal,
        bytes32,
        address token,
        uint128 amount,
        bytes calldata callbackData
    ) external override nonReentrant returns (bytes4) {
        if (allowedZoneId == 0 || sourceZoneId != allowedZoneId) revert WrongSourceZone();
        _validateWithdrawal(sourcePortal, amount);
        uint256 inputBalanceBefore = IERC20Like(token).balanceOf(address(this)) - amount;

        uint256 rawFlow = _decodeRawFlow(callbackData);
        if (rawFlow > uint256(Flow.Redeem)) revert BadFlow();
        /// @custom:ghost lastFlowWasDeposit = rawFlow == uint256(Flow.Deposit)
        CallbackData memory data = abi.decode(callbackData, (CallbackData));
        Operation memory operation = Operation({
            minVaultAssets: data.minVaultAssets,
            minEarnShares: data.minEarnShares,
            minOutputAmount: data.minOutputAmount,
            actionId: data.actionId
        });
        if (Flow(rawFlow) == Flow.Deposit) {
            if (token != privateAsset) revert WrongInputToken();
            _handleDepositToSourceZone(sourcePortal, token, amount, data.zoneReturn, operation);
        } else {
            if (token != earnShare) revert WrongInputToken();
            _handleRedeemToSourceZone(sourcePortal, amount, data.zoneReturn, operation);
        }

        _requireBalance(token, inputBalanceBefore);
        return IWithdrawalReceiver.onWithdrawalReceived.selector;
    }

    function _handleDepositToSourceZone(
        address sourcePortal,
        address token,
        uint128 amount,
        ZoneReturn memory zoneReturn,
        Operation memory operation
    ) private {
        _validateSourceReturn(sourcePortal, earnShare, zoneReturn);
        uint256 earnShareBalanceBefore = IERC20Like(earnShare).balanceOf(address(this));
        uint256 vaultAssets = _converts()
            ? _swap(privateAsset, vaultAsset, amount, operation.minVaultAssets, operation.actionId)
            : amount;
        if (vaultAssets == 0 || vaultAssets < operation.minVaultAssets) revert InsufficientOutput();
        /// The private input converts 1:1 into vault assets (par), within the caller's minimum.
        /// @custom:assert vaultAssets == amount && vaultAssets >= operation.minVaultAssets

        _approveStanding(vaultAsset, earnVault, vaultAssets);
        uint256 earnShares = IEarnVault(earnVault).deposit(vaultAssets, address(this), operation.minEarnShares);
        if (earnShares == 0 || earnShares < operation.minEarnShares) revert InsufficientOutput();
        /// @custom:assert earnShares > 0 && earnShares >= operation.minEarnShares

        bytes32 zoneDepositHash =
            _depositEncryptedToSourceZone(sourcePortal, earnShare, _toUint128(earnShares), zoneReturn);
        _requireBalance(earnShare, earnShareBalanceBefore);
        emit EarnDeposit(operation.actionId, earnVault, token, amount, vaultAssets, earnShares, zoneDepositHash);
    }

    function _handleRedeemToSourceZone(
        address sourcePortal,
        uint128 amount,
        ZoneReturn memory zoneReturn,
        Operation memory operation
    ) private {
        _validateSourceReturn(sourcePortal, privateAsset, zoneReturn);
        uint256 outputBalanceBefore = IERC20Like(privateAsset).balanceOf(address(this));

        _approveStanding(earnShare, earnVault, amount);
        uint256 vaultAssets = IEarnVault(earnVault).redeem(amount, address(this), operation.minVaultAssets);
        if (vaultAssets == 0 || vaultAssets < operation.minVaultAssets) revert InsufficientOutput();
        /// @custom:assert vaultAssets > 0 && vaultAssets >= operation.minVaultAssets

        uint256 outputAmount = _converts()
            ? _swap(vaultAsset, privateAsset, vaultAssets, operation.minOutputAmount, operation.actionId)
            : vaultAssets;
        if (outputAmount == 0 || outputAmount < operation.minOutputAmount) revert InsufficientOutput();
        /// Vault assets convert 1:1 into the private asset (par), within the caller's minimum.
        /// @custom:assert outputAmount == vaultAssets && outputAmount >= operation.minOutputAmount

        bytes32 zoneDepositHash =
            _depositEncryptedToSourceZone(sourcePortal, privateAsset, _toUint128(outputAmount), zoneReturn);
        _requireBalance(privateAsset, outputBalanceBefore);
        emit EarnRedeem(operation.actionId, earnVault, privateAsset, amount, vaultAssets, outputAmount, zoneDepositHash);
    }

    /// Conversion only at exact par along the bound pair: measured output equals input, the minimum never
    /// exceeds the input. The pool's standing approval is the only one set here.
    /// Callers convert a nonzero amount.
    /// @custom:requires locked && address(pool) != address(0) && amountIn > 0
    /// @custom:ensures amountOut == amountIn && amountOut >= minAmountOut
    /// @custom:ensures _isRoutePair(tokenIn, tokenOut)
    /// @custom:ensures locked
    /// @custom:ensures portalDeposits == old(portalDeposits) && lastFlowWasDeposit == old(lastFlowWasDeposit)
    /// @custom:ensures forall address t, address spender :: standingGhost[t][spender] && !old(standingGhost[t][spender]) ==> spender == address(pool) && t == tokenIn
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, bytes32 actionId)
        private
        returns (uint256 amountOut)
    {
        _requireRoutePair(tokenIn, tokenOut);
        if (minAmountOut > amountIn) revert InsufficientOutput();

        uint256 inputBalanceBefore = IERC20Like(tokenIn).balanceOf(address(this)) - amountIn;
        uint256 outputBalanceBefore = IERC20Like(tokenOut).balanceOf(address(this));
        bool baseToQuote = (tokenIn == privateAsset) == privateAssetIsBase;

        // Zero tolerance at par rejects any off-par oracle price. The pool still enforces its own
        // freshness and deviation guards, so this route needs no separate observation-time floor.
        _approveStanding(tokenIn, address(pool), amountIn);
        // The measured output delta below is authoritative, not the pool's reported amount.
        pool.swapExactInput(
            baseToQuote, amountIn, amountIn, address(this), customerId, actionId, block.timestamp, parPrice(), 0, 0
        );

        uint256 outputBalanceAfter = IERC20Like(tokenOut).balanceOf(address(this));
        if (outputBalanceAfter <= outputBalanceBefore) revert InsufficientOutput();
        amountOut = outputBalanceAfter - outputBalanceBefore;
        if (amountOut != amountIn) revert InsufficientOutput();
        _requireBalance(tokenIn, inputBalanceBefore);
    }

    /// @custom:ensures msg.sender == ZONE_MESSENGER_ADDRESS && amount > 0
    function _validateWithdrawal(address sourcePortal, uint128 amount) private view {
        if (msg.sender != ZONE_MESSENGER_ADDRESS) revert NotZoneMessenger();
        // Callers check sourceZoneId == allowedZoneId first, so zonePortal is that Zone's registered Portal.
        if (sourcePortal != zonePortal) revert InvalidSourcePortal();
        /// The source Portal is the one the Zone factory recorded for the source Zone at construction.
        /// @custom:assert sourcePortal == zonePortal
        if (amount == 0) revert ZeroAmount();
    }

    /// @custom:ensures zoneReturn.refundRecipient != address(0)
    function _validateSourceReturn(address sourcePortal, address token, ZoneReturn memory zoneReturn) private view {
        if (zoneReturn.refundRecipient == address(0)) revert ZeroAddress();
        if (!IZonePortal(sourcePortal).isTokenEnabled(token) || !IZonePortal(sourcePortal).areDepositsActive(token)) {
            revert InvalidReturnToken();
        }
    }

    function _depositEncryptedToSourceZone(
        address sourcePortal,
        address token,
        uint128 amount,
        ZoneReturn memory zoneReturn
    ) private returns (bytes32 hash) {
        // Standing approval: clearing it would recreate the allowance slot on every callback.
        _approveStanding(token, sourcePortal, amount);
        /// @custom:ghost portalDeposits = portalDeposits + 1
        /// @custom:ghost lastReturnPortal = sourcePortal
        /// @custom:ghost lastReturnToken = token
        /// @custom:ghost lastReturnAmount = amount
        /// @custom:ghost lastRefundRecipient = zoneReturn.refundRecipient
        hash = IZonePortal(sourcePortal)
            .depositEncrypted(token, amount, zoneReturn.keyIndex, zoneReturn.encrypted, zoneReturn.refundRecipient);
    }

    /// @custom:ensures earnVault_ != address(0) && asset != address(0) && share != address(0)
    function _earnVaultTokens(address earnVault_) private view returns (address asset, address share) {
        if (earnVault_ == address(0) || earnVault_.code.length == 0) revert InvalidEarnVault();
        asset = IEarnVault(earnVault_).asset();
        share = IEarnVault(earnVault_).earnShare();
        if (asset == address(0) || share == address(0)) revert InvalidEarnVault();
    }

    function _decodeRawFlow(bytes calldata callbackData) private pure returns (uint256 rawFlow) {
        if (callbackData.length < 32) revert BadFlow();
        uint256 tupleOffset = abi.decode(callbackData, (uint256));
        if (tupleOffset > callbackData.length || callbackData.length - tupleOffset < 32) revert BadFlow();
        assembly {
            rawFlow := calldataload(add(callbackData.offset, tupleOffset))
        }
    }

    /// @dev Whether the private asset differs from the vault asset and converts through the pool.
    /// @custom:ensures result == (address(pool) != address(0))
    function _converts() private view returns (bool) {
        return address(pool) != address(0);
    }

    /// @custom:ensures _isRoutePair(tokenIn, tokenOut)
    function _requireRoutePair(address tokenIn, address tokenOut) private view {
        if (tokenIn == privateAsset && tokenOut == vaultAsset) return;
        if (tokenIn == vaultAsset && tokenOut == privateAsset) return;
        revert InvalidRoutePair();
    }

    /// The pair is the private asset and the vault asset, in either direction.
    /// @custom:spec
    function _isRoutePair(address tokenIn, address tokenOut) internal view returns (bool) {
        return
            (tokenIn == privateAsset && tokenOut == vaultAsset) || (tokenIn == vaultAsset && tokenOut == privateAsset);
    }

    function _requireBalance(address token, uint256 expected) private view {
        if (IERC20Like(token).balanceOf(address(this)) != expected) revert ResidualBalance();
    }

    /// @custom:ensures result == value
    /// @custom:succeeds-if value <= type(uint128).max
    function _toUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert AmountOverflow();
        // The explicit bound above makes this narrowing conversion lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    /// @dev A standing maximum allowance for an immutable spender (the EarnVault, pool or Zone Portal): Tempo charges every
    ///      zero-to-nonzero allowance as a new storage slot, and every operation returns this router's touched
    ///      balances to their baseline, so none is left to pull.
    function _approveStanding(address token, address spender, uint256 amount) private {
        /// @custom:ghost standingGhost[token][spender] = true
        if (IERC20Allowance(token).allowance(address(this), spender) < amount) {
            _callOptionalReturn(token, abi.encodeCall(IERC20Like.approve, (spender, 0)));
            _callOptionalReturn(token, abi.encodeCall(IERC20Like.approve, (spender, type(uint256).max)));
        }
    }

    function _callOptionalReturn(address token, bytes memory data) private {
        (bool ok, bytes memory returnData) = token.call(data);
        /// @custom:ghost lastCallOk = ok
        /// @custom:ghost lastCallReturnedData = returnData.length != 0
        /// @custom:ghost lastCallReturnedTrue = returnData.length != 0 && abi.decode(returnData, (bool))
        if (!ok) revert TokenCallFailed();
        if (returnData.length != 0 && !abi.decode(returnData, (bool))) revert TokenCallFalse();
        /// A token call is accepted only if it succeeded and returned nothing or true.
        /// @custom:assert lastCallOk && (lastCallReturnedData ==> lastCallReturnedTrue)
    }
}
