// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { PropAMMEngine } from "../../../src/engines/propamm/PropAMMEngine.sol";
import { FixtureScript, IDirectPropAMMAdmin } from "./FixtureScript.sol";
import { LocalPropAMMOracle, LocalPropAMMToken } from "../src/LocalPropAMM.sol";

/// @notice The PropAMM engine's local venue: the unmodified pool (`DeployLocalEarn.routerPool`) over a
///         disposable base token, always-fresh oracle, and recipient registry, with the engine
///         configured as its taker.
contract DeployLocalPropAMMScript is FixtureScript {
    function token() external broadcast {
        new LocalPropAMMToken(_owner());
    }

    function oracle() external broadcast {
        new LocalPropAMMOracle();
    }

    function engine(address pool_) external broadcast {
        new PropAMMEngine(pool_, _owner(), 1 days, bytes32(uint256(1)));
    }

    function configure(LocalPropAMMToken baseToken, IDirectPropAMMAdmin pool_, address engine_, uint256 inventory)
        external
        broadcast
    {
        baseToken.mint(address(pool_), inventory);
        pool_.setTakerAllowed(engine_, true);
        pool_.setRecipientAllowed(engine_, true);
        pool_.unpause();
    }
}
