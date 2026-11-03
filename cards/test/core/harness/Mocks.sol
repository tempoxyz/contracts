// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { CardSpend } from "../../../src/core/CardSpend.sol";
import { ICardIssuer, ICardIssuerPayout } from "../../../src/core/interfaces/ICardIssuer.sol";
import { ITempoEarnVault } from "../../../src/core/interfaces/ITempoEarnVault.sol";

/// @notice A provider-neutral `ICardIssuer`: destinations, tokens and vaults set by the test, public and
///         private destinations kept apart, and a provider pause. Its program pays directly.
contract MockIssuer is ICardIssuer {
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
        return id == type(ICardIssuer).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @notice A provider's own payout contract, shaped like Bridge's clone and "TS" handler: it pays a spend from
///         its caller, stablecoin by `transferFrom` and Earn by pulling the share cost, redeeming it and
///         returning the rest. `mode` makes it misbehave.
contract MockPayoutTarget {
    enum Mode {
        Honest,
        PayNothing,
        TakeExtra,
        PayShort
    }

    Mode public mode;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function pay(CardSpend calldata s) external {
        if (mode == Mode.PayNothing) return;
        uint256 fromStable = s.amount - s.fromVault;
        if (mode == Mode.PayShort) fromStable -= 1;
        if (fromStable != 0) SafeTransferLib.safeTransferFrom(s.token, msg.sender, s.destination, fromStable);
        if (mode == Mode.TakeExtra) SafeTransferLib.safeTransferFrom(s.token, msg.sender, address(this), 1);
        if (s.fromVault == 0) return;
        ITempoEarnVault v = ITempoEarnVault(s.vault);
        uint256 required = v.previewWithdraw(s.fromVault);
        address share = v.earnShare();
        SafeTransferLib.safeTransferFrom(share, msg.sender, address(this), required);
        SafeTransferLib.safeApprove(share, address(v), required);
        uint256 burned = v.withdrawExact(s.fromVault, s.destination, required);
        if (burned < required) SafeTransferLib.safeTransfer(share, msg.sender, required - burned);
    }
}

/// @notice A `MockIssuer` whose program pays through a `MockPayoutTarget`.
contract MockPayoutIssuer is MockIssuer, ICardIssuerPayout {
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
        return id == type(ICardIssuerPayout).interfaceId || super.supportsInterface(id);
    }
}

/// @notice A contract that does not declare `ICardIssuer`.
contract NotAnIssuer {
    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}
