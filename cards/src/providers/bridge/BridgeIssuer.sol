// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { CardSpend } from "../../core/CardSpend.sol";
import { ICardIssuer, ICardIssuerPayout } from "../../core/interfaces/ICardIssuer.sol";
import { Spend } from "./interfaces/IBridgeSpender.sol";
import { IBridgeSpenderClone, IBridgeSpenderFactory } from "./interfaces/IBridgeSpenderFactory.sol";

/// @title BridgeIssuer
/// @notice The `ICardIssuer` for one Bridge card program (`SPENDER_ID` in Bridge's `SpenderFactory`). Its
///         program pays through the program's spender clone as the payer, with the "TS" handler
///         (`SpenderTempoSpend`) settling a `Spend`, so Bridge's factory governs every spend: destinations,
///         pause, handler routing and the Earn vault allowlist. Specified in docs/cards/bridge/design.md.
/// @dev Reads Bridge's factory and clone and holds nothing. Its answers mirror what the clone itself
///      enforces, so a spend Bridge would refuse is refused before any funds move; the clone stays the
///      authority. A Bridge settlement wallet is shared by every cardholder, so it serves private spends too.
contract BridgeIssuer is ICardIssuer, ICardIssuerPayout {
    bytes2 private constant HANDLER = "TS";
    bytes2 private constant PUBLIC_SPEND = "PS";
    bytes2 private constant GET_VAULT = "GV";

    IBridgeSpenderFactory public immutable FACTORY;
    bytes32 public immutable SPENDER_ID;
    /// @notice The program's spender clone, which its `CardProgram` pays through.
    address public immutable CLONE;

    error NoClone();
    error ZeroAddress();

    constructor(IBridgeSpenderFactory factory_, bytes32 spenderId_) {
        if (address(factory_) == address(0)) revert ZeroAddress();
        FACTORY = factory_;
        SPENDER_ID = spenderId_;
        address clone = factory_.getSpenderAddress(spenderId_);
        if (clone == address(0) || clone.code.length == 0) revert NoClone();
        CLONE = clone;
    }

    /// @inheritdoc ICardIssuer
    function isAuthorizedDestination(address, address destination, address, uint256, bool)
        external
        view
        returns (bool)
    {
        return FACTORY.isAuthorizedDestination(SPENDER_ID, destination);
    }

    /// @inheritdoc ICardIssuer
    /// @dev The vault allowlist the "TS" handler keeps in the clone (`publicGetCall "GV"`). A clone without
    ///      the handler reads as no vault.
    function isAllowedVault(address vault) external view returns (bool) {
        (bool ok, bytes memory ret) = CLONE.staticcall(
            abi.encodeCall(IBridgeSpenderClone.publicGetCall, (abi.encodePacked(HANDLER, GET_VAULT, vault)))
        );
        if (!ok || ret.length < 64) return false;
        bytes memory inner = abi.decode(ret, (bytes));
        return inner.length >= 32 && abi.decode(inner, (bool));
    }

    /// @inheritdoc ICardIssuer
    function paused() external view returns (bool) {
        return FACTORY.paused();
    }

    /// @inheritdoc ICardIssuerPayout
    function payoutTarget() external view returns (address) {
        return CLONE;
    }

    /// @inheritdoc ICardIssuerPayout
    /// @dev `publicCall "TS" "PS"` with the `Spend` the handler settles, paid by the caller (the program).
    function payoutData(CardSpend calldata s) external view returns (bytes memory) {
        Spend memory spend = Spend({
            spenderId: SPENDER_ID,
            token: s.token,
            amount: s.amount,
            destination: s.destination,
            vault: s.vault,
            fromVault: s.fromVault,
            maxShares: s.maxShares,
            ref: s.ref
        });
        return
            abi.encodeCall(IBridgeSpenderClone.publicCall, (abi.encodePacked(HANDLER, PUBLIC_SPEND, abi.encode(spend))));
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICardIssuer).interfaceId || interfaceId == type(ICardIssuerPayout).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}
