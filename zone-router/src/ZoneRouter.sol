// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IERC20Allowance } from "./interfaces/IERC20Allowance.sol";
import { ISpender } from "./interfaces/ISpender.sol";
import { IZonePortalFees } from "./interfaces/IZonePortalFees.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";
import { IPropAMMPriceOracle, IPropAMMVenue } from "tempo-earn/interfaces/external/propamm/IPropAMMVenue.sol";
import {
    EncryptedDepositPayload,
    IWithdrawalReceiver,
    IZoneFactory,
    IZonePortal,
    ZONE_FACTORY_ADDRESS,
    ZONE_MESSENGER_ADDRESS,
    ZoneInfo
} from "tempo-earn/interfaces/external/tempo/IZone.sol";

/// @title ZoneRouter
/// @notice Ownerless router for one Zone's withdrawal callbacks: Earn deposits and redemptions, and spends
///         through spenders fixed at deployment.
/// @dev Specified in docs/zone-router/zone-router.md. Every setting is fixed by the constructor; a different
///      mode is a new router. Ops 0 and 1 keep SingleZoneEarnRouter's callback layout and behavior. Op 2
///      (Spend) transfers exactly the sender's `maxInput` to a listed spender, measures what it used once
///      the spender hands back the rest, and returns the change to the source Zone, so no spender can take
///      more than the sender allowed.
contract ZoneRouter is IWithdrawalReceiver {
    enum Op {
        Deposit,
        Redeem,
        Spend
    }

    uint8 public constant OP_DEPOSIT = 1 << 0;
    uint8 public constant OP_REDEEM = 1 << 1;
    uint8 public constant OP_SPEND = 1 << 2;
    uint8 private constant ALL_OPS = OP_DEPOSIT | OP_REDEEM | OP_SPEND;

    /// @notice A router's complete, immutable configuration.
    /// @dev Earn ops require the Earn bindings and forbid them otherwise; Spend requires spenders and
    ///      forbids them otherwise. Spender order is part of the mode and so of its factory address.
    struct Mode {
        uint32 zoneId;
        uint8 enabledOps;
        address earnVault;
        address privateAsset;
        address pool;
        bytes32 customerId;
        address[] spenders;
    }

    /// @notice Ops 0 and 1: encrypted return data without a caller-selected Portal.
    struct ZoneReturn {
        uint256 keyIndex;
        EncryptedDepositPayload encrypted;
        address refundRecipient;
    }

    /// @notice Ops 0 and 1, byte-identical to SingleZoneEarnRouter's callback data.
    struct CallbackData {
        Op op;
        uint128 minVaultAssets;
        uint128 minEarnShares;
        uint128 minOutputAmount;
        bytes32 actionId;
        ZoneReturn zoneReturn;
    }

    /// @notice Op 2's return of unused input, with a cap on the Portal's deposit fee.
    struct SpendReturn {
        uint256 keyIndex;
        EncryptedDepositPayload encrypted;
        address refundRecipient;
        uint128 maxDepositFee;
    }

    /// @notice Op 2: the spender, the most input it may use, its own data, and the change return.
    /// @dev Size `maxInput` so the change is zero or at least the Portal's deposit fee plus bounce-back reserve.
    struct SpendData {
        Op op;
        address spender;
        uint128 maxInput;
        bytes spenderData;
        SpendReturn zoneReturn;
    }

    struct Operation {
        uint128 minVaultAssets;
        uint128 minEarnShares;
        uint128 minOutputAmount;
        bytes32 actionId;
    }

    /// @notice The only accepted source Zone.
    uint32 public immutable allowedZoneId;
    /// @notice That Zone's Portal, read once from the Zone factory: a Zone's Portal never changes.
    address public immutable portal;
    /// @notice Bitmask of OP_DEPOSIT, OP_REDEEM and OP_SPEND.
    uint8 public immutable enabledOps;
    /// @notice The only EarnVault this router uses; zero without Earn ops.
    address public immutable earnVault;
    /// @notice The private stablecoin for Earn ops; zero without Earn ops.
    address public immutable privateAsset;
    /// @notice The EarnVault base asset; zero without Earn ops.
    address public immutable vaultAsset;
    /// @notice The EarnShare; zero without Earn ops.
    address public immutable earnShare;
    /// @notice The DirectPropAMM pool converting the private asset at par; zero when none is needed.
    IPropAMMVenue public immutable pool;
    /// @notice The pool rounding route and trade-memo customer identifier; zero without a pool.
    bytes32 public immutable customerId;
    /// @notice Whether the private asset is the pool's base token; false without a pool.
    bool public immutable privateAssetIsBase;

    /// @notice Spenders Spend may use, written once by the constructor.
    mapping(address spender => bool listed) public isSpender;
    address[] private spenderList;

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
    /// @notice A Spend settled. Carries no senderTag, action ID or Zone account.
    /// @dev Not proof of a Zone spend by itself: bind it to the source Portal's `WithdrawalProcessed` for this
    ///      router in the same transaction.
    event Spent(address indexed spender, address indexed token, uint256 used, uint256 change, bytes32 zoneDepositHash);

    error AmountOverflow();
    error BadFlow();
    /// @notice A Spend's nonzero change is below the Portal's minimum deposit, its deposit fee plus its
    ///         bounce-back reserve, so its return would revert.
    error ChangeBelowDepositFee(uint256 change, uint256 fee);
    error DepositFeeTooHigh(uint128 fee);
    error InsufficientOutput();
    error InvalidCustomerId();
    error InvalidEarnBinding();
    error InvalidEarnVault();
    error InvalidMaxInput();
    error InvalidOps();
    error InvalidPool();
    error InvalidPrivateAsset();
    error InvalidReturnToken();
    error InvalidRoutePair();
    error InvalidSpend();
    error InvalidSpenders();
    error InvalidSourcePortal();
    error NotZoneMessenger();
    error OpDisabled();
    error ReentrantCall();
    error ResidualBalance();
    error TokenCallFailed();
    error TokenCallFalse();
    error UnknownSpender();
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

    constructor(Mode memory mode) {
        if (mode.zoneId == 0) revert WrongSourceZone();
        address portal_ = IZoneFactory(ZONE_FACTORY_ADDRESS).zones(mode.zoneId).portal;
        if (portal_ == address(0) || !IZoneFactory(ZONE_FACTORY_ADDRESS).isZonePortal(portal_)) {
            revert InvalidSourcePortal();
        }
        if (mode.enabledOps == 0 || mode.enabledOps & ~ALL_OPS != 0) revert InvalidOps();

        address vaultAsset_;
        address earnShare_;
        bool privateIsBase;
        if (mode.enabledOps & (OP_DEPOSIT | OP_REDEEM) != 0) {
            (vaultAsset_, earnShare_, privateIsBase) =
                _validateEarn(mode.earnVault, mode.privateAsset, mode.pool, mode.customerId);
        } else if (
            mode.earnVault != address(0) || mode.privateAsset != address(0) || mode.pool != address(0)
                || mode.customerId != bytes32(0)
        ) {
            revert InvalidEarnBinding();
        }
        earnVault = mode.earnVault;
        privateAsset = mode.privateAsset;
        vaultAsset = vaultAsset_;
        earnShare = earnShare_;
        pool = IPropAMMVenue(mode.pool);
        customerId = mode.customerId;
        privateAssetIsBase = privateIsBase;

        bool spends = mode.enabledOps & OP_SPEND != 0;
        if (spends != (mode.spenders.length != 0)) revert InvalidSpenders();
        for (uint256 i = 0; i < mode.spenders.length; i++) {
            address spender = mode.spenders[i];
            if (spender == address(0) || spender.code.length == 0 || isSpender[spender]) revert InvalidSpenders();
            isSpender[spender] = true;
            spenderList.push(spender);
        }

        allowedZoneId = mode.zoneId;
        portal = portal_;
        enabledOps = mode.enabledOps;
    }

    /// @notice The spenders Spend may use, in deployment order.
    function spenders() external view returns (address[] memory) {
        return spenderList;
    }

    /// @notice Sets the router's standing approval of `token` to its Zone's Portal, which a spend's
    ///         change would otherwise set on its first callback. Earn ops then use it too. Permissionless:
    ///         the router holds no balance between callbacks, and the Portal is the Zone's own.
    ///         Only a router that spends has one: an Earn-only router keeps SingleZoneEarnRouter's exact approvals.
    /// @dev Invariant: the Portal moves the router's tokens only inside a `depositEncrypted` call the router makes.
    function warm(address token) external {
        if (enabledOps & OP_SPEND == 0) revert OpDisabled();
        _approvePortal(token, portal, type(uint256).max);
    }

    function supportsFlow(uint8 flow) external view returns (bool) {
        return flow <= uint8(Op.Spend) && enabledOps & (1 << flow) != 0;
    }

    /// @notice The oracle price at which one private-asset unit converts to exactly one vault-asset unit.
    /// @dev Zero for a router without a pool, which has no conversion price.
    function parPrice() public view returns (uint256) {
        if (!_converts()) return 0;
        return 10 ** uint256(IPropAMMPriceOracle(pool.oracle()).decimals());
    }

    /// @notice Pool state and output inventory for each Earn op, as SingleZoneEarnRouter reports it.
    /// @dev Not a guaranteed executable conversion: execution also depends on the pool's oracle freshness
    ///      and deviation guard and on token policy. A router without a pool, including one without Earn
    ///      ops, reports an unpaused, admitted, at-par route with unlimited liquidity.
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

    function onWithdrawalReceived(
        uint32 sourceZoneId,
        address sourcePortal,
        bytes32,
        address token,
        uint128 amount,
        bytes calldata callbackData
    ) external override nonReentrant returns (bytes4) {
        if (sourceZoneId != allowedZoneId) revert WrongSourceZone();
        _validateWithdrawal(sourceZoneId, sourcePortal, amount);
        uint256 inputBalanceBefore = IERC20Like(token).balanceOf(address(this)) - amount;

        uint256 rawOp = _decodeRawOp(callbackData);
        if (rawOp > uint256(Op.Spend)) revert BadFlow();
        if (enabledOps & (1 << rawOp) == 0) revert OpDisabled();

        if (Op(rawOp) == Op.Spend) {
            _handleSpend(sourcePortal, token, amount, abi.decode(callbackData, (SpendData)));
        } else {
            CallbackData memory data = abi.decode(callbackData, (CallbackData));
            Operation memory operation = Operation({
                minVaultAssets: data.minVaultAssets,
                minEarnShares: data.minEarnShares,
                minOutputAmount: data.minOutputAmount,
                actionId: data.actionId
            });
            if (Op(rawOp) == Op.Deposit) {
                if (token != privateAsset) revert WrongInputToken();
                _handleDeposit(sourcePortal, token, amount, data.zoneReturn, operation);
            } else {
                if (token != earnShare) revert WrongInputToken();
                _handleRedeem(sourcePortal, amount, data.zoneReturn, operation);
            }
        }

        _requireBalance(token, inputBalanceBefore);
        return IWithdrawalReceiver.onWithdrawalReceived.selector;
    }

    function _handleSpend(address sourcePortal, address token, uint128 amount, SpendData memory data) private {
        if (!isSpender[data.spender]) revert UnknownSpender();
        if (data.maxInput == 0 || data.maxInput > amount) revert InvalidMaxInput();
        if (data.zoneReturn.refundRecipient == address(0)) revert ZeroAddress();
        // A maxInput below the amount always leaves change, so its return is checked before the spender pays.
        // The fee is checked again once it has paid, since the Portal's fee may change while the spender runs.
        bool returnChecked = data.maxInput < amount;
        if (returnChecked) _checkChangeReturn(sourcePortal, token, data.zoneReturn.maxDepositFee);

        uint256 balanceBefore = IERC20Like(token).balanceOf(address(this));
        // A transfer instead of an approval: the spender holds no allowance from the router, so it can
        // never take more than maxInput, and no router -> spender allowance slot is written.
        _safeTransfer(token, data.spender, data.maxInput);
        ISpender(data.spender).spendFrom(token, data.maxInput, data.spenderData);
        uint256 balanceAfter = IERC20Like(token).balanceOf(address(this));

        // A spender that used nothing, or handed back more than it was sent, must not look settled.
        if (balanceAfter >= balanceBefore) revert InvalidSpend();
        uint256 used = balanceBefore - balanceAfter;
        if (used > data.maxInput) revert InvalidSpend();

        uint256 change = amount - used;
        bytes32 zoneDepositHash;
        if (change != 0) {
            uint128 fee = returnChecked
                ? _checkDepositFee(sourcePortal, data.zoneReturn.maxDepositFee)
                : _checkChangeReturn(sourcePortal, token, data.zoneReturn.maxDepositFee);
            // The Portal's depositEncrypted reverts DepositTooSmall below this; named here for the sender.
            uint256 minimum = uint256(fee) + IZonePortalFees(sourcePortal).calculateBouncebackFee();
            if (change < minimum) revert ChangeBelowDepositFee(change, minimum);
            _approvePortal(token, sourcePortal, change);
            zoneDepositHash = IZonePortal(sourcePortal)
                .depositEncrypted(
                    token,
                    _toUint128(change),
                    data.zoneReturn.keyIndex,
                    data.zoneReturn.encrypted,
                    data.zoneReturn.refundRecipient
                );
        }
        emit Spent(data.spender, token, used, change, zoneDepositHash);
    }

    /// @dev Requires the Portal to take `token` back and its deposit fee to be within the sender's cap.
    function _checkChangeReturn(address sourcePortal, address token, uint128 maxDepositFee)
        private
        view
        returns (uint128 fee)
    {
        if (!IZonePortal(sourcePortal).isTokenEnabled(token) || !IZonePortal(sourcePortal).areDepositsActive(token)) {
            revert InvalidReturnToken();
        }
        fee = _checkDepositFee(sourcePortal, maxDepositFee);
    }

    /// @dev Requires the Portal's deposit fee to be within the sender's cap.
    function _checkDepositFee(address sourcePortal, uint128 maxDepositFee) private view returns (uint128 fee) {
        fee = IZonePortalFees(sourcePortal).calculateDepositFee();
        if (fee > maxDepositFee) revert DepositFeeTooHigh(fee);
    }

    function _handleDeposit(
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

        bytes32 zoneDepositHash = _depositEncrypted(sourcePortal, earnShare, _toUint128(earnShares), zoneReturn);
        _requireBalance(earnShare, earnShareBalanceBefore);
        emit EarnDeposit(operation.actionId, earnVault, token, amount, vaultAssets, earnShares, zoneDepositHash);
    }

    function _handleRedeem(
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

        bytes32 zoneDepositHash = _depositEncrypted(sourcePortal, privateAsset, _toUint128(outputAmount), zoneReturn);
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
        // freshness and deviation guards.
        _safeApprove(tokenIn, address(pool), amountIn);
        // The measured output delta below is authoritative, not the pool's reported amount.
        pool.swapExactInput(
            baseToQuote, amountIn, amountIn, address(this), customerId, actionId, block.timestamp, parPrice(), 0, 0
        );
        _safeApprove(tokenIn, address(pool), 0);

        uint256 outputBalanceAfter = IERC20Like(tokenOut).balanceOf(address(this));
        if (outputBalanceAfter <= outputBalanceBefore) revert InsufficientOutput();
        amountOut = outputBalanceAfter - outputBalanceBefore;
        if (amountOut != amountIn) revert InsufficientOutput();
        _requireBalance(tokenIn, inputBalanceBefore);
    }

    function _validateEarn(address earnVault_, address privateAsset_, address pool_, bytes32 customerId_)
        private
        view
        returns (address vaultAsset_, address earnShare_, bool privateIsBase)
    {
        if (earnVault_ == address(0) || earnVault_.code.length == 0) revert InvalidEarnVault();
        vaultAsset_ = IEarnVault(earnVault_).asset();
        earnShare_ = IEarnVault(earnVault_).earnShare();
        if (vaultAsset_ == address(0) || earnShare_ == address(0)) revert InvalidEarnVault();
        if (privateAsset_ == address(0) || privateAsset_ == earnShare_) revert InvalidPrivateAsset();

        if (privateAsset_ == vaultAsset_) {
            if (pool_ != address(0) || customerId_ != bytes32(0)) revert InvalidPrivateAsset();
        } else {
            if (pool_ == address(0) || pool_.code.length == 0) revert InvalidPool();
            if (customerId_ == bytes32(0)) revert InvalidCustomerId();
            IPropAMMVenue venue = IPropAMMVenue(pool_);
            address base = venue.baseToken();
            address quote = venue.quoteToken();
            privateIsBase = base == privateAsset_ && quote == vaultAsset_;
            if (!privateIsBase && !(base == vaultAsset_ && quote == privateAsset_)) revert InvalidRoutePair();
            // Equal units make the pool's par price an exact 1:1 conversion with no rounding remainder.
            if (IERC20Metadata(privateAsset_).decimals() != IERC20Metadata(vaultAsset_).decimals()) {
                revert InvalidRoutePair();
            }
        }
    }

    function _validateWithdrawal(uint32 sourceZoneId, address sourcePortal, uint128 amount) private view {
        if (msg.sender != ZONE_MESSENGER_ADDRESS) revert NotZoneMessenger();
        // The messenger relays only from the Zone's registered Portal, which the constructor read once.
        if (sourcePortal != portal) revert InvalidSourcePortal();
        if (amount == 0) revert ZeroAmount();
    }

    function _validateSourceReturn(address sourcePortal, address token, ZoneReturn memory zoneReturn) private view {
        if (zoneReturn.refundRecipient == address(0)) revert ZeroAddress();
        if (!IZonePortal(sourcePortal).isTokenEnabled(token) || !IZonePortal(sourcePortal).areDepositsActive(token)) {
            revert InvalidReturnToken();
        }
    }

    function _depositEncrypted(address sourcePortal, address token, uint128 amount, ZoneReturn memory zoneReturn)
        private
        returns (bytes32 hash)
    {
        // A standing approval a spend or `warm` left is used and kept, so an Earn op on a router that
        // also spends never clears it. Without one, the op keeps SingleZoneEarnRouter's exact approval,
        // cleared after the deposit, so an Earn-only router behaves exactly like it.
        bool standing = IERC20Allowance(token).allowance(address(this), sourcePortal) > type(uint128).max;
        if (!standing) _safeApprove(token, sourcePortal, amount);
        hash = IZonePortal(sourcePortal)
            .depositEncrypted(token, amount, zoneReturn.keyIndex, zoneReturn.encrypted, zoneReturn.refundRecipient);
        if (!standing) _safeApprove(token, sourcePortal, 0);
    }

    function _decodeRawOp(bytes calldata callbackData) private pure returns (uint256 rawOp) {
        if (callbackData.length < 32) revert BadFlow();
        uint256 tupleOffset = abi.decode(callbackData, (uint256));
        if (tupleOffset > callbackData.length || callbackData.length - tupleOffset < 32) revert BadFlow();
        assembly {
            rawOp := calldataload(add(callbackData.offset, tupleOffset))
        }
    }

    function _converts() private view returns (bool) {
        return address(pool) != address(0);
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

    /// @dev Leaves a standing maximum approval to the Portal, topped up only when it falls below `amount`.
    ///      Clearing it after each deposit would create its allowance slot again on every callback, which
    ///      Tempo charges as a new storage slot (TIP-1000) against the callback's gas limit. Safe only under the
    ///      invariant that the Portal moves the router's tokens only inside a `depositEncrypted` call the router makes.
    function _approvePortal(address token, address portal, uint256 amount) private {
        if (IERC20Allowance(token).allowance(address(this), portal) < amount) {
            _callOptionalReturn(token, abi.encodeCall(IERC20Like.approve, (portal, type(uint256).max)));
        }
    }

    function _safeApprove(address token, address spender, uint256 value) private {
        _callOptionalReturn(token, abi.encodeCall(IERC20Like.approve, (spender, 0)));
        if (value != 0) _callOptionalReturn(token, abi.encodeCall(IERC20Like.approve, (spender, value)));
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        _callOptionalReturn(token, abi.encodeCall(IERC20Like.transfer, (to, value)));
    }

    function _callOptionalReturn(address token, bytes memory data) private {
        (bool ok, bytes memory returnData) = token.call(data);
        if (!ok) revert TokenCallFailed();
        if (returnData.length != 0 && !abi.decode(returnData, (bool))) revert TokenCallFalse();
    }
}
