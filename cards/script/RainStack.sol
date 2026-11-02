// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CommonBase } from "forge-std/Base.sol";

/// @notice The subset of Rain's `RainCollateralFactory` (vendor/rain) its deployers call.
interface IRainFactoryAdmin {
    function initialize(address controller, address initialImplementation) external;

    function createCollateralContract(string calldata name, address user) external returns (address);

    function getBeacon() external view returns (address);

    function controller() external view returns (address);
}

/// @notice The subset of Rain's `RainCollateralController` (vendor/rain) tests and the E2E call.
interface IRainController {
    function controllerAdmin() external view returns (address);

    function treasury() external view returns (address);

    function nonce(address collateral) external view returns (uint256);

    function PAY_TYPE_HASH() external view returns (bytes32);

    function WITHDRAW_TYPE_HASH() external view returns (bytes32);

    function EIP712_DOMAIN_TYPE_HASH() external view returns (bytes32);

    function makePayment(
        address collateral,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256 expiresAt,
        bytes32 salt,
        bytes calldata signature
    ) external;

    function withdrawAsset(
        address collateral,
        address asset,
        uint256 amount,
        address recipient,
        uint256 expiresAt,
        bytes32 salt,
        bytes calldata signature
    ) external;

    function liquidateAsset(address collateral, address[] calldata assets, uint256[] calldata amounts) external;
}

/// @notice Deploys Rain's collateral contracts as Rain runs them (factory, beacon, implementation and
///         controller), from the creation code in test/fixtures/rain.json that script/rain/build-fixture.sh
///         builds from vendor/rain with Rain's own compiler settings. The factory is deployed directly and
///         initialized by the caller, who becomes its owner, as Rain's own deployer is.
abstract contract RainStack is CommonBase {
    struct Rain {
        IRainFactoryAdmin factory;
        IRainController controller;
        address implementation;
    }

    string internal constant RAIN_FIXTURE = "test/fixtures/rain.json";

    /// @dev Deploys from the script or test contract itself; under `vm.startBroadcast` each create is broadcast.
    function _deployRain(address controllerAdmin, address treasury) internal returns (Rain memory rain) {
        string memory json = vm.readFile(RAIN_FIXTURE);
        rain.implementation = _create(vm.parseJsonBytes(json, ".contracts.RainCollateral.bytecode"));
        rain.controller = IRainController(
            _create(
                bytes.concat(
                    vm.parseJsonBytes(json, ".contracts.RainCollateralController.bytecode"),
                    abi.encode(controllerAdmin, treasury)
                )
            )
        );
        rain.factory = IRainFactoryAdmin(_create(vm.parseJsonBytes(json, ".contracts.RainCollateralFactory.bytecode")));
        rain.factory.initialize(address(rain.controller), rain.implementation);
    }

    function _create(bytes memory code) private returns (address deployed) {
        assembly {
            deployed := create(0, add(code, 0x20), mload(code))
        }
        require(deployed != address(0), "Rain fixture deploy");
    }
}
