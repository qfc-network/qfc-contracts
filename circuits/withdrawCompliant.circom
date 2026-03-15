pragma circom 2.1.0;

include "./hasher.circom";
include "./merkleTree.circom";

/*
 * Compliant Withdrawal Circuit (Groth16)
 *
 * Extends the standard withdrawal circuit with an Association Set
 * membership proof. The user proves:
 *
 *   1. I know (secret, nullifier) such that Poseidon(secret, nullifier) = commitment
 *   2. commitment is a leaf in the ShieldedPool Merkle tree with root `root`
 *   3. Poseidon(nullifier) = nullifierHash
 *   4. NEW: depositorAddress is a member of the Association Set Merkle tree
 *      with root `associationSetRoot`
 *
 * Without revealing which commitment or which address.
 *
 * Public inputs:
 *   - root:               ShieldedPool Merkle root
 *   - nullifierHash:      Poseidon(nullifier)
 *   - recipient:          Withdrawal address
 *   - denomination:       Amount
 *   - associationSetRoot: Merkle root of the Association Set
 *
 * Private inputs:
 *   - secret, nullifier:  Commitment preimage
 *   - pathElements[20]:   ShieldedPool Merkle proof
 *   - pathIndices[20]:    ShieldedPool Merkle path
 *   - depositorAddress:   Address that made the deposit (field element)
 *   - assocPathElements[20]: Association Set Merkle proof
 *   - assocPathIndices[20]:  Association Set Merkle path
 */

// Association Set tree also uses depth 20 for consistency
template WithdrawCompliant(poolLevels, assocLevels) {
    // Public inputs
    signal input root;
    signal input nullifierHash;
    signal input recipient;
    signal input denomination;
    signal input associationSetRoot;

    // Private inputs — pool
    signal input secret;
    signal input nullifier;
    signal input pathElements[poolLevels];
    signal input pathIndices[poolLevels];

    // Private inputs — association set
    signal input depositorAddress;
    signal input assocPathElements[assocLevels];
    signal input assocPathIndices[assocLevels];

    // 1. Compute commitment and nullifier hash
    component hasher = CommitmentHasher();
    hasher.secret <== secret;
    hasher.nullifier <== nullifier;

    // 2. Verify nullifier hash
    nullifierHash === hasher.nullifierHash;

    // 3. Verify commitment is in ShieldedPool Merkle tree
    component poolTree = MerkleTreeChecker(poolLevels);
    poolTree.leaf <== hasher.commitment;
    poolTree.root <== root;
    for (var i = 0; i < poolLevels; i++) {
        poolTree.pathElements[i] <== pathElements[i];
        poolTree.pathIndices[i] <== pathIndices[i];
    }

    // 4. Verify depositorAddress is in Association Set Merkle tree
    // Leaf = Poseidon(depositorAddress) to match off-chain tree construction
    component addrHasher = Poseidon(1);
    addrHasher.inputs[0] <== depositorAddress;

    component assocTree = MerkleTreeChecker(assocLevels);
    assocTree.leaf <== addrHasher.out;
    assocTree.root <== associationSetRoot;
    for (var i = 0; i < assocLevels; i++) {
        assocTree.pathElements[i] <== assocPathElements[i];
        assocTree.pathIndices[i] <== assocPathIndices[i];
    }

    // 5. Bind recipient and denomination to proof
    signal recipientSquare;
    recipientSquare <== recipient * recipient;
    signal denomSquare;
    denomSquare <== denomination * denomination;
}

// Pool: 20 levels, Association Set: 20 levels
component main {public [root, nullifierHash, recipient, denomination, associationSetRoot]} = WithdrawCompliant(20, 20);
