// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Core accounting invariants.
import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { EarnFees } from "../../src/core/EarnFees.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { ExcessReturnFee, FeeConfig, FeePreview, FixedFeeRecipient } from "../../src/interfaces/core/EarnFeeTypes.sol";
import { CoreMockToken, earnVaultTestNoFees } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";
import { IEarnEngine } from "../../src/interfaces/engines/IEarnEngine.sol";
import { IEarnEngineAsyncRedeem } from "../../src/interfaces/engines/IEarnEngineAsyncRedeem.sol";
import { IEarnEngineExactWithdraw } from "../../src/interfaces/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineRedeem } from "../../src/interfaces/engines/IEarnEngineRedeem.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

function rewardRateWithinLimit(EarnVault core) view returns (bool) {
    uint256 baseline = core.rewardRateBaseline();
    uint256 current = core.normalizedRewardRate();
    uint256 wholeMultiples = current / baseline;
    uint256 maximum = core.MAX_REWARD_RATE_MULTIPLIER();
    return !(wholeMultiples > maximum || (wholeMultiples == maximum && current % baseline != 0));
}

function earnVaultInvariantFees(address fixedRecipient, address excessRecipient)
    pure
    returns (FeeConfig memory config)
{
    config.fixedFeeCount = 1;
    config.fixedFees[0] = FixedFeeRecipient({ account: fixedRecipient, rateBps: 1_000 });
    config.excess =
        ExcessReturnFee({ enabled: true, account: excessRecipient, annualTargetRateBps: 500, excessFeeRateBps: 2_000 });
}

contract ProportionalMockEngine {
    CoreMockToken public immutable assetToken;
    string public name = "Proportional Engine";
    string public symbol = "PENG";
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(CoreMockToken asset_, uint8 decimals_) {
        assetToken = asset_;
        decimals = decimals_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function shareScale() external view returns (uint256) {
        return 10 ** uint256(decimals);
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        uint256 supply = totalSupply;
        uint256 assetsBefore = totalAssets();

        require(assetToken.transferFrom(msg.sender, address(this), assets), "TRANSFER");

        shares = supply == 0 ? assets : assets * supply / assetsBefore;
        totalSupply += shares;
        balanceOf[msg.sender] += shares;
    }

    function redeem(uint256 shares, address receiver, uint256 minAssets) external returns (uint256 assets) {
        uint256 supply = totalSupply;
        require(balanceOf[msg.sender] >= shares, "SHARES");

        assets = shares * totalAssets() / supply;
        require(assets >= minAssets, "MIN_ASSETS");
        balanceOf[msg.sender] -= shares;
        totalSupply = supply - shares;
        require(assetToken.transfer(receiver, assets), "TRANSFER");
    }

    function previewWithdraw(uint256 assets) external view returns (uint256 shares) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        shares = _mulDivUp(assets, supply, totalAssets());
    }

    function withdraw(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = _mulDivUp(assets, totalSupply, totalAssets());
        require(balanceOf[msg.sender] >= shares, "SHARES");

        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        require(assetToken.transfer(receiver, assets), "TRANSFER");
    }

    function totalAssets() public view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    function totalShares() external view returns (uint256) {
        return totalSupply;
    }

    function valueOf(uint256 shares) external view returns (uint256) {
        if (totalSupply == 0) return 0;
        return Math.mulDiv(shares, totalAssets(), totalSupply);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        if (totalSupply == 0) return 0;
        return Math.mulDiv(shares, totalAssets(), totalSupply);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IEarnEngine).interfaceId
            || interfaceId == type(IEarnEngineRedeem).interfaceId
            || interfaceId == type(IEarnEngineExactWithdraw).interfaceId;
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return x == 0 ? 0 : (x * y - 1) / d + 1;
    }
}

