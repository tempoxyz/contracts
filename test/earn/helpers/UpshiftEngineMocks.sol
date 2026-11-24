// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IUpshiftVault } from "../../../src/interfaces/external/upshift/IUpshiftVault.sol";
import { CoreMockToken } from "./EarnVaultMocks.sol";

/// @dev Receipt token of {MockUpshiftVault}; only the vault mints and burns it.
contract MockUpshiftShareToken is CoreMockToken {
    address public vault;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        CoreMockToken(name_, symbol_, decimals_)
    { }

    function setVault(address vault_) external {
        require(vault == address(0), "VAULT_SET");
        vault = vault_;
    }

    function vaultMint(address to, uint256 value) external {
        require(msg.sender == vault, "NOT_VAULT");
        totalSupply += value;
        balanceOf[to] += value;
    }

    function vaultBurn(address from, uint256 value) external {
        require(msg.sender == vault, "NOT_VAULT");
        require(balanceOf[from] >= value, "BALANCE");
        balanceOf[from] -= value;
        totalSupply -= value;
    }
}

/// @dev Follows the queue rules of an Upshift tokenized vault: lagged redemptions are summed per claim date
///      and receiver, stay in the receipt-token supply until claimed, are priced when claimed, and cannot
///      be cancelled. NAV is the base asset the vault holds plus a reported external amount, less fees owed.
contract MockUpshiftVault is IUpshiftVault {
    error AmountTooLow();
    error DepositsPaused();
    error InvalidAmount();
    error InvalidReceiver();
    error NoSharesForReceiver();
    error NothingToProcess();
    error SenderNotWhitelisted();
    error TooEarly();
    error WithdrawalsPaused();

    uint256 private constant TIMESTAMP_MANIPULATION_WINDOW = 5 minutes;

    address public immutable asset;
    address public immutable lpTokenAddress;
    address public operator;
    uint256 public assetsUpdatedOn;
    uint256 public externalAssets;
    uint256 public totalCollectableFees;
    uint256 public lagDuration = 1 days;
    uint256 public withdrawalFee;
    uint256 public instantRedemptionFee;
    uint256 public globalLiabilityShares;
    bool public depositsPaused;
    bool public withdrawalsPaused;
    bool public whitelistEnabled;
    /// @dev Test faults: mint or queue this many shares fewer than the real vault would.
    uint256 public depositShortfall;
    uint256 public queueShortfall;

    mapping(address => bool) public isWhitelisted;
    mapping(bytes32 => uint256) private _dailyRequirement;
    mapping(bytes32 => mapping(address => uint256)) private _burnableAmounts;
    mapping(bytes32 => address[]) private _receivers;

    modifier ifSenderWhitelisted() {
        if (msg.sender != operator && whitelistEnabled && !isWhitelisted[msg.sender]) revert SenderNotWhitelisted();
        _;
    }

    constructor(address asset_, address lpToken_) {
        asset = asset_;
        lpTokenAddress = lpToken_;
        operator = msg.sender;
        assetsUpdatedOn = block.timestamp;
    }

    // --- operator controls ---

    function updateTotalAssets(uint256 externalAssets_) external {
        externalAssets = externalAssets_;
        assetsUpdatedOn = block.timestamp;
    }

    /// @dev Moves idle base asset out of the vault and reports it as external, leaving NAV unchanged.
    function deployCapital(uint256 amount) external {
        require(CoreMockToken(asset).transfer(operator, amount), "TRANSFER");
        externalAssets += amount;
    }

    function setFees(uint256 withdrawalFeeBps, uint256 instantFeeBps) external {
        withdrawalFee = withdrawalFeeBps;
        instantRedemptionFee = instantFeeBps;
    }

    function setLagDuration(uint256 lagDuration_) external {
        lagDuration = lagDuration_;
    }

    function setPaused(bool deposits, bool withdrawals) external {
        depositsPaused = deposits;
        withdrawalsPaused = withdrawals;
    }

    function setWhitelist(bool enabled, address account, bool whitelisted) external {
        whitelistEnabled = enabled;
        isWhitelisted[account] = whitelisted;
    }

    function setShortfalls(uint256 depositShortfall_, uint256 queueShortfall_) external {
        depositShortfall = depositShortfall_;
        queueShortfall = queueShortfall_;
    }

    // --- vault ---

    function deposit(address assetIn, uint256 amountIn, address receiverAddr)
        external
        ifSenderWhitelisted
        returns (uint256 shares)
    {
        if (depositsPaused) revert DepositsPaused();
        require(assetIn == asset, "ASSET");
        if (amountIn < 1) revert InvalidAmount();
        if (receiverAddr == address(0) || receiverAddr == address(this)) revert InvalidReceiver();
        if (whitelistEnabled && !isWhitelisted[receiverAddr]) revert SenderNotWhitelisted();
        uint256 supply = CoreMockToken(lpTokenAddress).totalSupply();
        shares = supply < 1 ? amountIn : amountIn * supply / getTotalAssets();
        shares -= depositShortfall;
        require(CoreMockToken(asset).transferFrom(msg.sender, address(this), amountIn), "TRANSFER_FROM");
        MockUpshiftShareToken(lpTokenAddress).vaultMint(receiverAddr, shares);
    }

    function instantRedeem(uint256 shares, address receiverAddr) external ifSenderWhitelisted {
        if (withdrawalsPaused) revert WithdrawalsPaused();
        if (receiverAddr == address(0) || receiverAddr == address(this)) revert InvalidReceiver();
        if (shares < 1) revert InvalidAmount();
        (uint256 assetsAmount, uint256 assetsAfterFee) = previewRedemption(shares, true);
        if (assetsAfterFee < 1) revert AmountTooLow();
        totalCollectableFees += assetsAmount - assetsAfterFee;
        MockUpshiftShareToken(lpTokenAddress).vaultBurn(msg.sender, shares);
        require(CoreMockToken(asset).transfer(receiverAddr, assetsAfterFee), "TRANSFER");
    }

    function requestRedeem(uint256 shares, address receiverAddr)
        external
        ifSenderWhitelisted
        returns (uint256 claimableEpoch, uint256 year, uint256 month, uint256 day)
    {
        if (withdrawalsPaused) revert WithdrawalsPaused();
        if (receiverAddr == address(0) || receiverAddr == address(this)) revert InvalidReceiver();
        if (shares < 1) revert InvalidAmount();
        (, uint256 assetsAfterFee) = previewRedemption(shares, false);
        if (assetsAfterFee < 1) revert AmountTooLow();

        uint256 claimDay = (block.timestamp + TIMESTAMP_MANIPULATION_WINDOW + lagDuration) / 1 days;
        (year, month, day) = _daysToDate(claimDay);
        claimableEpoch = claimDay * 1 days;
        bytes32 cluster = keccak256(abi.encode(year, month, day));

        uint256 queued = shares - queueShortfall;
        globalLiabilityShares += queued;
        _dailyRequirement[cluster] += queued;
        if (_burnableAmounts[cluster][receiverAddr] == 0) _receivers[cluster].push(receiverAddr);
        _burnableAmounts[cluster][receiverAddr] += queued;

        require(CoreMockToken(lpTokenAddress).transferFrom(msg.sender, address(this), queued), "TRANSFER_FROM");
    }

    function claim(uint256 year, uint256 month, uint256 day, address receiverAddr)
        external
        ifSenderWhitelisted
        returns (uint256 shares, uint256 assetsAfterFee)
    {
        if (withdrawalsPaused) revert WithdrawalsPaused();
        bytes32 cluster = keccak256(abi.encode(year, month, day));
        shares = _burnableAmounts[cluster][receiverAddr];
        if (shares < 1) revert NoSharesForReceiver();
        _requireClaimable(year, month, day);
        assetsAfterFee = _pay(cluster, receiverAddr, shares);
        address[] storage receivers = _receivers[cluster];
        for (uint256 i = 0; i < receivers.length; i++) {
            if (receivers[i] != receiverAddr) continue;
            receivers[i] = receivers[receivers.length - 1];
            receivers.pop();
            break;
        }
    }

    /// @dev Pays every receiver queued for the date, as the vault's operator does.
    function processAllClaimsByDate(uint256 year, uint256 month, uint256 day, uint256 maxLimit) external {
        if (withdrawalsPaused) revert WithdrawalsPaused();
        bytes32 cluster = keccak256(abi.encode(year, month, day));
        if (_dailyRequirement[cluster] < 1) revert NothingToProcess();
        _requireClaimable(year, month, day);
        address[] storage receivers = _receivers[cluster];
        for (uint256 n = 0; n < maxLimit && receivers.length != 0; n++) {
            address receiverAddr = receivers[receivers.length - 1];
            receivers.pop();
            _pay(cluster, receiverAddr, _burnableAmounts[cluster][receiverAddr]);
        }
    }

    function _pay(bytes32 cluster, address receiverAddr, uint256 shares) private returns (uint256 assetsAfterFee) {
        uint256 assetsAmount;
        (assetsAmount, assetsAfterFee) = previewRedemption(shares, false);
        _burnableAmounts[cluster][receiverAddr] = 0;
        _dailyRequirement[cluster] -= shares;
        globalLiabilityShares -= shares;
        totalCollectableFees += assetsAmount - assetsAfterFee;
        MockUpshiftShareToken(lpTokenAddress).vaultBurn(address(this), shares);
        require(CoreMockToken(asset).transfer(receiverAddr, assetsAfterFee), "TRANSFER");
    }

    function _requireClaimable(uint256 year, uint256 month, uint256 day) private view {
        if (
            lagDuration > 0 && msg.sender != operator
                && block.timestamp + TIMESTAMP_MANIPULATION_WINDOW < _daysFromDate(year, month, day) * 1 days
        ) revert TooEarly();
    }

    // --- views ---

    function getTotalAssets() public view returns (uint256) {
        uint256 valuation = CoreMockToken(asset).balanceOf(address(this)) + externalAssets;
        return totalCollectableFees < valuation ? valuation - totalCollectableFees : 0;
    }

    function previewRedemption(uint256 shares, bool isInstant)
        public
        view
        returns (uint256 assetsAmount, uint256 assetsAfterFee)
    {
        uint256 supply = CoreMockToken(lpTokenAddress).totalSupply();
        assetsAmount = supply < 1 ? shares : shares * getTotalAssets() / supply;
        uint256 fee = isInstant ? instantRedemptionFee : withdrawalFee;
        assetsAfterFee = assetsAmount - fee * assetsAmount / 1e4;
    }

    function getBurnableAmountByReceiver(uint256 year, uint256 month, uint256 day, address receiverAddr)
        external
        view
        returns (uint256)
    {
        return _burnableAmounts[keccak256(abi.encode(year, month, day))][receiverAddr];
    }

    function getRequirementByDate(uint256 year, uint256 month, uint256 day) external view returns (uint256) {
        return _dailyRequirement[keccak256(abi.encode(year, month, day))];
    }

    // --- civil dates (days since 1970-01-01), as in BokkyPooBah's DateTime library ---

    function _daysToDate(uint256 daysSinceEpoch) private pure returns (uint256 year, uint256 month, uint256 day) {
        unchecked {
            int256 l = int256(daysSinceEpoch) + 68_569 + 2_440_588;
            int256 n = (4 * l) / 146_097;
            l = l - (146_097 * n + 3) / 4;
            int256 y = (4000 * (l + 1)) / 1_461_001;
            l = l - (1461 * y) / 4 + 31;
            int256 m = (80 * l) / 2447;
            int256 d = l - (2447 * m) / 80;
            l = m / 11;
            m = m + 2 - 12 * l;
            y = 100 * (n - 49) + y + l;
            (year, month, day) = (uint256(y), uint256(m), uint256(d));
        }
    }

    function _daysFromDate(uint256 year, uint256 month, uint256 day) private pure returns (uint256 daysSinceEpoch) {
        unchecked {
            int256 y = int256(year);
            int256 m = int256(month);
            int256 d = int256(day);
            int256 result = d - 32_075 + (1461 * (y + 4800 + (m - 14) / 12)) / 4
                + (367 * (m - 2 - ((m - 14) / 12) * 12)) / 12 - (3 * ((y + 4900 + (m - 14) / 12) / 100)) / 4 - 2_440_588;
            daysSinceEpoch = uint256(result);
        }
    }
}
