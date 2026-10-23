// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IEarnVault } from "../interfaces/core/IEarnVault.sol";
import { IERC20Like } from "../interfaces/external/IERC20Like.sol";
import { IManagedPropAMMVenue } from "../interfaces/external/propamm/IManagedPropAMMVenue.sol";
import { IPropAMMPriceOracle, IPropAMMVenue } from "../interfaces/external/propamm/IPropAMMVenue.sol";
import {
    EncryptedDepositPayload,
    IWithdrawalReceiver,
    IZoneFactory,
    IZonePortal,
    ZONE_FACTORY_ADDRESS,
    ZONE_MESSENGER_ADDRESS,
    ZoneInfo
} from "../interfaces/external/tempo/IZone.sol";

/// @title SingleZoneEarnRouter
/// @notice Ownerless private Earn router scoped to one Zone, EarnVault, and private asset.
/// @dev A private asset other than the vault asset converts through one immutable PropAMM route at the
///      route's exact par price, with measured output equal to input: a DirectPropAMM pool, or one pair of a
///      ManagedDirectPropAMM pool traded under one sponsor list. A router whose private asset is the vault
///      asset has no pool and deposits and redeems that asset directly.
///      Only authenticated callbacks from the selected Zone can execute either route. Callback data
///      contains no route, token, vault, or destination selection, and every successful result returns
///      through the authenticated source Portal.
contract SingleZoneEarnRouter is IWithdrawalReceiver {
    enum Flow {
        Deposit,
        Redeem
    }

    /// @notice How the router reaches its pool: a single-pair DirectPropAMM, or one pair of a ManagedDirectPropAMM.
    enum PoolKind {
        Direct,
        Managed
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
    /// @notice The only PropAMM pool allowed to convert the private asset pair.
    /// @dev Zero when the private asset is the vault asset and no conversion is needed.
    IPropAMMVenue public immutable pool;
    /// @notice The pool's kind; `Direct` without a pool.
    PoolKind public immutable poolKind;
    /// @notice The converting pair of a Managed pool; zero otherwise.
    uint16 public immutable pairIndex;
    /// @notice The Managed pool list the router trades under (0: the pair's home list); zero otherwise.
    uint64 public immutable sponsorId;
    /// @notice The pool rounding route and trade-memo customer identifier; zero without a pool.
    bytes32 public immutable customerId;
    /// @notice Whether the private asset is the pool's base token; false without a pool.
    bool public immutable privateAssetIsBase;

    uint256 private locked = 1;

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
        if (locked != 1) revert ReentrantCall();
        locked = 2;
        _;
        locked = 1;
    }

    /// @dev Pass `privateAsset_ == earnVault_.asset()` with a zero pool, customer ID, pair, and sponsor for a
    ///      router without conversion. Any other private asset requires its pool and customer ID; a Direct pool
    ///      takes a zero pair and sponsor, and a Managed pool names a live pair and the list to trade under.
    constructor(
        uint32 allowedZoneId_,
        address earnVault_,
        address privateAsset_,
        address pool_,
        bytes32 customerId_,
        PoolKind poolKind_,
        uint16 pairIndex_,
        uint64 sponsorId_
    ) {
        (address vaultAsset_, address earnShare_) = _earnVaultTokens(earnVault_);
        if (privateAsset_ == address(0) || privateAsset_ == earnShare_) revert InvalidPrivateAsset();

        bool privateIsBase;
        if (privateAsset_ == vaultAsset_) {
            // Nothing to convert: a pool or route identifier would be an unused, misleading binding. Keep
            // the earlier `InvalidPrivateAsset` rejection for every such input; only the pool-less form is new.
            if (
                pool_ != address(0) || customerId_ != bytes32(0) || poolKind_ != PoolKind.Direct || pairIndex_ != 0
                    || sponsorId_ != 0
            ) revert InvalidPrivateAsset();
        } else {
            if (pool_ == address(0) || pool_.code.length == 0) revert InvalidPool();
            if (customerId_ == bytes32(0)) revert InvalidCustomerId();

            address base;
            address quote;
            if (poolKind_ == PoolKind.Direct) {
                if (pairIndex_ != 0 || sponsorId_ != 0) revert InvalidPool();
                base = IPropAMMVenue(pool_).baseToken();
                quote = IPropAMMVenue(pool_).quoteToken();
            } else {
                IManagedPropAMMVenue.Pair memory managed = IManagedPropAMMVenue(pool_).pair(pairIndex_);
                // A removed or unknown pair reads `None`; its index is never reused.
                if (managed.access == 0) revert InvalidPool();
                base = managed.base;
                quote = managed.quote;
            }
            privateIsBase = base == privateAsset_ && quote == vaultAsset_;
            if (!privateIsBase && !(base == vaultAsset_ && quote == privateAsset_)) revert InvalidRoutePair();
            // Equal units make the pool's par price an exact 1:1 conversion with no rounding remainder.
            if (IERC20Metadata(privateAsset_).decimals() != IERC20Metadata(vaultAsset_).decimals()) {
                revert InvalidRoutePair();
            }
        }

        allowedZoneId = allowedZoneId_;
        earnVault = earnVault_;
        privateAsset = privateAsset_;
        vaultAsset = vaultAsset_;
        earnShare = earnShare_;
        pool = IPropAMMVenue(pool_);
        poolKind = poolKind_;
        pairIndex = pairIndex_;
        sponsorId = sponsorId_;
        customerId = customerId_;
        privateAssetIsBase = privateIsBase;
    }

    function supportsFlow(uint8 flow) external pure returns (bool) {
        return flow <= uint8(Flow.Redeem);
    }

    /// @notice The oracle price at which one private-asset unit converts to exactly one vault-asset unit.
    /// @dev Zero for a router without a pool, which has no conversion price.
    function parPrice() public view returns (uint256) {
        if (!_converts()) return 0;
        return 10 ** uint256(IPropAMMPriceOracle(_oracle()).decimals());
    }

    /// @notice Pool state and output inventory for each flow, not a guaranteed executable conversion.
    /// @dev Execution also depends on the pool's oracle freshness and deviation guard and on token policy.
    ///      A Managed pool reports its pair `Closed` or removed as paused, and admission as the pair's taker check
    ///      under the router's sponsor list, since its swaps pay the caller.
    ///      `depositLiquidity` is pool vault-asset inventory; `redeemLiquidity` is pool private-asset inventory.
    ///      A router without a pool reports an unpaused, admitted, at-par route with unlimited liquidity,
    ///      because conversion imposes no limit; EarnVault and Portal limits still apply.
    function liquidityStatus()
        external
        view
        returns (bool paused, bool admitted, bool atPar, uint256 depositLiquidity, uint256 redeemLiquidity)
    {
        if (!_converts()) return (false, true, true, type(uint256).max, type(uint256).max);
        if (poolKind == PoolKind.Direct) {
            paused = pool.paused();
            admitted = pool.takerAllowed(address(this)) && pool.recipientAllowed(address(this))
                && pool.resolveRecipient(address(this)) == address(this);
        } else {
            IManagedPropAMMVenue managed = IManagedPropAMMVenue(address(pool));
            uint8 access = managed.pair(pairIndex).access;
            // `None` is a removed pair and `Closed` (1) the pair's own pause.
            paused = managed.paused() || access <= 1;
            admitted = managed.takerAllowed(pairIndex, address(this), sponsorId);
        }
        try IPropAMMPriceOracle(_oracle()).latestPrice() returns (uint256 price, uint256) {
            atPar = price == parPrice();
        } catch { }
        depositLiquidity = IERC20Like(vaultAsset).balanceOf(address(pool));
        redeemLiquidity = IERC20Like(privateAsset).balanceOf(address(pool));
    }

    function onWithdrawalReceived(
        uint32 sourceZoneId,
        address sourcePortal,
        bytes32,
        address token,
        uint128 amount,
        bytes calldata callbackData
    ) external override nonReentrant returns (bytes4) {
        if (allowedZoneId == 0 || sourceZoneId != allowedZoneId) revert WrongSourceZone();
        _validateWithdrawal(sourceZoneId, sourcePortal, amount);
        uint256 inputBalanceBefore = IERC20Like(token).balanceOf(address(this)) - amount;

        uint256 rawFlow = _decodeRawFlow(callbackData);
        if (rawFlow > uint256(Flow.Redeem)) revert BadFlow();
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

        _safeApprove(vaultAsset, earnVault, vaultAssets);
        uint256 earnShares = IEarnVault(earnVault).deposit(vaultAssets, address(this), operation.minEarnShares);
        _safeApprove(vaultAsset, earnVault, 0);
        if (earnShares == 0 || earnShares < operation.minEarnShares) revert InsufficientOutput();

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

        _safeApprove(earnShare, earnVault, amount);
        uint256 vaultAssets = IEarnVault(earnVault).redeem(amount, address(this), operation.minVaultAssets);
        _safeApprove(earnShare, earnVault, 0);
        if (vaultAssets == 0 || vaultAssets < operation.minVaultAssets) revert InsufficientOutput();

        uint256 outputAmount = _converts()
            ? _swap(vaultAsset, privateAsset, vaultAssets, operation.minOutputAmount, operation.actionId)
            : vaultAssets;
        if (outputAmount == 0 || outputAmount < operation.minOutputAmount) revert InsufficientOutput();

        bytes32 zoneDepositHash =
            _depositEncryptedToSourceZone(sourcePortal, privateAsset, _toUint128(outputAmount), zoneReturn);
        _requireBalance(privateAsset, outputBalanceBefore);
        emit EarnRedeem(operation.actionId, earnVault, privateAsset, amount, vaultAssets, outputAmount, zoneDepositHash);
    }

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
        _safeApprove(tokenIn, address(pool), amountIn);
        // The measured output delta below is authoritative, not the pool's reported amount.
        if (poolKind == PoolKind.Direct) {
            pool.swapExactInput(
                baseToQuote, amountIn, amountIn, address(this), customerId, actionId, block.timestamp, parPrice(), 0, 0
            );
        } else {
            // A Managed swap pays its caller, so the router is both taker and recipient.
            IManagedPropAMMVenue(address(pool))
                .swapExactInput(
                    pairIndex,
                    baseToQuote,
                    amountIn,
                    amountIn,
                    sponsorId,
                    customerId,
                    actionId,
                    block.timestamp,
                    parPrice(),
                    0,
                    0
                );
        }
        _safeApprove(tokenIn, address(pool), 0);

        uint256 outputBalanceAfter = IERC20Like(tokenOut).balanceOf(address(this));
        if (outputBalanceAfter <= outputBalanceBefore) revert InsufficientOutput();
        amountOut = outputBalanceAfter - outputBalanceBefore;
        if (amountOut != amountIn) revert InsufficientOutput();
        _requireBalance(tokenIn, inputBalanceBefore);
    }

    function _validateWithdrawal(uint32 sourceZoneId, address sourcePortal, uint128 amount) private view {
        if (msg.sender != ZONE_MESSENGER_ADDRESS) revert NotZoneMessenger();
        ZoneInfo memory zone = IZoneFactory(ZONE_FACTORY_ADDRESS).zones(sourceZoneId);
        if (zone.portal != sourcePortal || !IZoneFactory(ZONE_FACTORY_ADDRESS).isZonePortal(sourcePortal)) {
            revert InvalidSourcePortal();
        }
        if (amount == 0) revert ZeroAmount();
    }

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
        _safeApprove(token, sourcePortal, amount);
        hash = IZonePortal(sourcePortal)
            .depositEncrypted(token, amount, zoneReturn.keyIndex, zoneReturn.encrypted, zoneReturn.refundRecipient);
        _safeApprove(token, sourcePortal, 0);
    }

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
    function _converts() private view returns (bool) {
        return address(pool) != address(0);
    }

    /// @dev The converting route's oracle: the Direct pool's, or the Managed pair's, which changes only while
    ///      the pair is `Closed`.
    function _oracle() private view returns (address) {
        if (poolKind == PoolKind.Direct) return pool.oracle();
        return IManagedPropAMMVenue(address(pool)).pair(pairIndex).oracle;
    }

    function _requireRoutePair(address tokenIn, address tokenOut) private view {
        if (tokenIn == privateAsset && tokenOut == vaultAsset) return;
        if (tokenIn == vaultAsset && tokenOut == privateAsset) return;
        revert InvalidRoutePair();
    }

    function _requireBalance(address token, uint256 expected) private view {
        if (IERC20Like(token).balanceOf(address(this)) != expected) revert ResidualBalance();
    }

    function _toUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert AmountOverflow();
        // The explicit bound above makes this narrowing conversion lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    function _safeApprove(address token, address spender, uint256 value) private {
        _callOptionalReturn(token, abi.encodeCall(IERC20Like.approve, (spender, 0)));
        if (value != 0) _callOptionalReturn(token, abi.encodeCall(IERC20Like.approve, (spender, value)));
    }

    function _callOptionalReturn(address token, bytes memory data) private {
        (bool ok, bytes memory returnData) = token.call(data);
        if (!ok) revert TokenCallFailed();
        if (returnData.length != 0 && !abi.decode(returnData, (bool))) revert TokenCallFalse();
    }
}
