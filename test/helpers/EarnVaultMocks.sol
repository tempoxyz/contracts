// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { EarnVault } from "../../src/core/EarnVault.sol";
import { FeeConfig } from "../../src/interfaces/core/EarnFeeTypes.sol";
import { IEarnEngine } from "../../src/interfaces/engines/IEarnEngine.sol";
import { IEarnEngineAsyncRedeem } from "../../src/interfaces/engines/IEarnEngineAsyncRedeem.sol";
import { IEarnEngineExactWithdraw } from "../../src/interfaces/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineRedeem } from "../../src/interfaces/engines/IEarnEngineRedeem.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

function earnVaultTestNoFees() pure returns (FeeConfig memory config) { }

contract CoreMockToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    bool public forceApproveFalse;
    bool public forceApproveNoReturn;
    bool public forceTransferFromFalse;
    bool public forceTransferFromNoReturnOnce;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function setForceApproveFalse(bool v) external {
        forceApproveFalse = v;
    }

    function setForceApproveNoReturn(bool v) external {
        forceApproveNoReturn = v;
    }

    function setForceTransferFromFalse(bool v) external {
        forceTransferFromFalse = v;
    }

    function setForceTransferFromNoReturnOnce(bool v) external {
        forceTransferFromNoReturnOnce = v;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        if (forceApproveNoReturn) {
            allowance[msg.sender][spender] = value;
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (forceApproveFalse) return false;
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external virtual returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        if (forceTransferFromFalse) return false;
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= value, "ALLOWANCE");
            allowance[from][msg.sender] = a - value;
        }
        _transfer(from, to, value);
        if (forceTransferFromNoReturnOnce) {
            forceTransferFromNoReturnOnce = false;
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function mint(address to, uint256 value) external {
        totalSupply += value;
        balanceOf[to] += value;
    }

    function burn(uint256 value) external {
        require(balanceOf[msg.sender] >= value, "BALANCE");
        balanceOf[msg.sender] -= value;
        totalSupply -= value;
    }

    function _transfer(address from, address to, uint256 value) internal virtual {
        require(to != address(0), "ZERO_TO");
        require(balanceOf[from] >= value, "BALANCE");
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}

/// @dev Injects token failures: a blocked recipient makes direct transfers revert, `forceTransferFalse` makes them
/// return false, and a failing funder makes `transferFrom` return false.
contract FaultyMockToken is CoreMockToken {
    bool public forceTransferFalse;
    mapping(address recipient => bool blocked) public blockedRecipient;
    mapping(address funder => bool fail) public failTransferFrom;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        CoreMockToken(name_, symbol_, decimals_)
    { }

    function setForceTransferFalse(bool value) external {
        forceTransferFalse = value;
    }

    function setBlockedRecipient(address recipient, bool blocked) external {
        blockedRecipient[recipient] = blocked;
    }

    function setFailTransferFrom(address funder, bool fail) external {
        failTransferFrom[funder] = fail;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (blockedRecipient[to]) revert("BLOCKED");
        if (forceTransferFalse) return false;
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransferFrom[from]) return false;
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Minimal EarnVault surface for reward contracts: a pausable deposit at a fixed share rate.
contract RewardVaultMock {
    CoreMockToken public immutable assetToken;
    CoreMockToken public immutable shareToken;
    bool public depositsPaused;
    uint256 public sharesPerAsset = 1;

    constructor(CoreMockToken asset_, CoreMockToken share_) {
        assetToken = asset_;
        shareToken = share_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function earnShare() external view returns (address) {
        return address(shareToken);
    }

    function setDepositsPaused(bool paused) external {
        depositsPaused = paused;
    }

    function setSharesPerAsset(uint256 value) external {
        sharesPerAsset = value;
    }

    function deposit(uint256 assets, address receiver, uint256 minEarnShares) external returns (uint256 shares) {
        assetToken.transferFrom(msg.sender, address(this), assets);
        shares = assets * sharesPerAsset;
        require(shares >= minEarnShares, "MIN_SHARES");
        shareToken.mint(receiver, shares);
    }
}

contract CoreMockEngine {
    CoreMockToken public immutable assetToken;
    string public name = "Engine";
    string public symbol = "ENG";
    uint8 public immutable decimals;
    uint256 public totalSupply;
    uint256 public withdrawBurnOverride;
    uint256 public redeemBurnOverride;
    uint256 public redeemReportOverride;
    bool public redeemSupported = true;
    bool public exactWithdrawSupported = true;
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

    function setWithdrawBurnOverride(uint256 v) external {
        withdrawBurnOverride = v;
    }

    function setRedeemBurnOverride(uint256 v) external {
        redeemBurnOverride = v;
    }

    function setRedeemReportOverride(uint256 v) external {
        redeemReportOverride = v;
    }

    function setExitCapabilities(bool redeemSupported_, bool exactWithdrawSupported_) external {
        redeemSupported = redeemSupported_;
        exactWithdrawSupported = exactWithdrawSupported_;
    }

    function mintShares(address to, uint256 shares) external {
        totalSupply += shares;
        balanceOf[to] += shares;
    }

    function burnShares(address from, uint256 shares) external {
        require(balanceOf[from] >= shares, "SHARES");
        balanceOf[from] -= shares;
        totalSupply -= shares;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        require(assetToken.transferFrom(msg.sender, address(this), assets), "TRANSFER");
        shares = assets;
        totalSupply += shares;
        balanceOf[msg.sender] += shares;
    }

    function redeem(uint256 shares, address receiver, uint256 minAssets) external returns (uint256 assets) {
        uint256 sharesBurned = redeemBurnOverride == 0 ? shares : redeemBurnOverride;
        require(balanceOf[msg.sender] >= sharesBurned, "SHARES");
        assets = sharesBurned;
        minAssets; // deliberately ignored so the earnVault's independent post-check is exercised
        balanceOf[msg.sender] -= sharesBurned;
        totalSupply -= sharesBurned;
        require(assetToken.transfer(receiver, assets), "TRANSFER");
        if (redeemReportOverride != 0) assets = redeemReportOverride;
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function withdraw(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = withdrawBurnOverride == 0 ? assets : withdrawBurnOverride;
        require(balanceOf[msg.sender] >= shares, "SHARES");
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        require(assetToken.transfer(receiver, assets), "TRANSFER");
    }

    function totalShares() external view returns (uint256) {
        return totalSupply;
    }

    function totalAssets() external view returns (uint256) {
        return totalSupply;
    }

    function valueOf(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IEarnEngine).interfaceId
            || (redeemSupported && interfaceId == type(IEarnEngineRedeem).interfaceId)
            || (exactWithdrawSupported && interfaceId == type(IEarnEngineExactWithdraw).interfaceId);
    }
}

contract CoreReentrantDepositEngine {
    CoreMockToken public immutable assetToken;
    EarnVault public core;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(CoreMockToken asset_) {
        assetToken = asset_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function shareScale() external view returns (uint256) {
        return 10 ** uint256(assetToken.decimals());
    }

    function setCore(EarnVault core_) external {
        core = core_;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        require(assetToken.transferFrom(msg.sender, address(this), assets), "TRANSFER");
        core.deposit(1, address(this), 1);
        return assets;
    }

    function redeem(uint256 shares, address receiver, uint256 minAssets) external pure returns (uint256 assets) {
        shares;
        receiver;
        minAssets;
        return 0;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function withdraw(uint256 assets, address receiver) external pure returns (uint256 shares) {
        assets;
        receiver;
        return 0;
    }

    function totalShares() external view returns (uint256) {
        return totalSupply;
    }

    function totalAssets() external view returns (uint256) {
        return totalSupply;
    }

    function valueOf(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IEarnEngine).interfaceId
            || interfaceId == type(IEarnEngineRedeem).interfaceId
            || interfaceId == type(IEarnEngineExactWithdraw).interfaceId;
    }
}

contract CoreMockAsyncEngine {
    CoreMockToken public immutable assetToken;
    EarnVault public core;
    bool public asyncSupported = true;
    bool public valuationReverts;
    uint256 public rateWad = 1 ether;
    uint96 private _nonce;
    mapping(address => uint256) public balanceOf;
    mapping(bytes32 => uint256) public requestShares;
    mapping(bytes32 => bool) public requestOpen;

    constructor(CoreMockToken asset_) {
        assetToken = asset_;
    }

    function setCore(EarnVault core_) external {
        core = core_;
    }

    function setAsyncSupported(bool v) external {
        asyncSupported = v;
    }

    function setRate(uint256 v) external {
        rateWad = v;
    }

    function setValuationReverts(bool v) external {
        valuationReverts = v;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function shareScale() external view returns (uint256) {
        return 10 ** uint256(assetToken.decimals());
    }

    function totalAssets() external view returns (uint256) {
        require(!valuationReverts, "VALUATION");
        return balanceOf[address(core)] * rateWad / 1 ether;
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        require(!valuationReverts, "VALUATION");
        return shares * rateWad / 1 ether;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        require(assetToken.transferFrom(msg.sender, address(this), assets), "TRANSFER");
        shares = assets * 1 ether / rateWad;
        balanceOf[msg.sender] += shares;
    }

    function requestRedeem(uint256 shares, bytes calldata) external returns (bytes32 requestId) {
        require(balanceOf[msg.sender] >= shares, "SHARES");
        balanceOf[msg.sender] -= shares; // raw shares leave the engine into the queue
        requestId = keccak256(abi.encode(address(this), _nonce++));
        requestShares[requestId] = shares;
        requestOpen[requestId] = true;
    }

    function cancelRedeem(bytes32 requestId) external returns (uint256 shares) {
        require(requestOpen[requestId], "NOT_OPEN");
        requestOpen[requestId] = false;
        shares = requestShares[requestId];
        balanceOf[msg.sender] += shares; // raw shares return to the engine
    }

    function totalShares() external view returns (uint256) {
        return balanceOf[address(core)];
    }

    function valueOf(uint256 shares) external view returns (uint256) {
        require(!valuationReverts, "VALUATION");
        return shares * rateWad / 1 ether;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IEarnEngine).interfaceId
            || (asyncSupported && interfaceId == type(IEarnEngineAsyncRedeem).interfaceId);
    }

    /// @dev Test-only: settle a matured request. Transfers `amount` asset to the core and finalizes.
    function solve(bytes32 requestId, uint256 amount) external {
        require(requestOpen[requestId], "NOT_OPEN");
        requestOpen[requestId] = false;
        require(assetToken.transfer(address(core), amount), "TRANSFER");
        core.finalizeRedeem(requestId, address(assetToken), amount);
    }
}

/// @dev Receiver that records the async callbacks and can be toggled to revert inside them.
contract RecordingRedeemReceiver {
    bytes32 public lastFinalizedId;
    uint256 public lastFinalizedAmount;
    bytes32 public lastCancelledId;
    uint256 public lastCancelledShares;
    bool public revertInCallback;

    function setRevertInCallback(bool v) external {
        revertInCallback = v;
    }

    function onRedeemFinalized(bytes32 requestId, address, uint256 amount) external {
        require(!revertInCallback, "RECEIVER_REVERT");
        lastFinalizedId = requestId;
        lastFinalizedAmount = amount;
    }

    function onRedeemCancelled(bytes32 requestId, address, uint256 shares) external {
        require(!revertInCallback, "RECEIVER_REVERT");
        lastCancelledId = requestId;
        lastCancelledShares = shares;
    }
}

contract MockRateEngine {
    CoreMockToken public immutable assetToken;
    string public name = "Rate Engine";
    string public symbol = "RATE";
    uint8 public constant decimals = 18;

    uint256 public immutable rateWad; // assets per share, 1e18-scaled
    address public earnVault;
    uint256 public heldShares;
    bool public revertOnDeposit;
    uint256 public depositPullOverride;

    constructor(CoreMockToken asset_, uint256 rateWad_) {
        assetToken = asset_;
        rateWad = rateWad_;
    }

    function initializeEarnVault(address earnVault_) external {
        earnVault = earnVault_;
    }

    function setRevertOnDeposit(bool v) external {
        revertOnDeposit = v;
    }

    function setDepositPullOverride(uint256 v) external {
        depositPullOverride = v;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function shareScale() external view virtual returns (uint256) {
        return 1e18;
    }

    function totalShares() external view returns (uint256) {
        return heldShares;
    }

    function valueOf(uint256 shares) external view returns (uint256) {
        return previewRedeem(shares);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IEarnEngine).interfaceId
            || interfaceId == type(IEarnEngineRedeem).interfaceId
            || interfaceId == type(IEarnEngineExactWithdraw).interfaceId;
    }

    function _onlyCore() internal view {
        require(msg.sender == earnVault, "NOT_CORE");
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        _onlyCore();
        require(!revertOnDeposit, "DEPOSIT_REVERT");
        uint256 assetsPulled = depositPullOverride == 0 ? assets : depositPullOverride;
        require(assetsPulled <= assets, "EXCESS_PULL");
        require(assetToken.transferFrom(msg.sender, address(this), assetsPulled), "TRANSFER");
        shares = assetsPulled * 1e18 / rateWad;
        require(shares != 0, "ZERO_SHARES");
        heldShares += shares;
    }

    function redeem(uint256 shares, address receiver, uint256 minAssets) external returns (uint256 assets) {
        _onlyCore();
        require(heldShares >= shares, "SHARES");
        assets = previewRedeem(shares);
        require(assets >= minAssets, "MIN_ASSETS");
        heldShares -= shares;
        require(assetToken.transfer(receiver, assets), "TRANSFER");
    }

    function previewRedeem(uint256 shares) public view returns (uint256 assets) {
        uint256 currentShares = heldShares;
        if (currentShares == 0) return shares * rateWad / 1e18;
        return shares * assetToken.balanceOf(address(this)) / currentShares;
    }

    function totalAssets() external view returns (uint256 assets) {
        return assetToken.balanceOf(address(this));
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return (assets * 1e18 + rateWad - 1) / rateWad; // ceil
    }

    function withdraw(uint256 assets, address receiver) external returns (uint256 shares) {
        _onlyCore();
        shares = (assets * 1e18 + rateWad - 1) / rateWad;
        require(heldShares >= shares, "SHARES");
        heldShares -= shares;
        require(assetToken.transfer(receiver, assets), "TRANSFER");
    }
}

/// @dev Existing ERC-4626 shareholders can enter Earn in kind. The real engine pulls the exact
///      configured venue token, becomes its custodian, and the earnVault mints proportional EarnShare.
