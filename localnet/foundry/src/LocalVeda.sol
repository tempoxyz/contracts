// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20Like } from "../../../src/interfaces/external/IERC20Like.sol";
import { IBoringSolver } from "../../../src/interfaces/external/veda/IBoringSolver.sol";
import { OnChainWithdraw } from "../../../src/interfaces/external/veda/VedaTypes.sol";

/// @notice Disposable Veda-compatible contracts for transaction-level local integration tests.
/// @dev These fixtures reproduce the external surfaces and money movement consumed by `VedaEngine`;
///      production Veda deployments remain external and independently owned.
contract LocalVedaVault {
    string public constant name = "Local Veda Vault";
    string public constant symbol = "teVEDA";
    uint8 public constant decimals = 6;

    address public immutable assetToken;
    address public owner;
    address public immutable authority;
    uint256 public totalSupply;

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner_ => mapping(address spender => uint256 amount)) public allowance;

    constructor(address assetToken_, address owner_) {
        assetToken = assetToken_;
        owner = owner_;
        // The disposable fixture doubles as its own RolesAuthority so hosted Veda validation can
        // exercise the complete binding surface without vendoring Veda's licensed role contracts.
        authority = address(this);
    }

    /// @notice RolesAuthority surface: the fixture gates no caller, so it reports every call as allowed.
    function canCall(address, address, bytes4) external pure returns (bool) {
        return true;
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
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            require(approved >= amount, "VEDA_ALLOWANCE");
            allowance[from][msg.sender] = approved - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function enter(address from, uint256 assets, address to, uint256 shares) external {
        require(IERC20Like(assetToken).transferFrom(from, address(this), assets), "VEDA_ENTER");
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function exit(address to, uint256 assets, address from, uint256 shares) external {
        require(balanceOf[from] >= shares, "VEDA_SHARES");
        balanceOf[from] -= shares;
        totalSupply -= shares;
        require(IERC20Like(assetToken).transfer(to, assets), "VEDA_EXIT");
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "VEDA_BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract LocalVedaAccountant {
    address public immutable vault;
    address public immutable base;
    address public immutable owner;

    uint256 public rate = 1e6;
    uint256 public safeRate = 1e6;
    uint64 public lastStrategistUpdateTimestamp;

    constructor(address vault_, address base_, address owner_) {
        vault = vault_;
        base = base_;
        owner = owner_;
        lastStrategistUpdateTimestamp = uint64(block.timestamp);
    }

    function setRate(uint256 newRate) external {
        require(msg.sender == owner, "VEDA_OWNER");
        rate = newRate;
        safeRate = newRate;
        lastStrategistUpdateTimestamp = uint64(block.timestamp);
    }

    function setUnsafeRate(uint256 newRate) external {
        require(msg.sender == owner, "VEDA_OWNER");
        rate = newRate;
    }

    function setLastStrategistUpdateTimestamp(uint64 timestamp) external {
        require(msg.sender == owner, "VEDA_OWNER");
        lastStrategistUpdateTimestamp = timestamp;
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

    function getRateInQuoteSafe(address) external view returns (uint256) {
        return safeRate;
    }
}

contract LocalVedaTeller {
    event BulkDeposit(address indexed asset, uint256 depositAmount);
    event BulkWithdraw(address indexed asset, uint256 shareAmount);

    LocalVedaVault public immutable vault;
    LocalVedaAccountant public immutable accountant;
    address public immutable assetToken;
    address public immutable owner;

    uint64 public shareLockPeriod;
    uint256 public publicDepositCalls;
    uint256 public bulkDepositCalls;
    uint256 public publicWithdrawCalls;
    uint256 public bulkWithdrawCalls;
    uint256 public lastMinimumAssets;
    mapping(address account => uint256 timestamp) public shareUnlockTime;

    constructor(LocalVedaVault vault_, LocalVedaAccountant accountant_, address assetToken_, address owner_) {
        vault = vault_;
        accountant = accountant_;
        assetToken = assetToken_;
        owner = owner_;
    }

    function setShareLockPeriod(uint64 period) external {
        require(msg.sender == owner, "VEDA_OWNER");
        shareLockPeriod = period;
    }

    function beforeTransferData(address account)
        external
        view
        returns (bool denyFrom, bool denyTo, bool denyOperator, bool permissionedOperator, uint256 unlockTime)
    {
        return (false, false, false, false, shareUnlockTime[account]);
    }

    /// @dev Mirrors the public mapping getter on TellerWithMultiAssetSupport.
    function assetData(address asset)
        external
        view
        returns (bool allowDeposits, bool allowWithdraws, uint16 sharePremium)
    {
        bool supported = asset == assetToken;
        return (supported, supported, 0);
    }

    function deposit(address, uint256 depositAmount, uint256 minimumMint, address to, address)
        external
        payable
        returns (uint256 shares)
    {
        publicDepositCalls++;
        shareUnlockTime[to] = block.timestamp + shareLockPeriod;
        shares = _deposit(depositAmount, minimumMint, to);
    }

    function bulkDeposit(address, uint256 depositAmount, uint256 minimumMint, address to)
        external
        returns (uint256 shares)
    {
        bulkDepositCalls++;
        shares = _deposit(depositAmount, minimumMint, to);
        emit BulkDeposit(assetToken, depositAmount);
    }

    function withdraw(address, uint256 shareAmount, uint256 minimumAssets, address to)
        external
        returns (uint256 assetsOut)
    {
        publicWithdrawCalls++;
        require(block.timestamp >= shareUnlockTime[msg.sender], "VEDA_SHARES_LOCKED");
        assetsOut = _withdraw(shareAmount, minimumAssets, to);
    }

    function bulkWithdraw(address, uint256 shareAmount, uint256 minimumAssets, address to)
        external
        returns (uint256 assetsOut)
    {
        bulkWithdrawCalls++;
        assetsOut = _withdraw(shareAmount, minimumAssets, to);
        emit BulkWithdraw(assetToken, shareAmount);
    }

    function _withdraw(uint256 shareAmount, uint256 minimumAssets, address to) private returns (uint256 assetsOut) {
        lastMinimumAssets = minimumAssets;
        assetsOut = shareAmount * accountant.getRateInQuoteSafe(assetToken) / (10 ** uint256(vault.decimals()));
        require(assetsOut >= minimumAssets, "VEDA_MINIMUM_ASSETS");
        vault.exit(to, assetsOut, msg.sender, shareAmount);
    }

    function _deposit(uint256 depositAmount, uint256 minimumMint, address to) private returns (uint256 shares) {
        // TellerWithYieldStreaming uses the safe rate plus one as a conservative denominator.
        shares = depositAmount * (10 ** uint256(vault.decimals())) / (accountant.getRateInQuoteSafe(assetToken) + 1);
        require(shares >= minimumMint, "VEDA_MINIMUM_MINT");
        vault.enter(msg.sender, depositAmount, to, shares);
    }
}

contract LocalVedaQueue {
    LocalVedaVault public immutable boringVault;
    LocalVedaAccountant public immutable accountant;

    uint96 public nonce = 1;
    uint24 public secondsToMaturity;
    bool public trackWithdrawsOnChain = true;

    mapping(bytes32 requestId => OnChainWithdraw request) private _requests;
    mapping(bytes32 requestId => bool active) public isActive;
    mapping(bytes32 requestId => address solver) private _dequeuedBy;

    event OnChainWithdrawRequested(bytes32 indexed requestId, OnChainWithdraw request);

    constructor(LocalVedaVault boringVault_, LocalVedaAccountant accountant_) {
        boringVault = boringVault_;
        accountant = accountant_;
    }

    /// @notice The Queue shares the vault's RolesAuthority, as a Veda deployment does.
    function authority() external view returns (address) {
        return boringVault.authority();
    }

    function requestOnChainWithdraw(address assetOut, uint128 shares, uint16 discount, uint24 secondsToDeadline)
        external
        returns (bytes32 requestId)
    {
        require(boringVault.transferFrom(msg.sender, address(this), shares), "VEDA_QUEUE_PULL");
        uint128 assets = previewAssetsOut(assetOut, shares, discount);
        OnChainWithdraw memory request = OnChainWithdraw({
            nonce: nonce++,
            user: msg.sender,
            assetOut: assetOut,
            amountOfShares: shares,
            amountOfAssets: assets,
            creationTime: uint40(block.timestamp),
            secondsToMaturity: secondsToMaturity,
            secondsToDeadline: secondsToDeadline
        });
        requestId = keccak256(abi.encode(request));
        if (trackWithdrawsOnChain) _requests[requestId] = request;
        isActive[requestId] = true;
        emit OnChainWithdrawRequested(requestId, request);
    }

    function previewAssetsOut(address assetOut, uint128 shares, uint16 discount)
        public
        view
        returns (uint128 assets)
    {
        require(discount <= 10_000, "VEDA_QUEUE_DISCOUNT");
        uint256 discountedRate = accountant.getRateInQuoteSafe(assetOut) * (10_000 - discount) / 10_000;
        uint256 assets256 = uint256(shares) * discountedRate / (10 ** uint256(boringVault.decimals()));
        require(assets256 <= type(uint128).max, "VEDA_QUEUE_ASSETS");
        assets = uint128(assets256);
    }

    function cancelOnChainWithdrawUsingRequestId(bytes32 requestId) external returns (OnChainWithdraw memory request) {
        request = getOnChainWithdraw(requestId);
        require(isActive[requestId], "VEDA_QUEUE_INACTIVE");
        require(request.user == msg.sender, "VEDA_QUEUE_USER");
        isActive[requestId] = false;
        require(boringVault.transfer(request.user, request.amountOfShares), "VEDA_QUEUE_RETURN");
    }

    function getRequestId(OnChainWithdraw calldata request) external pure returns (bytes32) {
        return keccak256(abi.encode(request));
    }

    function getOnChainWithdraw(bytes32 requestId) public view returns (OnChainWithdraw memory request) {
        request = _requests[requestId];
        require(request.nonce != 0, "VEDA_QUEUE_REQUEST");
    }

    function dequeue(OnChainWithdraw calldata request) external {
        bytes32 requestId = keccak256(abi.encode(request));
        require(isActive[requestId], "VEDA_QUEUE_INACTIVE");
        isActive[requestId] = false;
        _dequeuedBy[requestId] = msg.sender;
        require(boringVault.transfer(msg.sender, request.amountOfShares), "VEDA_QUEUE_SOLVER_SHARES");
    }

    function pay(OnChainWithdraw calldata request) external {
        bytes32 requestId = keccak256(abi.encode(request));
        require(_dequeuedBy[requestId] == msg.sender, "VEDA_QUEUE_SOLVER");
        delete _dequeuedBy[requestId];
        require(
            IERC20Like(request.assetOut).transferFrom(msg.sender, request.user, request.amountOfAssets),
            "VEDA_QUEUE_PAY"
        );
    }
}

contract LocalVedaSolver is IBoringSolver {
    LocalVedaQueue public immutable queue;

    constructor(LocalVedaQueue queue_) {
        queue = queue_;
    }

    function boringRedeemSolve(OnChainWithdraw[] calldata requests, address teller, bool coverDeficit) external {
        require(requests.length != 0, "VEDA_SOLVER_EMPTY");
        address asset = requests[0].assetOut;
        uint256 totalShares;
        uint256 requiredAssets;
        for (uint256 i = 0; i < requests.length; i++) {
            require(requests[i].assetOut == asset, "VEDA_SOLVER_ASSET");
            totalShares += requests[i].amountOfShares;
            requiredAssets += requests[i].amountOfAssets;
            queue.dequeue(requests[i]);
        }

        uint256 assetsOut = LocalVedaTeller(teller).bulkWithdraw(asset, totalShares, 0, address(this));
        if (assetsOut < requiredAssets) {
            require(coverDeficit, "VEDA_CANNOT_COVER_DEFICIT");
            require(
                IERC20Like(asset).transferFrom(msg.sender, address(this), requiredAssets - assetsOut),
                "VEDA_DEFICIT_PULL"
            );
        } else if (assetsOut > requiredAssets) {
            require(IERC20Like(asset).transfer(address(queue.boringVault()), assetsOut - requiredAssets), "VEDA_SURPLUS");
        }

        require(IERC20Like(asset).approve(address(queue), requiredAssets), "VEDA_QUEUE_APPROVE");
        for (uint256 i = 0; i < requests.length; i++) {
            queue.pay(requests[i]);
        }
        require(IERC20Like(asset).approve(address(queue), 0), "VEDA_QUEUE_CLEAR");
    }
}
