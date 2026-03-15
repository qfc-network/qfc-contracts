// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title AssociationSet
 * @notice Manages sets of "compliant" addresses for Privacy Pools compliance proofs.
 *
 *  Two types of sets:
 *    - Inclusion sets: addresses known to be compliant (e.g., KYC'd, regulated entities)
 *    - Exclusion sets: addresses known to be malicious (e.g., hacks, sanctions)
 *
 *  Users can prove "my deposit was made by an address in inclusion set S" or
 *  "my deposit was NOT made by an address in exclusion set S", without revealing
 *  which specific address or deposit is theirs.
 *
 *  Sets are stored as Merkle roots (the full tree is built off-chain).
 *  Governance (DAO) manages which sets are active and trusted.
 *
 * @dev Each set has a unique ID, a Merkle root, and metadata.
 *      The Merkle tree leaves are keccak256(address) for gas efficiency.
 *      The ZK circuit uses Poseidon internally, but the association set
 *      uses a separate Poseidon tree built off-chain.
 */
contract AssociationSet is AccessControl {
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");

    enum SetType { Inclusion, Exclusion }

    struct AssocSet {
        bytes32 id;
        string name;
        SetType setType;
        uint256 root;          // Poseidon Merkle root of the address set
        uint256 memberCount;
        address curator;       // Who manages this set
        uint256 updatedAt;
        bool active;
    }

    /// @notice Set ID → Set data
    mapping(bytes32 => AssocSet) public sets;

    /// @notice List of all set IDs
    bytes32[] public setIds;

    /// @notice Compliance levels
    enum ComplianceLevel {
        None,       // 0 — No compliance proof
        Basic,      // 1 — Proved membership in at least one inclusion set
        Full        // 2 — Proved membership in inclusion set + exclusion from all exclusion sets
    }

    // --- Errors ---

    error SetNotFound();
    error SetAlreadyExists();
    error SetNotActive();
    error InvalidRoot();

    // --- Events ---

    event SetCreated(bytes32 indexed id, string name, SetType setType, address curator);
    event SetUpdated(bytes32 indexed id, uint256 newRoot, uint256 memberCount);
    event SetDeactivated(bytes32 indexed id);
    event SetActivated(bytes32 indexed id);

    constructor(address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(CURATOR_ROLE, _admin);
    }

    // =========================================================================
    // Set management
    // =========================================================================

    /**
     * @notice Create a new association set
     * @param _name Human-readable name (e.g., "KYC Verified Users Q1 2026")
     * @param _setType Inclusion or Exclusion
     * @param _root Initial Poseidon Merkle root of addresses
     * @param _memberCount Number of addresses in the set
     */
    function createSet(
        string calldata _name,
        SetType _setType,
        uint256 _root,
        uint256 _memberCount
    ) external onlyRole(CURATOR_ROLE) returns (bytes32 id) {
        id = keccak256(abi.encodePacked(_name, block.timestamp, msg.sender));
        if (sets[id].active) revert SetAlreadyExists();
        if (_root == 0) revert InvalidRoot();

        sets[id] = AssocSet({
            id: id,
            name: _name,
            setType: _setType,
            root: _root,
            memberCount: _memberCount,
            curator: msg.sender,
            updatedAt: block.timestamp,
            active: true
        });
        setIds.push(id);

        emit SetCreated(id, _name, _setType, msg.sender);
    }

    /**
     * @notice Update the Merkle root of an association set
     * @dev Called when addresses are added/removed from the set
     */
    function updateSet(
        bytes32 _id,
        uint256 _newRoot,
        uint256 _memberCount
    ) external onlyRole(CURATOR_ROLE) {
        AssocSet storage s = sets[_id];
        if (!s.active) revert SetNotActive();
        if (_newRoot == 0) revert InvalidRoot();

        s.root = _newRoot;
        s.memberCount = _memberCount;
        s.updatedAt = block.timestamp;

        emit SetUpdated(_id, _newRoot, _memberCount);
    }

    function deactivateSet(bytes32 _id) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!sets[_id].active) revert SetNotActive();
        sets[_id].active = false;
        emit SetDeactivated(_id);
    }

    function activateSet(bytes32 _id) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (sets[_id].root == 0) revert SetNotFound();
        sets[_id].active = true;
        emit SetActivated(_id);
    }

    // =========================================================================
    // View
    // =========================================================================

    function getSet(bytes32 _id) external view returns (AssocSet memory) {
        if (sets[_id].root == 0) revert SetNotFound();
        return sets[_id];
    }

    function getSetRoot(bytes32 _id) external view returns (uint256) {
        if (!sets[_id].active) revert SetNotActive();
        return sets[_id].root;
    }

    function getActiveInclusionSets() external view returns (AssocSet[] memory) {
        return _getActiveSets(SetType.Inclusion);
    }

    function getActiveExclusionSets() external view returns (AssocSet[] memory) {
        return _getActiveSets(SetType.Exclusion);
    }

    function setCount() external view returns (uint256) {
        return setIds.length;
    }

    function _getActiveSets(SetType _type) internal view returns (AssocSet[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < setIds.length; i++) {
            if (sets[setIds[i]].active && sets[setIds[i]].setType == _type) count++;
        }

        AssocSet[] memory result = new AssocSet[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < setIds.length; i++) {
            if (sets[setIds[i]].active && sets[setIds[i]].setType == _type) {
                result[idx] = sets[setIds[i]];
                idx++;
            }
        }
        return result;
    }
}
