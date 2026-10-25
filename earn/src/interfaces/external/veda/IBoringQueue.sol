// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { OnChainWithdraw } from "./VedaTypes.sol";

interface IBoringQueue {
    function boringVault() external view returns (address);
    function accountant() external view returns (address);
    function trackWithdrawsOnChain() external view returns (bool);
    function requestOnChainWithdraw(address assetOut, uint128 amountOfShares, uint16 discount, uint24 secondsToDeadline)
        external
        returns (bytes32 requestId);
    function previewAssetsOut(address assetOut, uint128 amountOfShares, uint16 discount)
        external
        view
        returns (uint128 amountOfAssets);
    function cancelOnChainWithdrawUsingRequestId(bytes32 requestId) external returns (OnChainWithdraw memory request);
    function getOnChainWithdraw(bytes32 requestId) external view returns (OnChainWithdraw memory request);
    function getRequestId(OnChainWithdraw calldata request) external pure returns (bytes32 requestId);
}
