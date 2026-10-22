// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Core factory and atomic wiring coverage.
import { Test } from "forge-std/Test.sol";
import { EarnFees } from "../../src/core/EarnFees.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { EarnFactory } from "../../src/core/EarnFactory.sol";
import { ERC4626Engine, IERC4626Vault } from "../../src/engines/ERC4626Engine.sol";
import { ERC4626EngineFactory } from "../../src/engines/ERC4626EngineFactory.sol";
import { DistributorConfig, EngineMigrationMode } from "../../src/interfaces/core/EarnVaultTypes.sol";
import { FixedFeeRecipient } from "../../src/interfaces/core/EarnFeeTypes.sol";
import { IEarnEngine } from "../../src/interfaces/engines/IEarnEngine.sol";
import { IEarnEngineRedeem } from "../../src/interfaces/engines/IEarnEngineRedeem.sol";
import {
    ALWAYS_ALLOW_POLICY_ID,
    TIP403_REGISTRY_ADDRESS,
    WHITELIST_POLICY_TYPE
} from "../../src/interfaces/external/tempo/ITIP403Registry.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { AdversarialERC4626Vault } from "../helpers/AdversarialERC4626Vault.sol";

contract FactoryMockEngine {
    address public immutable asset;
    address public earnVault;
    string public name = "Sentora Vault";
    string public symbol = "senV";
    uint8 public immutable decimals;
    bool private coreCapability = true;
    bool private exitCapability = true;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_, uint8 decimals_) {
        asset = asset_;
        decimals = decimals_;
    }

    function setEarnVault(address earnVault_) external {
        earnVault = earnVault_;
    }

    function setMetadata(string calldata name_, string calldata symbol_) external {
        name = name_;
        symbol = symbol_;
    }

    function setCapabilities(bool core, bool exit) external {
        coreCapability = core;
        exitCapability = exit;
    }

    function totalShares() external pure returns (uint256) {
        return 0;
    }

    function valueOf(uint256) external pure returns (uint256) {
        return 0;
    }

    function shareScale() external view returns (uint256) {
        return 10 ** uint256(decimals);
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || (coreCapability && interfaceId == type(IEarnEngine).interfaceId)
            || (exitCapability && interfaceId == type(IEarnEngineRedeem).interfaceId);
    }
}

contract FactoryMockTip20Asset {
    string public currency;

    constructor(string memory currency_) {
        currency = currency_;
    }
}

/// @dev Ways a TIP-20 implementation could fail to honor the factory's wiring calls.
enum ShareFault {
    None,
    IgnoreGrant,
    IgnoreRevoke,
    IgnorePolicyChange,
    Preminted
}

contract FactoryMockShareToken {
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    ShareFault public immutable fault;
    uint8 public decimals = 6;
    uint256 public totalSupply;
    uint64 public transferPolicyId = ALWAYS_ALLOW_POLICY_ID;
    mapping(address account => uint256 amount) public balanceOf;

    mapping(bytes32 role => mapping(address account => bool authorized)) private roles;

    constructor(address admin_, ShareFault fault_) {
        roles[DEFAULT_ADMIN_ROLE][admin_] = true;
        fault = fault_;
        if (fault_ == ShareFault.Preminted) totalSupply = 1;
    }

    function grantRole(bytes32 role, address account) external {
        require(roles[DEFAULT_ADMIN_ROLE][msg.sender], "NOT_ADMIN");
        if (fault != ShareFault.IgnoreGrant) roles[role][account] = true;
    }

    function revokeRole(bytes32 role, address account) external {
        require(roles[DEFAULT_ADMIN_ROLE][msg.sender], "NOT_ADMIN");
        if (fault != ShareFault.IgnoreRevoke) roles[role][account] = false;
    }

    function hasRole(address account, bytes32 role) external view returns (bool) {
        return roles[role][account];
    }

    function mint(address receiver, uint256 amount) external {
        require(roles[ISSUER_ROLE][msg.sender], "NOT_ISSUER");
        totalSupply += amount;
        balanceOf[receiver] += amount;
    }

    function changeTransferPolicyId(uint64 policyId) external {
        require(roles[DEFAULT_ADMIN_ROLE][msg.sender], "NOT_ADMIN");
        if (fault != ShareFault.IgnorePolicyChange) transferPolicyId = policyId;
    }
}

