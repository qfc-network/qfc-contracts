pragma circom 2.1.0;

include "./hasher.circom";
include "./merkleTree.circom";

/*
 * ShieldedPool Withdrawal Circuit (Groth16)
 *
 * Proves:
 *   1. I know (secret, nullifier) such that Poseidon(secret, nullifier) = commitment
 *   2. commitment is a leaf in the Merkle tree with the given root
 *   3. Poseidon(nullifier) = nullifierHash (public, for double-spend prevention)
 *
 * Public inputs:
 *   - root:           Merkle tree root at proof generation time
 *   - nullifierHash:  Hash of nullifier (checked on-chain to prevent replay)
 *   - recipient:      Withdrawal address (bound to proof to prevent front-running)
 *   - denomination:   Amount being withdrawn (bound to proof)
 *
 * Private inputs:
 *   - secret:         Random secret known only to depositor
 *   - nullifier:      Random nullifier known only to depositor
 *   - pathElements:   Merkle proof sibling hashes
 *   - pathIndices:    Merkle proof path (0=left, 1=right)
 */
template Withdraw(levels) {
    // Public inputs
    signal input root;
    signal input nullifierHash;
    signal input recipient;       // Not used in constraints, but bound to proof
    signal input denomination;    // Not used in constraints, but bound to proof

    // Private inputs
    signal input secret;
    signal input nullifier;
    signal input pathElements[levels];
    signal input pathIndices[levels];

    // 1. Compute commitment and nullifier hash
    component hasher = CommitmentHasher();
    hasher.secret <== secret;
    hasher.nullifier <== nullifier;

    // 2. Verify nullifier hash matches public input
    nullifierHash === hasher.nullifierHash;

    // 3. Verify commitment is in Merkle tree
    component tree = MerkleTreeChecker(levels);
    tree.leaf <== hasher.commitment;
    tree.root <== root;
    for (var i = 0; i < levels; i++) {
        tree.pathElements[i] <== pathElements[i];
        tree.pathIndices[i] <== pathIndices[i];
    }

    // 4. Bind recipient and denomination to the proof (prevent front-running)
    // Square them to create a constraint without affecting the circuit logic
    signal recipientSquare;
    recipientSquare <== recipient * recipient;
    signal denomSquare;
    denomSquare <== denomination * denomination;
}

// Instantiate with 20-level tree (~1M deposits)
component main {public [root, nullifierHash, recipient, denomination]} = Withdraw(20);