contract EarnVaultHandler is Test {
    CoreMockToken public immutable asset;
    CoreMockToken public immutable earnShare;
    ProportionalMockEngine public immutable engine;
    EarnVault public immutable core;
    bool public rewardRateInvariantViolated;

    constructor(CoreMockToken asset_, CoreMockToken earnShare_, ProportionalMockEngine engine_, EarnVault core_) {
        asset = asset_;
        earnShare = earnShare_;
        engine = engine_;
        core = core_;
    }

    function deposit(uint256 assets) external {
        assets = bound(assets, 1, 1e30);
        uint256 rateBefore = core.normalizedRewardRate();
        asset.mint(address(this), assets);
        asset.approve(address(core), assets);
        core.deposit(assets, address(this), 1);
        if (core.normalizedRewardRate() > rateBefore) rewardRateInvariantViolated = true;
    }

    function redeem(uint256 shares) external {
        uint256 shareBalance = earnShare.balanceOf(address(this));
        if (shareBalance == 0) return;

        shares = bound(shares, 1, shareBalance);
        earnShare.approve(address(core), shares);
        core.redeem(shares, address(this), 1);
    }

    function withdrawExact(uint256 assets) external {
        uint256 shareBalance = earnShare.balanceOf(address(this));
        if (shareBalance == 0) return;

        uint256 maxAssets = core.previewRedeem(shareBalance);
        if (maxAssets == 0) return;

        assets = bound(assets, 1, maxAssets);
        uint256 requiredShares = core.previewWithdraw(assets);
        if (requiredShares == 0 || requiredShares > shareBalance) return;

        earnShare.approve(address(core), requiredShares);
        core.withdrawExact(assets, address(this), shareBalance);
    }

    function accrueYield(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        asset.mint(address(engine), amount);
    }

    function contribute(uint256 assets) external {
        if (earnShare.totalSupply() == 0) return;

        assets = bound(assets, 1, 1e24);
        asset.mint(address(this), assets);
        asset.approve(address(core), assets);
        core.contribute(assets);
        if (!rewardRateWithinLimit(core)) rewardRateInvariantViolated = true;
    }
}

contract FeeEarnVaultHandler is EarnVaultHandler {
    address public immutable administrator;
    address public immutable fixedRecipient;
    address public immutable excessRecipient;
    EarnFees public immutable fees;

    constructor(
        CoreMockToken asset_,
        CoreMockToken earnShare_,
        ProportionalMockEngine engine_,
        EarnVault core_,
        address administrator_,
        address fixedRecipient_,
        address excessRecipient_
    ) EarnVaultHandler(asset_, earnShare_, engine_, core_) {
        administrator = administrator_;
        fixedRecipient = fixedRecipient_;
        excessRecipient = excessRecipient_;
        fees = EarnFees(core_.earnFees());
    }

    function checkpointFees() external {
        core.accrueFees();
    }

    function accrueLoss(uint256 amount) external {
        uint256 activeAssets = engine.totalAssets();
        if (activeAssets <= 1) return;
        amount = bound(amount, 1, activeAssets - 1);
        vm.prank(address(engine));
        asset.burn(amount);
    }

    function advanceTime(uint256 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 1, 365 days));
    }

    function updateFees(uint16 fixedRateBps, uint16 targetRateBps, uint16 excessRateBps) external {
        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] =
            FixedFeeRecipient({ account: fixedRecipient, rateBps: uint16(bound(fixedRateBps, 1, 2_500)) });
        config.excess = ExcessReturnFee({
            enabled: true,
            account: excessRecipient,
            annualTargetRateBps: uint16(bound(targetRateBps, 0, 10_000)),
            excessFeeRateBps: uint16(bound(excessRateBps, 1, 10_000))
        });
        vm.prank(administrator);
        core.setFeeConfig(config);
    }

    function disableFees() external {
        if (fees.feesDisabled()) return;
        vm.prank(administrator);
        core.disableFees();
    }

    function claimFees(uint256 recipientSeed, uint256 amount) external {
        address recipient = recipientSeed % 2 == 0 ? fixedRecipient : excessRecipient;
        uint256 claimable = fees.claimableEarnShares(recipient);
        if (claimable == 0) return;
        amount = bound(amount, 1, claimable);
        vm.prank(recipient);
        fees.claim(address(this), amount);
    }
}

contract AsyncInvariantEngine {
    CoreMockToken public immutable assetToken;
    EarnVault public core;
    uint96 private nonce;
    mapping(address => uint256) public balanceOf;
    mapping(bytes32 => uint256) public requestShares;
    mapping(bytes32 => bool) public requestOpen;

    constructor(CoreMockToken asset_) {
        assetToken = asset_;
    }

    function setCore(EarnVault core_) external {
        core = core_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function shareScale() external view returns (uint256) {
        return 10 ** uint256(assetToken.decimals());
    }

    function totalAssets() external view returns (uint256) {
        return balanceOf[address(core)];
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        require(assetToken.transferFrom(msg.sender, address(this), assets), "TRANSFER");
        shares = assets;
        balanceOf[msg.sender] += shares;
    }

    function requestRedeem(uint256 shares, bytes calldata) external returns (bytes32 requestId) {
        require(balanceOf[msg.sender] >= shares, "SHARES");
        balanceOf[msg.sender] -= shares;
        requestId = keccak256(abi.encode(address(this), nonce++));
        requestShares[requestId] = shares;
        requestOpen[requestId] = true;
    }

    function cancelRedeem(bytes32 requestId) external returns (uint256 shares) {
        require(requestOpen[requestId], "NOT_OPEN");
        requestOpen[requestId] = false;
        shares = requestShares[requestId];
        balanceOf[msg.sender] += shares;
    }

    function settle(bytes32 requestId) external {
        require(requestOpen[requestId], "NOT_OPEN");
        requestOpen[requestId] = false;
        uint256 assets = requestShares[requestId];
        require(assetToken.transfer(address(core), assets), "TRANSFER");
        core.finalizeRedeem(requestId, address(assetToken), assets);
    }

    function totalShares() external view returns (uint256) {
        return balanceOf[address(core)];
    }

    function valueOf(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IEarnEngine).interfaceId
            || interfaceId == type(IEarnEngineAsyncRedeem).interfaceId;
    }
}

