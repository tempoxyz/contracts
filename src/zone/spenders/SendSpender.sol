// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ADDRESS_REGISTRY_ADDRESS, IAddressRegistry } from "../../interfaces/zone/IAddressRegistry.sol";
import { IERC20Allowance } from "../../interfaces/external/IERC20Allowance.sol";
import { ISpender } from "../../interfaces/zone/ISpender.sol";
import { SpenderAuth } from "./SpenderAuth.sol";
import { IEarnVault } from "../../interfaces/earn/IEarnVault.sol";
import { IEarnVaultWithdrawCallback, IEarnWithdrawCallback } from "../../interfaces/earn/IEarnWithdrawCallback.sol";
import { IERC20Like } from "../../interfaces/external/IERC20Like.sol";
import { IPropAMMPriceOracle, IPropAMMVenue } from "../../interfaces/external/propamm/IPropAMMVenue.sol";

/// @title SendSpender
/// @notice Settles a Zone router's Spend op by paying a public address exactly `amount` of a token: the
///         withdrawn token itself (a stablecoin or EarnShare), a vault asset redeemed from EarnShare, or
///         the stablecoin its bound vault's asset converts into at par.
/// @dev Specified in docs/zone/zone-router.md#sendspender. It has no owner and no setters; its
///      settings, fixed at deployment, are the router factory it trusts and an optional conversion binding
///      (a vault, its par pool and a customer ID). Only a router that factory deployed, and whose mode lists
///      this spender, may call `spendFrom`. The router transfers `maxInput` before calling it; the spender
///      pays and hands every unused unit straight back. Whoever builds the callback picks the vault and
///      recipient and spends only their own input, which the router caps at `maxInput`; only the bound
///      vault's EarnShare reaches the pool, and only from its asset into the paired stablecoin. With a
///      conversion binding it keeps a standing maximum `convertAsset` allowance to its immutable pool. A vault
///      that reports the callback withdrawal is paid by transfer inside {earnWithdrawCallback}; any other vault
///      gets an exact approval cleared afterward. Tokens sent here outside a router's spend are not rescued; only
///      that pool could pull stranded `convertAsset`. It neither emits nor stores the Zone's sender commitment.
/// @custom:reentrancy-guard locked
/// gAllowance tracks temporary allowances only; the standing allowance to the immutable pool is outside it.
/// @custom:ghost mapping(address => mapping(address => uint256)) gAllowance
/// @custom:ghost mapping(address => mapping(address => uint256)) gSent
/// @custom:ghost uint256 gPaidBefore
/// @custom:ghost uint256 gReturnedBefore
/// @custom:invariant ROUTER_FACTORY != address(0)
/// @custom:invariant (address(convertVault) != address(0)) == (address(pool) != address(0))
/// @custom:invariant (address(convertVault) != address(0)) == (customerId != bytes32(0))
/// @custom:invariant address(convertVault) != address(0) ==> convertAsset != address(0) && parToken != address(0)
/// @custom:invariant address(convertVault) != address(0) ==> parToken != convertAsset
/// @custom:invariant address(convertVault) == address(0) ==> convertAsset == address(0) && parToken == address(0)
/// @custom:invariant address(convertVault) == address(0) ==> !assetIsBase
contract SendSpender is ISpender, IEarnWithdrawCallback {
    /// @notice One send: `to` receives exactly `amount` of `token`.
    /// @dev With `vault` zero, `token` is the withdrawn token. Otherwise the input is `vault`'s
    ///      EarnShare, redeemed exactly (through the vault's callback when it has one) into `token`, which is
    ///      the vault asset or, only for `convertVault`, `parToken` through `pool`. A virtual `to` (TIP-1022)
    ///      is paid through its registered master. `ref` is the sender's own reference.
    struct Send {
        address to;
        address token;
        uint128 amount;
        address vault;
        bytes32 ref;
    }

    /// @notice The ZoneRouterFactory whose routers, listing this spender, may call `spendFrom`.
    address public immutable ROUTER_FACTORY;
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
    /// @dev EarnVault's error when a burn exceeds its cap; under the callback the cap is the vault's own quote.
    bytes4 private constant EXCEEDS_MAX_EARN_SHARES = 0xee29738d; // ExceedsMaxEarnShares()

    /// @dev Routers already proved to be `ROUTER_FACTORY`'s and to list this spender, by {warmRouter}. Both facts are
    ///      fixed for good (a router has no setters and the factory never forgets one), so a spend reads this one
    ///      slot instead of asking the factory and the router again.
    mapping(address router => bool listed) private warmRouters;

    bool private transient locked;
    /// @dev Set only while a redemption waits on {earnWithdrawCallback}: the vault that may call it, the
    ///      EarnShare it pays and the most it may pay.
    address private transient callbackVault;
    address private transient callbackShare;
    uint256 private transient callbackMax;

    error ConversionNotAllowed();
    error DestinationNotPaid();
    error InsufficientInput();
    error InvalidAmount();
    error InvalidPool();
    error InvalidRecipient();
    error InvalidRouterFactory();
    error InvalidRoutePair();
    error InvalidVault();
    error NothingSpent();
    error NotRouter();
    error NotVault();
    error Reentrancy();
    error ResidualBalance(address token);
    error TokenCallFailed();
    error TokenCallFalse();
    error UnresolvedRecipient();
    error WrongInputToken(address token);
    error ZeroAddress();

    /// @notice A send settled. Carries no Zone sender commitment or Zone account.
    event Sent(
        bytes32 indexed ref,
        address indexed to,
        address inputToken,
        address outputToken,
        uint256 amount,
        uint256 inputConsumed,
        uint256 inputReturned
    );

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    /// @param routerFactory_ The ZoneRouterFactory whose routers may call `spendFrom`.
    /// @param convertVault_ The vault whose asset converts at par, or zero for a spender that only sends
    ///        and redeems.
    /// @param pool_ The pool pairing that asset with one other stablecoin of equal decimals.
    /// @param customerId_ The pool customer identifier. All three are set, or all three are zero.
    /// @custom:ensures ROUTER_FACTORY == routerFactory_ && convertVault == convertVault_
    /// @custom:ensures pool == pool_ && customerId == customerId_
    constructor(address routerFactory_, IEarnVault convertVault_, IPropAMMVenue pool_, bytes32 customerId_) {
        if (routerFactory_ == address(0) || routerFactory_.code.length == 0) revert InvalidRouterFactory();
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
            /// @custom:assert isBase ? base == asset && other == quote : quote == asset && other == base
            /// @custom:assert other != address(0) && other != asset && other != earnShare && asset != address(0)
            // Equal units make the par price an exact 1:1 conversion with no rounding remainder.
            if (IERC20Metadata(asset).decimals() != IERC20Metadata(other).decimals()) revert InvalidRoutePair();
        }
        ROUTER_FACTORY = routerFactory_;
        convertVault = convertVault_;
        pool = pool_;
        customerId = customerId_;
        convertAsset = asset;
        parToken = other;
        assetIsBase = isBase;
        // A standing maximum allowance for the immutable pool, set once here: Tempo charges every zero-to-nonzero
        // allowance as a new storage slot, and a TIP-20 never spends a maximum allowance down. The caller-chosen
        // vault keeps exact, cleared approvals. It sits outside gAllowance, which tracks only temporary allowances.
        if (converts) {
            _callOptionalReturn(asset, abi.encodeCall(IERC20Like.approve, (address(pool_), type(uint256).max)));
        }
    }

    /// @inheritdoc ISpender
    /// @dev `data` is `abi.encode(Send)`. Only a router from `ROUTER_FACTORY` listing this spender may call it, so
    ///      `maxInput` is what that router measured out, never a caller's claim on balances held here.
    /// @custom:requires forall address t, address s :: gAllowance[t][s] == 0
    /// @custom:ensures forall address t, address s :: gAllowance[t][s] == 0
    /// @custom:ensures 0 < maxInput && maxInput <= type(uint128).max
    function spendFrom(address token, uint256 maxInput, bytes calldata data) external override nonReentrant {
        if (!warmRouters[msg.sender] && !SpenderAuth.isListedRouter(ROUTER_FACTORY, msg.sender, address(this))) {
            revert NotRouter();
        }
        _spendFrom(token, maxInput, _decodeSend(data));
    }

    /// @notice Records that `router` may call `spendFrom` (`ROUTER_FACTORY` deployed it and its mode lists this
    ///         spender), so its spends skip asking the factory and the router. Permissionless: it only caches facts
    ///         that never change, and a router not recorded is still checked live.
    function warmRouter(address router) external {
        if (!SpenderAuth.isListedRouter(ROUTER_FACTORY, router, address(this))) revert NotRouter();
        warmRouters[router] = true;
    }

    function _spendFrom(address token, uint256 maxInput, Send calldata send) private {
        if (send.to == address(0) || send.token == address(0)) revert ZeroAddress();
        if (send.amount == 0 || maxInput == 0 || maxInput > type(uint128).max) revert InvalidAmount();
        // Paying the router would strand the output there: it measures and returns only the input token.
        if (send.to == address(this) || send.to == msg.sender) revert InvalidRecipient();
        /// @custom:assert send.to != address(0) && send.token != address(0) && send.amount != 0
        /// @custom:assert 0 < maxInput && maxInput <= type(uint128).max
        /// @custom:assert send.to != address(this) && send.to != msg.sender
        // A TIP-20 transfer to a virtual address credits its master, so that is whose balance must rise.
        address payee = _payee(send.to);
        if (payee == address(0)) revert ZeroAddress();
        if (payee == address(this) || payee == msg.sender) revert InvalidRecipient();
        /// @custom:assert payee != address(0) && payee != address(this) && payee != msg.sender

        // The caller sent maxInput first; anything else held here is the baseline, and none may stay behind.
        uint256 balance = IERC20Like(token).balanceOf(address(this));
        if (balance < maxInput) revert InsufficientInput();
        /// @custom:assert balance >= maxInput
        uint256 baseline = balance - maxInput;
        /// @custom:ghost gPaidBefore = gSent[send.token][send.to]
        uint256 paidBefore = IERC20Like(send.token).balanceOf(payee);

        if (send.vault == address(0)) {
            if (send.token != token) revert WrongInputToken(token);
            if (send.amount > maxInput) revert InvalidAmount();
            /// @custom:assert send.token == token && send.amount <= maxInput
            _safeTransfer(token, send.to, send.amount);
            /// @custom:assert gSent[token][send.to] == gPaidBefore + send.amount
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
            /// @custom:assert send.token != token && asset != token && converts == (send.token != asset)
            /// @custom:assert converts ==> send.vault == address(convertVault) && asset == convertAsset
            /// @custom:assert converts ==> send.token == parToken
            // A vault with the callback is paid by transfer inside it, so no allowance slot is written.
            bool callback = _hasWithdrawCallback(send.vault);
            if (!converts && payee == send.to) {
                _withdraw(send.vault, token, callback, send.amount, send.to, maxInput);
            } else {
                // Redeemed here first when it converts, or when `to` is virtual: Earn's engines measure the
                // literal receiver, which a virtual address never is, so this spender transfers to it instead.
                // Only this branch holds the output, so only it measures the output's baseline.
                uint256 assetBefore = IERC20Like(asset).balanceOf(address(this));
                // Read before the redemption, so the output stays at this baseline for the whole spend.
                uint256 outBefore = converts ? IERC20Like(parToken).balanceOf(address(this)) : 0;
                _withdraw(send.vault, token, callback, send.amount, address(this), maxInput);
                if (IERC20Like(asset).balanceOf(address(this)) != assetBefore + send.amount) {
                    revert InsufficientInput();
                }
                if (converts) _convertAtPar(send.amount, outBefore);
                _safeTransfer(send.token, send.to, send.amount);
                /// @custom:assert gSent[send.token][send.to] == gPaidBefore + send.amount
                /// @custom:assert converts || payee != send.to
                if (IERC20Like(asset).balanceOf(address(this)) != assetBefore) revert ResidualBalance(asset);
                // Without conversion the output is the asset, measured just above.
                if (converts && IERC20Like(parToken).balanceOf(address(this)) != outBefore) {
                    revert ResidualBalance(parToken);
                }
            }
            /// @custom:assert gAllowance[token][send.vault] == 0
        }

        // Checked on the payee, so a vault or pool that reports success without paying cannot settle.
        if (IERC20Like(send.token).balanceOf(payee) != paidBefore + send.amount) revert DestinationNotPaid();

        uint256 unused = IERC20Like(token).balanceOf(address(this)) - baseline;
        if (unused >= maxInput) revert NothingSpent();
        /// @custom:assert unused < maxInput
        /// @custom:ghost gReturnedBefore = gSent[token][msg.sender]
        // With nothing unused the balance read above already equals the baseline. Otherwise the transfer
        // leaves exactly the baseline: the router sends only a token its Zone's Portal enabled, and the
        // Portal enables only TIP-20s, which debit the sender exactly.
        if (unused != 0) _safeTransfer(token, msg.sender, unused);
        /// @custom:assert gSent[token][msg.sender] == gReturnedBefore + unused

        emit Sent(send.ref, send.to, token, send.token, send.amount, maxInput - unused, unused);
    }

    /// @inheritdoc IEarnWithdrawCallback
    /// @dev Only the vault a running spend redeems through, once, for at most that spend's `maxInput`. It is the
    ///      one entry point without the lock, which spendFrom holds around it; {_withdraw} arms it.
    function earnWithdrawCallback(uint256 earnShares) external override {
        address vault = callbackVault;
        if (vault == address(0) || msg.sender != vault) revert NotVault();
        if (earnShares > callbackMax) revert InsufficientInput();
        callbackVault = address(0);
        _safeTransfer(callbackShare, vault, earnShares);
    }

    /// @notice The pool's par price, or zero without a pool.
    /// @custom:ensures address(pool) == address(0) ==> result == 0
    function parPrice() public view returns (uint256) {
        if (address(pool) == address(0)) return 0;
        return 10 ** uint256(IPropAMMPriceOracle(pool.oracle()).decimals());
    }

    /// @dev Redeems exactly `amount` of `vault`'s asset to `receiver` for at most `maxInput` of its EarnShare
    ///      `share`, leaving no allowance. The callback burns at most the vault's own quote, so a burn above it
    ///      but within `maxInput` reverts there; only that error retries through an exact approval.
    function _withdraw(address vault, address share, bool callback, uint256 amount, address receiver, uint256 maxInput)
        private
    {
        // spendFrom holds the lock until it returns; earnWithdrawCallback admits only `vault`, once, during this call.
        // forge-lint: disable-start(reentrancy-no-eth)
        if (callback) {
            callbackVault = vault;
            callbackShare = share;
            callbackMax = maxInput;
            try IEarnVaultWithdrawCallback(vault).withdrawExactWithCallback(amount, receiver, maxInput) {
                // The callback clears callbackVault, so a vault that skipped it took nothing.
                if (callbackVault != address(0)) revert NothingSpent();
                return;
            } catch (bytes memory reason) {
                if (keccak256(reason) != keccak256(abi.encodeWithSelector(EXCEEDS_MAX_EARN_SHARES))) {
                    assembly ("memory-safe") {
                        revert(add(reason, 0x20), mload(reason))
                    }
                }
            }
            // The revert undid the callback's transfer; disarm it so nothing can call back during the retry.
            callbackVault = address(0);
        }
        _safeApprove(share, vault, maxInput);
        IEarnVault(vault).withdrawExact(amount, receiver, maxInput);
        _safeApprove(share, vault, 0);
        // forge-lint: disable-end(reentrancy-no-eth)
    }

    /// @dev Whether `vault` reports the callback withdrawal by ERC-165: it affirms the interface and denies
    ///      0xffffffff, so a fallback answering true to everything fails. A vault that affirms it without
    ///      implementing it cannot settle: the callback must clear `callbackVault` and the payee must be paid.
    function _hasWithdrawCallback(address vault) private view returns (bool) {
        return _supportsInterface(vault, type(IEarnVaultWithdrawCallback).interfaceId) == 1
            && _supportsInterface(vault, 0xffffffff) == 0;
    }

    /// @dev `vault`'s ERC-165 answer for `interfaceId`: 1 or 0, or 2 for a failed call or any other return.
    ///      Capped at ERC-165's 30,000 gas and one return word, so a caller-chosen vault cannot burn the spend's gas.
    function _supportsInterface(address vault, bytes4 interfaceId) private view returns (uint256 answer) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x01ffc9a7))
            mstore(add(ptr, 4), interfaceId)
            mstore(0x00, 2)
            let ok := staticcall(30000, vault, ptr, 0x24, 0x00, 0x20)
            answer := mload(0x00)
            if or(or(iszero(ok), lt(returndatasize(), 0x20)), gt(answer, 1)) { answer := 2 }
        }
    }

    /// @dev Who a transfer to `to` credits: its TIP-1022 master if it is a virtual address, else `to`.
    ///      Without the registry (empty return data) it is `to`; an unregistered virtual address reverts,
    ///      as the transfer would.
    function _payee(address to) private view returns (address) {
        address registry = ADDRESS_REGISTRY_ADDRESS;
        bytes4 selector = IAddressRegistry.resolveRecipient.selector;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            mstore(0x04, to)
            let ok := staticcall(gas(), registry, 0x00, 0x24, 0x00, 0x20)
            size := returndatasize()
            if iszero(ok) {
                let m := mload(0x40)
                returndatacopy(m, 0x00, size)
                revert(m, size)
            }
            word := mload(0x00)
        }
        if (size == 0) return to;
        if (size != 32) revert UnresolvedRecipient();
        /// @custom:assert size == 32
        // As abi.decode would: a word with bits above the address reverts without data.
        if (word >> 160 != 0) revert();
        // casting to 'uint160' is safe because the word was just checked to have no bits above 160
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word));
    }

    /// @dev `data` as a Send, read in place rather than copied to memory, with abi.decode's checks: the whole
    ///      tuple fits in `data` and every word is clean for its type, or it reverts without data.
    ///      Not proved: the verifier does not model the assembly that points `send` into `data`.
    function _decodeSend(bytes calldata data) private pure returns (Send calldata send) {
        // Send is five static words, so its head is the whole tuple and every member lies inside `data`.
        if (data.length < 0xa0) revert();
        assembly ("memory-safe") {
            send := data.offset
            // to, token and vault are addresses (words 0, 1 and 3); amount is a uint128 (word 2).
            let dirty := or(shr(160, calldataload(send)), shr(160, calldataload(add(send, 0x20))))
            dirty := or(dirty, or(shr(128, calldataload(add(send, 0x40))), shr(160, calldataload(add(send, 0x60)))))
            if dirty { revert(0x00, 0x00) }
        }
    }

    /// @dev Swaps exactly `amount` of `convertAsset` for exactly `amount` of `parToken` at the oracle's par
    ///      price, into this spender, which held `outBefore` of `parToken` before; any other price or output
    ///      reverts. The pool pulls through the standing allowance the constructor set.
    function _convertAtPar(uint256 amount, uint256 outBefore) private {
        // spendFrom holds the lock until it returns; earnWithdrawCallback admits only the vault being redeemed.
        // forge-lint: disable-start(reentrancy-no-eth)
        pool.swapExactInput(
            assetIsBase, amount, amount, address(this), customerId, bytes32(0), block.timestamp, parPrice(), 0, 0
        );
        // forge-lint: disable-end(reentrancy-no-eth)
        if (IERC20Like(parToken).balanceOf(address(this)) != outBefore + amount) revert DestinationNotPaid();
    }

    /// @dev Clears a leftover allowance first only when there is one; every path here leaves none.
    function _safeApprove(address token, address spender, uint256 value) private {
        /// @custom:ghost gAllowance[token][spender] = 0
        if (IERC20Allowance(token).allowance(address(this), spender) != 0) {
            _callOptionalReturn(token, abi.encodeCall(IERC20Like.approve, (spender, 0)));
        }
        /// @custom:ghost gAllowance[token][spender] = value
        if (value != 0) _callOptionalReturn(token, abi.encodeCall(IERC20Like.approve, (spender, value)));
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        /// @custom:ghost gSent[token][to] = gSent[token][to] + value
        _callOptionalReturn(token, abi.encodeCall(IERC20Like.transfer, (to, value)));
    }

    function _callOptionalReturn(address token, bytes memory data) private {
        // spendFrom holds the lock until it returns; earnWithdrawCallback admits only the vault being redeemed.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        (bool ok, bytes memory returnData) = token.call(data);
        if (!ok) revert TokenCallFailed();
        if (returnData.length != 0 && !abi.decode(returnData, (bool))) revert TokenCallFalse();
    }
}
