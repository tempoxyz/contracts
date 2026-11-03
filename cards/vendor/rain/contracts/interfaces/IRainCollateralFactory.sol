//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.17;

interface IRainCollateralFactory {
    function controller() external view returns (address);
}
