// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { ERC4626Engine, IERC4626Vault } from "../../../src/engines/ERC4626Engine.sol";
import { ERC4626EngineFactory } from "../../../src/engines/ERC4626EngineFactory.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AdversarialERC4626Vault } from "../../helpers/AdversarialERC4626Vault.sol";
import { CoreMockToken } from "../../helpers/EarnVaultMocks.sol";

/// @dev ERC-4626 metadata whose every field the engine constructor reads can be set.
contract EngineFactoryMockVault {
    address public asset;
    uint8 public decimals;
    string public name;
    string public symbol;

    constructor(address asset_, uint8 decimals_, string memory name_, string memory symbol_) {
        asset = asset_;
        decimals = decimals_;
        name = name_;
        symbol = symbol_;
    }
}

contract ERC4626EngineFactoryTest is Test {
    bytes32 private constant DEPLOYMENT_ID = keccak256("test-erc4626-engine");
    address private constant OWNER = address(0xA11CE);
    uint8 private constant ARGUMENT_COUNT = 5;

    event ERC4626EngineDeployed(
        address indexed engine,
        address indexed vault,
        address indexed owner,
        address asset,
        bytes32 deploymentId,
        bytes32 engineSalt
    );

    ERC4626EngineFactory private factory;
    CoreMockToken private asset;
    AdversarialERC4626Vault private venue;

    function setUp() public {
        factory = new ERC4626EngineFactory();
        asset = new CoreMockToken("Asset", "AST", 6);
        venue = new AdversarialERC4626Vault(address(asset));
    }

    function testDeployCreatesEngineAtPredictedAddressWithRequestedWiring() public {
        bytes32 expectedSalt = keccak256(
            abi.encode(factory.ENGINE_SALT_DOMAIN(), DEPLOYMENT_ID, address(venue), OWNER, keccak256(""), keccak256(""))
        );
        assertEq(factory.computeEngineSalt(DEPLOYMENT_ID, _venue(), OWNER, "", ""), expectedSalt);
        address predicted = factory.predictEngine(DEPLOYMENT_ID, _venue(), OWNER, "", "");

        ERC4626Engine engine = factory.deploy(DEPLOYMENT_ID, _venue(), OWNER, "", "");

        assertEq(address(engine), predicted);
        _assertEngine(engine, address(venue), OWNER, "Adversarial Venue", "advVEN");
        assertEq(engine.shareScale(), 1e18);
    }

    function testDeployAppliesMetadataOverrides() public {
        ERC4626Engine engine = factory.deploy(DEPLOYMENT_ID, _venue(), OWNER, "Sentora USD", "senUSD");

        _assertEngine(engine, address(venue), OWNER, "Sentora USD", "senUSD");
    }

    function testDeployEmitsEngineConfiguration() public {
        address predicted = factory.predictEngine(DEPLOYMENT_ID, _venue(), OWNER, "", "");
        bytes32 engineSalt = factory.computeEngineSalt(DEPLOYMENT_ID, _venue(), OWNER, "", "");

        vm.expectEmit(address(factory));
        emit ERC4626EngineDeployed(predicted, address(venue), OWNER, address(asset), DEPLOYMENT_ID, engineSalt);
        factory.deploy(DEPLOYMENT_ID, _venue(), OWNER, "", "");
    }

    function testFuzzPredictionMatchesDeployment(
        bytes32 deploymentId,
        address owner,
        string calldata nameOverride,
        string calldata symbolOverride
    ) public {
        vm.assume(deploymentId != bytes32(0) && owner != address(0) && owner != address(factory));
        address predicted = factory.predictEngine(deploymentId, _venue(), owner, nameOverride, symbolOverride);

        ERC4626Engine engine = factory.deploy(deploymentId, _venue(), owner, nameOverride, symbolOverride);

        assertEq(address(engine), predicted);
        _assertEngine(
            engine,
            address(venue),
            owner,
            bytes(nameOverride).length == 0 ? "Adversarial Venue" : nameOverride,
            bytes(symbolOverride).length == 0 ? "advVEN" : symbolOverride
        );
    }

    /// @dev Every constructor argument binds the salt and init code, so a different configuration
    ///      under the same deployment ID lands elsewhere and cannot occupy the original address.
    function testFuzzEveryArgumentSeparatesEngineAddresses(uint8 rawField, address alternate) public {
        vm.assume(alternate != address(0) && alternate != OWNER && alternate != address(factory));
        uint8 field = uint8(bound(rawField, 0, ARGUMENT_COUNT - 1));
        bytes32 deploymentId = field == 0 ? keccak256("other deployment") : DEPLOYMENT_ID;
        IERC4626Vault vault =
            field == 1 ? IERC4626Vault(address(new AdversarialERC4626Vault(address(asset)))) : _venue();
        address owner = field == 2 ? alternate : OWNER;
        string memory nameOverride = field == 3 ? "Other" : "";
        string memory symbolOverride = field == 4 ? "OTH" : "";

        ERC4626Engine variant = factory.deploy(deploymentId, vault, owner, nameOverride, symbolOverride);
        address predicted = factory.predictEngine(DEPLOYMENT_ID, _venue(), OWNER, "", "");
        assertEq(predicted.code.length, 0);
        ERC4626Engine engine = factory.deploy(DEPLOYMENT_ID, _venue(), OWNER, "", "");

        assertEq(address(engine), predicted);
        assertTrue(address(variant) != address(engine));
        _assertEngine(
            variant, address(vault), owner, field == 3 ? "Other" : "Adversarial Venue", field == 4 ? "OTH" : "advVEN"
        );
        _assertEngine(engine, address(venue), OWNER, "Adversarial Venue", "advVEN");
    }

    /// @dev The caller is not part of the salt: a front-runner can only deploy the exact engine the
    ///      victim requested, owned by the victim, and the victim's transaction then reverts.
    function testExactCopyFrontRunCreatesOnlyTheRequestedEngine() public {
        address attacker = makeAddr("attacker");
        address predicted = factory.predictEngine(DEPLOYMENT_ID, _venue(), OWNER, "", "");

        vm.prank(attacker);
        ERC4626Engine engine = factory.deploy(DEPLOYMENT_ID, _venue(), OWNER, "", "");

        assertEq(address(engine), predicted);
        _assertEngine(engine, address(venue), OWNER, "Adversarial Venue", "advVEN");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        engine.initializeEarnVault(attacker);

        vm.expectRevert(abi.encodeWithSelector(ERC4626EngineFactory.EngineAlreadyExists.selector, predicted));
        factory.deploy(DEPLOYMENT_ID, _venue(), OWNER, "", "");
    }

    function testDeployRejectsInvalidFactoryArguments() public {
        vm.expectRevert(ERC4626EngineFactory.EmptyDeploymentId.selector);
        factory.deploy(bytes32(0), _venue(), OWNER, "", "");

        vm.expectRevert(ERC4626EngineFactory.FactoryCannotBeFinalOwner.selector);
        factory.deploy(DEPLOYMENT_ID, _venue(), address(factory), "", "");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        factory.deploy(DEPLOYMENT_ID, _venue(), address(0), "", "");
    }

    function testDeployRejectsInvalidVenues() public {
        _expectVenueRevert(address(0), ERC4626Engine.ZeroAddress.selector);
        _expectVenueRevert(
            address(new EngineFactoryMockVault(address(0), 18, "Venue", "VEN")), ERC4626Engine.ZeroAddress.selector
        );
        _expectVenueRevert(
            address(new EngineFactoryMockVault(address(asset), 78, "Venue", "VEN")),
            ERC4626Engine.InvalidVenueShareDecimals.selector
        );
        _expectVenueRevert(
            address(new EngineFactoryMockVault(address(asset), 18, "", "VEN")), ERC4626Engine.EmptyMetadata.selector
        );
        _expectVenueRevert(
            address(new EngineFactoryMockVault(address(asset), 18, "Venue", "")), ERC4626Engine.EmptyMetadata.selector
        );

        address codeless = makeAddr("codeless venue");
        vm.expectRevert();
        factory.deploy(DEPLOYMENT_ID, IERC4626Vault(codeless), OWNER, "", "");
    }

    function testFactoryKeepsNoEngineAuthority() public {
        ERC4626Engine engine = factory.deploy(DEPLOYMENT_ID, _venue(), OWNER, "", "");

        vm.startPrank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(factory)));
        engine.initializeEarnVault(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(factory)));
        engine.transferOwnership(address(factory));
        vm.stopPrank();
    }

    function testSetupOwnerBindsOnceAndHandsOff() public {
        address earnVault = makeAddr("EarnVault");
        address finalOwner = makeAddr("final owner");
        ERC4626Engine engine = factory.deploy(DEPLOYMENT_ID, _venue(), OWNER, "", "");

        vm.prank(OWNER);
        engine.initializeEarnVault(earnVault, finalOwner);

        assertEq(engine.earnVault(), earnVault);
        assertEq(engine.owner(), finalOwner);
        assertEq(engine.pendingOwner(), address(0));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        engine.initializeEarnVault(makeAddr("replacement"));
        vm.prank(finalOwner);
        vm.expectRevert(ERC4626Engine.AlreadyInitialized.selector);
        engine.initializeEarnVault(makeAddr("replacement"));
        assertEq(engine.earnVault(), earnVault);
    }

    function _assertEngine(ERC4626Engine engine, address vault, address owner, string memory name, string memory symbol)
        private
        view
    {
        assertEq(address(engine.vault()), vault);
        assertEq(engine.asset(), address(asset));
        assertEq(engine.baseAsset(), address(asset));
        assertEq(engine.name(), name);
        assertEq(engine.symbol(), symbol);
        assertEq(engine.owner(), owner);
        assertEq(engine.pendingOwner(), address(0));
        assertEq(engine.earnVault(), address(0));
        assertEq(engine.totalShares(), 0);
    }

    function _expectVenueRevert(address vault, bytes4 selector) private {
        address predicted = factory.predictEngine(DEPLOYMENT_ID, IERC4626Vault(vault), OWNER, "", "");
        vm.expectRevert(selector);
        factory.deploy(DEPLOYMENT_ID, IERC4626Vault(vault), OWNER, "", "");
        assertEq(predicted.code.length, 0);
    }

    function _venue() private view returns (IERC4626Vault) {
        return IERC4626Vault(address(venue));
    }
}
