// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";
import { ADDRESS_REGISTRY_ADDRESS, IAddressRegistry } from "zone-router/interfaces/IAddressRegistry.sol";
import { IERC20Allowance } from "zone-router/interfaces/IERC20Allowance.sol";
import { ISpender } from "zone-router/interfaces/ISpender.sol";
import { SpenderAuth } from "zone-router/spenders/SpenderAuth.sol";

import { CardSpend } from "./CardSpend.sol";
import { ICardProvider, ICardProviderPayout } from "./interfaces/ICardProvider.sol";
import { ITempoEarnVault } from "./interfaces/ITempoEarnVault.sol";

/// @title CardSpender
/// @notice One card program on Tempo, for any provider: the stable address cardholders' access keys and a
///         Zone's router point at. It pays a spend from stablecoin, Tempo Earn shares, or both, to a
///         destination its provider authorizes, publicly (`spend`) or from a Zone withdrawal (`spendFrom`, as the
///         spender of a router `ROUTER_FACTORY` deployed). Specified in docs/cards/design.md.
/// @dev Deployed by `CardFactory` with a fixed provider and router factory, and never changed: no owner, setter
///      or pause of its own, so a provider replaces a program by deploying another and stops one through its own
///      `paused()`. Between spends it holds nothing but an optional seed (see `spendFrom`). Two ways to pay,
///      fixed by the provider:
///      - direct: the program moves the funds itself (Rain);
///      - payout: the provider supports `ICardProviderPayout`, and the program pays through its target as the
///        payer (Bridge, through its spender clone and "TS" handler, so Bridge's factory governs the spend).
///      Either way it checks the destination (its TIP-1022 master, for a virtual address) got exactly the
///      amount, and a payout uses exactly the spend's input, no more than the share cost it quoted.
contract CardSpender is ISpender {
    /// @dev Solady's `TransferFailed()` and `ApproveFailed()`.
    bytes4 private constant TRANSFER_FAILED = 0x90b8ec18;
    bytes4 private constant APPROVE_FAILED = 0x3e3f8f73;

    ICardProvider public immutable PROVIDER;
    /// @notice The provider's payout target, or zero when the program pays directly.
    address public immutable PAYOUT_TARGET;
    /// @notice The `ZoneRouterFactory` whose routers may call `spendFrom`, when their mode lists this program.
    address public immutable ROUTER_FACTORY;

    bool private transient _locked;

    error DestinationNotAuthorized(address destination);
    error DestinationNotCredited();
    error IncorrectAssetForVault();
    error InputNotConsumed(uint256 consumed, uint256 expected);
    error InsufficientInput();
    error InvalidAmount();
    error NotProvider();
    error NotRouter();
    error NothingSpent();
    error ProgramPaused();
    error Reentrancy();
    error RefundNotCredited();
    error ResidualBalance(address token);
    error ShareCostExceeded(uint256 required, uint256 maxShares);
    error UnresolvedRecipient();
    error VaultNotAllowed(address vault);
    error WrongInputToken(address token);
    error WrongProgram(address program);
    error ZeroAddress();

    /// @dev `payer` is the cardholder's account for a public spend and the router for a private one, so a
    ///      private spend's events name no cardholder. `sharesUsed` is the EarnShare the spend consumed.
    event CardSpent(
        bytes32 indexed ref,
        address indexed payer,
        address indexed destination,
        address token,
        uint256 amount,
        uint256 fromVault,
        uint256 sharesUsed,
        bool isPrivate
    );
    /// @dev A private spend's input accounting, as the Zone router sees it. No cardholder or `senderTag`.
    event InputSpent(bytes32 indexed ref, address inputToken, uint256 inputConsumed, uint256 inputReturned);

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(ICardProvider provider_, address routerFactory_) {
        if (address(provider_) == address(0) || routerFactory_ == address(0)) revert ZeroAddress();
        if (!ERC165Checker.supportsInterface(address(provider_), type(ICardProvider).interfaceId)) {
            revert NotProvider();
        }
        PROVIDER = provider_;
        ROUTER_FACTORY = routerFactory_;
        if (ERC165Checker.supportsInterface(address(provider_), type(ICardProviderPayout).interfaceId)) {
            address target = ICardProviderPayout(address(provider_)).payoutTarget();
            if (target == address(0)) revert ZeroAddress();
            PAYOUT_TARGET = target;
        }
    }

    // ------------------------------------------------------------------
    // Spends
    // ------------------------------------------------------------------

    /// @notice A public spend: pays `s.amount` of `s.token` to `s.destination`, `s.amount - s.fromVault`
    ///         from the caller's `s.token` and `s.fromVault` redeemed from the caller's shares in `s.vault`.
    ///         The caller approves this program for both first.
    function spend(CardSpend calldata s) external nonReentrant {
        address payee = _check(s, msg.sender, false);
        uint256 destinationBefore = IERC20Like(s.token).balanceOf(payee);
        uint256 sharesUsed = PAYOUT_TARGET == address(0) ? _payDirect(s, payee) : _payThroughPublic(s);
        if (IERC20Like(s.token).balanceOf(payee) != destinationBefore + s.amount) revert DestinationNotCredited();
        emit CardSpent(s.ref, msg.sender, s.destination, s.token, s.amount, s.fromVault, sharesUsed, false);
    }

    /// @inheritdoc ISpender
    /// @notice A private spend, as a Zone router's spender: pays `abi.decode(data, (CardSpend))` from the
    ///         `maxInput` of `token` the caller transferred first, and returns the rest in the same call.
    /// @dev Only a router `ROUTER_FACTORY` deployed whose mode lists this program may call it, so `maxInput`
    ///      is a router's measured transfer: nobody can spend what the program holds outside a spend. That
    ///      lets a program keep a seed (one unit of each token it handles, sent by anyone) as the baseline
    ///      every spend leaves untouched, so a spend never creates the program's balance slot (TIP-1000). One
    ///      withdrawal carries one token: the stablecoin, or the shares of the vault that funds all of it.
    function spendFrom(address token, uint256 maxInput, bytes calldata data) external override nonReentrant {
        if (!SpenderAuth.isListedRouter(ROUTER_FACTORY, msg.sender, address(this))) revert NotRouter();
        CardSpend memory s = abi.decode(data, (CardSpend));
        if (maxInput == 0 || maxInput > type(uint128).max) revert InvalidAmount();
        address input;
        if (s.fromVault == 0) {
            input = s.token;
        } else if (s.fromVault == s.amount && s.vault != address(0)) {
            input = ITempoEarnVault(s.vault).earnShare();
        }
        if (input == address(0) || input != token) revert WrongInputToken(token);
        // A private spend names no cardholder, so the provider gets no payer.
        address payee = _check(s, address(0), true);

        // Whatever else the program holds (a seed) is the baseline, and nothing beyond it may stay behind.
        uint256 balance = IERC20Like(token).balanceOf(address(this));
        if (balance < maxInput) revert InsufficientInput();
        uint256 baseline = balance - maxInput;
        uint256 destinationBefore = IERC20Like(s.token).balanceOf(payee);

        uint256 expected;
        if (PAYOUT_TARGET == address(0)) {
            _spendDirect(s, maxInput, payee);
        } else if (s.fromVault == 0) {
            // A payout uses exactly the stablecoin spend, so a target cannot keep the rest as a buffer.
            expected = s.amount;
            _payout(s, token, address(0));
        } else {
            // At most the share cost quoted before the payout: a target can neither keep the rest of the input
            // nor burn more shares than the amount costs and keep the surplus assets.
            expected = ITempoEarnVault(s.vault).previewWithdraw(s.fromVault);
            _payout(s, token, address(0));
        }

        // Reverts if the spend took more than maxInput, since the balance would be below the baseline.
        uint256 unused = IERC20Like(token).balanceOf(address(this)) - baseline;
        if (unused >= maxInput) revert NothingSpent();
        uint256 consumed = maxInput - unused;
        if (PAYOUT_TARGET != address(0) && (s.fromVault == 0 ? consumed != expected : consumed > expected)) {
            revert InputNotConsumed(consumed, expected);
        }
        if (IERC20Like(s.token).balanceOf(payee) != destinationBefore + s.amount) revert DestinationNotCredited();
        if (unused != 0) _tokenCall(token, IERC20Like.transfer.selector, msg.sender, unused, TRANSFER_FAILED);
        if (IERC20Like(token).balanceOf(address(this)) != baseline) revert ResidualBalance(token);

        emit CardSpent(
            s.ref, msg.sender, s.destination, s.token, s.amount, s.fromVault, s.fromVault == 0 ? 0 : consumed, true
        );
        emit InputSpent(s.ref, token, consumed, unused);
    }

    // ------------------------------------------------------------------
    // Views and warm-up
    // ------------------------------------------------------------------

    /// @notice Whether spends are stopped: the provider's own pause, read live (Bridge's factory pause and
    ///         "TS" handler routing; Rain reports none). The program has no pause of its own.
    function paused() public view returns (bool) {
        return PROVIDER.paused();
    }

    /// @notice Sets the program's standing approval of `token` to its payout target before the first spend,
    ///         which would otherwise create the allowance slot in a spend (TIP-1000). Permissionless: the
    ///         program holds nothing between spends but a seed. Does nothing for a program that pays directly.
    function warm(address token) external {
        if (PAYOUT_TARGET != address(0)) _approve(token, PAYOUT_TARGET, type(uint256).max);
    }

    /// @notice Sets the program's standing approval of `vault`'s EarnShare to `vault`, which a program that pays
    ///         directly would otherwise create in its first spend from it (TIP-1000). Permissionless, for a
    ///         vault the provider allows. Does nothing for a program that pays through a payout target.
    function warmVault(address vault) external {
        if (!PROVIDER.isAllowedVault(vault)) revert VaultNotAllowed(vault);
        if (PAYOUT_TARGET == address(0)) _approve(ITempoEarnVault(vault).earnShare(), vault, type(uint256).max);
    }

    /// @notice `from`'s balance of `token`, plus the value of its shares in `vault` when the provider allows
    ///         it and it holds `token`. Pass `vault` zero for the stablecoin alone.
    /// @dev An upper bound on what one spend can pay: shares are valued with `previewRedeem`, while a spend
    ///      pays an exact amount at the `previewWithdraw` cost, which rounds against the payer, and a private
    ///      spend carries one token, so it pays from the stablecoin or the shares, never both.
    function availableBalance(address from, address token, address vault) external view returns (uint256 total) {
        total = IERC20Like(token).balanceOf(from);
        if (vault == address(0) || !PROVIDER.isAllowedVault(vault)) return total;
        (bool ok, uint256 word) = _readWord(vault, abi.encodeCall(ITempoEarnVault.asset, ()));
        if (!ok || word != uint256(uint160(token))) return total;
        (ok, word) = _readWord(vault, abi.encodeCall(ITempoEarnVault.earnShare, ()));
        if (!ok || word >> 160 != 0) return total;
        uint256 shares;
        // casting to 'uint160' is safe because the word was just checked to have no bits above 160
        // forge-lint: disable-next-line(unsafe-typecast)
        (ok, shares) = _readWord(address(uint160(word)), abi.encodeCall(IERC20Like.balanceOf, (from)));
        if (!ok || shares == 0) return total;
        (ok, word) = _readWord(vault, abi.encodeCall(ITempoEarnVault.previewRedeem, (shares)));
        if (ok) total += word;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev Checks `s` and returns its payee: who a transfer to `s.destination` credits.
    function _check(CardSpend memory s, address payer, bool isPrivate) private view returns (address payee) {
        if (s.program != address(this)) revert WrongProgram(s.program);
        if (s.amount == 0 || s.fromVault > s.amount) revert InvalidAmount();
        payee = _payee(s.destination);
        // The program's own balance is the baseline it measures input against, so it never pays itself.
        if (payee == address(0) || payee == address(this)) revert DestinationNotAuthorized(s.destination);
        // The router returns only unused input, so paying it the redeemed asset would strand that asset.
        if (isPrivate && (s.destination == msg.sender || payee == msg.sender)) {
            revert DestinationNotAuthorized(s.destination);
        }
        // A payout target enforces the provider's pause, destination and vault rules in the same call
        // (ICardProviderPayout), so asking the provider first would only repeat them.
        if (PAYOUT_TARGET != address(0)) return payee;
        if (paused()) revert ProgramPaused();
        if (!PROVIDER.isAuthorizedDestination(payer, s.destination, s.token, s.destinationHint, isPrivate)) {
            revert DestinationNotAuthorized(s.destination);
        }
        if (s.fromVault != 0) {
            if (!PROVIDER.isAllowedVault(s.vault)) revert VaultNotAllowed(s.vault);
            if (ITempoEarnVault(s.vault).asset() != s.token) revert IncorrectAssetForVault();
        }
    }

    /// @dev A direct public spend: stablecoin straight from the payer, shares pulled, redeemed for the
    ///      destination and the rest returned.
    function _payDirect(CardSpend calldata s, address payee) private returns (uint256 sharesUsed) {
        uint256 fromStable = s.amount - s.fromVault;
        if (fromStable != 0) SafeTransferLib.safeTransferFrom(s.token, msg.sender, s.destination, fromStable);
        if (s.fromVault == 0) return 0;
        ITempoEarnVault v = ITempoEarnVault(s.vault);
        uint256 required = v.previewWithdraw(s.fromVault);
        if (s.maxShares != 0 && required > s.maxShares) revert ShareCostExceeded(required, s.maxShares);
        address share = v.earnShare();
        SafeTransferLib.safeTransferFrom(share, msg.sender, address(this), required);
        sharesUsed = _redeem(v, share, s, payee, required);
        if (sharesUsed < required) _refund(share, required - sharesUsed);
    }

    /// @dev A direct private spend, from the `maxInput` the router sent. The vault prices shares itself and
    ///      reverts when the cost is above the cap, the lower of `maxInput` and `maxShares`.
    function _spendDirect(CardSpend memory s, uint256 maxInput, address payee) private {
        if (s.fromVault == 0) {
            if (s.amount > maxInput) revert InsufficientInput();
            SafeTransferLib.safeTransfer(s.token, s.destination, s.amount);
            return;
        }
        ITempoEarnVault v = ITempoEarnVault(s.vault);
        uint256 cap = s.maxShares != 0 && s.maxShares < maxInput ? s.maxShares : maxInput;
        _redeem(v, v.earnShare(), s, payee, cap);
    }

    /// @dev Burns at most `cap` of the program's shares for exactly `s.fromVault` to `s.destination`. Earn's
    ///      engines check the literal receiver's balance, so a virtual destination is redeemed to the program
    ///      first and transferred on. The approval to the vault is a standing maximum (TIP-1000); the provider
    ///      decides on every spend which vaults may be used, and the program holds only a seed between spends.
    function _redeem(ITempoEarnVault v, address share, CardSpend memory s, address payee, uint256 cap)
        private
        returns (uint256 burned)
    {
        _approve(share, address(v), cap);
        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-start(reentrancy-no-eth)
        if (payee == s.destination) return v.withdrawExact(s.fromVault, s.destination, cap);
        uint256 before = IERC20Like(s.token).balanceOf(address(this));
        burned = v.withdrawExact(s.fromVault, address(this), cap);
        if (IERC20Like(s.token).balanceOf(address(this)) != before + s.fromVault) revert DestinationNotCredited();
        SafeTransferLib.safeTransfer(s.token, s.destination, s.fromVault);
        // forge-lint: disable-end(reentrancy-no-eth)
    }

    /// @dev A public spend through the provider's payout target: pulls the stablecoin part and the share quote
    ///      from the payer and pays through the target, which must use all of the stablecoin and at most the
    ///      quote; the program returns the shares it did not use.
    function _payThroughPublic(CardSpend calldata s) private returns (uint256 sharesUsed) {
        uint256 fromStable = s.amount - s.fromVault;
        address share;
        uint256 shareIn;
        if (s.fromVault != 0) {
            ITempoEarnVault v = ITempoEarnVault(s.vault);
            share = v.earnShare();
            // The live cost, as the target computes it in this same call: pulling the `maxShares` cap instead
            // would decline a payer whose shares cover the cost but not the cap.
            shareIn = v.previewWithdraw(s.fromVault);
            if (s.maxShares != 0 && shareIn > s.maxShares) revert ShareCostExceeded(shareIn, s.maxShares);
        }
        uint256 stableBase = IERC20Like(s.token).balanceOf(address(this));
        uint256 shareBase = share == address(0) ? 0 : IERC20Like(share).balanceOf(address(this));
        if (fromStable != 0) SafeTransferLib.safeTransferFrom(s.token, msg.sender, address(this), fromStable);
        if (shareIn != 0) SafeTransferLib.safeTransferFrom(share, msg.sender, address(this), shareIn);

        _payout(s, fromStable != 0 ? s.token : address(0), share);

        // Each reverts if the target took more than the payer put in.
        uint256 stableLeft = IERC20Like(s.token).balanceOf(address(this)) - stableBase;
        if (stableLeft != 0) revert InputNotConsumed(fromStable - stableLeft, fromStable);
        if (share != address(0)) {
            uint256 shareLeft = IERC20Like(share).balanceOf(address(this)) - shareBase;
            sharesUsed = shareIn - shareLeft;
            if (shareLeft != 0) _refund(share, shareLeft);
        }
    }

    /// @dev Receive policies can redirect successful transfers, so a public refund must credit the payer.
    function _refund(address share, uint256 amount) private {
        uint256 before = IERC20Like(share).balanceOf(msg.sender);
        SafeTransferLib.safeTransfer(share, msg.sender, amount);
        if (IERC20Like(share).balanceOf(msg.sender) != before + amount) revert RefundNotCredited();
    }

    /// @dev Approves the payout target for the input tokens (standing maxima, TIP-1000) and calls it with the
    ///      provider's payout data, bubbling up its revert.
    function _payout(CardSpend memory s, address tokenA, address tokenB) private {
        address target = PAYOUT_TARGET;
        if (tokenA != address(0)) _approve(tokenA, target, type(uint128).max);
        if (tokenB != address(0)) _approve(tokenB, target, type(uint128).max);
        bytes memory data = ICardProviderPayout(address(PROVIDER)).payoutData(s);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @dev Who a transfer to `to` credits: its TIP-1022 master if it is a virtual address, else `to`. Without
    ///      the registry (empty return data) it is `to`; an unregistered virtual address reverts, as the
    ///      transfer would.
    function _payee(address to) private view returns (address) {
        (bool ok, bytes memory ret) =
            ADDRESS_REGISTRY_ADDRESS.staticcall(abi.encodeCall(IAddressRegistry.resolveRecipient, (to)));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        if (ret.length == 0) return to;
        if (ret.length != 32) revert UnresolvedRecipient();
        return abi.decode(ret, (address));
    }

    /// @dev Sets a standing maximum approval of `token` to `spender` when it is below `amount`.
    function _approve(address token, address spender, uint256 amount) private {
        if (IERC20Allowance(token).allowance(address(this), spender) < amount) {
            _tokenCall(token, IERC20Like.approve.selector, spender, type(uint256).max, APPROVE_FAILED);
        }
    }

    /// @dev `approve` or `transfer` on `token`, reverting with `failure` alone unless it returns `true`, or
    ///      returns nothing from an address with code.
    function _tokenCall(address token, bytes4 selector, address to, uint256 amount, bytes4 failure) private {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), to)
            mstore(add(m, 0x24), amount)
            mstore(0x00, 0)
            let success := call(gas(), token, 0, m, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    mstore(0x00, failure)
                    revert(0x00, 0x04)
                }
            }
        }
    }

    /// @dev False unless `target` has code, the call succeeds and returns at least one word.
    function _readWord(address target, bytes memory data) private view returns (bool ok, uint256 word) {
        if (target.code.length == 0) return (false, 0);
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }
}
