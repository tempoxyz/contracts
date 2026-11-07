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

import { CardFactory } from "../../src/core/CardFactory.sol";
import { ICardProvider } from "../../src/core/interfaces/ICardProvider.sol";
import { IRainCollateralFactory } from "../../src/providers/rain/IRain.sol";
import { RainProvider } from "../../src/providers/rain/RainProvider.sol";
import { RainStack } from "./RainStack.sol";

/// @notice A card program's router mode: Spend only on `zoneId`, through `spender` (the program) alone.
library CardSpendMode {
    function forSpender(uint32 zoneId, address spender) internal pure returns (ZoneRouter.Mode memory mode) {
        mode.zoneId = zoneId;
        mode.enabledOps = uint8(1 << 2);
        mode.spenders = new address[](1);
        mode.spenders[0] = spender;
    }
}

/// @notice Deploys a Rain card program for the card E2E (`e2e/cards`) on a disposable L1: Rain's own
///         collateral contracts from the vendored sources, with the deployer as Rain (factory owner) and
///         RAIN_ADMIN as its controller admin; the cardholder's own collateral contract and the program's
///         pooled one; with EARN=true, a Tempo Earn vault over pathUSD; a `RainProvider` accepting pathUSD
///         (and that vault); a `CardFactory` and the program's `CardSpender` over that provider; the
///         Spend-mode `ZoneRouter` for ZONE_ID listing the program as its spender; and a TIP-20 to launch
///         the Zone with. Reads DEPLOYER_PK, RAIN_ADMIN, RAIN_TREASURY, CARDHOLDER, PARTNER, ZONE_ID, EARN,
///         RAIN_RUN_ID and OUT.
contract CardsE2EDeploy is Script, RainStack {
    uint64 internal constant ALWAYS_ALLOW_POLICY_ID = 1;

    struct Inputs {
        uint256 deployerPk;
        address deployer;
        uint32 zoneId;
        bool earn;
        address rainAdmin;
        address rainTreasury;
        address cardholder;
        address partner;
        string runId;
        string out;
    }

    function run() external {
        _run(_inputs());
    }

    function _run(Inputs memory input) internal {
        vm.startBroadcast(input.deployerPk);
        Rain memory rain = _deployRain(input.rainAdmin, input.rainTreasury);
        address cardholderCollateral = rain.factory.createCollateralContract("cardholder", input.cardholder);
        address programCollateral = rain.factory.createCollateralContract("program", input.partner);

        address vault = input.earn ? _deployEarn(input.deployer) : address(0);
        address[] memory tokens = new address[](1);
        tokens[0] = StdTokens.PATH_USD_ADDRESS;
        address[] memory vaults = new address[](input.earn ? 1 : 0);
        if (input.earn) vaults[0] = vault;
        address[] memory pooled = new address[](1);
        pooled[0] = programCollateral;
        // Pooled collateral takes public spends too, as a partner-managed program's does.
        RainProvider provider = new RainProvider(address(rain.factory), tokens, vaults, pooled, true);
        // The router factory first: only its routers may call the program's spendFrom.
        ZoneRouterFactory routerFactory = new ZoneRouterFactory();
        CardFactory cardFactory = new CardFactory(address(routerFactory));
        address program = cardFactory.deploy("cards-e2e.rain", ICardProvider(address(provider)));
        // A router reads its Zone's Portal when it is created, so the E2E deploys it once the Zone exists;
        // its address is fixed by the mode already.
        address router = routerFactory.predict(CardSpendMode.forSpender(input.zoneId, program));
        // The Zone factory only launches with a token whose TIP-403 transfer policy is set.
        address zoneToken = StdPrecompiles.TIP20_FACTORY
            .createToken(
                "Zone Launch USD",
                "zlUSD",
                "USD",
                ITIP20(StdTokens.PATH_USD_ADDRESS),
                input.deployer,
                keccak256(abi.encode("cards-e2e.launch-token", input.deployer, block.timestamp))
            );
        ITIP20(zoneToken).changeTransferPolicyId(ALWAYS_ALLOW_POLICY_ID);
        vm.stopBroadcast();

        require(IRainCollateralFactory(address(rain.factory)).collateralProxies(0) == cardholderCollateral, "index 0");
        require(IRainCollateralFactory(address(rain.factory)).collateralProxies(1) == programCollateral, "index 1");

        string memory key = string.concat("cards-e2e.", input.runId);
        // The consumer accepts only the report produced for its own chain, inputs and invocation.
        vm.serializeString(key, "runId", input.runId);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "zoneId", input.zoneId);
        vm.serializeAddress(key, "deployer", input.deployer);
        vm.serializeAddress(key, "rainAdmin", input.rainAdmin);
        vm.serializeAddress(key, "rainTreasury", input.rainTreasury);
        vm.serializeAddress(key, "cardholder", input.cardholder);
        vm.serializeAddress(key, "partner", input.partner);
        vm.serializeBool(key, "earn", input.earn);
        vm.serializeAddress(key, "rainFactory", address(rain.factory));
        vm.serializeAddress(key, "rainController", address(rain.controller));
        vm.serializeAddress(key, "cardholderCollateral", cardholderCollateral);
        vm.serializeUint(key, "cardholderCollateralIndex", 0);
        vm.serializeAddress(key, "programCollateral", programCollateral);
        vm.serializeUint(key, "programCollateralIndex", 1);
        vm.serializeAddress(key, "cardFactory", address(cardFactory));
        vm.serializeAddress(key, "provider", address(provider));
        vm.serializeAddress(key, "program", program);
        vm.serializeAddress(key, "routerFactory", address(routerFactory));
        vm.serializeAddress(key, "router", router);
        if (input.earn) {
            vm.serializeAddress(key, "earnVault", vault);
            vm.serializeAddress(key, "earnShare", EarnVault(vault).earnShare());
        }
        string memory json = vm.serializeAddress(key, "zoneToken", zoneToken);
        vm.writeJson(json, input.out);
    }

    function _inputs() private view returns (Inputs memory input) {
        input.deployerPk = vm.envUint("DEPLOYER_PK");
        input.deployer = vm.addr(input.deployerPk);
        uint256 zoneId = vm.envUint("ZONE_ID");
        require(zoneId != 0 && zoneId <= type(uint32).max, "ZONE_ID out of range");
        input.zoneId = uint32(zoneId);
        input.earn = vm.envOr("EARN", false);
        input.rainAdmin = vm.envAddress("RAIN_ADMIN");
        input.rainTreasury = vm.envAddress("RAIN_TREASURY");
        input.cardholder = vm.envAddress("CARDHOLDER");
        input.partner = vm.envAddress("PARTNER");
        input.runId = vm.envString("RAIN_RUN_ID");
        require(bytes(input.runId).length != 0, "RAIN_RUN_ID required");
        input.out = vm.envString("OUT");
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
