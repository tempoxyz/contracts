// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ADDRESS_REGISTRY_ADDRESS, IAddressRegistry } from "./interfaces/IAddressRegistry.sol";
import { ISpendSettler } from "./interfaces/ISpendSettler.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";
import { IPropAMMPriceOracle, IPropAMMVenue } from "tempo-earn/interfaces/external/propamm/IPropAMMVenue.sol";

/// @title SendSettler
/// @notice Settles a Zone router's Spend op by paying a public address exactly `amount` of a token: the
///         withdrawn token itself (a stablecoin or EarnShare), a vault asset redeemed from EarnShare, or
///         the stablecoin its bound vault's asset converts into at par.
/// @dev Specified in docs/zone-router/zone-router.md#sendsettler. It has no owner and no setters; its only
///      setting is an optional conversion binding (a vault, its par pool and a customer ID) fixed at
///      deployment. A router allows sends only if its mode lists this settler. The router transfers
///      `maxInput` before calling `settle`; the settler pays, hands every unused unit straight back and
///      keeps nothing. Whoever builds the callback picks the vault and recipient and spends only their own
///      input, which the router caps at `maxInput`; only the bound vault's EarnShare reaches the pool, and
///      only from its asset into the paired stablecoin. Tokens sent here outside a `settle` call are not
///      rescued: a later `settle` caller can spend them and gets back what its send did not use. It
///      neither emits nor stores the Zone's sender commitment.
contract SendSettler is ISpendSettler {
    /// @notice One send: `to` receives exactly `amount` of `token`.
    /// @dev With `vault` zero, `token` is the withdrawn token. Otherwise the input is `vault`'s
    ///      EarnShare, redeemed with `withdrawExact` into `token`, which is the vault asset or, only for
    ///      `convertVault`, `parToken` through `pool`. A virtual `to` (TIP-1022) is paid through its
    ///      registered master. `ref` is the sender's own reference.
    struct Send {
        address to;
        address token;
        uint128 amount;
        address vault;
        bytes32 ref;
    }

    /// @notice The only vault whose asset converts at par; zero when sends never convert.
    IEarnVault public immutable convertVault;
    /// @notice The DirectPropAMM pool pairing `convertAsset` with `parToken`; zero without conversion.
    IPropAMMVenue public immutable pool;
    /// @notice The pool rounding route and trade-memo customer identifier; zero without conversion.
    bytes32 public immutable customerId;
    /// @notice `convertVault`'s asset, the only token the pool converts from; zero without conversion.
    address public immutable convertAsset;
    /// @notice The stablecoin `convertAsset` converts into, the pool's other token; zero without conversion.
    address public immutable parToken;
    bool private immutable assetIsBase;

    uint256 private locked = 1;

    error ConversionNotAllowed();
    error DestinationNotPaid();
    error InsufficientInput();
    error InvalidAmount();
    error InvalidPool();
    error InvalidRoutePair();
    error InvalidVault();
    error NothingSettled();
    error Reentrancy();
    error ResidualBalance(address token);
    error TokenCallFailed();
    error TokenCallFalse();
    error UnresolvedRecipient();
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

    /// @param convertVault_ The vault whose asset converts at par, or zero for a settler that only sends
    ///        and redeems.
    /// @param pool_ The pool pairing that asset with one other stablecoin of equal decimals.
    /// @param customerId_ The pool customer identifier. All three are set, or all three are zero.
    constructor(IEarnVault convertVault_, IPropAMMVenue pool_, bytes32 customerId_) {
        bool converts = address(convertVault_) != address(0);
        if (converts != (address(pool_) != address(0)) || converts != (customerId_ != bytes32(0))) {
            revert InvalidPool();
        }
        address asset;
        address other;
        bool isBase;
        if (converts) {
            if (address(convertVault_).code.length == 0) revert InvalidVault();
            if (address(pool_).code.length == 0) revert InvalidPool();
            asset = convertVault_.asset();
            address earnShare = convertVault_.earnShare();
            if (asset == address(0) || earnShare == address(0)) revert InvalidVault();
            address base = pool_.baseToken();
            address quote = pool_.quoteToken();
            isBase = base == asset;
            if (!isBase && quote != asset) revert InvalidRoutePair();
            other = isBase ? quote : base;
            if (other == address(0) || other == asset || other == earnShare) revert InvalidRoutePair();
            // Equal units make the par price an exact 1:1 conversion with no rounding remainder.
            if (IERC20Metadata(asset).decimals() != IERC20Metadata(other).decimals()) revert InvalidRoutePair();
        }
        convertVault = convertVault_;
        pool = pool_;
        customerId = customerId_;
        convertAsset = asset;
        parToken = other;
        assetIsBase = isBase;
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
        // A TIP-20 transfer to a virtual address credits its master, so that is whose balance must rise.
        address payee = _payee(send.to);
        if (payee == address(0) || payee == address(this)) revert ZeroAddress();

        // The caller sent maxInput first; anything else held here is the baseline, and none may stay behind.
        uint256 balance = IERC20Like(token).balanceOf(address(this));
        if (balance < maxInput) revert InsufficientInput();
        uint256 baseline = balance - maxInput;
        uint256 outputBaseline = send.token == token ? baseline : IERC20Like(send.token).balanceOf(address(this));
        uint256 paidBefore = IERC20Like(send.token).balanceOf(payee);

        if (send.vault == address(0)) {
            if (send.token != token) revert WrongInputToken(token);
            if (send.amount > maxInput) revert InvalidAmount();
            _safeTransfer(token, send.to, send.amount);
        } else {
            if (IEarnVault(send.vault).earnShare() != token) revert WrongInputToken(token);
            address asset = IEarnVault(send.vault).asset();
            if (send.token == token || asset == token) revert WrongInputToken(token);
            bool converts = send.token != asset;
            // Only the bound vault's asset reaches the pool, and only into its paired stablecoin: a
            // caller-chosen vault could report any pair and trade through the pool at par.
            if (converts && (send.vault != address(convertVault) || asset != convertAsset || send.token != parToken)) {
                revert ConversionNotAllowed();
            }
            _safeApprove(token, send.vault, maxInput);
            if (!converts && payee == send.to) {
                // Every entry point is nonReentrant; the lock is released only after settle returns.
                // forge-lint: disable-next-line(reentrancy-no-eth)
                IEarnVault(send.vault).withdrawExact(send.amount, send.to, maxInput);
            } else {
                // Redeemed here first when it converts, or when `to` is virtual: Earn's engines measure the
                // literal receiver, which a virtual address never is, so this settler transfers to it instead.
                uint256 assetBefore = IERC20Like(asset).balanceOf(address(this));
                // Every entry point is nonReentrant; the lock is released only after settle returns.
                // forge-lint: disable-next-line(reentrancy-no-eth)
                IEarnVault(send.vault).withdrawExact(send.amount, address(this), maxInput);
                if (IERC20Like(asset).balanceOf(address(this)) != assetBefore + send.amount) {
                    revert InsufficientInput();
                }
                if (converts) _convertAtPar(send.amount);
                _safeTransfer(send.token, send.to, send.amount);
                if (IERC20Like(asset).balanceOf(address(this)) != assetBefore) revert ResidualBalance(asset);
            }
            _safeApprove(token, send.vault, 0);
        }

        // Checked on the payee, so a vault or pool that reports success without paying cannot settle.
        if (IERC20Like(send.token).balanceOf(payee) != paidBefore + send.amount) revert DestinationNotPaid();

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

    /// @dev Who a transfer to `to` credits: its TIP-1022 master if it is a virtual address, else `to`.
    ///      Without the registry (empty return data) it is `to`; an unregistered virtual address reverts,
    ///      as the transfer would.
    function _payee(address to) private view returns (address) {
        (bool ok, bytes memory returnData) =
            ADDRESS_REGISTRY_ADDRESS.staticcall(abi.encodeCall(IAddressRegistry.resolveRecipient, (to)));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        if (returnData.length == 0) return to;
        if (returnData.length != 32) revert UnresolvedRecipient();
        return abi.decode(returnData, (address));
    }

    /// @dev Swaps exactly `amount` of `convertAsset` for exactly `amount` of `parToken` at the oracle's par
    ///      price, into this settler; any other price or output reverts.
    function _convertAtPar(uint256 amount) private {
        uint256 outBefore = IERC20Like(parToken).balanceOf(address(this));
        _safeApprove(convertAsset, address(pool), amount);
        // Every entry point is nonReentrant; the lock is released only after settle returns.
        // forge-lint: disable-start(reentrancy-no-eth)
        pool.swapExactInput(
            assetIsBase, amount, amount, address(this), customerId, bytes32(0), block.timestamp, parPrice(), 0, 0
        );
        // forge-lint: disable-end(reentrancy-no-eth)
        _safeApprove(convertAsset, address(pool), 0);
        if (IERC20Like(parToken).balanceOf(address(this)) != outBefore + amount) revert DestinationNotPaid();
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