/// @dev Deterministic stand-in for the TIP-20 factory: tokens land at `getTokenAddress(sender, salt)`,
///      so an occupied prediction is a real collision, and the creation arguments are recorded.
contract FactoryMockTip20Factory {
    ShareFault public fault;
    bool public returnZero;
    string public lastName;
    string public lastSymbol;
    string public lastCurrency;
    address public lastQuoteToken;
    address public lastAdmin;
    bytes32 public lastSalt;

    function setFault(ShareFault fault_) external {
        fault = fault_;
    }

    function setReturnZero(bool returnZero_) external {
        returnZero = returnZero_;
    }

    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata currency,
        address quoteToken,
        address admin,
        bytes32 salt
    ) external returns (address token) {
        (lastName, lastSymbol, lastCurrency, lastQuoteToken, lastAdmin, lastSalt) =
        (name, symbol, currency, quoteToken, admin, salt);
        token = address(new FactoryMockShareToken{ salt: _namespacedSalt(msg.sender, salt) }(admin, fault));
        if (returnZero) token = address(0);
    }

    function getTokenAddress(address sender, bytes32 salt) external view returns (address token) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(FactoryMockShareToken).creationCode, abi.encode(sender, fault)));
        return Create2.computeAddress(_namespacedSalt(sender, salt), initCodeHash);
    }

    function _namespacedSalt(address sender, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(sender, salt));
    }
}

contract FactoryMockTip403Registry {
    mapping(uint64 policyId => bool exists) public policyExists;
    mapping(uint64 policyId => uint8 policyType) private policyTypes;
    mapping(uint64 policyId => address administrator) private administrators;

    function setPolicy(uint64 policyId, uint8 policyType, address administrator) external {
        policyExists[policyId] = true;
        policyTypes[policyId] = policyType;
        administrators[policyId] = administrator;
    }

    function policyData(uint64 policyId) external view returns (uint8 policyType, address administrator) {
        return (policyTypes[policyId], administrators[policyId]);
    }
}

