// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ISpenderHandler, SpenderStatus } from "bridge-spender/src/ISpenderHandler.sol";
import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";

import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";

import { SpenderTempoSpend } from "../src/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../src/interfaces/IBridgeSpenderFactory.sol";
import { SpendMode } from "./deploy/DeployZoneRouter.s.sol";
import { BridgeSettler } from "zone-router/settlers/BridgeSettler.sol";

/// @notice Deploys a Bridge card program with the "TS" handler, its `BridgeSettler`, and the
///         Spend-mode `ZoneRouter` for ZONE_ID through a new `ZoneRouterFactory` to an L1 for the
///         Zone E2E (`e2e/bridge`), plus a TIP-20 with a transfer policy to launch the Zone with. The
///         router needs no Zone at deployment, so it can be deployed before the Zone launches.
///         "TS" is registered and gated with the program allowlisted, as docs/bridge/deploy.md sets it up,
///         and the program pays the settlement wallet and the program wallet.
///         Reads DEPLOYER_PK, SETTLEMENT, PROGRAM_WALLET, ZONE_ID and OUT from the env.
contract ZoneE2EDeploy is Script {
    bytes32 internal constant SPENDER_ID = keccak256("zone-e2e.card-program");
    uint64 internal constant ALWAYS_ALLOW_POLICY_ID = 1;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(deployerPk);
        address settlement = vm.envAddress("SETTLEMENT");
        address programWallet = vm.envAddress("PROGRAM_WALLET");
        uint256 zoneIdValue = vm.envUint("ZONE_ID");
        require(zoneIdValue != 0 && zoneIdValue <= type(uint32).max, "ZONE_ID out of range");
        uint32 zoneId = uint32(zoneIdValue);

        vm.startBroadcast(deployerPk);
        SpenderFactory factory = SpenderFactory(
            address(
                new ERC1967Proxy(
                    address(new SpenderFactory()),
                    abi.encodeCall(SpenderFactory.initialize, (deployer, deployer, deployer))
                )
            )
        );
        ISpenderHandler handler = ISpenderHandler(address(new SpenderTempoSpend(IFactory(address(factory)))));
        factory.setSpenderHandler("TS", handler);
        factory.updateSpenderHandlerStatus("TS", SpenderStatus.Gated);
        factory.grantRole(factory.MANAGER_ROLE(), deployer);
        address[] memory destinations = new address[](2);
        destinations[0] = settlement;
        destinations[1] = programWallet;
        address clone = factory.createSpender(SPENDER_ID, destinations);
        factory.updateSpenderHandlerAllowlist("TS", SPENDER_ID, true);
        BridgeSettler settler = new BridgeSettler(IBridgeSpenderFactory(address(factory)), SPENDER_ID);
        ZoneRouterFactory routerFactory = new ZoneRouterFactory();
        address router = routerFactory.deploy(SpendMode.forSettler(zoneId, address(settler)));
        // The Zone factory only launches with a token whose TIP-403 transfer policy is set.
        address zoneToken = StdPrecompiles.TIP20_FACTORY
            .createToken(
                "Zone Launch USD",
                "zlUSD",
                "USD",
                ITIP20(StdTokens.PATH_USD_ADDRESS),
                deployer,
                keccak256(abi.encode("zone-e2e.launch-token", deployer, block.timestamp))
            );
        ITIP20(zoneToken).changeTransferPolicyId(ALWAYS_ALLOW_POLICY_ID);
        vm.stopBroadcast();

        string memory key = "zone-e2e";
        vm.serializeAddress(key, "factory", address(factory));
        vm.serializeAddress(key, "clone", clone);
        vm.serializeBytes32(key, "spenderId", SPENDER_ID);
        vm.serializeAddress(key, "programWallet", programWallet);
        vm.serializeAddress(key, "zoneToken", zoneToken);
        vm.serializeAddress(key, "settler", address(settler));
        vm.serializeAddress(key, "routerFactory", address(routerFactory));
        string memory json = vm.serializeAddress(key, "router", router);
        vm.writeJson(json, vm.envString("OUT"));
    }
}
