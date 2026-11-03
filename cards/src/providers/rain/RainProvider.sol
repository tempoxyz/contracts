// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { ICardProvider } from "../../core/interfaces/ICardProvider.sol";
import { IRainCollateral, IRainCollateralFactory } from "./IRain.sol";

/// @title RainProvider
/// @notice The `ICardProvider` for Rain card programs: a spend pays into a Rain collateral contract, which
///         backs the card's spending as Rain's real-time funding commits it at authorization. Rain's
///         contracts are used as they are (vendor/rain); nothing here asks them to change. The program pays
///         directly. Specified in docs/cards/rain/README.md.
/// @dev A destination is authorized when it is a collateral contract Rain's factory created and either:
///      - the spend is public and the payer owns it and is its only admin: the cardholder's own collateral
///        (Rain-managed); or
///      - it is one of the program's pooled collateral contracts, the only destinations of a private spend,
///        which must not name the cardholder, and, when `POOLED_ACCEPTS_PUBLIC`, of a partner-managed
///        program's public spends.
///      Rain's factory records every collateral contract it creates in its public `collateralProxies` array
///      but keeps no address lookup, so the spend names the collateral's index in that array (`hint`): one
///      read proves the factory created it, without trusting the destination's code. Tokens, vaults and
///      pooled collateral are fixed at deployment (`Configured` lists them): there is no owner. Rain's
///      contracts have no pause, so this provider reports none: Rain stops a program by revoking its access
///      keys and Zone keys, the only senders of its spends, which can pay only collateral Rain controls.
contract RainProvider is ICardProvider {
    /// @notice Rain's `RainCollateralFactory` (its proxy, where it is behind one).
    address public immutable FACTORY;
    /// @notice Whether public spends may pay the pooled collateral; private spends always may.
    bool public immutable POOLED_ACCEPTS_PUBLIC;

    mapping(address token => bool) public isAcceptedToken;
    mapping(address vault => bool) public isAllowedVault;
    mapping(address collateral => bool) public isProgramCollateral;

    /// @notice The provider's whole configuration, emitted once at deployment.
    event Configured(
        address indexed factory,
        address[] tokens,
        address[] vaults,
        address[] programCollaterals,
        bool pooledAcceptsPublic
    );

    error ZeroAddress();

    constructor(
        address factory_,
        address[] memory tokens_,
        address[] memory vaults_,
        address[] memory programCollaterals_,
        bool pooledAcceptsPublic_
    ) {
        if (factory_ == address(0)) revert ZeroAddress();
        FACTORY = factory_;
        POOLED_ACCEPTS_PUBLIC = pooledAcceptsPublic_;
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
        emit Configured(factory_, tokens_, vaults_, programCollaterals_, pooledAcceptsPublic_);
    }

    /// @inheritdoc ICardProvider
    /// @dev `hint` is `destination`'s index in the factory's `collateralProxies`.
    function isAuthorizedDestination(address payer, address destination, address token, uint256 hint, bool isPrivate)
        external
        view
        returns (bool)
    {
        if (!isAcceptedToken[token] || !isRainCollateral(destination, hint)) return false;
        if (isProgramCollateral[destination]) return isPrivate || POOLED_ACCEPTS_PUBLIC;
        // A private spend reaches only pooled collateral: any other names one cardholder.
        if (isPrivate) return false;
        // Rain's controller lets any admin withdraw, and an owner can add admins before handing ownership over,
        // so the payer must own the collateral and be its only admin.
        return _owner(destination) == payer && _isSoleAdmin(destination, payer);
    }

    /// @inheritdoc ICardProvider
    function paused() external pure returns (bool) {
        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICardProvider).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Whether `collateral` is the collateral contract Rain's factory recorded at `index` of its
    ///         `collateralProxies`. An index past the end reverts in the factory and reads as false.
    function isRainCollateral(address collateral, uint256 index) public view returns (bool) {
        if (collateral == address(0)) return false;
        (bool ok, bytes memory ret) =
            FACTORY.staticcall(abi.encodeCall(IRainCollateralFactory.collateralProxies, (index)));
        return ok && ret.length >= 32 && abi.decode(ret, (address)) == collateral;
    }

    /// @dev Whether `account` is `collateral`'s only admin, the role Rain's controller lets withdraw it: the
    ///      first entry of its public `admins` array, with no second entry (reading past the end reverts).
    function _isSoleAdmin(address collateral, address account) private view returns (bool) {
        (bool ok, bytes memory ret) = collateral.staticcall(abi.encodeCall(IRainCollateral.admins, (0)));
        if (!ok || ret.length < 32 || abi.decode(ret, (address)) != account) return false;
        (ok,) = collateral.staticcall(abi.encodeCall(IRainCollateral.admins, (1)));
        return !ok;
    }

    /// @dev The collateral's owner, or zero when it cannot report one.
    function _owner(address collateral) private view returns (address) {
        (bool ok, bytes memory ret) = collateral.staticcall(abi.encodeCall(IRainCollateral.owner, ()));
        return ok && ret.length >= 32 ? abi.decode(ret, (address)) : address(0);
    }
}
