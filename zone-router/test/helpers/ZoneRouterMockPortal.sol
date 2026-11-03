// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test-only mock: simple ERC-20 calls.
// forge-lint: disable-start(erc20-unchecked-transfer)

import { MemoMockToken } from "earn-test/helpers/PropAMMEngineMocks.sol";
import { EncryptedDepositPayload } from "tempo-earn/interfaces/external/tempo/IZone.sol";

/// @dev Earn's RouterMockZonePortal with the ZonePortal's deposit fee rules: a deposit below the deposit fee
///      plus the bounce-back reserve reverts `DepositTooSmall`, and the deposit fee goes to the admin. Its
///      storage layout matches Earn's mock, so tests etch it over `portalA` and `portalB` and keep their state.
contract ZoneRouterMockPortal {
    /// @dev Where the deposit fee goes, as the ZonePortal pays its admin.
    address internal constant ADMIN = address(uint160(uint256(keccak256("zone-router mock portal admin"))));

    mapping(address => bool) public enabled;
    mapping(address => bool) public depositsActive;
    address public lastToken;
    uint128 public lastAmount;
    address public lastRefundRecipient;
    uint256 public depositCount;
    uint128 public depositFee;
    uint128 public bouncebackFee;

    error DepositTooSmall();

    function admin() external pure returns (address) {
        return ADMIN;
    }

    function setDepositFee(uint128 fee) external {
        depositFee = fee;
    }

    function setBouncebackFee(uint128 fee) external {
        bouncebackFee = fee;
    }

    function calculateDepositFee() external view returns (uint128) {
        return depositFee;
    }

    function calculateBouncebackFee() external view returns (uint128) {
        return bouncebackFee;
    }

    function setToken(address token, bool enabled_, bool active_) external {
        enabled[token] = enabled_;
        depositsActive[token] = active_;
    }

    function isTokenEnabled(address token) external view returns (bool) {
        return enabled[token];
    }

    function areDepositsActive(address token) external view returns (bool) {
        return depositsActive[token];
    }

    /// @dev Records the net amount the Zone credits, as the ZonePortal queues it.
    function depositEncrypted(
        address token,
        uint128 amount,
        uint256,
        EncryptedDepositPayload calldata,
        address refundRecipient
    ) external returns (bytes32 hash) {
        require(enabled[token] && depositsActive[token], "TOKEN_DISABLED");
        uint128 fee = depositFee;
        if (amount < fee + bouncebackFee) revert DepositTooSmall();
        MemoMockToken(token).transferFrom(msg.sender, address(this), amount);
        if (fee > 0) MemoMockToken(token).transfer(ADMIN, fee);
        lastToken = token;
        lastAmount = amount - fee;
        lastRefundRecipient = refundRecipient;
        depositCount += 1;
        hash = keccak256(abi.encode(address(this), token, amount, depositCount));
    }

    function release(address token, address to, uint256 amount) external {
        MemoMockToken(token).transfer(to, amount);
    }
}
