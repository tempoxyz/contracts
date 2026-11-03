// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ADDRESS_REGISTRY_ADDRESS, IAddressRegistry } from "zone-router/interfaces/IAddressRegistry.sol";

import { CardSpend } from "../../../src/core/CardSpend.sol";
import { CardSpender } from "../../../src/core/CardSpender.sol";
import { ICardProvider, ICardProviderPayout } from "../../../src/core/interfaces/ICardProvider.sol";
import { ITempoEarnVault } from "../../../src/core/interfaces/ITempoEarnVault.sol";

/// @notice A provider-neutral `ICardProvider`: destinations, tokens and vaults set by the test, public and
///         private destinations kept apart, and a provider pause. Its program pays directly.
contract MockProvider is ICardProvider {
    mapping(address => bool) public isAcceptedToken;
    mapping(address => bool) public isPublicDestination;
    mapping(address => bool) public isPrivateDestination;
    mapping(address => bool) public isAllowedVault;
    bool public paused;

    function setToken(address token, bool accepted) external {
        isAcceptedToken[token] = accepted;
    }

    function setDestination(address destination, bool publicSpend, bool privateSpend) external {
        isPublicDestination[destination] = publicSpend;
        isPrivateDestination[destination] = privateSpend;
    }

    function setVault(address vault, bool allowed) external {
        isAllowedVault[vault] = allowed;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function isAuthorizedDestination(address, address destination, address token, uint256, bool isPrivate)
        external
        view
        returns (bool)
    {
        if (!isAcceptedToken[token]) return false;
        return isPrivate ? isPrivateDestination[destination] : isPublicDestination[destination];
    }

    function supportsInterface(bytes4 id) public view virtual returns (bool) {
        return id == type(ICardProvider).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @notice A provider's own payout contract, shaped like Bridge's clone and "TS" handler: it enforces its
///         provider's pause, destination and vault rules, as `ICardProviderPayout` requires, then pays a spend from
///         its caller, stablecoin by `transferFrom` and Earn by pulling the share cost, redeeming it and
///         returning the rest. `mode` makes it misbehave.
contract MockPayoutTarget {
    enum Mode {
        Honest,
        PayNothing,
        TakeExtra,
        PayShort,
        /// @dev Pays the destination from its own balance and takes nothing from the caller.
        PayFromOwn,
        /// @dev Pays honestly, then keeps everything else the caller holds of the spend's input token.
        KeepSurplus
    }

    Mode public mode;
    ICardProvider public provider;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setProvider(ICardProvider provider_) external {
        provider = provider_;
    }

    function pay(CardSpend calldata s) external {
        _enforce(s);
        if (mode == Mode.PayNothing) return;
        if (mode == Mode.PayFromOwn) {
            SafeTransferLib.safeTransfer(s.token, s.destination, s.amount);
            return;
        }
        uint256 fromStable = s.amount - s.fromVault;
        if (mode == Mode.PayShort) fromStable -= 1;
        if (fromStable != 0) SafeTransferLib.safeTransferFrom(s.token, msg.sender, s.destination, fromStable);
        if (mode == Mode.TakeExtra) SafeTransferLib.safeTransferFrom(s.token, msg.sender, address(this), 1);
        if (s.fromVault == 0) {
            if (mode == Mode.KeepSurplus) _keepAll(s.token);
            return;
        }
        ITempoEarnVault v = ITempoEarnVault(s.vault);
        uint256 required = v.previewWithdraw(s.fromVault);
        address share = v.earnShare();
        SafeTransferLib.safeTransferFrom(share, msg.sender, address(this), required);
        SafeTransferLib.safeApprove(share, address(v), required);
        uint256 burned = v.withdrawExact(s.fromVault, s.destination, required);
        if (burned < required) SafeTransferLib.safeTransfer(share, msg.sender, required - burned);
        if (mode == Mode.KeepSurplus) _keepAll(share);
    }

    /// @dev Like Bridge's handler, it does not tell public and private spends apart.
    function _enforce(CardSpend calldata s) private view {
        if (provider.paused()) revert CardSpender.ProgramPaused();
        if (
            !provider.isAuthorizedDestination(address(0), s.destination, s.token, s.destinationHint, false)
                && !provider.isAuthorizedDestination(address(0), s.destination, s.token, s.destinationHint, true)
        ) revert CardSpender.DestinationNotAuthorized(s.destination);
        if (s.fromVault != 0) {
            if (!provider.isAllowedVault(s.vault)) revert CardSpender.VaultNotAllowed(s.vault);
            if (ITempoEarnVault(s.vault).asset() != s.token) revert CardSpender.IncorrectAssetForVault();
        }
    }

    function _keepAll(address token) private {
        uint256 held = ERC20(token).balanceOf(msg.sender);
        if (held != 0) SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), held);
    }
}

/// @notice A `MockProvider` whose program pays through a `MockPayoutTarget`.
contract MockPayoutProvider is MockProvider, ICardProviderPayout {
    address public immutable TARGET;

    constructor(address target) {
        TARGET = target;
    }

    function payoutTarget() external view returns (address) {
        return TARGET;
    }

    function payoutData(CardSpend calldata s) external pure returns (bytes memory) {
        return abi.encodeCall(MockPayoutTarget.pay, (s));
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == type(ICardProviderPayout).interfaceId || super.supportsInterface(id);
    }
}

/// @notice A `ZoneRouterFactory` stand-in whose routers the test registers.
contract MockRouterFactory {
    mapping(address router => bool) public isRouter;

    function register(address router, bool registered) external {
        isRouter[router] = registered;
    }
}

/// @notice A `ZoneRouter` stand-in whose spender list the test sets. Tests prank it to transfer a withdrawal's
///         input and call `spendFrom`, as a router does.
contract MockRouter {
    mapping(address spender => bool) public isSpender;

    function list(address spender, bool listed) external {
        isSpender[spender] = listed;
    }
}

/// @notice A contract that does not declare `ICardProvider`.
contract NotAProvider {
    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}

/// @notice An ERC-20 anyone can mint that, once armed, makes one call from inside its next transfer and keeps
///         what that call reverted with.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public reentry;
    bytes public reentryError;
    bool public reentered;

    constructor() ERC20("Reentrant USD", "RUSD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata reentry_) external {
        target = target_;
        reentry = reentry_;
        reentered = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (target != address(0) && !reentered && from != address(0) && to != address(0)) {
            reentered = true;
            (bool ok, bytes memory err) = target.call(reentry);
            require(!ok, "reentry succeeded");
            reentryError = err;
        }
        super._update(from, to, value);
    }
}

