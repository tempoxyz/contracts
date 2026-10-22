// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IAccountant } from "./IAccountant.sol";
import { IBoringQueue } from "./IBoringQueue.sol";
import { IBoringVault } from "./IBoringVault.sol";
import { ITeller } from "./ITeller.sol";

interface IVedaPeripheryRegistry {
    function bindEngine(address engine_) external;

    function vault() external view returns (IBoringVault);
    function baseAsset() external view returns (address);
    function engine() external view returns (address);
    function teller() external view returns (ITeller);
    /// @notice Active Queue candidate, or zero when the vault is configured for immediate-only exits.
    function queue() external view returns (IBoringQueue);
    function accountant() external view returns (IAccountant);
    function version() external view returns (uint64);
}
