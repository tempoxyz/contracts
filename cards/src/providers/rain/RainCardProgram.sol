// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ICardProgram } from "../../core/interfaces/ICardProgram.sol";
import { IRainCollateral, IRainCollateralFactory } from "./IRain.sol";

/// @title RainCardProgram
/// @notice The `ICardProgram` adapter for one Rain card program: a spend pays into a Rain collateral
///         contract, which backs the card's spending as Rain's real-time funding commits it at authorization.
///         Rain's contracts are used as they are (vendor/rain); nothing here asks them to change.
///         Specified in docs/cards/rain/README.md.
/// @dev A destination is authorized when it is a collateral contract Rain's factory created and either:
///      - the spend is public and the payer owns and administers it: the cardholder's own collateral
///        (Rain-managed); or
///      - it is one of the program's pooled collateral contracts, the only destinations of a private spend,
///        which must not name the cardholder, and of a partner-managed program's public spends.
///      Rain's factory records every collateral contract it creates in its public `collateralProxies`
///      array but keeps no address lookup, so the spend names the collateral's index in that array
///      (`hint`): one read proves the factory created it, without trusting the destination's code.
///      Tokens and vaults are fixed at deployment: there is no owner, and changing them means
///      deploying a new adapter, spender and settler. The one mutable setting is the pause, which only
///      `PAUSER` (Rain's pause key, or nobody when zero) can set: it stops every spend and nothing else.
contract RainCardProgram is ICardProgram {
    /// @notice Rain's `RainCollateralFactory` (its proxy, where it is behind one).
    address public immutable FACTORY;
    /// @notice The only account that can pause and unpause this program's spends; zero for none.
    address public immutable PAUSER;

    /// @inheritdoc ICardProgram
    bool public paused;

    mapping(address token => bool) public isAcceptedToken;
    mapping(address vault => bool) public isAllowedVault;
    mapping(address collateral => bool) public isProgramCollateral;

    address[] private _tokens;
    address[] private _vaults;
    address[] private _programCollaterals;

    error NotPauser();
    error ZeroAddress();

    event PausedSet(bool paused);

    constructor(
        address factory_,
        address[] memory tokens_,
        address[] memory vaults_,
        address[] memory programCollaterals_,
        // Zero is allowed: a program without a pause key cannot be paused.
        // forge-lint: disable-next-line(missing-zero-check)
        address pauser_
    ) {
        if (factory_ == address(0)) revert ZeroAddress();
        FACTORY = factory_;
        PAUSER = pauser_;
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
    /// @dev `hint` is `destination`'s index in the factory's `collateralProxies`.
    function isAuthorizedDestination(address payer, address destination, address token, uint256 hint, bool isPrivate)
        external
        view
        returns (bool)
    {
        if (!isAcceptedToken[token] || !isRainCollateral(destination, hint)) return false;
        if (isProgramCollateral[destination]) return true;
        // A private spend reaches only pooled collateral: any other names one cardholder.
        if (isPrivate) return false;
        // Ownership moves with a plain `transferOwnership` that leaves the admins as they were, so the payer
        // must also administer the collateral: a collateral handed over without its admin rights stays the
        // previous holder's, and no payer can fund it.
        return _owner(destination) == payer && _isAdmin(destination, payer);
    }

    /// @notice Stops (`true`) or resumes (`false`) every spend of this program. Only `PAUSER`.
    function setPaused(bool paused_) external {
        if (msg.sender != PAUSER || PAUSER == address(0)) revert NotPauser();
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Whether `collateral` is the collateral contract Rain's factory recorded at `index` of its
    ///         `collateralProxies`. An index past the end reverts in the factory and reads as false.
    function isRainCollateral(address collateral, uint256 index) public view returns (bool) {
        if (collateral == address(0)) return false;
        (bool ok, bytes memory ret) =
            FACTORY.staticcall(abi.encodeCall(IRainCollateralFactory.collateralProxies, (index)));
        return ok && ret.length >= 32 && abi.decode(ret, (address)) == collateral;
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

    /// @dev Whether `account` is an admin of `collateral`, the role Rain's controller lets withdraw it.
    function _isAdmin(address collateral, address account) private view returns (bool) {
        (bool ok, bytes memory ret) = collateral.staticcall(abi.encodeCall(IRainCollateral.isAdmin, (account)));
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }

    /// @dev The collateral's owner, or zero when it cannot report one.
    function _owner(address collateral) private view returns (address) {
        (bool ok, bytes memory ret) = collateral.staticcall(abi.encodeCall(IRainCollateral.owner, ()));
        return ok && ret.length >= 32 ? abi.decode(ret, (address)) : address(0);
    }
}
