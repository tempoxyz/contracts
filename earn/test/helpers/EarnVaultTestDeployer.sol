// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { EarnFees } from "../../src/core/EarnFees.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import {
    DistributorConfig,
    EarnVaultControls,
    EngineMigrationMode
} from "../../src/interfaces/core/EarnVaultTypes.sol";
import { FeeConfig } from "../../src/interfaces/core/EarnFeeTypes.sol";
import { IEarnFees } from "../../src/interfaces/core/IEarnFees.sol";

library EarnVaultTestDeployer {
    function deploy(address engine, address earnShare, address operator, FeeConfig memory fees)
        internal
        returns (EarnVault earnVault)
    {
        EarnVault implementation = new EarnVault();
        return deployWithImplementation(
            address(implementation),
            engine,
            earnShare,
            operator,
            defaultControls(operator),
            DistributorConfig(address(0), 0),
            fees
        );
    }

    function deploy(
        address engine,
        address earnShare,
        address operator,
        EarnVaultControls memory controls,
        FeeConfig memory fees
    ) internal returns (EarnVault earnVault) {
        EarnVault implementation = new EarnVault();
        return deployWithImplementation(
            address(implementation), engine, earnShare, operator, controls, DistributorConfig(address(0), 0), fees
        );
    }

    function deploy(
        address engine,
        address earnShare,
        address operator,
        EarnVaultControls memory controls,
        DistributorConfig memory distributorConfig,
        FeeConfig memory fees
    ) internal returns (EarnVault earnVault) {
        EarnVault implementation = new EarnVault();
        return deployWithImplementation(
            address(implementation), engine, earnShare, operator, controls, distributorConfig, fees
        );
    }

    function deployWithImplementation(
        address implementation,
        address engine,
        address earnShare,
        address operator,
        EarnVaultControls memory controls,
        DistributorConfig memory distributorConfig,
        FeeConfig memory fees
    ) internal returns (EarnVault earnVault) {
        earnVault = EarnVault(address(new ERC1967Proxy(implementation, bytes(""))));
        EarnFees feeImplementation = new EarnFees();
        address earnFees = Clones.clone(address(feeImplementation));
        IEarnFees(earnFees).initialize(address(earnVault), earnShare, fees);
        earnVault.initialize(engine, earnShare, earnFees, operator, controls, distributorConfig);
    }

    function defaultControls(address operator) internal pure returns (EarnVaultControls memory controls) {
        controls = EarnVaultControls({
            emergencyGuardian: operator,
            asyncJanitor: operator,
            maxManagedAssets: 0,
            migrationMode: EngineMigrationMode.OperatorEnabled
        });
    }
}
