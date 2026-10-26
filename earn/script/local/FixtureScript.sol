// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script } from "forge-std/Script.sol";

import { DemoStablecoinFunder } from "../../src/demo/DemoStablecoinFunder.sol";
import { ITIP20Factory, ITIP20IssuerAccess } from "../../src/interfaces/external/tempo/ITIP20Factory.sol";
import { ALWAYS_ALLOW_POLICY_ID, ITIP20PolicyAccess } from "../../src/interfaces/external/tempo/ITIP403Registry.sol";

/// @notice The owner controls of the pinned DirectPropAMM artifact that fixture setup uses.
interface IDirectPropAMMAdmin {
    function setTakerAllowed(address taker, bool allowed) external;
    function setRecipientAllowed(address recipient, bool allowed) external;
    function unpause() external;
}

/// @notice Shared base of the fixture scripts, which localnet runs on its disposable chain and the
///         hosted fixture bootstrap on a persistent one. The deployer signs and owns every fixture.
/// @dev Tempo batches allow a top-level CREATE only in the first slot, so each helper that deploys a
///      contract runs as its own step.
abstract contract FixtureScript is Script {
    ITIP20Factory internal constant TIP20_FACTORY = ITIP20Factory(0x20Fc000000000000000000000000000000000000);
    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    string private constant DIRECT_PROPAMM_ARTIFACT = "test/fixtures/propamm/DirectPropAMM.json";
    uint256 private constant PROPAMM_MAX_ORACLE_AGE = 1 days;
    uint256 private constant PROPAMM_MAX_PRICE_DEVIATION_BPS = 50;

    error FixtureCreationFailed();

    modifier broadcast() {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        _;
        vm.stopBroadcast();
    }

    function _owner() internal view returns (address) {
        return vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
    }

    /// @dev Deploys the permissionless funder of the base and alternate test USD pair that
    ///      `_createStablecoins` then creates at the predicted addresses. `nonce` separates the
    ///      fixtures one deployer creates on a persistent chain.
    function _deployStablecoinFunder(uint256 nonce) internal returns (DemoStablecoinFunder) {
        address owner = _owner();
        return new DemoStablecoinFunder(
            TIP20_FACTORY.getTokenAddress(owner, _stablecoinSalt("base", nonce)),
            TIP20_FACTORY.getTokenAddress(owner, _stablecoinSalt("alternate", nonce))
        );
    }

    /// @dev Creates the funder's pair with the deployer as admin, the open transfer policy, and the
    ///      funder as sole issuer.
    function _createStablecoins(DemoStablecoinFunder funder, uint256 nonce) internal {
        _createToken(funder, funder.baseAsset(), "Earn Test Base USD", "etBASE", _stablecoinSalt("base", nonce));
        _createToken(
            funder, funder.alternateAsset(), "Earn Test Alternate USD", "etALT", _stablecoinSalt("alternate", nonce)
        );
    }

    /// @dev Deploys the unmodified pinned DirectPropAMM artifact; it starts paused until `unpause()`.
    function _deployDirectPropAMM(address base, address quote, address oracle, address registry)
        internal
        returns (address deployed)
    {
        address owner = _owner();
        bytes memory code = abi.encodePacked(
            vm.getCode(DIRECT_PROPAMM_ARTIFACT),
            abi.encode(
                base, quote, oracle, registry, owner, owner, PROPAMM_MAX_ORACLE_AGE, PROPAMM_MAX_PRICE_DEVIATION_BPS
            )
        );
        assembly { deployed := create(0, add(code, 32), mload(code)) }
        if (deployed == address(0)) revert FixtureCreationFailed();
    }

    function _createToken(
        DemoStablecoinFunder funder,
        address expected,
        string memory name,
        string memory symbol,
        bytes32 salt
    ) private {
        if (TIP20_FACTORY.createToken(name, symbol, "USD", PATH_USD, _owner(), salt) != expected) {
            revert FixtureCreationFailed();
        }
        // Disposable test tokens use Tempo's built-in open policy.
        ITIP20PolicyAccess(expected).changeTransferPolicyId(ALWAYS_ALLOW_POLICY_ID);
        ITIP20IssuerAccess access = ITIP20IssuerAccess(expected);
        access.grantRole(access.ISSUER_ROLE(), address(funder));
    }

    function _stablecoinSalt(string memory label, uint256 nonce) private pure returns (bytes32) {
        return keccak256(abi.encode("tempo-earn.stablecoin-fixture.v2", label, nonce));
    }
}
