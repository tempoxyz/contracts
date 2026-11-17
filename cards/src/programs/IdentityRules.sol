// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice The issuer a card program answers to.
interface IIssued {
    function ISSUER() external view returns (address);
}

/// @title IdentityRules
/// @notice Jurisdiction rules and identity attestations that card programs check at authorization. A jurisdiction
///         names the BIN sponsors licensed there and its large-transaction reporting threshold. Attesters (KYC
///         providers) record that an account passed a check, signed by a key they registered; only the claim, the
///         jurisdiction, an expiry and the hash of the attester's record go on chain. A program's identity policy
///         names the attesters it accepts, the claim and its jurisdiction, and needs a sponsor licensed there, so one
///         attestation serves every program that accepts its attester.
/// @custom:invariant GOVERNOR != address(0)
contract IdentityRules {
    /// @notice Sets jurisdictions.
    address public immutable GOVERNOR;

    /// @notice Most sponsors a jurisdiction or attesters a policy may list.
    uint256 public constant MAX_ENTRIES = 16;

    struct Jurisdiction {
        uint128 reportThreshold;
        address[] sponsors;
    }

    struct Attestation {
        address attester;
        bytes32 claim;
        bytes32 jurisdiction;
        uint64 expiresAt;
        bytes32 hash;
    }

    struct Policy {
        address[] attesters;
        bytes32 claim;
        bytes32 jurisdiction;
        address sponsor;
    }

    mapping(bytes32 code => Jurisdiction) internal _jurisdictions;
    mapping(address attester => mapping(address key => bool)) public isKey;
    mapping(address account => Attestation[]) internal _attestations;
    mapping(address program => Policy) internal _policies;

    event JurisdictionSet(bytes32 indexed code, uint128 reportThreshold, address[] sponsors);
    event AttesterKeySet(address indexed attester, address indexed key, bool active);
    event Attested(
        address indexed account,
        address indexed attester,
        bytes32 indexed claim,
        bytes32 jurisdiction,
        uint64 expiresAt,
        bytes32 hash
    );
    event PolicySet(address indexed program, bytes32 claim, bytes32 jurisdiction, address sponsor, address[] attesters);

    error Unauthorized();
    error UnknownJurisdiction(bytes32 code);
    error SponsorNotLicensed(address sponsor, bytes32 code);
    error TooManyEntries();
    error InvalidAttestation();
    error IdentityRequired();

    /// @custom:ensures GOVERNOR == governor
    constructor(address governor) {
        if (governor == address(0)) revert Unauthorized();
        GOVERNOR = governor;
    }

    /// @notice Sets a jurisdiction's rules. Programs already admitted keep their policy; a sponsor dropped here only
    ///         stops new policies naming it.
    function setJurisdiction(bytes32 code, uint128 reportThreshold, address[] calldata sponsors) external {
        if (msg.sender != GOVERNOR) revert Unauthorized();
        if (code == bytes32(0)) revert UnknownJurisdiction(code);
        if (sponsors.length > MAX_ENTRIES) revert TooManyEntries();
        _jurisdictions[code] = Jurisdiction(reportThreshold, sponsors);
        emit JurisdictionSet(code, reportThreshold, sponsors);
    }

    /// @notice The caller, an attester, registers or revokes a key that signs its attestations.
    function setKey(address key, bool active) external {
        isKey[msg.sender][key] = active;
        emit AttesterKeySet(msg.sender, key, active);
    }

    /// @notice Records that `account` passed `claim` under `jurisdiction`, until `expiresAt`. The caller is one of
    ///         `attester`'s active keys; copying a trusted attester's address and record hash records nothing.
    function attest(
        address attester,
        address account,
        bytes32 claim,
        bytes32 jurisdiction,
        uint64 expiresAt,
        bytes32 hash
    ) external {
        if (!isKey[attester][msg.sender]) revert Unauthorized();
        // Expiries are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (account == address(0) || claim == bytes32(0) || expiresAt <= block.timestamp) revert InvalidAttestation();
        _attestations[account].push(Attestation(attester, claim, jurisdiction, expiresAt, hash));
        emit Attested(account, attester, claim, jurisdiction, expiresAt, hash);
    }

    /// @notice The program's issuer sets the identity its cardholders need: a live attestation of `claim` from one of
    ///         `attesters`, made under `jurisdiction`. The program's BIN sponsor must be licensed there.
    function setPolicy(
        address program,
        address[] calldata attesters,
        bytes32 claim,
        bytes32 jurisdiction,
        address sponsor
    ) external {
        if (msg.sender != IIssued(program).ISSUER()) revert Unauthorized();
        if (attesters.length == 0 || attesters.length > MAX_ENTRIES) revert TooManyEntries();
        if (!licensed(sponsor, jurisdiction)) revert SponsorNotLicensed(sponsor, jurisdiction);
        _policies[program] = Policy(attesters, claim, jurisdiction, sponsor);
        emit PolicySet(program, claim, jurisdiction, sponsor, attesters);
    }

    /// @notice Reverts with `IdentityRequired` unless the calling program admits `account`.
    function admit(address account) external view {
        if (!admits(msg.sender, account)) revert IdentityRequired();
    }

    /// @notice Whether `program` admits `account`: always without a policy, else with a live matching attestation.
    function admits(address program, address account) public view returns (bool) {
        Policy storage policy = _policies[program];
        address[] storage attesters = policy.attesters;
        if (attesters.length == 0) return true;
        Attestation[] storage list = _attestations[account];
        for (uint256 i; i < list.length; ++i) {
            Attestation storage a = list[i];
            // forge-lint: disable-next-line(block-timestamp)
            if (a.claim != policy.claim || a.jurisdiction != policy.jurisdiction || a.expiresAt <= block.timestamp) {
                continue;
            }
            if (_contains(attesters, a.attester)) return true;
        }
        return false;
    }

    /// @notice Whether `sponsor` is licensed to sponsor programs in `code`.
    function licensed(address sponsor, bytes32 code) public view returns (bool) {
        address[] storage sponsors = _jurisdictions[code].sponsors;
        return sponsor != address(0) && _contains(sponsors, sponsor);
    }

    function jurisdictionOf(bytes32 code) external view returns (uint128 reportThreshold, address[] memory sponsors) {
        Jurisdiction storage j = _jurisdictions[code];
        return (j.reportThreshold, j.sponsors);
    }

    function attestationsOf(address account) external view returns (Attestation[] memory) {
        return _attestations[account];
    }

    function policyOf(address program) external view returns (Policy memory) {
        return _policies[program];
    }

    function _contains(address[] storage list, address value) private view returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == value) return true;
        }
        return false;
    }
}
