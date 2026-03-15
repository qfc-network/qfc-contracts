pragma circom 2.1.0;

include "../node_modules/circomlib/circuits/poseidon.circom";

// Commitment = Poseidon(secret, nullifier)
template CommitmentHasher() {
    signal input secret;
    signal input nullifier;
    signal output commitment;
    signal output nullifierHash;

    component commitmentHasher = Poseidon(2);
    commitmentHasher.inputs[0] <== secret;
    commitmentHasher.inputs[1] <== nullifier;
    commitment <== commitmentHasher.out;

    component nullifierHasher = Poseidon(1);
    nullifierHasher.inputs[0] <== nullifier;
    nullifierHash <== nullifierHasher.out;
}
