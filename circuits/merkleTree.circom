pragma circom 2.1.0;

include "../node_modules/circomlib/circuits/poseidon.circom";

// Hash two children to get parent
template HashLeftRight() {
    signal input left;
    signal input right;
    signal output hash;

    component hasher = Poseidon(2);
    hasher.inputs[0] <== left;
    hasher.inputs[1] <== right;
    hash <== hasher.out;
}

// Dual Mux: select between two inputs based on selector bit
template DualMux() {
    signal input in[2];
    signal input s;
    signal output out[2];

    s * (1 - s) === 0;  // s must be 0 or 1
    out[0] <== (in[1] - in[0]) * s + in[0];
    out[1] <== (in[0] - in[1]) * s + in[1];
}

// Verify a Merkle proof
// levels = tree depth
template MerkleTreeChecker(levels) {
    signal input leaf;
    signal input root;
    signal input pathElements[levels];
    signal input pathIndices[levels];  // 0 = left, 1 = right

    component selectors[levels];
    component hashers[levels];

    signal computedHash[levels + 1];
    computedHash[0] <== leaf;

    for (var i = 0; i < levels; i++) {
        selectors[i] = DualMux();
        selectors[i].in[0] <== computedHash[i];
        selectors[i].in[1] <== pathElements[i];
        selectors[i].s <== pathIndices[i];

        hashers[i] = HashLeftRight();
        hashers[i].left <== selectors[i].out[0];
        hashers[i].right <== selectors[i].out[1];

        computedHash[i + 1] <== hashers[i].hash;
    }

    // Verify computed root matches expected root
    root === computedHash[levels];
}
