#!/bin/bash
# Build script for ShieldedPool ZK circuits
# Usage: ./circuits/build.sh
set -e

BUILD_DIR="build/circuits"
CIRCUIT="circuits/withdraw.circom"

echo "=== ShieldedPool ZK Circuit Build ==="
echo ""

# Step 1: Compile circuit
echo "[1/6] Compiling circuit..."
circom2 $CIRCUIT --r1cs --wasm --sym -o $BUILD_DIR
echo "  ✓ R1CS: $BUILD_DIR/withdraw.r1cs"
echo "  ✓ WASM: $BUILD_DIR/withdraw_js/withdraw.wasm"

# Step 2: Powers of Tau (phase 1)
echo "[2/6] Powers of Tau ceremony..."
if [ ! -f "$BUILD_DIR/pot14_final.ptau" ]; then
  snarkjs powersoftau new bn128 14 $BUILD_DIR/pot14_0000.ptau
  snarkjs powersoftau contribute $BUILD_DIR/pot14_0000.ptau $BUILD_DIR/pot14_0001.ptau \
    --name="QFC Phase 1" -e="$(head -c 64 /dev/urandom | xxd -p)"
  snarkjs powersoftau prepare phase2 $BUILD_DIR/pot14_0001.ptau $BUILD_DIR/pot14_final.ptau
  echo "  ✓ Powers of Tau finalized"
else
  echo "  ✓ Powers of Tau already exists, skipping"
fi

# Step 3: Groth16 setup
echo "[3/6] Groth16 setup..."
snarkjs groth16 setup $BUILD_DIR/withdraw.r1cs $BUILD_DIR/pot14_final.ptau $BUILD_DIR/withdraw_0000.zkey

# Step 4: Contribute to ceremony
echo "[4/6] Contributing to ceremony..."
snarkjs zkey contribute $BUILD_DIR/withdraw_0000.zkey $BUILD_DIR/withdraw_0001.zkey \
  --name="QFC contributor 1" -e="$(head -c 64 /dev/urandom | xxd -p)"
snarkjs zkey beacon $BUILD_DIR/withdraw_0001.zkey $BUILD_DIR/withdraw_final.zkey \
  0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20 10 -n="Final Beacon"
echo "  ✓ Final zkey: $BUILD_DIR/withdraw_final.zkey"

# Step 5: Export verification key
echo "[5/6] Exporting verification key..."
snarkjs zkey export verificationkey $BUILD_DIR/withdraw_final.zkey $BUILD_DIR/verification_key.json
echo "  ✓ Verification key: $BUILD_DIR/verification_key.json"

# Step 6: Generate Solidity verifier
echo "[6/6] Generating Solidity verifier..."
snarkjs zkey export solidityverifier $BUILD_DIR/withdraw_final.zkey contracts/privacy/Groth16Verifier.sol
echo "  ✓ Verifier contract: contracts/privacy/Groth16Verifier.sol"

echo ""
echo "=== Build complete ==="
echo ""
echo "Circuit stats:"
snarkjs r1cs info $BUILD_DIR/withdraw.r1cs
echo ""
echo "Files needed for client SDK:"
echo "  - $BUILD_DIR/withdraw_js/withdraw.wasm  (witness generator)"
echo "  - $BUILD_DIR/withdraw_final.zkey         (proving key)"
echo "  - $BUILD_DIR/verification_key.json       (verification key)"
