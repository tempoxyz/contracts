// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { LibRLP } from "solady/utils/LibRLP.sol";

import { ICardProgram } from "../../interfaces/ICardProgram.sol";
import { IRainCollateral, IRainCollateralFactory } from "./IRain.sol";

/// @title RainCardProgram
/// @notice The `ICardProgram` adapter for one Rain card program: a spend pays into a Rain collateral
///         contract, which backs the card's spending as Rain's real-time funding commits it at authorization.
///         Rain's contracts are used as they are (vendor/rain); nothing here asks them to change.
///         Specified in docs/cards/rain.md.
/// @dev A destination is authorized when it is a collateral contract Rain's factory created and either:
///      - the payer owns it and is not one of this program's settlers: a public spend into the
///        cardholder's own collateral (Rain-managed); or
///      - it is one of the program's pooled collateral contracts: a private spend, which must not name
///        the cardholder, or a partner-managed program.
///      Rain's factory keeps no lookup of its collateral contracts, so the spend names the factory nonce
///      that created it (`hint`), and the address must be the factory's CREATE address for that nonce.
///      Only the factory's code deploys from the factory's address, so that proves provenance without
///      trusting the destination's code; the beacon, the one other contract the factory creates, is
///      excluded. Tokens and vaults are fixed at deployment: there is no owner, and changing them means
///      deploying a new adapter, spender and settler.
contract RainCardProgram is ICardProgram {
    /// @notice Rain's `RainCollateralFactory` (its proxy, where it is behind one).
    address public immutable FACTORY;

    mapping(address token => bool) public isAcceptedToken;
    mapping(address vault => bool) public isAllowedVault;
    mapping(address collateral => bool) public isProgramCollateral;

    address[] private _tokens;
    address[] private _vaults;
    address[] private _programCollaterals;

    error ZeroAddress();

    constructor(
        address factory_,
        address[] memory tokens_,
        address[] memory vaults_,
        address[] memory programCollaterals_
    ) {
        if (factory_ == address(0)) revert ZeroAddress();
        FACTORY = factory_;
        for (uint256 i; i < tokens_.length; ++i) {
            if (tokens_[i] == address(0)) revert ZeroAddress();
            isAcceptedToken[tokens_[i]] = true;
        }
        for (uint256 i; i < vaults_.length; ++i) {
            if (vaults_[i] == address(0)) revert ZeroAddress();
            isAllowedVault[vaults_[i]] = true;
        }
        for (uint256 i; i < programCollaterals_.length; ++i) {
            if (programCollaterals_[i] == address(0)) revert ZeroAddress();
            isProgramCollateral[programCollaterals_[i]] = true;
        }
        _tokens = tokens_;
        _vaults = vaults_;
        _programCollaterals = programCollaterals_;
    }

    /// @inheritdoc ICardProgram
    /// @dev `hint` is the factory nonce whose CREATE address is `destination`.
    function isAuthorizedDestination(address payer, address destination, address token, uint256 hint)
        external
        view
        returns (bool)
    {
        if (!isAcceptedToken[token] || !isRainCollateral(destination, hint)) return false;
        if (isProgramCollateral[destination]) return true;
        // A settler of this program pays private spends, which must reach only pooled collateral, even
        // one a cardholder has made the owner of their own collateral.
        return !_isProgramSettler(payer) && _owner(destination) == payer;
    }

    /// @notice Whether `collateral` is a collateral contract Rain's factory created with nonce `nonce`.
    function isRainCollateral(address collateral, uint256 nonce) public view returns (bool) {
        if (collateral == address(0) || collateral.code.length == 0) return false;
        if (LibRLP.computeAddress(FACTORY, nonce) != collateral) return false;
        if (collateral == IRainCollateralFactory(FACTORY).getBeacon()) return false;
        (bool ok, bytes memory ret) = collateral.staticcall(abi.encodeCall(IRainCollateral.factory, ()));
        return ok && ret.length >= 32 && abi.decode(ret, (address)) == FACTORY;
    }

    function tokens() external view returns (address[] memory) {
        return _tokens;
    }

    function vaults() external view returns (address[] memory) {
        return _vaults;
    }

    function programCollaterals() external view returns (address[] memory) {
        return _programCollaterals;
    }

    /// @dev Whether `payer` reports this adapter as its `PROGRAM`, as every `CardSettler` (and `CardSpender`)
    ///      of this program does. An account without code reports nothing.
    function _isProgramSettler(address payer) private view returns (bool) {
        if (payer.code.length == 0) return false;
        (bool ok, bytes memory ret) = payer.staticcall(abi.encodeWithSignature("PROGRAM()"));
        return ok && ret.length >= 32 && abi.decode(ret, (address)) == address(this);
    }

    /// @dev The collateral's owner, or zero when it cannot report one.
    function _owner(address collateral) private view returns (address) {
        (bool ok, bytes memory ret) = collateral.staticcall(abi.encodeCall(IRainCollateral.owner, ()));
        return ok && ret.length >= 32 ? abi.decode(ret, (address)) : address(0);
    }
}
