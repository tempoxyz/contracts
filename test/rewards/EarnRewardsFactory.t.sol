// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test, Vm } from "forge-std/Test.sol";

import { IEarnVault } from "../../src/interfaces/core/IEarnVault.sol";
import { EarnContributionController } from "../../src/rewards/EarnContributionController.sol";
import { EarnMerkleRewardDistributor } from "../../src/rewards/EarnMerkleRewardDistributor.sol";
import { EarnRewardsFactory } from "../../src/rewards/EarnRewardsFactory.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { CoreMockToken, RewardVaultMock } from "../helpers/EarnVaultMocks.sol";

/// @dev Vault surface whose asset can change, to reach the factory's existing-deployment check.
contract RewardsFactoryMutableAssetVault {
    address public asset;
    address public earnShare;

    constructor(address asset_, address earnShare_) {
        asset = asset_;
        earnShare = earnShare_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }
}

contract EarnRewardsFactoryTest is Test {
    event ContributionControllerInstalled(
        address indexed earnVault, address indexed owner, address contributionController
    );
    event MerkleDistributorInstalled(
        address indexed earnVault,
        address indexed owner,
        address indexed treasury,
        address merkleDistributor,
        bytes32 campaignId,
        uint40 claimDeadline
    );

    EarnRewardsFactory private factory;
    RewardVaultMock private vault;

    address private owner = makeAddr("owner");
    address private treasury = makeAddr("treasury");
    uint40 private deadline;

    function setUp() public {
        factory = new EarnRewardsFactory();
        vault = new RewardVaultMock(new CoreMockToken("Asset", "AST", 6), new CoreMockToken("Share", "SH", 6));
        deadline = uint40(block.timestamp + 30 days);
    }

    function testInstallsBothComponentsAtPredictedAddressesWithRequestedWiring() public {
        address predictedController = factory.predictContributionController(_vault(), owner);
        address predictedDistributor = factory.predictMerkleDistributor(_vault(), owner, treasury, deadline);

        EarnRewardsFactory.Installation memory installed =
            factory.install(_vault(), owner, treasury, deadline, true, true);

        assertEq(installed.contributionController, predictedController);
        assertEq(installed.merkleDistributor, predictedDistributor);
        _assertController(predictedController, owner);
        _assertDistributor(predictedDistributor, owner, treasury, deadline);
    }

    function testInstallEmitsComponentConfiguration() public {
        address predictedController = factory.predictContributionController(_vault(), owner);
        address predictedDistributor = factory.predictMerkleDistributor(_vault(), owner, treasury, deadline);

        vm.expectEmit(address(factory));
        emit ContributionControllerInstalled(address(vault), owner, predictedController);
        vm.expectEmit(address(factory));
        emit MerkleDistributorInstalled(
            address(vault), owner, treasury, predictedDistributor, factory.campaignId(_vault()), deadline
        );
        factory.install(_vault(), owner, treasury, deadline, true, true);
    }

    function testInstallsOnlyRequestedComponent() public {
        address predictedController = factory.predictContributionController(_vault(), owner);
        address predictedDistributor = factory.predictMerkleDistributor(_vault(), owner, treasury, deadline);

        EarnRewardsFactory.Installation memory controllerOnly =
            factory.install(_vault(), owner, address(0), 0, true, false);
        assertEq(controllerOnly.contributionController, predictedController);
        assertEq(controllerOnly.merkleDistributor, address(0));
        assertEq(predictedDistributor.code.length, 0);

        EarnRewardsFactory.Installation memory distributorOnly =
            factory.install(_vault(), owner, treasury, deadline, false, true);
        assertEq(distributorOnly.contributionController, address(0));
        assertEq(distributorOnly.merkleDistributor, predictedDistributor);
    }

    function testRepeatedInstallationIsIdempotent() public {
        EarnRewardsFactory.Installation memory first = factory.install(_vault(), owner, treasury, deadline, true, true);

        vm.recordLogs();
        EarnRewardsFactory.Installation memory second = factory.install(_vault(), owner, treasury, deadline, true, true);

        assertEq(second.contributionController, first.contributionController);
        assertEq(second.merkleDistributor, first.merkleDistributor);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
    }

    function testInstallRejectsInvalidConfiguration() public {
        vm.expectRevert(EarnRewardsFactory.ZeroAddress.selector);
        factory.install(IEarnVault(address(0)), owner, treasury, deadline, true, true);
        vm.expectRevert(EarnRewardsFactory.ZeroAddress.selector);
        factory.install(_vault(), address(0), treasury, deadline, true, true);
        vm.expectRevert(EarnRewardsFactory.EmptyInstallation.selector);
        factory.install(_vault(), owner, address(0), 0, false, false);

        vm.expectRevert(EarnRewardsFactory.InvalidRewardConfiguration.selector);
        factory.install(_vault(), owner, address(0), deadline, true, true);
        vm.expectRevert(EarnRewardsFactory.InvalidRewardConfiguration.selector);
        factory.install(_vault(), owner, treasury, 0, true, true);
        vm.expectRevert(EarnRewardsFactory.InvalidRewardConfiguration.selector);
        factory.install(_vault(), owner, treasury, 0, true, false);
        vm.expectRevert(EarnRewardsFactory.InvalidRewardConfiguration.selector);
        factory.install(_vault(), owner, address(0), deadline, true, false);
    }

    function testFuzzInstallRejectsElapsedClaimDeadline(uint40 claimDeadline) public {
        vm.warp(deadline);
        claimDeadline = uint40(bound(claimDeadline, 1, block.timestamp));
        address predicted = factory.predictMerkleDistributor(_vault(), owner, treasury, claimDeadline);

        vm.expectRevert(EarnRewardsFactory.InvalidRewardConfiguration.selector);
        factory.install(_vault(), owner, treasury, claimDeadline, false, true);
        assertEq(predicted.code.length, 0);
    }

    function testInstallRejectsVaultWithoutCode() public {
        IEarnVault codeless = IEarnVault(makeAddr("codeless vault"));

        vm.expectRevert();
        factory.install(codeless, owner, address(0), 0, true, false);
        vm.expectRevert(EarnMerkleRewardDistributor.InvalidEarnVault.selector);
        factory.install(codeless, owner, treasury, deadline, false, true);
    }

    /// @dev The caller is not part of any salt: an installation for another owner lands at another
    ///      address, and replaying the victim's exact arguments yields components the victim owns.
    function testFuzzOtherCallersCannotOccupyOwnerInstallation(address attacker) public {
        vm.assume(attacker != address(0) && attacker != owner);
        vm.startPrank(attacker);
        EarnRewardsFactory.Installation memory squatted =
            factory.install(_vault(), attacker, treasury, deadline, true, true);
        EarnRewardsFactory.Installation memory replayed =
            factory.install(_vault(), owner, treasury, deadline, true, true);
        vm.stopPrank();

        assertTrue(squatted.contributionController != replayed.contributionController);
        assertTrue(squatted.merkleDistributor != replayed.merkleDistributor);
        _assertController(replayed.contributionController, owner);
        _assertDistributor(replayed.merkleDistributor, owner, treasury, deadline);

        EarnRewardsFactory.Installation memory installed =
            factory.install(_vault(), owner, treasury, deadline, true, true);
        assertEq(installed.contributionController, replayed.contributionController);
        assertEq(installed.merkleDistributor, replayed.merkleDistributor);
    }

    function testFuzzDistributorAddressBindsTreasuryAndDeadline(address otherTreasury, uint40 otherDeadline) public {
        otherDeadline = uint40(bound(otherDeadline, block.timestamp + 1, type(uint40).max));
        vm.assume(otherTreasury != address(0) && (otherTreasury != treasury || otherDeadline != deadline));

        address first = factory.install(_vault(), owner, treasury, deadline, false, true).merkleDistributor;
        address second = factory.install(_vault(), owner, otherTreasury, otherDeadline, false, true).merkleDistributor;

        assertTrue(first != second);
        _assertDistributor(first, owner, treasury, deadline);
        _assertDistributor(second, owner, otherTreasury, otherDeadline);
    }

    function testFactoryKeepsNoComponentAuthority() public {
        EarnRewardsFactory.Installation memory installed =
            factory.install(_vault(), owner, treasury, deadline, true, true);
        bytes memory unauthorized =
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(factory));

        vm.startPrank(address(factory));
        vm.expectRevert(unauthorized);
        EarnContributionController(installed.contributionController).setActive(false);
        vm.expectRevert(unauthorized);
        Ownable(installed.contributionController).transferOwnership(address(factory));
        vm.expectRevert(unauthorized);
        Ownable(installed.merkleDistributor).transferOwnership(address(factory));
        vm.stopPrank();
    }

    function testReinstallRejectsComponentNoLongerMatchingVault() public {
        RewardsFactoryMutableAssetVault mutableVault =
            new RewardsFactoryMutableAssetVault(address(vault.assetToken()), address(vault.shareToken()));
        IEarnVault target = IEarnVault(address(mutableVault));
        address controller = factory.install(target, owner, address(0), 0, true, false).contributionController;

        mutableVault.setAsset(address(new CoreMockToken("Other", "OTH", 6)));

        vm.expectRevert(abi.encodeWithSelector(EarnRewardsFactory.InvalidExistingDeployment.selector, controller));
        factory.install(target, owner, address(0), 0, true, false);
    }

    function _assertController(address component, address expectedOwner) private view {
        EarnContributionController controller = EarnContributionController(component);
        assertEq(address(controller.earnVault()), address(vault));
        assertEq(controller.asset(), vault.asset());
        assertEq(controller.owner(), expectedOwner);
        assertEq(controller.pendingOwner(), address(0));
        assertTrue(controller.active());
    }

    function _assertDistributor(
        address component,
        address expectedOwner,
        address expectedTreasury,
        uint40 expectedDeadline
    ) private view {
        EarnMerkleRewardDistributor distributor = EarnMerkleRewardDistributor(component);
        assertEq(address(distributor.earnVault()), address(vault));
        assertEq(distributor.asset(), vault.asset());
        assertEq(distributor.earnShare(), vault.earnShare());
        assertEq(distributor.treasury(), expectedTreasury);
        assertEq(distributor.campaignId(), bytes32(uint256(uint160(address(vault)))));
        assertEq(distributor.claimDeadline(), expectedDeadline);
        assertEq(distributor.owner(), expectedOwner);
        assertEq(distributor.pendingOwner(), address(0));
    }

    function _vault() private view returns (IEarnVault) {
        return IEarnVault(address(vault));
    }
}
