// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Disposable PropAMM pool base token, the venue asset the engine holds.
contract LocalPropAMMToken is ERC20 {
    address public immutable owner;

    constructor(address owner_) ERC20("Local Base Token", "BASE") {
        owner = owner_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address receiver, uint256 amount) external {
        require(msg.sender == owner);
        _mint(receiver, amount);
    }

    function transferWithMemo(address to, uint256 amount, bytes32) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFromWithMemo(address from, address to, uint256 amount, bytes32) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }
}

/// @notice Fixed-price, always-fresh local oracle; stale-price behavior is covered by Foundry tests.
contract LocalPropAMMOracle {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (105_000_000, block.timestamp);
    }
}
