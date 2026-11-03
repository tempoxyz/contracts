// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";

import { EarnFactory } from "tempo-earn/core/EarnFactory.sol";
import { EarnFees } from "tempo-earn/core/EarnFees.sol";
import { EarnVault } from "tempo-earn/core/EarnVault.sol";
import { Simple4626Vault } from "tempo-earn/demo/Simple4626Vault.sol";
import { ERC4626Engine, IERC4626Vault } from "tempo-earn/engines/ERC4626Engine.sol";
import { FeeConfig } from "tempo-earn/interfaces/core/EarnFeeTypes.sol";
import {
    DistributorConfig,
    EarnVaultControls,
    EngineMigrationMode
} from "tempo-earn/interfaces/core/EarnVaultTypes.sol";
import { ZoneRouter } from "zone-router/ZoneRouter.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";

import { CardSettler } from "../../src/core/CardSettler.sol";
import { CardSpender } from "../../src/core/CardSpender.sol";
import { IRainCollateralFactory } from "../../src/providers/rain/IRain.sol";
import { RainCardProgram } from "../../src/providers/rain/RainCardProgram.sol";
import { RainStack } from "./RainStack.sol";

/// @notice A card program's router mode: Spend only on `zoneId`, through `settler` alone.
library CardSpendMode {
    function forSettler(uint32 zoneId, address settler) internal pure returns (ZoneRouter.Mode memory mode) {
        mode.zoneId = zoneId;
        mode.enabledOps = uint8(1 << 2);
        mode.settlers = new address[](1);
        mode.settlers[0] = settler;
    }
}

/// @notice Deploys a Rain card program for the card E2E (`e2e/cards`) on a disposable L1: Rain's own
///         collateral contracts from the vendored sources, with the deployer as Rain (factory owner) and
///         RAIN_ADMIN as its controller admin; the cardholder's own collateral contract and the program's
///         pooled one; with EARN=true, a Tempo Earn vault over pathUSD; the `RainCardProgram` adapter
///         accepting pathUSD (and that vault); the provider-agnostic `CardSpender` and `CardSettler`; the
///         Spend-mode `ZoneRouter` for ZONE_ID listing the settler; and a TIP-20 to launch the Zone with.
///         Reads DEPLOYER_PK, RAIN_ADMIN, RAIN_TREASURY, RAIN_PAUSER, CARDHOLDER, PARTNER, ZONE_ID, EARN and
///         OUT.
contract CardsE2EDeploy is Script, RainStack {
    uint64 internal constant ALWAYS_ALLOW_POLICY_ID = 1;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(deployerPk);
        uint256 zoneIdValue = vm.envUint("ZONE_ID");
        require(zoneIdValue != 0 && zoneIdValue <= type(uint32).max, "ZONE_ID out of range");
        bool earn = vm.envOr("EARN", false);

        vm.startBroadcast(deployerPk);
        Rain memory rain = _deployRain(vm.envAddress("RAIN_ADMIN"), vm.envAddress("RAIN_TREASURY"));
        address cardholderCollateral = rain.factory.createCollateralContract("cardholder", vm.envAddress("CARDHOLDER"));
        address programCollateral = rain.factory.createCollateralContract("program", vm.envAddress("PARTNER"));

        address vault = earn ? _deployEarn(deployer) : address(0);
        address[] memory tokens = new address[](1);
        tokens[0] = StdTokens.PATH_USD_ADDRESS;
        address[] memory vaults = new address[](earn ? 1 : 0);
        if (earn) vaults[0] = vault;
        address[] memory pooled = new address[](1);
        pooled[0] = programCollateral;
        RainCardProgram program =
            new RainCardProgram(address(rain.factory), tokens, vaults, pooled, vm.envAddress("RAIN_PAUSER"));
        CardSpender spender = new CardSpender(program);
        CardSettler settler = CardSettler(spender.SETTLER());
        ZoneRouterFactory routerFactory = new ZoneRouterFactory();
        address router = routerFactory.deploy(CardSpendMode.forSettler(uint32(zoneIdValue), address(settler)));
        // The Zone factory only launches with a token whose TIP-403 transfer policy is set.
        address zoneToken = StdPrecompiles.TIP20_FACTORY
            .createToken(
                "Zone Launch USD",
                "zlUSD",
                "USD",
                ITIP20(StdTokens.PATH_USD_ADDRESS),
                deployer,
                keccak256(abi.encode("cards-e2e.launch-token", deployer, block.timestamp))
            );
        ITIP20(zoneToken).changeTransferPolicyId(ALWAYS_ALLOW_POLICY_ID);
        vm.stopBroadcast();

        require(IRainCollateralFactory(address(rain.factory)).collateralProxies(0) == cardholderCollateral, "index 0");
        require(IRainCollateralFactory(address(rain.factory)).collateralProxies(1) == programCollateral, "index 1");

        string memory key = "cards-e2e";
        vm.serializeAddress(key, "rainFactory", address(rain.factory));
        vm.serializeAddress(key, "rainController", address(rain.controller));
        vm.serializeAddress(key, "cardholderCollateral", cardholderCollateral);
        vm.serializeUint(key, "cardholderCollateralIndex", 0);
        vm.serializeAddress(key, "programCollateral", programCollateral);
        vm.serializeUint(key, "programCollateralIndex", 1);
        vm.serializeAddress(key, "program", address(program));
        vm.serializeAddress(key, "spender", address(spender));
        vm.serializeAddress(key, "settler", address(settler));
        vm.serializeAddress(key, "routerFactory", address(routerFactory));
        vm.serializeAddress(key, "router", router);
        if (earn) {
            vm.serializeAddress(key, "earnVault", vault);
            vm.serializeAddress(key, "earnShare", EarnVault(vault).earnShare());
        }
        string memory json = vm.serializeAddress(key, "zoneToken", zoneToken);
        vm.writeJson(json, vm.envString("OUT"));
    }

    /// @dev A Tempo Earn vault over pathUSD through an ERC-4626 venue, without fees, owned by the deployer.
    function _deployEarn(address owner) private returns (address) {
        Simple4626Vault venue = new Simple4626Vault(StdTokens.PATH_USD_ADDRESS, "Vault pathUSD", "vpUSD", 6);
        ERC4626Engine engine = new ERC4626Engine(IERC4626Vault(address(venue)), owner, "", "");
        EarnFactory factory =
            new EarnFactory(address(StdPrecompiles.TIP20_FACTORY), address(new EarnVault()), address(new EarnFees()));
        FeeConfig memory noFees;
        (, EarnVault vault,) = factory.deploy(
            EarnFactory.DeployParams({
                deploymentId: keccak256(abi.encode("cards-e2e.earn", owner, block.timestamp)),
                engine: address(engine),
                owner: owner,
                controls: EarnVaultControls({
                    emergencyGuardian: owner,
                    asyncJanitor: owner,
                    maxManagedAssets: 0,
                    migrationMode: EngineMigrationMode.OperatorEnabled
                }),
                distributorConfig: DistributorConfig(address(0), 0),
                fees: noFees,
                transferPolicyId: ALWAYS_ALLOW_POLICY_ID
            })
        );
        engine.initializeEarnVault(address(vault));
        return address(vault);
    }
}
