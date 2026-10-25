// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Funding } from "../harness/SpendRail.sol";
import {
    BridgeErc20Rail,
    BridgeErc4626Rail,
    BridgePermit2Rail,
    BridgeTewfRail
} from "../rails/BridgeRails.sol";
import { TempoAccessKeyRail, TempoPrivateRail } from "../rails/TempoRails.sol";
import { CardScenarios } from "./CardScenarios.sol";

// Every contract setup crossed with every funding source it supports. Each contract runs the full
// card scenario suite in CardScenarios.

// ---------------------------------------------------------------------
// Bridge today
// ---------------------------------------------------------------------

contract Bridge_EA_Stablecoin is CardScenarios, BridgeErc20Rail {
    function _funding() internal pure override returns (Funding) {
        return Funding.Stablecoin;
    }
}

contract Bridge_P2_Stablecoin is CardScenarios, BridgePermit2Rail {
    function _funding() internal pure override returns (Funding) {
        return Funding.Stablecoin;
    }
}

contract Bridge_TF_Stablecoin is CardScenarios, BridgeTewfRail {
    function _funding() internal pure override returns (Funding) {
        return Funding.Stablecoin;
    }
}

contract Bridge_TF_Earn is CardScenarios, BridgeTewfRail {
    function _funding() internal pure override returns (Funding) {
        return Funding.Earn;
    }
}

contract Bridge_EV_Earn is CardScenarios, BridgeErc4626Rail {
    function _funding() internal pure override returns (Funding) {
        return Funding.Earn;
    }
}

// ---------------------------------------------------------------------
// Tempo short-term proposal
// ---------------------------------------------------------------------

contract Tempo_AccessKey_Stablecoin is CardScenarios, TempoAccessKeyRail {
    function _funding() internal pure override returns (Funding) {
        return Funding.Stablecoin;
    }
}

contract Tempo_AccessKey_Earn is CardScenarios, TempoAccessKeyRail {
    function _funding() internal pure override returns (Funding) {
        return Funding.Earn;
    }
}

contract Tempo_Private_Stablecoin is CardScenarios, TempoPrivateRail {
    function _funding() internal pure override returns (Funding) {
        return Funding.Stablecoin;
    }

    function _closedLoop() internal pure override returns (bool) {
        return false;
    }
}

contract Tempo_Private_Earn is CardScenarios, TempoPrivateRail {
    function _funding() internal pure override returns (Funding) {
        return Funding.Earn;
    }

    function _closedLoop() internal pure override returns (bool) {
        return false;
    }
}

contract Tempo_PrivateClosedLoop_Stablecoin is CardScenarios, TempoPrivateRail {
    function _funding() internal pure override returns (Funding) {
        return Funding.Stablecoin;
    }

    function _closedLoop() internal pure override returns (bool) {
        return true;
    }
}

contract Tempo_PrivateClosedLoop_Earn is CardScenarios, TempoPrivateRail {
    function _funding() internal pure override returns (Funding) {
        return Funding.Earn;
    }

    function _closedLoop() internal pure override returns (bool) {
        return true;
    }
}
