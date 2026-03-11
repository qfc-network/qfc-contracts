// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title BridgeRelayerManager
 * @dev Manages a set of relayers and validates 3-of-5 multisig signature sets
 *      for cross-chain bridge operations.
 *
 * Features:
 * - Owner-managed relayer set (add/remove)
 * - ECDSA signature verification against registered relayers
 * - Configurable quorum threshold (default 3-of-5)
 */
contract BridgeRelayerManager is Ownable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @dev Minimum number of valid relayer signatures required
    uint256 public quorum;

    /// @dev Maximum number of relayers allowed
    uint256 public constant MAX_RELAYERS = 10;

    /// @dev Set of registered relayer addresses
    mapping(address => bool) public isRelayer;

    /// @dev Array of relayer addresses for enumeration
    address[] public relayers;

    // ── Events ──────────────────────────────────────────────────────────

    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);

    // ── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error AlreadyRelayer();
    error NotRelayer();
    error TooManyRelayers();
    error InvalidQuorum();
    error InsufficientSignatures();
    error DuplicateSignature();
    error InvalidSignerOrder();

    // ── Constructor ─────────────────────────────────────────────────────

    /**
     * @param _initialRelayers Initial set of relayer addresses
     * @param _quorum Minimum signatures required for validation
     */
    constructor(
        address[] memory _initialRelayers,
        uint256 _quorum
    ) Ownable(msg.sender) {
        if (_quorum == 0 || _quorum > _initialRelayers.length) revert InvalidQuorum();
        if (_initialRelayers.length > MAX_RELAYERS) revert TooManyRelayers();

        for (uint256 i = 0; i < _initialRelayers.length; i++) {
            if (_initialRelayers[i] == address(0)) revert ZeroAddress();
            if (isRelayer[_initialRelayers[i]]) revert AlreadyRelayer();
            isRelayer[_initialRelayers[i]] = true;
            relayers.push(_initialRelayers[i]);
            emit RelayerAdded(_initialRelayers[i]);
        }

        quorum = _quorum;
    }

    // ── Admin Functions ─────────────────────────────────────────────────

    /**
     * @notice Add a new relayer
     * @param _relayer Address to add as relayer
     */
    function addRelayer(address _relayer) external onlyOwner {
        if (_relayer == address(0)) revert ZeroAddress();
        if (isRelayer[_relayer]) revert AlreadyRelayer();
        if (relayers.length >= MAX_RELAYERS) revert TooManyRelayers();

        isRelayer[_relayer] = true;
        relayers.push(_relayer);
        emit RelayerAdded(_relayer);
    }

    /**
     * @notice Remove a relayer
     * @param _relayer Address to remove
     */
    function removeRelayer(address _relayer) external onlyOwner {
        if (!isRelayer[_relayer]) revert NotRelayer();
        if (relayers.length <= quorum) revert InvalidQuorum();

        isRelayer[_relayer] = false;

        // Swap-and-pop removal
        for (uint256 i = 0; i < relayers.length; i++) {
            if (relayers[i] == _relayer) {
                relayers[i] = relayers[relayers.length - 1];
                relayers.pop();
                break;
            }
        }

        emit RelayerRemoved(_relayer);
    }

    /**
     * @notice Update the quorum threshold
     * @param _quorum New quorum value
     */
    function setQuorum(uint256 _quorum) external onlyOwner {
        if (_quorum == 0 || _quorum > relayers.length) revert InvalidQuorum();
        uint256 oldQuorum = quorum;
        quorum = _quorum;
        emit QuorumUpdated(oldQuorum, _quorum);
    }

    // ── Signature Validation ────────────────────────────────────────────

    /**
     * @notice Validate that a message hash has been signed by at least `quorum` relayers
     * @param _hash The message hash that was signed
     * @param _signatures Array of ECDSA signatures (sorted by signer address ascending)
     * @return True if the signature set is valid
     */
    function isValidSignatureSet(
        bytes32 _hash,
        bytes[] calldata _signatures
    ) public view returns (bool) {
        if (_signatures.length < quorum) revert InsufficientSignatures();

        bytes32 ethSignedHash = _hash.toEthSignedMessageHash();
        address lastSigner = address(0);
        uint256 validCount = 0;

        for (uint256 i = 0; i < _signatures.length; i++) {
            address signer = ethSignedHash.recover(_signatures[i]);

            // Enforce ascending order to prevent duplicates
            if (signer <= lastSigner) revert InvalidSignerOrder();
            lastSigner = signer;

            if (isRelayer[signer]) {
                validCount++;
            }
        }

        return validCount >= quorum;
    }

    // ── View Functions ──────────────────────────────────────────────────

    /**
     * @notice Get the total number of relayers
     */
    function relayerCount() external view returns (uint256) {
        return relayers.length;
    }

    /**
     * @notice Get all relayer addresses
     */
    function getRelayers() external view returns (address[] memory) {
        return relayers;
    }
}