contract AsyncEarnVaultHandler is Test {
    CoreMockToken public immutable asset;
    CoreMockToken public immutable earnShare;
    AsyncInvariantEngine public immutable engine;
    EarnVault public immutable core;
    bytes32[] private requestIds;
    mapping(bytes32 => bool) public requestOpen;
    uint256 public openRequests;
    uint256 public pendingEngineShares;
    bool public rewardRateInvariantViolated;

    constructor(CoreMockToken asset_, CoreMockToken earnShare_, AsyncInvariantEngine engine_, EarnVault core_) {
        asset = asset_;
        earnShare = earnShare_;
        engine = engine_;
        core = core_;
    }

    function deposit(uint256 assets) external {
        assets = bound(assets, 1, 1e24);
        uint256 rateBefore = core.normalizedRewardRate();
        asset.mint(address(this), assets);
        asset.approve(address(core), assets);
        core.deposit(assets, address(this), 1);
        if (core.normalizedRewardRate() > rateBefore) rewardRateInvariantViolated = true;
    }

    function contribute(uint256 assets) external {
        if (earnShare.totalSupply() == 0) return;
        assets = bound(assets, 1, 1e24);
        asset.mint(address(this), assets);
        asset.approve(address(core), assets);
        core.contribute(assets);
        if (!rewardRateWithinLimit(core)) rewardRateInvariantViolated = true;
    }

    function requestRedeem(uint256 shares) external {
        uint256 balance = earnShare.balanceOf(address(this));
        if (balance == 0) return;
        shares = bound(shares, 1, balance);
        earnShare.approve(address(core), shares);
        bytes32 requestId = core.requestRedeem(shares, "", address(this));
        EarnVault.PendingRedeem memory pending = core.pendingRedeem(requestId);
        requestIds.push(requestId);
        requestOpen[requestId] = true;
        openRequests += 1;
        pendingEngineShares += pending.engineShares;
    }

    function cancelRedeem(uint256 seed) external {
        bytes32 requestId = _openRequest(seed);
        if (requestId == bytes32(0)) return;
        bool activePoolWasNonempty = earnShare.totalSupply() != 0;
        uint256 rateBefore = core.normalizedRewardRate();
        uint256 rewardBaselineBefore = core.rewardRateBaseline();
        uint256 engineShares = core.pendingRedeem(requestId).engineShares;
        core.cancelRedeem(requestId, 1);
        if (activePoolWasNonempty && core.normalizedRewardRate() > rateBefore) {
            rewardRateInvariantViolated = true;
        }
        if (core.rewardRateBaseline() != rewardBaselineBefore) rewardRateInvariantViolated = true;
        requestOpen[requestId] = false;
        openRequests -= 1;
        pendingEngineShares -= engineShares;
    }

    function finalizeRedeem(uint256 seed) external {
        bytes32 requestId = _openRequest(seed);
        if (requestId == bytes32(0)) return;
        uint256 engineShares = core.pendingRedeem(requestId).engineShares;
        engine.settle(requestId);
        requestOpen[requestId] = false;
        openRequests -= 1;
        pendingEngineShares -= engineShares;
    }

    function requestCount() external view returns (uint256) {
        return requestIds.length;
    }

    function _openRequest(uint256 seed) private view returns (bytes32 requestId) {
        uint256 count = requestIds.length;
        if (count == 0) return bytes32(0);
        uint256 start = seed % count;
        for (uint256 i = 0; i < count; i++) {
            requestId = requestIds[(start + i) % count];
            if (requestOpen[requestId]) return requestId;
        }
        return bytes32(0);
    }
}

