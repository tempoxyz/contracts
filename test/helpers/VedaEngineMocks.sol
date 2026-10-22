// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { VedaEngine } from "../../src/engines/veda/VedaEngine.sol";
import { OnChainWithdraw, VedaRedeemRequest } from "../../src/interfaces/external/veda/VedaTypes.sol";

interface IERC20T {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract MockAsset {
    uint8 public constant decimals = 6;
    uint16 public feeBps;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setFeeBps(uint16 feeBps_) external {
        feeBps = feeBps_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "ALLOWANCE");
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount - (amount * feeBps / 10_000);
    }
}

/// @dev Raw BoringVault shares + asset custody buffer, with `enter`/`exit` driven by the teller.
contract MockBoringVault {
    uint8 public immutable decimals;
    address public immutable assetToken;
    uint256 public totalSupply;
    address public owner;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address asset_, uint8 decimals_) {
        assetToken = asset_;
        decimals = decimals_;
        owner = msg.sender;
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "OWNER");
        owner = newOwner;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "ALLOWANCE");
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function enter(address from, uint256 assets, address to, uint256 shares) external {
        require(IERC20T(assetToken).transferFrom(from, address(this), assets), "ENTER");
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function exit(address to, uint256 assets, address from, uint256 shares) external {
        require(balanceOf[from] >= shares, "SHARES");
        balanceOf[from] -= shares;
        totalSupply -= shares;
        require(IERC20T(assetToken).transfer(to, assets), "EXIT");
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MockAccountant {
    MockBoringVault public immutable vault;
    address public immutable base;
    uint256 public rate = 1e6;
    uint256 public safeRate = 1e6;
    uint256 public supplyRateDivisor;
    uint64 internal _lastStrategistUpdateTimestamp;

    constructor(MockBoringVault vault_, address base_) {
        vault = vault_;
        base = base_;
        _lastStrategistUpdateTimestamp = uint64(block.timestamp);
    }

    function setRate(uint256 rate_) external virtual {
        rate = rate_;
        safeRate = rate_;
        _lastStrategistUpdateTimestamp = uint64(block.timestamp);
    }

    function setUnsafeRate(uint256 rate_) external {
        rate = rate_;
    }

    function setSupplyRateDivisor(uint256 divisor) external {
        supplyRateDivisor = divisor;
    }

    function setLastStrategistUpdateTimestamp(uint64 timestamp) external {
        _lastStrategistUpdateTimestamp = timestamp;
    }

    function lastStrategistUpdateTimestamp() external view virtual returns (uint64) {
        return _lastStrategistUpdateTimestamp;
    }

    function getRate() external view returns (uint256) {
        return rate + _supplyRateDelta();
    }

    function getRateInQuoteSafe(address) external view returns (uint256) {
        return safeRate + _supplyRateDelta();
    }

    function _supplyRateDelta() private view returns (uint256) {
        uint256 divisor = supplyRateDivisor;
        return divisor == 0 ? 0 : vault.totalSupply() / divisor;
    }
}

/// @dev Buffer-backed teller. Both withdrawal paths enforce `minimumAssets` (the exact-asset backstop)
///      and can be told to underpay to prove the backstop reverts.
contract MockTeller {
    MockBoringVault public immutable vault;
    MockAccountant public immutable accountant;
    address public immutable assetToken;
    uint256 public underpay;
    uint256 public publicDepositCalls;
    uint256 public bulkDepositCalls;
    uint256 public publicWithdrawCalls;
    uint256 public bulkWithdrawCalls;
    uint256 public shareBurnOverride;
    address public withdrawalReceiverOverride;
    uint64 public shareLockPeriod = 1 hours;
    mapping(address => uint256) public shareUnlockTime;

    constructor(MockBoringVault vault_, MockAccountant accountant_, address asset_) {
        vault = vault_;
        accountant = accountant_;
        assetToken = asset_;
    }

    function setUnderpay(uint256 underpay_) external {
        underpay = underpay_;
    }

    function setShareBurnOverride(uint256 shareBurnOverride_) external {
        shareBurnOverride = shareBurnOverride_;
    }

    function setWithdrawalReceiverOverride(address withdrawalReceiverOverride_) external {
        withdrawalReceiverOverride = withdrawalReceiverOverride_;
    }

    /// @dev Models the public Teller path that snapshots a holder lock. `VedaEngine` must not call it.
    function deposit(address, uint256 depositAmount, uint256 minimumMint, address to, address)
        external
        payable
        returns (uint256 shares)
    {
        publicDepositCalls++;
        shareUnlockTime[to] = block.timestamp + shareLockPeriod;
        shares = _deposit(depositAmount, minimumMint, to);
    }

    /// @dev Models Veda's permissioned pooled path, which deliberately does not set a holder lock.
    function bulkDeposit(address, uint256 depositAmount, uint256 minimumMint, address to)
        external
        returns (uint256 shares)
    {
        bulkDepositCalls++;
        shares = _deposit(depositAmount, minimumMint, to);
    }

    function _deposit(uint256 depositAmount, uint256 minimumMint, address to) private returns (uint256 shares) {
        shares = depositAmount * (10 ** uint256(vault.decimals())) / accountant.getRate();
        require(shares >= minimumMint, "MIN_MINT");
        vault.enter(msg.sender, depositAmount, to, shares);
    }

    function withdraw(address, uint256 shareAmount, uint256 minimumAssets, address to)
        external
        returns (uint256 assetsOut)
    {
        publicWithdrawCalls++;
        // The timestamp comparison is the behavior under test: public deposits lock this holder,
        // while bulk deposits deliberately leave its unlock time unset.
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp >= shareUnlockTime[msg.sender], "SHARES_LOCKED");
        assetsOut = _withdraw(shareAmount, minimumAssets, to);
    }

    /// @dev Models Veda's permissioned pooled exit, which deliberately bypasses the holder lock.
    function bulkWithdraw(address, uint256 shareAmount, uint256 minimumAssets, address to)
        external
        returns (uint256 assetsOut)
    {
        bulkWithdrawCalls++;
        assetsOut = _withdraw(shareAmount, minimumAssets, to);
    }

    function _withdraw(uint256 shareAmount, uint256 minimumAssets, address to) private returns (uint256 assetsOut) {
        assetsOut = shareAmount * accountant.getRate() / (10 ** uint256(vault.decimals()));
        if (underpay != 0) assetsOut = assetsOut > underpay ? assetsOut - underpay : 0;
        require(assetsOut >= minimumAssets, "MIN_ASSETS");
        uint256 sharesToBurn = shareBurnOverride == 0 ? shareAmount : shareBurnOverride;
        address actualReceiver = withdrawalReceiverOverride == address(0) ? to : withdrawalReceiverOverride;
        vault.exit(actualReceiver, assetsOut, msg.sender, sharesToBurn);
    }
}

/// @dev Models BoringOnChainQueueWithTracking: complete requests are stored by ID and remain readable
///      after cancellation or settlement, while active membership is tracked separately.
contract MockQueue {
    MockBoringVault public immutable boringVault;
    MockAccountant public immutable accountant;
    uint96 public nonce = 1;
    uint24 public secondsToMaturity = 100;
    bool public trackWithdrawsOnChain = true;
    uint256 public rateAfterRequest;
    uint256 public rateAfterCancel;
    uint16 public sharePullBps = 10_000;
    mapping(bytes32 => OnChainWithdraw) internal _built;
    mapping(bytes32 => bool) public isActive;

    constructor(MockBoringVault vault_, MockAccountant accountant_) {
        boringVault = vault_;
        accountant = accountant_;
    }

    function setRateAfterRequest(uint256 rate_) external {
        rateAfterRequest = rate_;
    }

    function setRateAfterCancel(uint256 rate_) external {
        rateAfterCancel = rate_;
    }

    function setTrackWithdrawsOnChain(bool enabled) external {
        trackWithdrawsOnChain = enabled;
    }

    function setSharePullBps(uint16 bps) external {
        sharePullBps = bps;
    }

    function requestOnChainWithdraw(address assetOut, uint128 shares, uint16, uint24 secondsToDeadline)
        external
        returns (bytes32 requestId)
    {
        uint256 sharesToPull = uint256(shares) * sharePullBps / 10_000;
        if (sharesToPull != 0) require(boringVault.transferFrom(msg.sender, address(this), sharesToPull), "PULL");
        OnChainWithdraw memory r = OnChainWithdraw({
            nonce: nonce,
            user: msg.sender,
            assetOut: assetOut,
            amountOfShares: shares,
            amountOfAssets: shares, // 1:1 payout accounting for the mock
            creationTime: uint40(block.timestamp),
            secondsToMaturity: secondsToMaturity,
            secondsToDeadline: secondsToDeadline
        });
        requestId = keccak256(abi.encode(r));
        if (trackWithdrawsOnChain) _built[requestId] = r;
        isActive[requestId] = true;
        nonce++;
        if (rateAfterRequest != 0) accountant.setRate(rateAfterRequest);
    }

    function cancelOnChainWithdrawUsingRequestId(bytes32 requestId) external returns (OnChainWithdraw memory request) {
        request = getOnChainWithdraw(requestId);
        require(isActive[requestId], "REQUEST");
        require(request.user == msg.sender, "USER");
        isActive[requestId] = false;
        require(boringVault.transfer(request.user, request.amountOfShares), "RETURN");
        if (rateAfterCancel != 0) accountant.setRate(rateAfterCancel);
    }

    /// @dev Models an authorized stock solver that bypasses VedaForwardingSolver: the Queue consumes
    ///      the request and shares, then pays request.user (the engine) directly.
    function solveExternally(bytes32 requestId, MockAsset asset_, address solver) external {
        OnChainWithdraw memory request = getOnChainWithdraw(requestId);
        require(isActive[requestId], "REQUEST");
        isActive[requestId] = false;
        require(boringVault.transfer(solver, request.amountOfShares), "SHARES");
        asset_.mint(request.user, request.amountOfAssets);
    }

    function getRequestId(OnChainWithdraw calldata request) external pure returns (bytes32) {
        return keccak256(abi.encode(request));
    }

    function getOnChainWithdraw(bytes32 requestId) public view returns (OnChainWithdraw memory request) {
        request = _built[requestId];
        require(request.nonce != 0, "REQUEST");
    }
}

/// @dev Stand-in for the EarnVault single client: forwards the onlyEarnVault engine calls and receives the
///      finalize callback (with a revert toggle to drive the degrade-to-skip path).
contract MockCore {
    VedaEngine public engine;
    MockAsset public immutable assetToken;
    bool public depositsPaused;
    bool public revertFinalize;
    mapping(bytes32 => uint256) public finalizedAmount;

    constructor(MockAsset asset_) {
        assetToken = asset_;
    }

    function setEngine(VedaEngine engine_) external {
        engine = engine_;
    }

    function setRevertFinalize(bool v) external {
        revertFinalize = v;
    }

    function setDepositsPaused(bool paused) external {
        depositsPaused = paused;
    }

    function deposit(uint256 assets) external returns (uint256) {
        assetToken.approve(address(engine), assets);
        return engine.deposit(assets);
    }

    function requestRedeem(uint128 shares, address assetOut, uint16 discountBps, uint24 secondsToDeadline)
        external
        returns (bytes32)
    {
        return engine.requestRedeem(
            shares,
            abi.encode(
                VedaRedeemRequest({
                    assetOut: assetOut,
                    discountBps: discountBps,
                    secondsToDeadline: secondsToDeadline,
                    minQueuedAssets: 1
                })
            )
        );
    }

    function requestRedeemWithMinimum(
        uint128 shares,
        address assetOut,
        uint16 discountBps,
        uint24 secondsToDeadline,
        uint128 minQueuedAssets
    ) external returns (bytes32) {
        return engine.requestRedeem(
            shares,
            abi.encode(
                VedaRedeemRequest({
                    assetOut: assetOut,
                    discountBps: discountBps,
                    secondsToDeadline: secondsToDeadline,
                    minQueuedAssets: minQueuedAssets
                })
            )
        );
    }

    function cancelRedeem(bytes32 requestId) external returns (uint256) {
        return engine.cancelRedeem(requestId);
    }

    function withdraw(uint256 assets, address receiver) external returns (uint256) {
        return engine.withdraw(assets, receiver);
    }

    function redeem(uint256 shares, address receiver, uint256 minAssets) external returns (uint256) {
        return engine.redeem(shares, receiver, minAssets);
    }

    function depositUpdateRateAndRedeem(uint256 assets, MockAccountant accountant, uint256 newRate, address receiver)
        external
        returns (uint256)
    {
        assetToken.approve(address(engine), assets);
        uint256 shares = engine.deposit(assets);
        accountant.setRate(newRate);
        return engine.redeem(shares, receiver, 1);
    }

    function depositUpdateRateAndRequest(
        uint256 assets,
        MockAccountant accountant,
        uint256 newRate,
        address assetOut,
        uint16 discountBps,
        uint24 secondsToDeadline
    ) external returns (bytes32) {
        assetToken.approve(address(engine), assets);
        uint256 shares = engine.deposit(assets);
        accountant.setRate(newRate);
        return engine.requestRedeem(
            shares,
            abi.encode(
                VedaRedeemRequest({
                    assetOut: assetOut,
                    discountBps: discountBps,
                    secondsToDeadline: secondsToDeadline,
                    minQueuedAssets: 1
                })
            )
        );
    }

    function depositAndRedeem(uint256 assets, address receiver) external returns (uint256) {
        assetToken.approve(address(engine), assets);
        uint256 shares = engine.deposit(assets);
        return engine.redeem(shares, receiver, 1);
    }

    function finalizeRedeem(bytes32 requestId, address, uint256 amount) external {
        require(!revertFinalize, "CORE_REVERT");
        finalizedAmount[requestId] = amount;
    }
}
