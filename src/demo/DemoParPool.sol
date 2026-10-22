// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Public stand-in for the DirectPropAMM surface that `SingleZoneEarnRouter` uses.
/// @dev Test scaffolding only, for consumers without access to the private PropAMM artifact.
///      It is its own always-fresh par oracle and converts 1:1 from owner-provided inventory.
///      Production routers bind a reviewed DirectPropAMM pool; Earn's own local E2E uses one.
contract DemoParPool {
    using SafeERC20 for IERC20;

    uint8 private constant DECIMALS = 8;
    uint256 private constant PAR = 10 ** DECIMALS;

    address public immutable baseToken;
    address public immutable quoteToken;
    address public immutable owner;
    bool public paused;
    mapping(address taker => bool) public takerAllowed;
    mapping(address recipient => bool) public recipientAllowed;

    error DeadlineExpired();
    error InvalidAmount();
    error InvalidToken();
    error NotOwner();
    error OffPar();
    error Paused();
    error RecipientNotAllowed();
    error SlippageExceeded();
    error TakerNotAllowed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address baseToken_, address quoteToken_, address owner_) {
        if (baseToken_ == address(0) || quoteToken_ == address(0) || baseToken_ == quoteToken_) {
            revert InvalidToken();
        }
        if (owner_ == address(0)) revert NotOwner();
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        owner = owner_;
    }

    function setTakerAllowed(address taker, bool allowed) external onlyOwner {
        takerAllowed[taker] = allowed;
    }

    function setRecipientAllowed(address recipient, bool allowed) external onlyOwner {
        recipientAllowed[recipient] = allowed;
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
    }

    /// @notice The pool is its own par oracle.
    function oracle() external view returns (address) {
        return address(this);
    }

    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
        return (PAR, block.timestamp);
    }

    /// @notice Mirrors DirectPropAMM's oracle age bound so freshness preflights accept this pool.
    function maxOracleAge() external pure returns (uint256) {
        return 1 days;
    }

    function resolveRecipient(address recipient) external pure returns (address) {
        return recipient;
    }

    /// @notice Converts `amountIn` 1:1 from pool inventory; the trailing route and quote binding
    ///         arguments mirror DirectPropAMM, and only an exact par expectation is accepted.
    function swapExactInput(
        bool baseToQuote,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes32,
        bytes32,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256,
        uint256
    ) external returns (uint256 amountOut) {
        if (paused) revert Paused();
        if (!takerAllowed[msg.sender]) revert TakerNotAllowed();
        if (!recipientAllowed[recipient]) revert RecipientNotAllowed();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (expectedOraclePrice != PAR) revert OffPar();
        if (amountIn == 0) revert InvalidAmount();
        amountOut = amountIn;
        if (amountOut < minAmountOut) revert SlippageExceeded();
        (address tokenIn, address tokenOut) = baseToQuote ? (baseToken, quoteToken) : (quoteToken, baseToken);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
    }
}
