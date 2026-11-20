// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20, ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20Factory } from "tempo-std/interfaces/ITIP20Factory.sol";

import { EarnFactory } from "../../../src/earn/core/EarnFactory.sol";
import { EarnFees } from "../../../src/earn/core/EarnFees.sol";
import { EarnVault } from "../../../src/earn/core/EarnVault.sol";
import { ExcessReturnFee, FeeConfig, FixedFeeRecipient } from "../../../src/interfaces/earn/EarnFeeTypes.sol";
import {
    DistributorConfig,
    EarnVaultControls,
    EngineMigrationMode
} from "../../../src/interfaces/earn/EarnVaultTypes.sol";
import { CoreMockAsyncEngine, CoreMockToken } from "../../earn/helpers/EarnVaultMocks.sol";

/// @notice EarnVault async exits measured on real TIP-20 precompiles, where every zero-to-nonzero storage write
///         is charged as a new slot (TIP-1000), over a mock async engine and a fee configuration that records a
///         fee snapshot per request. Each call is measured with `gasleft`, since `snapshotGasLastCall` leaves the
///         new-slot charge out. `FOUNDRY_PROFILE=spend forge test --match-path 'test/spend/gas/*'` writes the results
///         to snapshots/.
contract EarnAsyncTip20GasTest is Test {
    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    bytes32 internal constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    ITIP20Factory internal tip20Factory = ITIP20Factory(StdPrecompiles.TIP20_FACTORY_ADDRESS);
    ITIP20Token internal usd;
    ITIP20Token internal earnShare;
    EarnVault internal earnVault;
    AsyncGasEngine internal engine;

    address internal holder = makeAddr("gas.holder");

    function setUp() public {
        vm.warp(1_790_000_000);
        usd = ITIP20Token(
            tip20Factory.createToken("Open USD", "OUSD", "USD", ITIP20(PATH_USD), address(this), keccak256("OUSD"))
        );
        usd.grantRole(ISSUER_ROLE, address(this));
        engine = new AsyncGasEngine(CoreMockToken(address(usd)));
        EarnFactory earnFactory =
            new EarnFactory(address(tip20Factory), address(new EarnVault()), address(new EarnFees()));
        FeeConfig memory fees;
        fees.fixedFeeCount = 1;
        fees.fixedFees[0] = FixedFeeRecipient(makeAddr("gas.fee"), 250);
        fees.excess = ExcessReturnFee(true, makeAddr("gas.fee"), 300, 5000);
        (address share, EarnVault vault,) = earnFactory.deploy(
            EarnFactory.DeployParams({
                deploymentId: bytes32("tempo-earn.async"),
                engine: address(engine),
                owner: address(this),
                controls: EarnVaultControls({
                    emergencyGuardian: address(this),
                    asyncJanitor: address(this),
                    maxManagedAssets: 0,
                    migrationMode: EngineMigrationMode.OperatorEnabled
                }),
                distributorConfig: DistributorConfig(address(0), 0),
                fees: fees,
                transferPolicyId: 0
            })
        );
        engine.setCore(vault);
        earnVault = vault;
        earnShare = ITIP20Token(share);

        usd.mint(holder, 10_000e6);
        // Residue that keeps the vault's and the engine's base-asset balance slots nonzero.
        usd.mint(address(vault), 1);
        usd.mint(address(engine), 1);
        vm.startPrank(holder);
        usd.approve(address(vault), type(uint256).max);
        earnShare.approve(address(vault), type(uint256).max);
        vault.deposit(1000e6, holder, 1);
        vm.stopPrank();
    }

    /// @dev The first request into an empty queue.
    function test_gasRequestRedeemFirst() public {
        vm.prank(holder);
        uint256 before = gasleft();
        earnVault.requestRedeem(100e6, "", holder);
        vm.snapshotValue("earn-async-tip20", "request.first", before - gasleft());
    }

    /// @dev A request while another is still open.
    function test_gasRequestRedeemSecond() public {
        vm.startPrank(holder);
        earnVault.requestRedeem(100e6, "", holder);
        uint256 before = gasleft();
        earnVault.requestRedeem(100e6, "", holder);
        vm.snapshotValue("earn-async-tip20", "request.second", before - gasleft());
        vm.stopPrank();
    }

    /// @dev A request after an earlier one was solved, so the queue emptied in between.
    function test_gasRequestRedeemAfterSolve() public {
        vm.prank(holder);
        bytes32 requestId = earnVault.requestRedeem(100e6, "", holder);
        engine.solve(requestId, 100e6);
        vm.prank(holder);
        uint256 before = gasleft();
        earnVault.requestRedeem(100e6, "", holder);
        vm.snapshotValue("earn-async-tip20", "request.after-solve", before - gasleft());
    }

    function test_gasSolve() public {
        vm.prank(holder);
        bytes32 requestId = earnVault.requestRedeem(100e6, "", holder);
        uint256 before = gasleft();
        engine.solve(requestId, 100e6);
        vm.snapshotValue("earn-async-tip20", "solve", before - gasleft());
    }

    function test_gasCancelRedeem() public {
        vm.prank(holder);
        bytes32 requestId = earnVault.requestRedeem(100e6, "", holder);
        vm.prank(holder);
        uint256 before = gasleft();
        earnVault.cancelRedeem(requestId, 1);
        vm.snapshotValue("earn-async-tip20", "cancel", before - gasleft());
    }
}

/// @dev The mock async engine with the binding and metadata getters the factory reads before it deploys a stack.
contract AsyncGasEngine is CoreMockAsyncEngine {
    constructor(CoreMockToken asset_) CoreMockAsyncEngine(asset_) { }

    function earnVault() external view returns (address) {
        return address(core);
    }

    function name() external pure returns (string memory) {
        return "Async USD";
    }

    function symbol() external pure returns (string memory) {
        return "aUSD";
    }
}