/// @notice An ERC-20 anyone can mint that, like a TIP-20, credits a virtual recipient's master, as Tempo's
///         TIP-1022 registry precompile resolves it (which a test mocks for its virtual addresses).
contract VirtualAwareToken is ERC20 {
    constructor(string memory symbol) ERC20(symbol, symbol) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) to = IAddressRegistry(ADDRESS_REGISTRY_ADDRESS).resolveRecipient(to);
        super._update(from, to, value);
    }
}

/// @notice An Earn vault at two shares per asset that, like Earn's engines, checks the literal receiver got
///         the assets, so it refuses a virtual receiver.
contract LiteralReceiverVault is ITempoEarnVault {
    /// @dev No fees to accrue.
    function accrueFees() external pure returns (uint256, uint256) { }

    address public immutable asset;
    VirtualAwareToken public immutable SHARE;

    constructor(address asset_) {
        asset = asset_;
        SHARE = new VirtualAwareToken("vES");
    }

    function earnShare() external view returns (address) {
        return address(SHARE);
    }

    function previewWithdraw(uint256 assets) public pure returns (uint256) {
        return assets * 2;
    }

    function previewRedeem(uint256 earnShares) external pure returns (uint256) {
        return earnShares / 2;
    }

    function withdrawExact(uint256 assets, address receiver, uint256 maxEarnShares) external returns (uint256 burned) {
        burned = previewWithdraw(assets);
        require(burned <= maxEarnShares, "max shares");
        SafeTransferLib.safeTransferFrom(address(SHARE), msg.sender, address(0xdead), burned);
        uint256 before = ERC20(asset).balanceOf(receiver);
        SafeTransferLib.safeTransfer(asset, receiver, assets);
        require(ERC20(asset).balanceOf(receiver) == before + assets, "receiver not credited");
    }
}
