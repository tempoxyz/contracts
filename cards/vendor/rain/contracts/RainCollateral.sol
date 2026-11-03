// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IRainCollateralFactory.sol";

using SafeERC20 for IERC20;

/**
 *  @title Collateral contract
 *  @notice Used to deposit assets as collateral.
 *          Withdrawal and liquidation are done by RainCollateralController contract.
 *          Admins can withdraw and make payment by RainCollateralController contract.
 *          Owner can add/remove admin.
 */
contract RainCollateral is Initializable, Ownable {
    /// @notice name of collateral
    string public name;

    /// @notice RainCollateralFactory Address
    ///         It is used to get controller address held in factory
    address public factory;

    /// @notice Admins Of this contracts.
    /// They will be checked from RainCollateralController._isCollateralAdmin
    address[] public admins;

    /// @notice Maximum number of admins
    uint8 public constant MAX_ADMINS = 30;

    /// @notice Used to authorize transactions from RainCollateralController contract only
    modifier onlyController() {
        require(_getController() == msg.sender, "Unauthorized");
        _;
    }

    /// @notice Revert if address param is 0x0
    modifier validAddress(address _address) {
        require(_address != address(0), "Address Zero");
        _;
    }

    /// @notice Prevent the implementation contract from being used
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Used to initialize this contract
     * @param _name name of collateral
     * @param _owner address of collateral owner
     *               also becomes the first admin
     */
    function initialize(string memory _name, address _owner)
        public
        validAddress(_owner)
        initializer
    {
        _transferOwnership(_owner);

        name = _name;
        factory = msg.sender;
        admins.push(_owner);
    }

    /**
     * @notice Check if _address is admin of this contract
     * @param _address address to check
     * @return status If true => is admin
     */
    function isAdmin(address _address) public view returns (bool) {
        // It is expected that the number of admins would be around 1~5
        for (uint256 i = 0; i < admins.length; i++) {
            if (admins[i] == _address) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Used to add a collateral admin
     * @dev only admin can call this function
     * @param _admin new admin address
     */
    function addAdmin(address _admin) external validAddress(_admin) onlyOwner {
        require(admins.length < MAX_ADMINS, "Max admins");

        (bool found, ) = _getAdminIndex(_admin);
        require(!found, "Admin already exists");
        admins.push(_admin);
    }

    /**
     * @notice Used to remove a collateral admin
     * @dev only admin can call this function
     * @param _admin admin address to be removed
     */
    function removeAdmin(address _admin)
        external
        validAddress(_admin)
        onlyOwner
    {
        require(admins.length > 1, "Last admin");

        (bool found, uint256 index) = _getAdminIndex(_admin);
        require(found, "Admin not found");
        admins[index] = admins[admins.length - 1];
        admins.pop();
    }

    /**
     * @notice Used to withdraw asset that this contract owns.
     * @dev only active RainCollateralController can call this function
     * @param _recipient recipient address
     * @param _amount withdrawed amount
     */
    function withdrawAsset(
        address _asset,
        address _recipient,
        uint256 _amount
    ) external onlyController {
        IERC20(_asset).safeTransfer(_recipient, _amount);
    }

    /**
     * @notice Used to get admin index from admins array
     * @dev Internal view function
     * @param _admin querying admin address
     * @return found if index is found or not
     * @return index admin address if found
     */
    function _getAdminIndex(address _admin)
        internal
        view
        returns (bool found, uint256 index)
    {
        // It is expected that the number of admins would be around 1~5
        for (uint256 i = 0; i < admins.length; i++) {
            if (admins[i] == _admin) {
                return (true, i);
            }
        }
        // Index value 0 is meaningless here as admin was not found
        return (false, 0);
    }

    /**
     * @notice Used to get RainCollateralController contract address
     * @dev Internal function used to interact with RainCollateralController contract
     * @return address RainCollateralController contract address
     */
    function _getController() internal view returns (address) {
        // Controller address is kept in RainCollateralFactory
        return IRainCollateralFactory(factory).controller();
    }

    /**
     * @notice Block renounceOwnership
     * @dev Prevent assets to be stuck in the contract without an owner
     */
    function renounceOwnership() public virtual override onlyOwner {
        revert("Cannot renounce ownership");
    }
}
