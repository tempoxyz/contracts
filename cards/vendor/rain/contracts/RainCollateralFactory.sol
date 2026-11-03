// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "./RainCollateralBeacon.sol";
import "./RainCollateral.sol";

/**
 *  @title RainCollateralFactory Contract
 *  @notice Used to create user RainCollateral contracts.
            Also RainCollateralController address is saved here so that
            RainCollateral contracts can find which controller address has the permission
            to run logical functions.
 *  @dev This is an upgradable contract
 */

contract RainCollateralFactory is OwnableUpgradeable {
    RainCollateralBeacon public beacon;

    /// @notice RainCollateralController address,
    /// working as beacon from RainCollateral to RainCollateralController
    address public controller;

    /// @notice RainCollateral contract address array
    address[] public collateralProxies;

    /// @notice Emitted when a new RainCollateral contract is deployed
    event NewRainCollateral(
        address indexed _collateralProxy,
        string _name,
        address _user
    );

    /// @notice Revert if address param is 0x0
    modifier validAddress(address _address) {
        require(_address != address(0), "Address Zero");
        _;
    }

    /**
     * @notice Used to initialize
     * @param _controller RainCollateralController address
     */
    function initialize(address _controller, address _initialImplementation)
        public
        initializer
        validAddress(_controller)
        validAddress(_initialImplementation)
    {
        __Ownable_init();
        controller = _controller;
        beacon = new RainCollateralBeacon(_initialImplementation, owner());
    }

    /**
     * @notice Used to update RainCollateralController address
     * @dev Only owner can call this function
     * @param _controller new RainCollateralController address
     */
    function updateController(address _controller)
        external
        onlyOwner
        validAddress(_controller)
    {
        controller = _controller;
    }

    /**
     * @notice Used to deploy a new RainCollateral contract
     * @dev owner deploys a new RainCollateral contract for this user
     * @param _name collateral name
     * @param _user user address
     * @return collateralProxyAddress new RainCollateral address
     */
    function createCollateralContract(string memory _name, address _user)
        external
        onlyOwner
        returns (address collateralProxyAddress)
    {
        BeaconProxy collateralProxy = new BeaconProxy(
            address(beacon),
            abi.encodeWithSelector(
                RainCollateral.initialize.selector,
                _name,
                _user
            )
        );
        collateralProxyAddress = address(collateralProxy);
        collateralProxies.push(collateralProxyAddress);
        emit NewRainCollateral(collateralProxyAddress, _name, _user);
    }

    /**
     * @notice Get the address of the beacon contract
     *         to the RainCollateral implementation contract
     * @dev actual implementation contract address can be retrieved by getImplementation function
     * @return address of the becon contract
     */
    function getBeacon() public view returns (address) {
        return address(beacon);
    }

    /**
     * @notice Get the address of RainCollateral implementation contract
     * @dev Retrived via beacon contract
     * @return address of RainCollateral implementation contract
     */
    function getImplementation() public view returns (address) {
        return beacon.implementation();
    }
}
