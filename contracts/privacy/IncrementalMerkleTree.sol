// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IncrementalMerkleTree
 * @notice Gas-efficient incremental Merkle tree for commitment storage.
 *         Uses the "filled subtrees" technique — only stores O(depth) nodes.
 * @dev Leaf hash function: keccak256. Tree depth: 20 (supports ~1M deposits).
 */
contract IncrementalMerkleTree {
    uint256 public constant TREE_DEPTH = 20;
    uint256 public constant MAX_LEAVES = 2 ** TREE_DEPTH; // 1,048,576

    /// @notice Current number of leaves inserted
    uint256 public nextLeafIndex;

    /// @notice Zero values for each level (precomputed)
    bytes32[TREE_DEPTH] public zeros;

    /// @notice Filled subtrees (one per level)
    bytes32[TREE_DEPTH] public filledSubtrees;

    /// @notice Set of known roots (for historical root validation)
    mapping(bytes32 => bool) public knownRoots;

    /// @notice Current Merkle root
    bytes32 public currentRoot;

    /// @notice Ring buffer of recent roots (last 100)
    uint256 public constant ROOT_HISTORY_SIZE = 100;
    bytes32[100] public rootHistory;
    uint256 public currentRootIndex;

    error MerkleTreeFull();

    constructor() {
        // Precompute zero values: zeros[0] = keccak256(0), zeros[i] = hash(zeros[i-1], zeros[i-1])
        bytes32 zero = keccak256(abi.encodePacked(uint256(0)));
        zeros[0] = zero;
        filledSubtrees[0] = zero;

        for (uint256 i = 1; i < TREE_DEPTH; i++) {
            zero = _hashPair(zero, zero);
            zeros[i] = zero;
            filledSubtrees[i] = zero;
        }

        // Initial root
        currentRoot = _hashPair(zero, zero);
        knownRoots[currentRoot] = true;
        rootHistory[0] = currentRoot;
    }

    /**
     * @notice Insert a leaf into the Merkle tree
     * @param _leaf The commitment hash to insert
     * @return index The index of the inserted leaf
     */
    function _insertLeaf(bytes32 _leaf) internal returns (uint256 index) {
        if (nextLeafIndex >= MAX_LEAVES) revert MerkleTreeFull();

        index = nextLeafIndex;
        bytes32 currentHash = _leaf;

        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            if (index % 2 == 0) {
                // Left child: pair with zero
                filledSubtrees[i] = currentHash;
                currentHash = _hashPair(currentHash, zeros[i]);
            } else {
                // Right child: pair with filled subtree
                currentHash = _hashPair(filledSubtrees[i], currentHash);
            }
            index /= 2;
        }

        currentRoot = currentHash;
        knownRoots[currentRoot] = true;

        // Update root history ring buffer
        currentRootIndex = (currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        rootHistory[currentRootIndex] = currentRoot;

        nextLeafIndex++;
        return nextLeafIndex - 1;
    }

    /**
     * @notice Check if a root is known (current or historical)
     */
    function isKnownRoot(bytes32 _root) public view returns (bool) {
        if (_root == currentRoot) return true;

        // Check ring buffer
        for (uint256 i = 0; i < ROOT_HISTORY_SIZE; i++) {
            if (rootHistory[i] == _root) return true;
        }
        return false;
    }

    function _hashPair(bytes32 _left, bytes32 _right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_left, _right));
    }
}