contract EarnFactoryTest is Test {
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address private constant OWNER = address(0xA11CE);
    address private constant POLICY_ADMIN = address(0xAD);
    bytes32 private constant DEPLOYMENT_ID = keccak256("test-earn-stack");
    uint64 private constant WHITELIST_POLICY_ID = 469;
    uint8 private constant SALT_FIELD_COUNT = 9;

    event EarnStackDeployed(
        address indexed earnVault,
        address indexed earnShare,
        address indexed earnFees,
        address engine,
        address asset,
        address owner,
        bytes32 deploymentId,
        address emergencyGuardian,
        address asyncJanitor,
        uint256 maxManagedAssets,
        EngineMigrationMode migrationMode,
        uint64 transferPolicyId,
        bytes32 earnShareSalt,
        bytes32 controlConfigHash,
        bytes32 feeConfigHash,
        bytes32 earnFeesSalt
    );

    FactoryMockTip20Asset asset;
    FactoryMockEngine engine;
    FactoryMockTip20Factory tip20Factory;
    EarnFactory factory;

    function setUp() public {
        asset = new FactoryMockTip20Asset("USD");
        engine = new FactoryMockEngine(address(asset), 18);
        tip20Factory = new FactoryMockTip20Factory();
        factory = new EarnFactory(address(tip20Factory), address(new EarnVault()), address(new EarnFees()));
    }

    function testConstructorFixesImplementationsAndRejectsInvalidOnes() public {
        address vaultImplementation = address(new EarnVault());
        address feesImplementation = address(new EarnFees());
        EarnFactory deployed = new EarnFactory(address(tip20Factory), vaultImplementation, feesImplementation);
        assertEq(deployed.tip20Factory(), address(tip20Factory));
        assertEq(deployed.earnVaultImplementation(), vaultImplementation);
        assertEq(deployed.earnFeesImplementation(), feesImplementation);

        vm.expectRevert(EarnFactory.ZeroAddress.selector);
        new EarnFactory(address(0), vaultImplementation, feesImplementation);
        vm.expectRevert(EarnFactory.ZeroAddress.selector);
        new EarnFactory(address(tip20Factory), address(0), feesImplementation);
        vm.expectRevert(EarnFactory.ZeroAddress.selector);
        new EarnFactory(address(tip20Factory), vaultImplementation, address(0));
        vm.expectRevert(EarnFactory.InvalidEarnVaultImplementation.selector);
        new EarnFactory(address(tip20Factory), makeAddr("codeless vault"), feesImplementation);
        vm.expectRevert(EarnFactory.InvalidEarnFeesImplementation.selector);
        new EarnFactory(address(tip20Factory), vaultImplementation, makeAddr("codeless fees"));
    }

    function testDeployCreatesEarnStackAndRelinquishesEarnAdmin() public {
        EarnFactory.DeployParams memory params = _baseParams();
        bytes32 expectedSalt = keccak256(
            abi.encode(
                factory.EARN_SHARE_SALT_DOMAIN(),
                DEPLOYMENT_ID,
                address(engine),
                OWNER,
                keccak256(abi.encode(params.controls)),
                keccak256(abi.encode(params.distributorConfig, params.fees)),
                ALWAYS_ALLOW_POLICY_ID
            )
        );
        assertEq(factory.computeEarnShareSalt(params), expectedSalt);
        assertEq(factory.predictEarnShare(params), tip20Factory.getTokenAddress(address(factory), expectedSalt));

        (address earnShare, EarnVault earnVault, EarnFees earnFees) = factory.deploy(params);

        assertEq(earnShare, factory.predictEarnShare(params));
        assertEq(address(earnFees), factory.predictEarnFees(params));
        assertEq(tip20Factory.lastSalt(), expectedSalt);
        assertEq(tip20Factory.lastName(), "Sentora Vault (Earn)");
        assertEq(tip20Factory.lastSymbol(), "senVE");
        assertEq(tip20Factory.lastCurrency(), factory.EARN_SHARE_CURRENCY());
        assertEq(bytes(tip20Factory.lastCurrency()).length, 0);
        assertEq(tip20Factory.lastQuoteToken(), address(asset));
        assertEq(tip20Factory.lastAdmin(), address(factory));
        _assertStack(params, earnShare, earnVault, earnFees);
    }

    function testDeployWiresEveryConfiguredRoleAndControl() public {
        _installPolicy(WHITELIST_POLICY_ID, WHITELIST_POLICY_TYPE);
        EarnFactory.DeployParams memory params = _baseParams();
        params.controls.emergencyGuardian = makeAddr("guardian");
        params.controls.asyncJanitor = makeAddr("janitor");
        params.controls.maxManagedAssets = 5_000_000e6;
        params.controls.migrationMode = EngineMigrationMode.UserOnly;
        params.distributorConfig.distributor = makeAddr("distributor");
        params.distributorConfig.updateDelay = 3 days;
        params.fees.fixedFeeCount = 2;
        params.fees.fixedFees[1] = FixedFeeRecipient(makeAddr("treasury"), 50);
        params.fees.excess.enabled = true;
        params.fees.excess.account = makeAddr("excess");
        params.fees.excess.annualTargetRateBps = 400;
        params.fees.excess.excessFeeRateBps = 2_000;
        params.transferPolicyId = WHITELIST_POLICY_ID;

        (address earnShare, EarnVault earnVault, EarnFees earnFees) = factory.deploy(params);

        _assertStack(params, earnShare, earnVault, earnFees);
    }

    function testDeployEmitsStackConfiguration() public {
        EarnFactory.DeployParams memory params = _baseParams();
        params.controls.maxManagedAssets = 1e12;
        bytes32 earnShareSalt = factory.computeEarnShareSalt(params);
        address expectedVault = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        vm.expectEmit(address(factory));
        emit EarnStackDeployed(
            expectedVault,
            factory.predictEarnShare(params),
            factory.predictEarnFees(params),
            address(engine),
            address(asset),
            OWNER,
            DEPLOYMENT_ID,
            OWNER,
            OWNER,
            1e12,
            EngineMigrationMode.OperatorEnabled,
            ALWAYS_ALLOW_POLICY_ID,
            earnShareSalt,
            keccak256(abi.encode(params.controls)),
            keccak256(abi.encode(params.distributorConfig, params.fees)),
            keccak256(abi.encode(factory.FEES_SALT_DOMAIN(), earnShareSalt))
        );
        (, EarnVault earnVault,) = factory.deploy(params);
        assertEq(address(earnVault), expectedVault);
    }

    function testFuzzPredictionsMatchDeployment(
        bytes32 deploymentId,
        address owner,
        uint256 maxManagedAssets,
        bool userOnly
    ) public {
        vm.assume(deploymentId != bytes32(0) && owner != address(0) && owner != address(factory));
        EarnFactory.DeployParams memory params = _baseParams();
        params.deploymentId = deploymentId;
        params.owner = owner;
        params.controls.maxManagedAssets = maxManagedAssets;
        params.controls.migrationMode = userOnly ? EngineMigrationMode.UserOnly : EngineMigrationMode.OperatorEnabled;
        address predictedShare = factory.predictEarnShare(params);
        address predictedFees = factory.predictEarnFees(params);

        (address earnShare, EarnVault earnVault, EarnFees earnFees) = factory.deploy(params);

        assertEq(earnShare, predictedShare);
        assertEq(address(earnFees), predictedFees);
        _assertStack(params, earnShare, earnVault, earnFees);
    }

    /// @dev Every configuration field binds the EarnShare salt, so a different configuration under
    ///      the same deployment ID lands at a different address and cannot occupy the original one.
    function testFuzzEverySaltFieldSeparatesNamespaces(uint8 rawField, address alternate, uint40 entropy) public {
        vm.assume(alternate != address(0) && alternate != OWNER && alternate != address(factory));
        uint8 field = uint8(bound(rawField, 0, SALT_FIELD_COUNT - 1));
        EarnFactory.DeployParams memory variant = _variant(field, alternate, entropy);
        EarnFactory.DeployParams memory params = _baseParams();
        assertTrue(factory.computeEarnShareSalt(variant) != factory.computeEarnShareSalt(params));

        (address variantShare, EarnVault variantVault, EarnFees variantFees) = factory.deploy(variant);
        address predictedShare = factory.predictEarnShare(params);
        assertEq(predictedShare.code.length, 0);
        (address earnShare, EarnVault earnVault, EarnFees earnFees) = factory.deploy(params);

        assertEq(earnShare, predictedShare);
        assertTrue(earnShare != variantShare);
        assertTrue(address(earnFees) != address(variantFees));
        _assertStack(variant, variantShare, variantVault, variantFees);
        _assertStack(params, earnShare, earnVault, earnFees);
    }

    function testSquatterCannotPreemptDeploymentIdWithOwnConfiguration() public {
        address attacker = makeAddr("attacker");
        EarnFactory.DeployParams memory squat = _baseParams();
        squat.owner = attacker;
        squat.controls.emergencyGuardian = attacker;
        squat.controls.asyncJanitor = attacker;
        vm.prank(attacker);
        (address squatShare,,) = factory.deploy(squat);

        EarnFactory.DeployParams memory params = _baseParams();
        (address earnShare, EarnVault earnVault, EarnFees earnFees) = factory.deploy(params);

        assertTrue(earnShare != squatShare);
        _assertStack(params, earnShare, earnVault, earnFees);
    }

    /// @dev The caller is not part of the salt: a front-runner can only create the exact stack the
    ///      victim requested, with the victim's roles, and the victim's transaction then reverts.
    function testExactCopyFrontRunCreatesOnlyTheRequestedStack() public {
        address attacker = makeAddr("attacker");
        EarnFactory.DeployParams memory params = _baseParams();
        address predictedShare = factory.predictEarnShare(params);

        vm.prank(attacker);
        (address earnShare, EarnVault earnVault, EarnFees earnFees) = factory.deploy(params);

        assertEq(earnShare, predictedShare);
        _assertStack(params, earnShare, earnVault, earnFees);
        assertTrue(earnVault.operator() != attacker);
        assertFalse(FactoryMockShareToken(earnShare).hasRole(attacker, bytes32(0)));

        vm.expectRevert(abi.encodeWithSelector(EarnFactory.EarnShareAlreadyExists.selector, predictedShare));
        factory.deploy(params);
    }

    function testUnsetAndAlwaysAllowPolicyShareOneNamespace() public {
        EarnFactory.DeployParams memory unset = _baseParams();
        EarnFactory.DeployParams memory explicitAllow = _baseParams();
        explicitAllow.transferPolicyId = ALWAYS_ALLOW_POLICY_ID;
        assertEq(factory.computeEarnShareSalt(unset), factory.computeEarnShareSalt(explicitAllow));

        (address earnShare,,) = factory.deploy(unset);

        assertEq(FactoryMockShareToken(earnShare).transferPolicyId(), ALWAYS_ALLOW_POLICY_ID);
        vm.expectRevert(abi.encodeWithSelector(EarnFactory.EarnShareAlreadyExists.selector, earnShare));
        factory.deploy(explicitAllow);
    }

    function testDeployRejectsInvalidParameters() public {
        EarnFactory.DeployParams memory params = _baseParams();
        params.deploymentId = bytes32(0);
        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.EmptyDeploymentId.selector));

        params = _baseParams();
        params.engine = address(0);
        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.ZeroAddress.selector));

        params = _baseParams();
        params.owner = address(0);
        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.ZeroAddress.selector));

        params = _baseParams();
        params.owner = address(factory);
        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.FactoryCannotBeFinalOwner.selector));

        params = _baseParams();
        params.engine = makeAddr("codeless engine");
        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.InvalidEngine.selector));
    }

    function testFuzzDeployRejectsInconsistentDistributorConfig(address distributor, uint40 updateDelay) public {
        vm.assume((distributor == address(0)) != (updateDelay == 0));
        EarnFactory.DeployParams memory params = _baseParams();
        params.distributorConfig.distributor = distributor;
        params.distributorConfig.updateDelay = updateDelay;

        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.InvalidDistributorConfig.selector));
    }

    function testDeployRejectsAlreadyBoundEngine() public {
        address existingEarnVault = makeAddr("existing EarnVault");
        engine.setEarnVault(existingEarnVault);

        _expectDeployRevert(
            _baseParams(), abi.encodeWithSelector(EarnFactory.EngineAlreadyBound.selector, existingEarnVault)
        );
    }

    function testDeployRejectsEngineWithoutAssetOrMetadata() public {
        FactoryMockEngine assetless = new FactoryMockEngine(address(0), 18);
        EarnFactory.DeployParams memory params = _baseParams();
        params.engine = address(assetless);
        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.ZeroAddress.selector));

        engine.setMetadata("", "senV");
        _expectDeployRevert(_baseParams(), abi.encodeWithSelector(EarnFactory.EmptyEarnShareMetadata.selector));
        engine.setMetadata("Sentora Vault", "");
        _expectDeployRevert(_baseParams(), abi.encodeWithSelector(EarnFactory.EmptyEarnShareMetadata.selector));
    }

    /// @dev EarnVault initialization runs inside the factory call, so an engine the vault refuses
    ///      reverts the whole stack, including the EarnShare.
    function testDeployRevertsAtomicallyForEngineWithoutRequiredCapabilities() public {
        engine.setCapabilities(false, true);
        _expectDeployRevert(
            _baseParams(),
            abi.encodeWithSelector(EarnVault.EngineCapabilityUnsupported.selector, type(IEarnEngine).interfaceId)
        );

        engine.setCapabilities(true, false);
        _expectDeployRevert(_baseParams(), abi.encodeWithSelector(EarnVault.EngineExitUnsupported.selector));
    }

    function testDeployRejectsTransferPolicyWithoutRegistry() public {
        EarnFactory.DeployParams memory params = _baseParams();
        params.transferPolicyId = WHITELIST_POLICY_ID;

        _expectDeployRevert(
            params, abi.encodeWithSelector(EarnFactory.InvalidTransferPolicy.selector, WHITELIST_POLICY_ID)
        );
    }

    function testFuzzDeployRejectsMissingTransferPolicy(uint64 policyId) public {
        vm.assume(policyId > ALWAYS_ALLOW_POLICY_ID && policyId != WHITELIST_POLICY_ID);
        _installPolicy(WHITELIST_POLICY_ID, WHITELIST_POLICY_TYPE);
        EarnFactory.DeployParams memory params = _baseParams();
        params.transferPolicyId = policyId;

        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.InvalidTransferPolicy.selector, policyId));
    }

    function testFuzzDeployRejectsNonWhitelistTransferPolicy(uint8 policyType) public {
        vm.assume(policyType != WHITELIST_POLICY_TYPE);
        _installPolicy(WHITELIST_POLICY_ID, policyType);
        EarnFactory.DeployParams memory params = _baseParams();
        params.transferPolicyId = WHITELIST_POLICY_ID;

        _expectDeployRevert(
            params,
            abi.encodeWithSelector(EarnFactory.UnsupportedTransferPolicy.selector, WHITELIST_POLICY_ID, policyType)
        );
    }

    function testDeployBindsWhitelistAndLeavesNoAccountAbleToChangeIt() public {
        _installPolicy(WHITELIST_POLICY_ID, WHITELIST_POLICY_TYPE);
        EarnFactory.DeployParams memory params = _baseParams();
        params.transferPolicyId = WHITELIST_POLICY_ID;

        (address earnShare, EarnVault earnVault,) = factory.deploy(params);
        FactoryMockShareToken share = FactoryMockShareToken(earnShare);

        assertEq(share.transferPolicyId(), WHITELIST_POLICY_ID);
        address[4] memory accounts = [OWNER, POLICY_ADMIN, address(factory), address(earnVault)];
        for (uint256 i = 0; i < accounts.length; i++) {
            vm.prank(accounts[i]);
            vm.expectRevert("NOT_ADMIN");
            share.changeTransferPolicyId(ALWAYS_ALLOW_POLICY_ID);
        }
    }

    function testDeployVerifiesTokenHonoredEachWiringStep() public {
        _installPolicy(WHITELIST_POLICY_ID, WHITELIST_POLICY_TYPE);
        EarnFactory.DeployParams memory params = _baseParams();
        params.transferPolicyId = WHITELIST_POLICY_ID;

        tip20Factory.setFault(ShareFault.Preminted);
        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.EarnShareSupplyNotZero.selector));
        tip20Factory.setFault(ShareFault.IgnoreGrant);
        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.IssuerGrantFailed.selector));
        tip20Factory.setFault(ShareFault.IgnorePolicyChange);
        _expectDeployRevert(
            params,
            abi.encodeWithSelector(
                EarnFactory.TransferPolicyMismatch.selector, WHITELIST_POLICY_ID, ALWAYS_ALLOW_POLICY_ID
            )
        );
        tip20Factory.setFault(ShareFault.IgnoreRevoke);
        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.AdminRelinquishmentFailed.selector));

        tip20Factory.setFault(ShareFault.None);
        tip20Factory.setReturnZero(true);
        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.ZeroAddress.selector));
    }

    function testDeployFreezesIssuerMembershipAndRejectsUnauthorizedMint() public {
        (address earnShare, EarnVault earnVault,) = factory.deploy(_baseParams());
        FactoryMockShareToken share = FactoryMockShareToken(earnShare);
        address attacker = makeAddr("attacker");
        bytes32 issuerRole = share.ISSUER_ROLE();

        address[3] memory admins = [OWNER, address(factory), address(earnVault)];
        for (uint256 i = 0; i < admins.length; i++) {
            vm.prank(admins[i]);
            vm.expectRevert("NOT_ADMIN");
            share.grantRole(issuerRole, attacker);
        }

        vm.prank(attacker);
        vm.expectRevert("NOT_ISSUER");
        share.mint(attacker, 1);

        vm.prank(address(earnVault));
        share.mint(OWNER, 1);
        assertEq(share.totalSupply(), 1);
        assertEq(share.balanceOf(OWNER), 1);
        assertFalse(share.hasRole(attacker, issuerRole));
    }

    function testFactoryKeepsNoEarnVaultAuthority() public {
        (, EarnVault earnVault,) = factory.deploy(_baseParams());

        vm.startPrank(address(factory));
        vm.expectRevert(EarnVault.NotOperator.selector);
        earnVault.setMaxManagedAssets(1);
        vm.expectRevert(EarnVault.NotEmergencyGuardianOrOperator.selector);
        earnVault.setDepositsPaused(true);
        vm.stopPrank();
    }

    function testDeployedStackCannotBeReinitialized() public {
        EarnFactory.DeployParams memory params = _baseParams();
        (address earnShare, EarnVault earnVault, EarnFees earnFees) = factory.deploy(params);
        address attacker = makeAddr("attacker");

        vm.startPrank(attacker);
        vm.expectRevert(EarnVault.AlreadyInitialized.selector);
        earnVault.initialize(
            address(engine), earnShare, address(earnFees), attacker, params.controls, params.distributorConfig
        );
        vm.expectRevert(EarnFees.AlreadyInitialized.selector);
        earnFees.initialize(attacker, earnShare, params.fees);
        vm.stopPrank();
        assertEq(earnVault.operator(), OWNER);
        assertEq(earnFees.earnVault(), address(earnVault));
    }

    function testImplementationsAreLocked() public {
        EarnFactory.DeployParams memory params = _baseParams();
        address vaultImplementation = factory.earnVaultImplementation();
        address feesImplementation = factory.earnFeesImplementation();

        vm.expectRevert(EarnVault.AlreadyInitialized.selector);
        EarnVault(vaultImplementation)
            .initialize(address(engine), address(1), address(2), OWNER, params.controls, params.distributorConfig);
        vm.expectRevert(EarnFees.AlreadyInitialized.selector);
        EarnFees(feesImplementation).initialize(address(1), address(2), params.fees);
    }

    /// @dev Production setup order: the engine's setup owner deploys it, the factory wraps the unbound
    ///      engine, and the setup owner then binds it to the new vault and hands it to the final owner.
    function testERC4626EngineSetupOwnerBindsFactoryStack() public {
        AdversarialERC4626Vault venue = new AdversarialERC4626Vault(address(asset));
        ERC4626EngineFactory engineFactory = new ERC4626EngineFactory();
        ERC4626Engine erc4626Engine =
            engineFactory.deploy(DEPLOYMENT_ID, IERC4626Vault(address(venue)), address(this), "", "");
        EarnFactory.DeployParams memory params = _baseParams();
        params.engine = address(erc4626Engine);

        (address earnShare, EarnVault earnVault, EarnFees earnFees) = factory.deploy(params);
        erc4626Engine.initializeEarnVault(address(earnVault), OWNER);

        _assertStack(params, earnShare, earnVault, earnFees);
        assertEq(tip20Factory.lastName(), "Adversarial Venue (Earn)");
        assertEq(tip20Factory.lastSymbol(), "advVENE");
        assertEq(erc4626Engine.earnVault(), address(earnVault));
        assertEq(erc4626Engine.owner(), OWNER);

        params.deploymentId = keccak256("second stack");
        _expectDeployRevert(params, abi.encodeWithSelector(EarnFactory.EngineAlreadyBound.selector, address(earnVault)));
    }

    function _assertStack(
        EarnFactory.DeployParams memory params,
        address earnShare,
        EarnVault earnVault,
        EarnFees earnFees
    ) private view {
        assertEq(earnVault.engine(), params.engine);
        assertEq(earnVault.asset(), IEarnEngine(params.engine).asset());
        assertEq(earnVault.earnShare(), earnShare);
        assertEq(earnVault.earnFees(), address(earnFees));
        assertEq(earnVault.operator(), params.owner);
        assertEq(earnVault.pendingOperator(), address(0));
        assertEq(earnVault.distributor(), params.distributorConfig.distributor);
        assertEq(earnVault.distributorUpdateDelay(), params.distributorConfig.updateDelay);
        assertEq(earnVault.emergencyGuardian(), params.controls.emergencyGuardian);
        assertEq(earnVault.asyncJanitor(), params.controls.asyncJanitor);
        assertEq(earnVault.maxManagedAssets(), params.controls.maxManagedAssets);
        assertEq(uint8(earnVault.engineMigrationMode()), uint8(params.controls.migrationMode));
        assertEq(
            address(uint160(uint256(vm.load(address(earnVault), ERC1967_IMPLEMENTATION_SLOT)))),
            factory.earnVaultImplementation()
        );

        assertEq(earnFees.earnVault(), address(earnVault));
        assertEq(earnFees.earnShare(), earnShare);
        assertEq(earnFees.currentFeeConfigId(), 1);
        assertEq(keccak256(abi.encode(earnFees.feeConfig(1))), keccak256(abi.encode(params.fees)));

        FactoryMockShareToken share = FactoryMockShareToken(earnShare);
        uint64 expectedPolicy = params.transferPolicyId == 0 ? ALWAYS_ALLOW_POLICY_ID : params.transferPolicyId;
        assertEq(share.transferPolicyId(), expectedPolicy);
        assertEq(share.totalSupply(), 0);
        bytes32 issuerRole = share.ISSUER_ROLE();
        address[3] memory others = [address(factory), params.owner, address(earnFees)];
        assertTrue(share.hasRole(address(earnVault), issuerRole));
        assertFalse(share.hasRole(address(earnVault), bytes32(0)));
        for (uint256 i = 0; i < others.length; i++) {
            assertFalse(share.hasRole(others[i], issuerRole));
            assertFalse(share.hasRole(others[i], bytes32(0)));
        }
    }

    function _variant(uint8 field, address alternate, uint40 entropy)
        private
        returns (EarnFactory.DeployParams memory params)
    {
        params = _baseParams();
        if (field == 0) {
            params.engine = address(new FactoryMockEngine(address(asset), 18));
        } else if (field == 1) {
            params.owner = alternate;
        } else if (field == 2) {
            params.controls.emergencyGuardian = alternate;
        } else if (field == 3) {
            params.controls.asyncJanitor = alternate;
        } else if (field == 4) {
            params.controls.maxManagedAssets = uint256(entropy) + 1;
        } else if (field == 5) {
            params.controls.migrationMode = EngineMigrationMode.UserOnly;
        } else if (field == 6) {
            params.distributorConfig = DistributorConfig(alternate, uint40(bound(entropy, 1, type(uint40).max)));
        } else if (field == 7) {
            params.fees.fixedFees[0].rateBps = uint16(bound(entropy, 101, 10_000));
        } else {
            _installPolicy(WHITELIST_POLICY_ID, WHITELIST_POLICY_TYPE);
            params.transferPolicyId = WHITELIST_POLICY_ID;
        }
    }

    function _expectDeployRevert(EarnFactory.DeployParams memory params, bytes memory revertData) private {
        address predictedShare = factory.predictEarnShare(params);
        vm.expectRevert(revertData);
        factory.deploy(params);
        assertEq(predictedShare.code.length, 0);
    }

    function _baseParams() internal view returns (EarnFactory.DeployParams memory params) {
        params.deploymentId = DEPLOYMENT_ID;
        params.engine = address(engine);
        params.owner = OWNER;
        params.controls.emergencyGuardian = OWNER;
        params.controls.asyncJanitor = OWNER;
        params.controls.migrationMode = EngineMigrationMode.OperatorEnabled;
        params.fees.fixedFeeCount = 1;
        params.fees.fixedFees[0] = FixedFeeRecipient(OWNER, 100);
        params.transferPolicyId = 0;
    }

    function _installPolicy(uint64 policyId, uint8 policyType) private {
        if (TIP403_REGISTRY_ADDRESS.code.length == 0) {
            vm.etch(TIP403_REGISTRY_ADDRESS, address(new FactoryMockTip403Registry()).code);
        }
        FactoryMockTip403Registry(TIP403_REGISTRY_ADDRESS).setPolicy(policyId, policyType, POLICY_ADMIN);
    }
}
