// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./AssociationSet.sol";

/**
 * @title IComplianceProofVerifier
 * @notice Interface for the Groth16 verifier for compliance proofs
 * @dev Generated from the compliance circom circuit (extends withdraw circuit)
 *
 *  Public signals for compliance proof:
 *    [0] withdrawRoot       — ShieldedPool Merkle root
 *    [1] nullifierHash      — Poseidon(nullifier)
 *    [2] recipient          — Withdrawal address
 *    [3] denomination       — Amount
 *    [4] associationSetRoot — Merkle root of the Association Set
 */
interface IComplianceProofVerifier {
    function verifyProof(
        uint[2] calldata _pA,
        uint[2][2] calldata _pB,
        uint[2] calldata _pC,
        uint[5] calldata _pubSignals
    ) external view returns (bool);
}

/**
 * @title ComplianceVerifier
 * @notice Verifies Privacy Pool compliance proofs — users prove their deposit
 *         came from a compliant address without revealing which one.
 *
 *  Three compliance levels:
 *    None  — Standard withdrawal, no compliance proof
 *    Basic — User proved inclusion in at least one active inclusion set
 *    Full  — Inclusion proof + proved exclusion from all active exclusion sets
 *
 *  DeFi protocols can query `getComplianceLevel(nullifierHash)` to check
 *  whether a withdrawal has been compliance-verified.
 *
 * @dev The compliance ZK circuit extends the withdrawal circuit by adding:
 *      - depositorAddress as a private input
 *      - Association Set Merkle proof (depositorAddress ∈ set)
 *      - associationSetRoot as a public input
 *
 *      For the simplified (non-ZK) version used in testing, we accept
 *      a standard proof format and verify the association set root is valid.
 */
contract ComplianceVerifier {
    AssociationSet public immutable associationSets;

    /// @notice Compliance records: nullifierHash → ComplianceRecord
    struct ComplianceRecord {
        AssociationSet.ComplianceLevel level;
        bytes32[] inclusionSets;   // Set IDs the user proved inclusion in
        bytes32[] exclusionSets;   // Set IDs the user proved exclusion from
        uint256 verifiedAt;
    }

    mapping(uint256 => ComplianceRecord) public records;

    // --- Errors ---

    error InvalidProof();
    error InvalidAssociationSet();
    error AlreadyVerified();
    error SetNotActive();

    // --- Events ---

    event ComplianceProved(
        uint256 indexed nullifierHash,
        AssociationSet.ComplianceLevel level,
        bytes32[] inclusionSets,
        bytes32[] exclusionSets
    );

    constructor(address _associationSets) {
        associationSets = AssociationSet(_associationSets);
    }

    // =========================================================================
    // Compliance verification
    // =========================================================================

    /**
     * @notice Submit a compliance proof for a withdrawal
     * @param _nullifierHash The nullifier hash from the withdrawal
     * @param _inclusionSetIds Set IDs to prove inclusion in
     * @param _inclusionRoots Merkle roots of the inclusion sets (must match on-chain)
     * @param _exclusionSetIds Set IDs to prove exclusion from
     * @param _exclusionRoots Merkle roots of the exclusion sets
     *
     * @dev In production, this would accept ZK proofs for each set.
     *      The simplified version verifies that the provided roots match
     *      the on-chain set roots (proving awareness of the sets).
     *      Full ZK verification requires the extended compliance circuit.
     */
    function proveCompliance(
        uint256 _nullifierHash,
        bytes32[] calldata _inclusionSetIds,
        uint256[] calldata _inclusionRoots,
        bytes32[] calldata _exclusionSetIds,
        uint256[] calldata _exclusionRoots
    ) external {
        if (records[_nullifierHash].verifiedAt != 0) revert AlreadyVerified();

        // Verify inclusion sets
        for (uint256 i = 0; i < _inclusionSetIds.length; i++) {
            AssociationSet.AssocSet memory s = associationSets.getSet(_inclusionSetIds[i]);
            if (!s.active) revert SetNotActive();
            if (s.setType != AssociationSet.SetType.Inclusion) revert InvalidAssociationSet();
            if (s.root != _inclusionRoots[i]) revert InvalidProof();
        }

        // Verify exclusion sets
        for (uint256 i = 0; i < _exclusionSetIds.length; i++) {
            AssociationSet.AssocSet memory s = associationSets.getSet(_exclusionSetIds[i]);
            if (!s.active) revert SetNotActive();
            if (s.setType != AssociationSet.SetType.Exclusion) revert InvalidAssociationSet();
            if (s.root != _exclusionRoots[i]) revert InvalidProof();
        }

        // Determine compliance level
        AssociationSet.ComplianceLevel level;
        if (_inclusionSetIds.length > 0 && _exclusionSetIds.length > 0) {
            level = AssociationSet.ComplianceLevel.Full;
        } else if (_inclusionSetIds.length > 0) {
            level = AssociationSet.ComplianceLevel.Basic;
        } else {
            level = AssociationSet.ComplianceLevel.None;
        }

        records[_nullifierHash] = ComplianceRecord({
            level: level,
            inclusionSets: _inclusionSetIds,
            exclusionSets: _exclusionSetIds,
            verifiedAt: block.timestamp
        });

        emit ComplianceProved(_nullifierHash, level, _inclusionSetIds, _exclusionSetIds);
    }

    // =========================================================================
    // Query interface (for DeFi protocols)
    // =========================================================================

    /**
     * @notice Check the compliance level of a withdrawal
     * @param _nullifierHash The nullifier hash from the withdrawal
     * @return level The compliance level (None/Basic/Full)
     */
    function getComplianceLevel(uint256 _nullifierHash)
        external view returns (AssociationSet.ComplianceLevel)
    {
        return records[_nullifierHash].level;
    }

    /**
     * @notice Check if a withdrawal meets a minimum compliance level
     * @param _nullifierHash The nullifier hash
     * @param _minLevel Minimum required compliance level
     */
    function meetsComplianceLevel(
        uint256 _nullifierHash,
        AssociationSet.ComplianceLevel _minLevel
    ) external view returns (bool) {
        return records[_nullifierHash].level >= _minLevel;
    }

    /**
     * @notice Get full compliance record for a withdrawal
     */
    function getComplianceRecord(uint256 _nullifierHash)
        external view returns (ComplianceRecord memory)
    {
        return records[_nullifierHash];
    }
}
