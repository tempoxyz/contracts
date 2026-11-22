// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ISpenderHandler, SpenderStatus } from "./ISpenderHandler.sol";
import { SpenderDelegator } from "./SpenderDelegator.sol";
import { SpenderFactoryErrorsAndEvents } from "./SpenderFactoryErrorsAndEvents.sol";
import {
    HandlerConfig,
    SpenderFactoryStorage,
    SpenderFactoryStorageLib
} from "./lib/SpenderFactoryStorage.sol";

import { IFactory } from "./lib/IFactory.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "openzeppelin-contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {
    UUPSUpgradeable
} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    PausableUpgradeable
} from "openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IBeacon } from "openzeppelin-contracts/proxy/beacon/IBeacon.sol";
import { LibClone } from "solady/utils/LibClone.sol";

interface ISpenderDelegatorMigration {

    function migrateBeacon(address newBeacon) external;

}

/**
 * @title SpenderFactory
 * @notice Factory contract for deploying and managing "Spender" contracts, which represent an
 * entity
 *         that can pull funds from wallets.
 *         The Factory is the entrypoint for deploying new Spenders, managing them, and moving funds
 *         on behalf of Spenders. Deploying a contract per-spender scopes token allowances to a
 *         a particular address.
 */
contract SpenderFactory is
    SpenderFactoryErrorsAndEvents,
    IFactory,
    IBeacon,
    AccessControlDefaultAdminRulesUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant DEBITOR_ROLE = keccak256("DEBITOR_ROLE");

    /**
     * @notice Locks the implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory
     */
    function initialize(address initial_admin, address initial_governer, address pauser)
        external
        initializer
    {
        require(initial_admin != address(0), AccessControlInvalidDefaultAdmin(address(0)));
        require(pauser != address(0), InvalidManager());
        require(initial_governer != address(0), InvalidGovernor());

        // This contract is meant to set the initial_admin to a TimelockController, which already
        // enforces a delay
        __AccessControlDefaultAdminRules_init(0, initial_admin);
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(GOVERNANCE_ROLE, initial_governer);

        // role admins
        _setRoleAdmin(MANAGER_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(DEBITOR_ROLE, MANAGER_ROLE);

        SpenderFactoryStorageLib.getStorage().delegator =
            address(new SpenderDelegator(IFactory(address(this))));
    }

    /**
     * @notice Migrates state for the v2 upgrade
     * @dev Deploys a new SpenderDelegator bound to this factory and stores it as the beacon
     *      implementation. Called atomically via upgradeToAndCall — never as a standalone tx.
     */
    function initializeV2() external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        SpenderFactoryStorageLib.getStorage().delegator =
            address(new SpenderDelegator(IFactory(address(this))));
    }

    // ============ External Functions ============

    /**
     * @notice Creates a new spender contract as a minimal proxy to the delegator
     * @param spenderId Unique identifier for the spender
     * @param destinations Addresses that will receive spender payments (1–10)
     * @return spenderAddress Address of the deployed spender contract
     */
    function createSpender(bytes32 spenderId, address[] calldata destinations)
        external
        onlyRole(MANAGER_ROLE)
        whenNotPaused
        returns (address spenderAddress)
    {
        require(destinations.length > 0, InvalidDestination());
        require(destinations.length <= 10, TooManyDestinations());
        for (uint256 i = 0; i < destinations.length; i++) {
            require(destinations[i] != address(0), InvalidDestination());
        }
        SpenderFactoryStorage storage $ = SpenderFactoryStorageLib.getStorage();
        require($.delegator != address(0), InvalidSpenderAddress());
        spenderAddress = LibClone.deployDeterministicERC1967BeaconProxy(address(this), spenderId);
        _registerSpender(spenderId, destinations, spenderAddress);

        emit SpenderCreated(spenderId, spenderAddress);
    }

    /**
     * @notice Registers an existing contract as a spender without deploying a new one.
     * @dev Use this to migrate spenders created by a legacy factory into this factory's registry.
     * @param spenderId Unique identifier for the spender
     * @param destinations Addresses that will receive spender payments (1–10)
     * @param contractAddress Address of the existing spender contract
     */
    function createSpenderWithExistingContract(
        bytes32 spenderId,
        address[] calldata destinations,
        address contractAddress
    ) external onlyRole(MANAGER_ROLE) whenNotPaused {
        require(destinations.length > 0, InvalidDestination());
        require(destinations.length <= 10, TooManyDestinations());
        for (uint256 i = 0; i < destinations.length; i++) {
            require(destinations[i] != address(0), InvalidDestination());
        }
        require(contractAddress != address(0), InvalidSpenderAddress());
        _registerSpender(spenderId, destinations, contractAddress);

        emit SpenderCreated(spenderId, contractAddress);
    }

    /**
     * @notice Updates a spender's payment destination
     * @param spenderId Identifier of the spender to update
     * @param destination New destination address
     * @param allowed Whether the destination is allowed
     */
    function updateSpenderDestination(bytes32 spenderId, address destination, bool allowed)
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
    {
        getSpenderAddress(spenderId); // reverts UnknownSpender if not yet registered
        require(destination != address(0), InvalidDestination());
        SpenderFactoryStorageLib.getStorage().allowedSpenderDestinations[spenderId][destination] =
        allowed;
        emit DestinationUpdated(spenderId, destination, allowed);
    }

    /**
     * @notice Transfers tokens to a destination for a given spender
     * @param spenderId Unique identifier for the spender
     * @param destination Destination address
     * @param data Serialized data of the transfer
     */
    function transferToDestination(bytes32 spenderId, address destination, bytes calldata data)
        external
        onlyRole(DEBITOR_ROLE)
        whenNotPaused
    {
        require(isAuthorizedDestination(spenderId, destination), NotAuthorizedDestination());
        address spender = getSpenderAddress(spenderId);
        ISpenderHandler(spender).transferToDestination(destination, data);
    }

    /**
     * @notice Like transferToDestination, but validates balance and allowances before transferring.
     * @dev Reverts with specific errors instead of the opaque TransferFromFailed.
     *      Costs extra gas — use for debugging or when actionable revert reasons are needed.
     * @param spenderId Unique identifier for the spender
     * @param destination Destination address
     * @param data Serialized data of the transfer
     */
    function transferToDestinationStrict(
        bytes32 spenderId,
        address destination,
        bytes calldata data
    ) external onlyRole(DEBITOR_ROLE) whenNotPaused {
        require(isAuthorizedDestination(spenderId, destination), NotAuthorizedDestination());
        address spender = getSpenderAddress(spenderId);
        ISpenderHandler(spender).transferToDestinationStrict(destination, data);
    }

    /**
     * @notice Returns the balance that can be pulled by the spender
     * @param spenderId Spender identifier
     * @param data Serialized data for the transfer
     * @return _ The token balance of `account`
     */
    function availableBalance(bytes32 spenderId, bytes calldata data) external returns (uint256) {
        address spender = getSpenderAddress(spenderId);
        return ISpenderHandler(spender).availableBalance(data);
    }

    /**
     * @notice Forwards a manager call to a spender contract
     * @param spenderId Unique identifier for the spender
     * @param data Calldata to forward
     */
    function managerCall(bytes32 spenderId, bytes calldata data)
        external
        onlyRole(MANAGER_ROLE)
        whenNotPaused
    {
        address spender = getSpenderAddress(spenderId);
        ISpenderHandler(spender).managerCall(data);
    }

    /**
     * @notice Forwards a governor call to a spender contract
     * @param spenderId Unique identifier for the spender
     * @param data Calldata to forward
     */
    function governorCall(bytes32 spenderId, bytes calldata data)
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
    {
        address spender = getSpenderAddress(spenderId);
        ISpenderHandler(spender).governorCall(data);
    }

    /**
     * @notice Pauses the factory
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the factory
     */
    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    // ============ Admin Functions ============

    /**
     * @notice Sets a spender handler implementation
     * Requires the admin role because this should be kept behind a Timelock controller.
     */
    function setSpenderHandler(bytes2 prefix, ISpenderHandler handler)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setSpenderHandler(prefix, handler);
    }

    function updateSpenderHandlerStatus(bytes2 prefix, SpenderStatus status)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        _updateSpenderHandlerStatus(prefix, status);
    }

    function updateSpenderHandlerAllowlist(bytes2 prefix, bytes32 spenderId, bool allowed)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        _updateSpenderHandlerAllowlist(prefix, spenderId, allowed);
    }

    // ============ Public View Functions ============

    /**
     * @notice Derives the address of a spender contract
     * @param spenderId Spender identifier
     * @return Stored address of the spender contract
     */
    function getSpenderAddress(bytes32 spenderId) public view returns (address) {
        address spender = SpenderFactoryStorageLib.getStorage().spenderAddresses[spenderId];
        require(spender != address(0), UnknownSpender());
        return spender;
    }

    /**
     * @notice Checks if a destination is authorized for a spender
     * @param spenderId Spender identifier
     * @param destination Destination address
     * @return True if destination is authorized, false otherwise
     */
    function isAuthorizedDestination(bytes32 spenderId, address destination)
        public
        view
        returns (bool)
    {
        return SpenderFactoryStorageLib.getStorage()
        .allowedSpenderDestinations[spenderId][destination];
    }

    function getSpenderHandler(bytes2 key) external view returns (ISpenderHandler spender) {
        return ISpenderHandler(SpenderFactoryStorageLib.getStorage().handlerConfigs[key].handler);
    }

    function getSpenderHandlerWithCheckedPermissions(bytes2 key, address user)
        external
        view
        returns (ISpenderHandler spender)
    {
        HandlerConfig storage config = SpenderFactoryStorageLib.getStorage().handlerConfigs[key];

        require(config.status != SpenderStatus.Disabled, SpenderHandlerDisabled());

        if (config.status == SpenderStatus.Enabled) {
            return config.handler;
        }

        require(config.allowlist[user], SpenderHandlerNotAllowed());

        return config.handler;
    }

    /// @notice Satisfies IBeacon so that legacy ERC-1967 beacon proxies (created by the old
    ///         SpenderFactory) can read the current implementation after their beacon slot is
    ///         migrated to point at this factory.
    function implementation() external view override returns (address) {
        return SpenderFactoryStorageLib.getStorage().delegator;
    }

    // ============ Admin Functions — Migration ============

    /// @notice Migrates legacy ERC-1967 beacon proxies to use this factory as their beacon.
    /// @dev Must be called AFTER the old factory's beacon implementation has been set to a
    ///      SpenderDelegator deployed with this factory as its FACTORY address. Each call to
    ///      a spender proxy delegatecalls into SpenderDelegator.migrateBeacon, which writes
    ///      this factory's address into the proxy's ERC-1967 beacon slot. After this call,
    ///      the old factory has no further authority over those proxies.
    /// @param spenders Addresses of the legacy beacon proxy spenders to migrate.
    function migrateBeacons(address[] calldata spenders) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < spenders.length; i++) {
            require(spenders[i] != address(0), InvalidSpenderAddress());
            ISpenderDelegatorMigration(spenders[i]).migrateBeacon(address(this));
        }
    }

    // ============ Internal Functions ============

    /**
     * @notice Registers a new spender in storage
     */
    function _registerSpender(
        bytes32 spenderId,
        address[] calldata destinations,
        address spenderAddress
    ) internal {
        SpenderFactoryStorage storage $ = SpenderFactoryStorageLib.getStorage();
        require($.spenderAddresses[spenderId] == address(0), SpenderAlreadyRegistered());
        for (uint256 i = 0; i < destinations.length; i++) {
            $.allowedSpenderDestinations[spenderId][destinations[i]] = true;
            emit DestinationUpdated(spenderId, destinations[i], true);
        }
        $.spenderAddresses[spenderId] = spenderAddress;
    }

    function _setSpenderHandler(bytes2 prefix, ISpenderHandler handler) private {
        SpenderFactoryStorage storage $ = SpenderFactoryStorageLib.getStorage();
        address oldValue = address($.handlerConfigs[prefix].handler);
        $.handlerConfigs[prefix].handler = handler;
        emit SpenderHandlerUpdated(prefix, oldValue, address(handler));
    }

    function _updateSpenderHandlerAllowlist(bytes2 prefix, bytes32 spenderId, bool allowed)
        private
    {
        address spenderAddress = getSpenderAddress(spenderId);

        SpenderFactoryStorage storage $ = SpenderFactoryStorageLib.getStorage();
        HandlerConfig storage value = $.handlerConfigs[prefix];
        value.allowlist[spenderAddress] = allowed;
        emit SpenderHandlerAllowlistModified(prefix, spenderId, allowed);
    }

    function _updateSpenderHandlerStatus(bytes2 prefix, SpenderStatus status) private {
        SpenderFactoryStorage storage $ = SpenderFactoryStorageLib.getStorage();
        SpenderStatus oldStatus = $.handlerConfigs[prefix].status;
        $.handlerConfigs[prefix].status = status;
        emit SpenderHandlerStatusUpdated(prefix, oldStatus, status);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    { }

    function paused() public view override(PausableUpgradeable, IFactory) returns (bool) {
        return super.paused();
    }

}
