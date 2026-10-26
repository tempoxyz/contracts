// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IAccountant } from "../../interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../interfaces/external/veda/IBoringQueue.sol";
import { IBoringVault } from "../../interfaces/external/veda/IBoringVault.sol";
import { ITeller } from "../../interfaces/external/veda/ITeller.sol";
import { IVedaPeripheryRegistry } from "../../interfaces/external/veda/IVedaPeripheryRegistry.sol";

interface IVedaRegistryEngine {
    function peripheryRegistry() external view returns (IVedaPeripheryRegistry);
    function vault() external view returns (IBoringVault);
    function baseAsset() external view returns (address);
}

/// @title VedaPeripheryRegistry
/// @notice Engine-bound source of truth for the Teller, optional Queue, and Accountant attached to one BoringVault.
/// @dev Only the BoringVault's current owner can bind the registry's single engine or publish a tuple.
///      The engine binding is write-once. The bound engine's administrator cannot pick different Veda
///      modules; it may only activate the registry's latest version. A zero Queue disables new async exits
///      while preserving immediate Teller entry and exit.
contract VedaPeripheryRegistry is IVedaPeripheryRegistry {
    IBoringVault public immutable vault;
    address public immutable baseAsset;

    address public engine;
    ITeller public teller;
    IBoringQueue public queue;
    IAccountant public accountant;
    uint64 public version;

    event VedaEngineBound(address indexed engine);
    event VedaPeripheryPublished(
        uint64 indexed version, address indexed teller, address indexed queue, address accountant
    );

    error EngineAlreadyBound(address currentEngine);
    error InvalidVedaEngine(address account);
    error InvalidVedaPeriphery(address account);
    error InvalidVedaPeripheryWiring(address component, address expected, address actual);
    error NotBoringVaultOwner(address caller, address expectedOwner);
    error ZeroAddress();

    constructor(IBoringVault vault_, address baseAsset_) {
        _validateContract(address(vault_));
        _validateContract(baseAsset_);
        vault = vault_;
        baseAsset = baseAsset_;
    }

    /// @notice Permanently binds the only engine permitted to activate this registry.
    /// @dev The engine must already point back to this registry and its immutable BoringVault and base asset.
    function bindEngine(address engine_) external {
        _requireBoringVaultOwner();
        if (engine != address(0)) revert EngineAlreadyBound(engine);
        if (engine_ == address(0)) revert ZeroAddress();
        if (engine_.code.length == 0) revert InvalidVedaEngine(engine_);

        IVedaRegistryEngine candidate = IVedaRegistryEngine(engine_);
        _requireWiring(engine_, address(this), address(candidate.peripheryRegistry()));
        _requireWiring(engine_, address(vault), address(candidate.vault()));
        _requireWiring(engine_, baseAsset, candidate.baseAsset());

        engine = engine_;
        emit VedaEngineBound(engine_);
    }

    /// @notice Publishes the canonical Veda tuple for the bound engine.
    /// @dev Publication may happen before engine binding. Activation remains engine-local so the
    ///      engine owner can pause deposits, enforce a reviewed safe-rate range, and preserve old
    ///      Queue dependencies before switching. `newQueue` may be zero to deploy or return to
    ///      immediate-only operation.
    function setVedaPeriphery(ITeller newTeller, IBoringQueue newQueue, IAccountant newAccountant) external {
        _requireBoringVaultOwner();

        _validateVedaPeriphery(newTeller, newQueue, newAccountant);
        teller = newTeller;
        queue = newQueue;
        accountant = newAccountant;
        version++;
        emit VedaPeripheryPublished(version, address(newTeller), address(newQueue), address(newAccountant));
    }

    function _validateVedaPeriphery(ITeller newTeller, IBoringQueue newQueue, IAccountant newAccountant) private view {
        _validateContract(address(newTeller));
        _validateContract(address(newAccountant));

        address expectedVault = address(vault);
        _requireWiring(address(newTeller), expectedVault, newTeller.vault());
        _requireWiring(address(newTeller), address(newAccountant), newTeller.accountant());
        if (address(newQueue) != address(0)) {
            _validateContract(address(newQueue));
            _requireWiring(address(newQueue), expectedVault, newQueue.boringVault());
            _requireWiring(address(newQueue), address(newAccountant), newQueue.accountant());
        }
        _requireWiring(address(newAccountant), expectedVault, newAccountant.vault());
        _requireWiring(address(newAccountant), baseAsset, newAccountant.base());
    }

    function _requireBoringVaultOwner() private view {
        address expectedOwner = vault.owner();
        if (msg.sender != expectedOwner) revert NotBoringVaultOwner(msg.sender, expectedOwner);
    }

    function _validateContract(address account) private view {
        if (account == address(0)) revert ZeroAddress();
        if (account.code.length == 0) revert InvalidVedaPeriphery(account);
    }

    function _requireWiring(address component, address expected, address actual) private pure {
        if (actual != expected) revert InvalidVedaPeripheryWiring(component, expected, actual);
    }
}