contract FeeEarnVaultInvariantTest is StdInvariant, Test {
    address private constant ADMINISTRATOR = address(0xAD);
    address private constant FIXED_RECIPIENT = address(0xF1);
    address private constant EXCESS_RECIPIENT = address(0xE1);

    CoreMockToken private asset;
    CoreMockToken private earnShare;
    ProportionalMockEngine private engine;
    EarnVault private core;
    EarnFees private fees;
    FeeEarnVaultHandler private handler;

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        earnShare = new CoreMockToken("Share", "SH", 18);
        engine = new ProportionalMockEngine(asset, 18);
        core = EarnVaultTestDeployer.deploy(
            address(engine),
            address(earnShare),
            ADMINISTRATOR,
            earnVaultInvariantFees(FIXED_RECIPIENT, EXCESS_RECIPIENT)
        );
        fees = EarnFees(core.earnFees());
        handler =
            new FeeEarnVaultHandler(asset, earnShare, engine, core, ADMINISTRATOR, FIXED_RECIPIENT, EXCESS_RECIPIENT);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = EarnVaultHandler.deposit.selector;
        selectors[1] = EarnVaultHandler.redeem.selector;
        selectors[2] = EarnVaultHandler.withdrawExact.selector;
        selectors[3] = EarnVaultHandler.accrueYield.selector;
        selectors[4] = EarnVaultHandler.contribute.selector;
        selectors[5] = FeeEarnVaultHandler.checkpointFees.selector;
        selectors[6] = FeeEarnVaultHandler.accrueLoss.selector;
        selectors[7] = FeeEarnVaultHandler.advanceTime.selector;
        selectors[8] = FeeEarnVaultHandler.updateFees.selector;
        selectors[9] = FeeEarnVaultHandler.disableFees.selector;
        selectors[10] = FeeEarnVaultHandler.claimFees.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_feeAccrualPreservesBackingAlignment() public view {
        assertTrue(core.isAccountingAligned());
    }

    function invariant_rewardAdmissionsAndEntriesPreserveRatePolicy() public view {
        assertFalse(handler.rewardRateInvariantViolated());
    }

    function invariant_feeCustodyEqualsRecordedClaims() public view {
        assertEq(earnShare.balanceOf(address(fees)), fees.totalClaimableEarnShares());
        assertLe(fees.totalClaimableEarnShares(), earnShare.totalSupply());
    }

    function invariant_previewNeverChargesMoreThanPositiveAccrual() public view {
        FeePreview memory preview = fees.previewAccruedFees();
        assertLe(preview.totalFeeAssets, preview.positiveAccrualAssets);
        assertEq(preview.totalFeeAssets, preview.fixedFeeAssets + preview.excessFeeAssets);
    }

    function invariant_earnVaultRetainsNoTokens() public view {
        assertEq(asset.balanceOf(address(core)), 0);
        assertEq(earnShare.balanceOf(address(core)), 0);
    }
}

contract AsyncEarnVaultInvariantTest is StdInvariant, Test {
    CoreMockToken private asset;
    CoreMockToken private earnShare;
    AsyncInvariantEngine private engine;
    EarnVault private core;
    AsyncEarnVaultHandler private handler;

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        earnShare = new CoreMockToken("Share", "SH", 18);
        engine = new AsyncInvariantEngine(asset);
        core = EarnVaultTestDeployer.deploy(address(engine), address(earnShare), address(this), earnVaultTestNoFees());
        engine.setCore(core);
        handler = new AsyncEarnVaultHandler(asset, earnShare, engine, core);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = AsyncEarnVaultHandler.deposit.selector;
        selectors[1] = AsyncEarnVaultHandler.contribute.selector;
        selectors[2] = AsyncEarnVaultHandler.requestRedeem.selector;
        selectors[3] = AsyncEarnVaultHandler.cancelRedeem.selector;
        selectors[4] = AsyncEarnVaultHandler.finalizeRedeem.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_activeSupplyExcludesPendingClaims() public view {
        assertTrue(core.isAccountingAligned());
        assertEq(core.convertToEngineShares(core.totalEarnShares()), core.engineShares());
        assertEq(core.rawEngineShares(), engine.balanceOf(address(core)));
    }

    function invariant_rewardAdmissionsAndEntriesPreserveRatePolicy() public view {
        assertFalse(handler.rewardRateInvariantViolated());
    }

    function invariant_openRequestCountMatchesHandlerBookkeeping() public view {
        assertEq(core.openRedeemRequestCount(), handler.openRequests());
    }

    function invariant_engineAssetsCoverActiveAndPendingShares() public view {
        assertEq(asset.balanceOf(address(engine)), engine.balanceOf(address(core)) + handler.pendingEngineShares());
    }

    function invariant_earnVaultRetainsNoTokens() public view {
        assertEq(asset.balanceOf(address(core)), 0);
        assertEq(earnShare.balanceOf(address(core)), 0);
    }
}
