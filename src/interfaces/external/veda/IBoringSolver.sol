// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { OnChainWithdraw } from "./VedaTypes.sol";

interface IBoringSolver {
    function boringRedeemSolve(OnChainWithdraw[] calldata requests, address teller, bool coverDeficit) external;
}
