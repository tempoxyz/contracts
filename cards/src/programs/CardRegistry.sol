// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardProgram } from "./CardProgram.sol";

/// @title CardRegistry
/// @notice What a card program's issuer records about each card beyond what authorization reads: the hash of a
///         network token reference bound to it, its program type and who carries it. Card numbers and network tokens
///         stay off chain; the token hash is not a payment credential. A companion to one program, kept apart so
///         the program's runtime code stays small. Authorization never reads it.
contract CardRegistry {
    /// @notice Program types; every type runs on the same holds and limits.
    uint8 public constant PREPAID = 1;
    uint8 public constant DEBIT = 2;
    uint8 public constant CREDIT = 3;
    uint8 public constant CORPORATE = 4;
    uint8 public constant VIRTUAL = 5;

    struct Metadata {
        bytes32 tokenHash;
        uint8 programType;
        string holder;
    }

    CardProgram public immutable PROGRAM;

    mapping(bytes32 card => Metadata) internal _metadata;
    /// @notice The card a network token reference was bound to. It follows the card's replacements, which the
    ///         program's CardReplaced events record.
    mapping(bytes32 tokenHash => bytes32 card) public cardOfToken;

    event TokenBound(bytes32 indexed card, bytes32 indexed tokenHash);
    event ProgramTypeSet(bytes32 indexed card, uint8 programType);
    event HolderSet(bytes32 indexed card, string holder);

    error NotIssuer();
    error UnknownCard();
    error TokenAlreadyBound();
    error InvalidProgramType();

    constructor(CardProgram program) {
        PROGRAM = program;
    }

    modifier onlyIssuer() {
        if (msg.sender != PROGRAM.ISSUER() && !PROGRAM.operators(msg.sender)) revert NotIssuer();
        _;
    }

    /// @notice Binds the hash of a network token reference to `card`. A hash binds once: a replaced card keeps
    ///         its tokens through the program's replacement record instead.
    function bindToken(bytes32 card, bytes32 tokenHash) external onlyIssuer {
        _requireCard(card);
        if (tokenHash == bytes32(0) || cardOfToken[tokenHash] != bytes32(0)) revert TokenAlreadyBound();
        cardOfToken[tokenHash] = card;
        _metadata[card].tokenHash = tokenHash;
        emit TokenBound(card, tokenHash);
    }

    /// @notice Sets `card`'s program type, one of the constants above.
    function setProgramType(bytes32 card, uint8 programType) external onlyIssuer {
        _requireCard(card);
        if (programType == 0 || programType > VIRTUAL) revert InvalidProgramType();
        _metadata[card].programType = programType;
        emit ProgramTypeSet(card, programType);
    }

    /// @notice Sets who carries `card`, such as an employee on a corporate account.
    function setHolder(bytes32 card, string calldata holder) external onlyIssuer {
        _requireCard(card);
        _metadata[card].holder = holder;
        emit HolderSet(card, holder);
    }

    /// @notice What the issuer recorded about `card`; empty fields were never set.
    function metadataOf(bytes32 card) external view returns (Metadata memory) {
        return _metadata[card];
    }

    function _requireCard(bytes32 card) private view {
        if (PROGRAM.cardOf(card).status == CardProgram.Status.None) revert UnknownCard();
    }
}
