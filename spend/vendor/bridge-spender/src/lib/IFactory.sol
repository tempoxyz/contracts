// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ISpenderHandler } from "../ISpenderHandler.sol";

interface IFactory {

    function getSpenderHandlerWithCheckedPermissions(bytes2 key, address user)
        external
        view
        returns (ISpenderHandler spender);

    function paused() external view returns (bool);

}
