// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { ICardProvider } from "../../../interfaces/spend/ICardProvider.sol";
import { IRainCollateral, IRainCollateralFactory } from "./IRain.sol";

/// @title RainProvider
/// @notice The `ICardProvider` for Rain card programs: a spend pays into a Rain collateral contract, which
///         backs the card's spending as Rain's real-time funding commits it at authorization. Rain's
///         contracts are used as they are (vendor/rain); nothing here asks them to change. The program pays
///         directly. Specified in docs/spend/rain/README.md.
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
/// @custom:invariant FACTORY != address(0)
/// @custom:invariant !_moreTokens[address(0)] && !_moreVaults[address(0)] && !_moreCollaterals[address(0)]
contract RainProvider is ICardProvider {
    /// @notice Rain's `RainCollateralFactory` (its proxy, where it is behind one).
    address public immutable FACTORY;
    /// @notice Whether public spends may pay the pooled collateral; private spends always may.
    bool public immutable POOLED_ACCEPTS_PUBLIC;

    /// @dev How many entries of each set are held in immutables.
    uint256 private constant _INLINE = 4;

    // Each set's first four entries are immutables, so a spend reads no storage to check them; entries past the
    // fourth, which deployments rarely need, are kept in a mapping read only when the set has more than four.
    address private immutable _TOKEN_0;
    address private immutable _TOKEN_1;
    address private immutable _TOKEN_2;
    address private immutable _TOKEN_3;
    address private immutable _VAULT_0;
    address private immutable _VAULT_1;
    address private immutable _VAULT_2;
    address private immutable _VAULT_3;
    address private immutable _COLLATERAL_0;
    address private immutable _COLLATERAL_1;
    address private immutable _COLLATERAL_2;
    address private immutable _COLLATERAL_3;
    bool private immutable _MORE_TOKENS;
    bool private immutable _MORE_VAULTS;
    bool private immutable _MORE_COLLATERALS;

    mapping(address token => bool) private _moreTokens;
    mapping(address vault => bool) private _moreVaults;
    mapping(address collateral => bool) private _moreCollaterals;

    /// @notice The provider's whole configuration, emitted once at deployment.
    event Configured(
        address indexed factory,
        address[] tokens,
        address[] vaults,
        address[] programCollaterals,
        bool pooledAcceptsPublic
    );

    error ZeroAddress();
    /// @notice A pooled collateral is not the contract Rain's factory recorded at its given index.
    error NotRainCollateral(address collateral, uint256 index);
    /// @notice The pooled collaterals and their factory indexes differ in length.
    error LengthMismatch();

    /// @dev Pooled collateral also needs Rain's factory to confirm each entry, which a spec cannot read, so the
    ///      success condition covers deployments without it.
    /// @custom:succeeds-if factory_ != address(0) && (forall uint256 i :: i < tokens_.length ==> tokens_[i] != address(0)) && (forall uint256 i :: i < vaults_.length ==> vaults_[i] != address(0)) && (forall uint256 i :: i < programCollaterals_.length ==> programCollaterals_[i] != address(0)) && programCollateralIndexes_.length == 0 && programCollaterals_.length == 0
    /// @custom:ensures FACTORY == factory_ && POOLED_ACCEPTS_PUBLIC == pooledAcceptsPublic_
    /// @custom:ensures forall uint256 i :: i < tokens_.length ==> isAcceptedToken(tokens_[i])
    /// @custom:ensures forall uint256 i :: i < vaults_.length ==> isAllowedVault(vaults_[i])
    /// @custom:ensures forall uint256 i :: i < programCollaterals_.length ==> isProgramCollateral(programCollaterals_[i])
    constructor(
        address factory_,
        address[] memory tokens_,
        address[] memory vaults_,
        address[] memory programCollaterals_,
        uint256[] memory programCollateralIndexes_,
        bool pooledAcceptsPublic_
    ) {
        if (factory_ == address(0)) revert ZeroAddress();
        FACTORY = factory_;
        POOLED_ACCEPTS_PUBLIC = pooledAcceptsPublic_;
        /// @custom:invariant i <= tokens_.length && FACTORY != address(0)
        /// @custom:invariant !_moreTokens[address(0)] && !_moreVaults[address(0)] && !_moreCollaterals[address(0)]
        /// @custom:invariant forall uint256 j :: _INLINE <= j && j < i ==> _moreTokens[tokens_[j]]
        /// @custom:invariant forall uint256 j :: j < i ==> tokens_[j] != address(0)
        for (uint256 i; i < tokens_.length; ++i) {
            if (tokens_[i] == address(0)) revert ZeroAddress();
            if (i >= _INLINE) _moreTokens[tokens_[i]] = true;
        }
        _TOKEN_0 = _entry(tokens_, 0);
        _TOKEN_1 = _entry(tokens_, 1);
        _TOKEN_2 = _entry(tokens_, 2);
        _TOKEN_3 = _entry(tokens_, 3);
        _MORE_TOKENS = tokens_.length > _INLINE;
        /// @custom:invariant i <= vaults_.length && FACTORY != address(0)
        /// @custom:invariant !_moreTokens[address(0)] && !_moreVaults[address(0)] && !_moreCollaterals[address(0)]
        /// @custom:invariant forall uint256 j :: _INLINE <= j && j < tokens_.length ==> _moreTokens[tokens_[j]]
        /// @custom:invariant forall uint256 j :: _INLINE <= j && j < i ==> _moreVaults[vaults_[j]]
        /// @custom:invariant forall uint256 j :: j < tokens_.length ==> isAcceptedToken(tokens_[j])
        /// @custom:invariant forall uint256 j :: j < i ==> vaults_[j] != address(0)
        for (uint256 i; i < vaults_.length; ++i) {
            if (vaults_[i] == address(0)) revert ZeroAddress();
            if (i >= _INLINE) _moreVaults[vaults_[i]] = true;
        }
        _VAULT_0 = _entry(vaults_, 0);
        _VAULT_1 = _entry(vaults_, 1);
        _VAULT_2 = _entry(vaults_, 2);
        _VAULT_3 = _entry(vaults_, 3);
        _MORE_VAULTS = vaults_.length > _INLINE;
        if (programCollateralIndexes_.length != programCollaterals_.length) {
            revert LengthMismatch();
        }
        /// @custom:invariant i <= programCollaterals_.length && FACTORY != address(0)
        /// @custom:invariant !_moreTokens[address(0)] && !_moreVaults[address(0)] && !_moreCollaterals[address(0)]
        /// @custom:invariant forall uint256 j :: _INLINE <= j && j < tokens_.length ==> _moreTokens[tokens_[j]]
        /// @custom:invariant forall uint256 j :: _INLINE <= j && j < vaults_.length ==> _moreVaults[vaults_[j]]
        /// @custom:invariant forall uint256 j :: _INLINE <= j && j < i ==> _moreCollaterals[programCollaterals_[j]]
        /// @custom:invariant forall uint256 j :: j < tokens_.length ==> isAcceptedToken(tokens_[j])
        /// @custom:invariant forall uint256 j :: j < vaults_.length ==> isAllowedVault(vaults_[j])
        /// @custom:invariant forall uint256 j :: j < i ==> programCollaterals_[j] != address(0)
        for (uint256 i; i < programCollaterals_.length; ++i) {
            if (programCollaterals_[i] == address(0)) revert ZeroAddress();
            // Proved once here, so a spend to pooled collateral reads no factory state.
            if (!isRainCollateral(programCollaterals_[i], programCollateralIndexes_[i])) {
                revert NotRainCollateral(programCollaterals_[i], programCollateralIndexes_[i]);
            }
            if (i >= _INLINE) _moreCollaterals[programCollaterals_[i]] = true;
        }
        _COLLATERAL_0 = _entry(programCollaterals_, 0);
        _COLLATERAL_1 = _entry(programCollaterals_, 1);
        _COLLATERAL_2 = _entry(programCollaterals_, 2);
        _COLLATERAL_3 = _entry(programCollaterals_, 3);
        _MORE_COLLATERALS = programCollaterals_.length > _INLINE;
        emit Configured(factory_, tokens_, vaults_, programCollaterals_, pooledAcceptsPublic_);
    }

    /// @inheritdoc ICardProvider
    /// @dev `hint` is `destination`'s index in the factory's `collateralProxies`, unused for pooled collateral,
    ///      which the constructor proved Rain's factory created.
    /// @custom:ensures result ==> isAcceptedToken(token) && destination != address(0)
    /// @custom:ensures result && isPrivate ==> isProgramCollateral(destination)
    /// @custom:ensures result && isProgramCollateral(destination) ==> isPrivate || POOLED_ACCEPTS_PUBLIC
    function isAuthorizedDestination(address payer, address destination, address token, uint256 hint, bool isPrivate)
        external
        view
        returns (bool)
    {
        if (!isAcceptedToken(token)) return false;
        if (isProgramCollateral(destination)) return isPrivate || POOLED_ACCEPTS_PUBLIC;
        // A private spend reaches only pooled collateral: any other names one cardholder.
        if (isPrivate || !isRainCollateral(destination, hint)) return false;
        // Rain's controller lets any admin withdraw, and an owner can add admins before handing ownership over,
        // so the payer must own the collateral and be its only admin.
        return _owner(destination) == payer && _isSoleAdmin(destination, payer);
    }

    /// @notice Whether spends may pay in `token`.
    /// @custom:ensures token == address(0) ==> !result
    /// @custom:ensures result == ((token != address(0) && (token == _TOKEN_0 || token == _TOKEN_1 || token == _TOKEN_2 || token == _TOKEN_3)) || (_MORE_TOKENS && _moreTokens[token]))
    function isAcceptedToken(address token) public view returns (bool) {
        return _inline(token, _TOKEN_0, _TOKEN_1, _TOKEN_2, _TOKEN_3) || (_MORE_TOKENS && _moreTokens[token]);
    }

    /// @inheritdoc ICardProvider
    /// @custom:ensures vault == address(0) ==> !result
    /// @custom:ensures result == ((vault != address(0) && (vault == _VAULT_0 || vault == _VAULT_1 || vault == _VAULT_2 || vault == _VAULT_3)) || (_MORE_VAULTS && _moreVaults[vault]))
    function isAllowedVault(address vault) public view returns (bool) {
        return _inline(vault, _VAULT_0, _VAULT_1, _VAULT_2, _VAULT_3) || (_MORE_VAULTS && _moreVaults[vault]);
    }

    /// @notice Whether `collateral` is one of the program's pooled collateral contracts.
    /// @custom:ensures collateral == address(0) ==> !result
    /// @custom:ensures result == ((collateral != address(0) && (collateral == _COLLATERAL_0 || collateral == _COLLATERAL_1 || collateral == _COLLATERAL_2 || collateral == _COLLATERAL_3)) || (_MORE_COLLATERALS && _moreCollaterals[collateral]))
    function isProgramCollateral(address collateral) public view returns (bool) {
        return _inline(collateral, _COLLATERAL_0, _COLLATERAL_1, _COLLATERAL_2, _COLLATERAL_3)
            || (_MORE_COLLATERALS && _moreCollaterals[collateral]);
    }

    /// @inheritdoc ICardProvider
    /// @custom:ensures !result
    function paused() external pure returns (bool) {
        return false;
    }

    /// @custom:ensures interfaceId == type(ICardProvider).interfaceId ==> result
    /// @custom:ensures interfaceId == type(IERC165).interfaceId ==> result
    /// @custom:ensures result ==> interfaceId == type(ICardProvider).interfaceId || interfaceId == type(IERC165).interfaceId
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICardProvider).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Whether `collateral` is the collateral contract Rain's factory recorded at `index` of its
    ///         `collateralProxies`. An index past the end reverts in the factory and reads as false.
    /// @custom:ensures collateral == address(0) ==> !result
    function isRainCollateral(address collateral, uint256 index) public view returns (bool) {
        if (collateral == address(0)) return false;
        // The constructor calls this once per pooled collateral, a list the deployer fixes.
        // forge-lint: disable-start(calls-loop)
        (bool ok, bytes memory ret) =
            FACTORY.staticcall(abi.encodeCall(IRainCollateralFactory.collateralProxies, (index)));
        // forge-lint: disable-end(calls-loop)
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

    /// @dev Whether nonzero `account` is one of a set's inline entries; unused entries are zero.
    function _inline(address account, address a0, address a1, address a2, address a3) private pure returns (bool) {
        return account != address(0) && (account == a0 || account == a1 || account == a2 || account == a3);
    }

    /// @dev `list[i]`, or zero past its end.
    function _entry(address[] memory list, uint256 i) private pure returns (address) {
        return i < list.length ? list[i] : address(0);
    }
}
