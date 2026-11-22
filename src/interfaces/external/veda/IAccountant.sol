// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

interface IAccountant {
    function vault() external view returns (address);
    function base() external view returns (address);
    function getRate() external view returns (uint256 rate);
    function getRateInQuoteSafe(address quote) external view returns (uint256 rate);
}

/// @dev Freshness surface exposed by Veda's yield-streaming Accountant.
interface IYieldStreamingAccountant {
    function lastStrategistUpdateTimestamp() external view returns (uint64 timestamp);
}

/// @dev Freshness surface exposed by Veda's step-accounting AccountantWithRateProviders. Solidity's
///      generated getter returns the complete packed state tuple; Earn consumes only
///      `lastUpdateTimestamp` while retaining the exact ABI as a compatibility gate.
interface IStepAccountant {
    function accountantState()
        external
        view
        returns (
            address payoutAddress,
            uint96 highwaterMark,
            uint128 feesOwedInBase,
            uint128 totalSharesLastUpdate,
            uint96 exchangeRate,
            uint16 allowedExchangeRateChangeUpper,
            uint16 allowedExchangeRateChangeLower,
            uint64 lastUpdateTimestamp,
            bool isPaused,
            uint24 minimumUpdateDelayInSeconds,
            uint16 platformFee,
            uint16 performanceFee
        );
}
