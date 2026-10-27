// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ISpendSettler } from "./interfaces/ISpendSettler.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";
import { IPropAMMPriceOracle, IPropAMMVenue } from "tempo-earn/interfaces/external/propamm/IPropAMMVenue.sol";

/// @title SendSettler
/// @notice Settles a Zone router's Spend op by paying a public address exactly `amount` of a token: the
///         withdrawn token itself (a stablecoin or EarnShare), the vault asset redeemed from EarnShare,
///         or a stablecoin converted from that asset at par.
/// @dev Specified in docs/router/zone-router.md#sendsettler. It has no owner and no setters; its only
///      setting is an optional par-conversion pool fixed at deployment. A router allows sends only if its
///      mode lists this settler. The router transfers `maxInput` before calling `settle`; the settler
///      pays, hands every unused unit straight back and keeps nothing. Whoever builds the callback picks
///      the vault and recipient and spends only their own input, which the router caps at `maxInput`.
///      Tokens sent here outside a `settle` call are not rescued: a later `settle` caller can spend them
///      and gets back what its send did not use. It neither emits nor stores the Zone's sender commitment.
contract SendSettler is ISpendSettler {
    /// @notice One send: `to` receives exactly `amount` of `token`.
    /// @dev With `vault` zero, `token` is the withdrawn token. Otherwise the input is `vault`'s
    ///      EarnShare, redeemed with `withdrawExact` into `token`, which is the vault asset or, through
    ///      `pool`, the stablecoin it pairs with at par. `ref` is the sender's own reference.
    struct Send {
        address to;
        address token;
        uint128 amount;
        address vault;
        bytes32 ref;
    }

    /// @notice The DirectPropAMM pool for par conversion from a vault asset; zero when sends never convert.
    IPropAMMVenue public immutable pool;
    /// @notice The pool rounding route and trade-memo customer identifier; zero without a pool.
    bytes32 public immutable customerId;

    uint256 private locked = 1;

    error DestinationNotPaid();
    error InsufficientInput();
    error InvalidAmount();
    error InvalidPool();
    error InvalidRoutePair();
    error NothingSettled();
    error Reentrancy();
    error ResidualBalance(address token);
    error TokenCallFailed();
    error TokenCallFalse();
    error WrongInputToken(address token);
    error ZeroAddress();

    /// @notice A send settled. Carries no Zone sender commitment or Zone account.
    event SendSettled(
        bytes32 indexed ref,
        address indexed to,
        address inputToken,
        address outputToken,
        uint256 amount,
        uint256 inputConsumed,
        uint256 inputReturned
    );

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    /// @param pool_ The par-conversion pool, or zero for a settler that only sends and redeems.
    /// @param customerId_ The pool customer identifier; zero exactly when `pool_` is zero.
    constructor(IPropAMMVenue pool_, bytes32 customerId_) {
        if ((address(pool_) == address(0)) != (customerId_ == bytes32(0))) revert InvalidPool();
        if (address(pool_) != address(0) && address(pool_).code.length == 0) revert InvalidPool();
        pool = pool_;
        customerId = customerId_;
    }

    /// @inheritdoc ISpendSettler
    /// @dev `data` is `abi.encode(Send)`.
    function settle(address token, uint256 maxInput, bytes calldata data) external override nonReentrant {
        _settle(token, maxInput, abi.decode(data, (Send)));
    }

    function _settle(address token, uint256 maxInput, Send memory send) private {
        if (send.to == address(0) || send.token == address(0)) revert ZeroAddress();
        if (send.amount == 0 || maxInput == 0 || maxInput > type(uint128).max) revert InvalidAmount();
        if (send.to == address(this)) revert ZeroAddress();

        // The caller sent maxInput first; anything else held here is the baseline, and none may stay behind.
        uint256 balance = IERC20Like(token).balanceOf(address(this));
        if (balance < maxInput) revert InsufficientInput();
        uint256 baseline = balance - maxInput;
        uint256 outputBaseline = send.token == token ? baseline : IERC20Like(send.token).balanceOf(address(this));
        uint256 paidBefore = IERC20Like(send.token).balanceOf(send.to);

        address asset;
        if (send.vault == address(0)) {
            if (send.token != token) revert WrongInputToken(token);
            if (send.amount > maxInput) revert InvalidAmount();
            _safeTransfer(token, send.to, send.amount);
        } else {
            if (IEarnVault(send.vault).earnShare() != token) revert WrongInputToken(token);
            asset = IEarnVault(send.vault).asset();
            if (send.token == token || asset == token) revert WrongInputToken(token);
            _safeApprove(token, send.vault, maxInput);
            if (send.token == asset) {
                // Every entry point is nonReentrant; the lock is released only after settle returns.
                // forge-lint: disable-next-line(reentrancy-no-eth)
                IEarnVault(send.vault).withdrawExact(send.amount, send.to, maxInput);
            } else {
                uint256 assetBefore = IERC20Like(asset).balanceOf(address(this));
                // Every entry point is nonReentrant; the lock is released only after settle returns.
                // forge-lint: disable-next-line(reentrancy-no-eth)
                IEarnVault(send.vault).withdrawExact(send.amount, address(this), maxInput);
                if (IERC20Like(asset).balanceOf(address(this)) != assetBefore + send.amount) {
                    revert InsufficientInput();
                }
                _convertAtPar(asset, send.token, send.amount);
                if (IERC20Like(asset).balanceOf(address(this)) != assetBefore) revert ResidualBalance(asset);
                _safeTransfer(send.token, send.to, send.amount);
            }
            _safeApprove(token, send.vault, 0);
        }

        // Checked on the recipient, so a vault or pool that reports success without paying cannot settle.
        if (IERC20Like(send.token).balanceOf(send.to) != paidBefore + send.amount) revert DestinationNotPaid();

        uint256 unused = IERC20Like(token).balanceOf(address(this)) - baseline;
        if (unused >= maxInput) revert NothingSettled();
        if (unused != 0) _safeTransfer(token, msg.sender, unused);
        if (IERC20Like(token).balanceOf(address(this)) != baseline) revert ResidualBalance(token);
        if (send.token != token && IERC20Like(send.token).balanceOf(address(this)) != outputBaseline) {
            revert ResidualBalance(send.token);
        }

        emit SendSettled(send.ref, send.to, token, send.token, send.amount, maxInput - unused, unused);
    }

    /// @notice The pool's par price, or zero without a pool.
    function parPrice() public view returns (uint256) {
        if (address(pool) == address(0)) return 0;
        return 10 ** uint256(IPropAMMPriceOracle(pool.oracle()).decimals());
    }

    /// @dev Swaps exactly `amount` of `tokenIn` for exactly `amount` of `tokenOut` at the oracle's par
    ///      price, into this settler; any other price or output reverts.
    function _convertAtPar(address tokenIn, address tokenOut, uint256 amount) private {
        if (address(pool) == address(0)) revert InvalidPool();
        address base = pool.baseToken();
        address quote = pool.quoteToken();
        bool baseToQuote = base == tokenIn && quote == tokenOut;
        if (!baseToQuote && !(base == tokenOut && quote == tokenIn)) revert InvalidRoutePair();
        // Equal units make the par price an exact 1:1 conversion with no rounding remainder.
        if (IERC20Metadata(tokenIn).decimals() != IERC20Metadata(tokenOut).decimals()) revert InvalidRoutePair();

        uint256 outBefore = IERC20Like(tokenOut).balanceOf(address(this));
        _safeApprove(tokenIn, address(pool), amount);
        // Every entry point is nonReentrant; the lock is released only after settle returns.
        // forge-lint: disable-start(reentrancy-no-eth)
        pool.swapExactInput(
            baseToQuote, amount, amount, address(this), customerId, bytes32(0), block.timestamp, parPrice(), 0, 0
        );
        // forge-lint: disable-end(reentrancy-no-eth)
        _safeApprove(tokenIn, address(pool), 0);
        if (IERC20Like(tokenOut).balanceOf(address(this)) != outBefore + amount) revert DestinationNotPaid();
    }

    function _safeApprove(address token, address spender, uint256 value) private {
        _callOptionalReturn(token, abi.encodeCall(IERC20Like.approve, (spender, 0)));
        if (value != 0) _callOptionalReturn(token, abi.encodeCall(IERC20Like.approve, (spender, value)));
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        _callOptionalReturn(token, abi.encodeCall(IERC20Like.transfer, (to, value)));
    }

    function _callOptionalReturn(address token, bytes memory data) private {
        // Every entry point is nonReentrant; the lock is released only after settle returns.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        (bool ok, bytes memory returnData) = token.call(data);
        if (!ok) revert TokenCallFailed();
        if (returnData.length != 0 && !abi.decode(returnData, (bool))) revert TokenCallFalse();
    }
}
