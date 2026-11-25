// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20, ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20Factory } from "tempo-std/interfaces/ITIP20Factory.sol";

import { EarnFactory } from "../../../src/earn/core/EarnFactory.sol";
import { EarnFees } from "../../../src/earn/core/EarnFees.sol";
import { EarnVault } from "../../../src/earn/core/EarnVault.sol";
import { Simple4626Vault } from "../../../src/demo/Simple4626Vault.sol";
import { ERC4626Engine, IERC4626Vault } from "../../../src/earn/engines/erc4626/ERC4626Engine.sol";
import { ExcessReturnFee, FeeConfig, FixedFeeRecipient } from "../../../src/interfaces/earn/EarnFeeTypes.sol";
import {
    DistributorConfig,
    EarnVaultControls,
    EngineMigrationMode
} from "../../../src/interfaces/earn/EarnVaultTypes.sol";

/// @notice EarnVault paths that checkpoint fees, measured on real TIP-20 precompiles, where every zero-to-nonzero
///         storage write is charged as a new slot (TIP-1000). A fixed fee and an excess fee pay two recipients
///         that already hold claimable EarnShare. Each call is measured with `gasleft`, since
///         `snapshotGasLastCall` leaves the new-slot charge out.
///         `FOUNDRY_PROFILE=spend forge test --match-path 'test/spend/gas/*'` writes the results to snapshots/.
contract EarnFeesTip20GasTest is Test {
    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    bytes32 internal constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    ITIP20Factory internal tip20Factory = ITIP20Factory(StdPrecompiles.TIP20_FACTORY_ADDRESS);
    ITIP20Token internal usd;
    ITIP20Token internal earnShare;
    Simple4626Vault internal venue;
    EarnVault internal earnVault;
    EarnFees internal fees;

    address internal holder = makeAddr("gas.holder");
    address internal fixedRecipient = makeAddr("gas.fee.fixed");
    address internal excessRecipient = makeAddr("gas.fee.excess");

    function setUp() public {
        vm.warp(1_790_000_000);
        usd = ITIP20Token(
            tip20Factory.createToken("Open USD", "OUSD", "USD", ITIP20(PATH_USD), address(this), keccak256("OUSD"))
        );
        usd.grantRole(ISSUER_ROLE, address(this));
        venue = new Simple4626Vault(address(usd), "Vault OUSD", "vOUSD", 6);
        ERC4626Engine engine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        EarnFactory earnFactory =
            new EarnFactory(address(tip20Factory), address(new EarnVault()), address(new EarnFees()));
        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(fixedRecipient, 250);
        config.excess = ExcessReturnFee(true, excessRecipient, 300, 5000);
        (address share, EarnVault vault, EarnFees fees_) = earnFactory.deploy(
            EarnFactory.DeployParams({
                deploymentId: bytes32("tempo-earn.fees"),
                engine: address(engine),
                owner: address(this),
                controls: EarnVaultControls({
                    emergencyGuardian: address(this),
                    asyncJanitor: address(this),
                    maxManagedAssets: 0,
                    migrationMode: EngineMigrationMode.OperatorEnabled
                }),
                distributorConfig: DistributorConfig(address(0), 0),
                fees: config,
                transferPolicyId: 0
            })
        );
        engine.initializeEarnVault(address(vault));
        earnVault = vault;
        earnShare = ITIP20Token(share);
        fees = fees_;

        usd.mint(holder, 100_000e6);
        // Residue that keeps the vault's and the engine's base-asset balance slots nonzero.
        usd.mint(address(vault), 1);
        usd.mint(address(engine), 1);
        vm.startPrank(holder);
        usd.approve(address(vault), type(uint256).max);
        earnShare.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6, holder, 1);
        vm.stopPrank();
        // A first charging checkpoint, so both recipients already hold claimable EarnShare.
        _accrueYield();
        vm.prank(holder);
        vault.deposit(1e6, holder, 1);
    }

    /// @dev A deposit with fees active and no new yield since the last checkpoint.
    function test_gasDepositSteady() public {
        vm.prank(holder);
        uint256 before = gasleft();
        earnVault.deposit(1000e6, holder, 1);
        vm.snapshotValue("earn-fees-tip20", "deposit.steady", before - gasleft());
    }

    /// @dev A deposit whose checkpoint charges new yield to both recipients.
    function test_gasDepositChargingYield() public {
        _accrueYield();
        vm.prank(holder);
        uint256 before = gasleft();
        earnVault.deposit(1000e6, holder, 1);
        vm.snapshotValue("earn-fees-tip20", "deposit.yield", before - gasleft());
    }

    /// @dev As above after both recipients claimed everything they were owed.
    function test_gasDepositChargingYieldAfterClaims() public {
        _claimAll(fixedRecipient);
        _claimAll(excessRecipient);
        assertEq(fees.totalClaimableEarnShares(), 0);
        _accrueYield();
        vm.prank(holder);
        uint256 before = gasleft();
        earnVault.deposit(1000e6, holder, 1);
        vm.snapshotValue("earn-fees-tip20", "deposit.yield.after-claims", before - gasleft());
    }

    /// @dev A redemption with fees active and no new yield since the last checkpoint.
    function test_gasRedeemSteady() public {
        vm.prank(holder);
        uint256 before = gasleft();
        earnVault.redeem(1000e6, holder, 1);
        vm.snapshotValue("earn-fees-tip20", "redeem.steady", before - gasleft());
    }

    /// @dev A redemption whose checkpoint charges new yield to both recipients.
    function test_gasRedeemChargingYield() public {
        _accrueYield();
        vm.prank(holder);
        uint256 before = gasleft();
        earnVault.redeem(1000e6, holder, 1);
        vm.snapshotValue("earn-fees-tip20", "redeem.yield", before - gasleft());
    }

    /// @dev A deposit into a $100M pool one second after its last charging checkpoint, with one second of 5% annual
    ///      yield since: growth below one value unit per EarnShare waits, so the checkpoint charges nothing.
    function test_gasDepositOneSecondOfYieldLargePool() public {
        usd.mint(holder, 100_000_000e6);
        vm.prank(holder);
        earnVault.deposit(100_000_000e6, holder, 1);
        _accrueYield();
        earnVault.accrueFees();
        uint256 claimable = fees.totalClaimableEarnShares();
        usd.mint(address(venue), usd.balanceOf(address(venue)) * 500 / 10_000 / 365 days);
        vm.warp(block.timestamp + 1);
        vm.prank(holder);
        uint256 before = gasleft();
        earnVault.deposit(1000e6, holder, 1);
        vm.snapshotValue("earn-fees-tip20", "deposit.large-pool.one-second-yield", before - gasleft());
        assertEq(fees.totalClaimableEarnShares(), claimable);
    }

    /// @dev A full claim by one recipient while the other's EarnShare stays with `EarnFees`.
    function test_gasClaimAll() public {
        uint256 claimable = fees.claimableEarnShares(fixedRecipient);
        vm.prank(fixedRecipient);
        uint256 before = gasleft();
        fees.claim(fixedRecipient, claimable);
        vm.snapshotValue("earn-fees-tip20", "claim.all", before - gasleft());
    }

    function _accrueYield() private {
        usd.mint(address(venue), usd.balanceOf(address(venue)) / 100);
        vm.warp(block.timestamp + 30 days);
    }

    function _claimAll(address recipient) private {
        uint256 claimable = fees.claimableEarnShares(recipient);
        assertGt(claimable, 0);
        vm.prank(recipient);
        fees.claim(recipient, claimable);
        assertEq(fees.claimableEarnShares(recipient), 0);
    }
}
