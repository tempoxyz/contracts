// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { DeployBridgeCardsScript } from "../../../../script/spend/bridge/lifecycle/DeployBridgeCards.s.sol";
import { CardFactory } from "../../../../src/spend/CardFactory.sol";
import { CardSpender } from "../../../../src/spend/CardSpender.sol";
import { BridgeProvider } from "../../../../src/spend/providers/bridge/BridgeProvider.sol";
import { IBridgeSpenderFactory } from "../../../../src/spend/providers/bridge/interfaces/IBridgeSpenderFactory.sol";
import { TempoEnv } from "../harness/TempoEnv.sol";

/// @notice The profile lifecycle's card steps: `deploy-card-provider` creates the program's provider at its
///         release address, and `deploy-card-program` creates the program through the registry's
///         `CardFactory`, which it never creates.
contract DeployBridgeCardsTest is TempoEnv {
    uint256 internal constant DEPLOYER_PK = uint256(keccak256("tempo.deployer"));
    string internal constant OUTPUT = "reports/test-deploy-bridge-cards.json";

    DeployBridgeCardsScript internal script;

    function setUp() public {
        _deployTempo();
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_PK));
        vm.createDir("reports", true);
        vm.writeFile(OUTPUT, '{"latestOutputs":{}}');
        script = new DeployBridgeCardsScript();
    }

    function test_providerAtItsReleaseAddressThenProgramThroughTheCardFactory() public {
        BridgeProvider created = script.provider(_providerInput());
        assertEq(address(created), script.bridgeProviderAddress(address(bridgeFactory), SPENDER_ID));
        assertEq(address(created.FACTORY()), address(bridgeFactory));
        assertEq(created.SPENDER_ID(), SPENDER_ID);
        assertEq(vm.parseJsonAddress(vm.readFile(OUTPUT), ".latestOutputs.cardProvider"), address(created));
        // An existing provider is reused.
        assertEq(address(script.provider(_providerInput())), address(created));

        CardSpender deployed = script.run(_programInput(cardFactory));
        assertEq(address(deployed), cardFactory.predict(SPENDER_ID, created));
        assertTrue(cardFactory.isDeployed(address(deployed)));
        assertEq(address(deployed.PROVIDER()), address(created));
        assertEq(deployed.ROUTER_FACTORY(), address(routerFactory));
        assertEq(deployed.PAYOUT_TARGET(), spender);
        string memory json = vm.readFile(OUTPUT);
        assertEq(vm.parseJsonAddress(json, ".latestOutputs.cardProgram"), address(deployed));
        assertEq(vm.parseJsonAddress(json, ".latestOutputs.cardFactory"), address(cardFactory));
        assertEq(vm.parseJsonAddress(json, ".latestOutputs.cardRouterFactory"), address(routerFactory));
        // An existing program is reused.
        assertEq(address(script.run(_programInput(cardFactory))), address(deployed));
    }

    function test_programRequiresItsProvider() public {
        address missing = script.bridgeProviderAddress(address(bridgeFactory), SPENDER_ID);
        vm.expectRevert(abi.encodeWithSelector(DeployBridgeCardsScript.NoProvider.selector, missing));
        script.run(_programInput(cardFactory));
    }

    function test_programNeverCreatesTheCardFactory() public {
        script.provider(_providerInput());
        CardFactory missing = CardFactory(makeAddr("no.card.factory"));
        vm.expectRevert(abi.encodeWithSelector(DeployBridgeCardsScript.NoCardFactory.selector, address(missing)));
        script.run(_programInput(missing));
    }

    function test_refusesAnotherChain() public {
        DeployBridgeCardsScript.ProviderInput memory input = _providerInput();
        input.expectedChainId = block.chainid + 1;
        vm.expectRevert(
            abi.encodeWithSelector(DeployBridgeCardsScript.UnexpectedChain.selector, block.chainid, block.chainid + 1)
        );
        script.provider(input);
    }

    function _providerInput() internal view returns (DeployBridgeCardsScript.ProviderInput memory) {
        return DeployBridgeCardsScript.ProviderInput({
            expectedChainId: block.chainid,
            spenderFactory: IBridgeSpenderFactory(address(bridgeFactory)),
            spenderId: SPENDER_ID,
            outputPath: OUTPUT
        });
    }

    function _programInput(CardFactory factory) internal view returns (DeployBridgeCardsScript.Input memory) {
        return DeployBridgeCardsScript.Input({
            expectedChainId: block.chainid,
            cardFactory: factory,
            spenderFactory: IBridgeSpenderFactory(address(bridgeFactory)),
            spenderId: SPENDER_ID,
            outputPath: OUTPUT
        });
    }
}
