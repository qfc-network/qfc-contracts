import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import * as path from "path";
import * as fs from "fs";

// @ts-ignore
const snarkjs = require("snarkjs");

// Poseidon hash (same as circomlib)
const circomlibjs = require("circomlibjs");

describe("ShieldedPoolV2 (Groth16 ZK Proof)", function () {
  this.timeout(120000); // ZK proof generation can take time

  const DENOM_1000 = ethers.parseEther("1000");
  const TREE_DEPTH = 20;
  const WASM_PATH = path.join(__dirname, "../build/circuits/withdraw_js/withdraw.wasm");
  const ZKEY_PATH = path.join(__dirname, "../build/circuits/withdraw_final.zkey");

  let poseidon: any;
  let F: any;
  let poseidonContract: any; // deployed Poseidon hasher contract address

  before(async function () {
    // Check if circuit build artifacts exist
    if (!fs.existsSync(WASM_PATH) || !fs.existsSync(ZKEY_PATH)) {
      console.log("  ⚠️  Circuit build artifacts not found. Run: ./circuits/build.sh");
      this.skip();
    }
    poseidon = await circomlibjs.buildPoseidon();
    F = poseidon.F;

    // Deploy Poseidon hasher contract (from circomlibjs bytecode)
    const [deployer] = await ethers.getSigners();
    const poseidonBytecode = circomlibjs.poseidonContract.createCode(2);
    const poseidonAbi = circomlibjs.poseidonContract.generateABI(2);
    const PoseidonFactory = new ethers.ContractFactory(poseidonAbi, poseidonBytecode, deployer);
    poseidonContract = await PoseidonFactory.deploy();
    await poseidonContract.waitForDeployment();
  });

  async function deployFixture() {
    const [owner, alice, bob, relayer] = await ethers.getSigners();

    const MockToken = await ethers.getContractFactory("QFCToken");
    const qusd = await MockToken.deploy("qUSD Stablecoin", "qUSD", ethers.parseEther("1000000000"), ethers.parseEther("10000000"));

    const Verifier = await ethers.getContractFactory("Groth16Verifier");
    const verifier = await Verifier.deploy();

    const ShieldedPoolV2 = await ethers.getContractFactory("ShieldedPoolV2");
    const pool = await ShieldedPoolV2.deploy(
      await qusd.getAddress(),
      await verifier.getAddress(),
      await poseidonContract.getAddress()
    );

    await qusd.transfer(alice.address, ethers.parseEther("100000"));

    return { qusd, verifier, pool, owner, alice, bob, relayer };
  }

  // Poseidon hash helper (matches circom circuit)
  function poseidonHash(inputs: bigint[]): bigint {
    const hash = poseidon(inputs.map(x => F.e(x)));
    return F.toObject(hash);
  }

  // Build Merkle tree and generate proof path
  function buildMerkleProof(leaves: bigint[], leafIndex: number) {
    const depth = TREE_DEPTH;

    // Compute zero values
    let zeros: bigint[] = [];
    zeros[0] = poseidonHash([0n]); // zero leaf placeholder — but our tree uses keccak.
    // Actually the on-chain tree uses keccak, but circuit uses poseidon.
    // For E2E test we need them to match. Let's compute the tree ourselves with poseidon.

    // Pad leaves to next power of 2
    const treeSize = 2 ** depth;
    const paddedLeaves = [...leaves];

    // Compute zero hashes for empty leaves
    let zeroHash = 0n; // empty leaf
    const zeroHashes: bigint[] = [zeroHash];
    for (let i = 0; i < depth; i++) {
      zeroHash = poseidonHash([zeroHash, zeroHash]);
      zeroHashes.push(zeroHash);
    }

    // Build tree layer by layer
    let currentLayer = new Array(treeSize).fill(0n);
    for (let i = 0; i < paddedLeaves.length; i++) {
      currentLayer[i] = paddedLeaves[i];
    }

    const pathElements: bigint[] = [];
    const pathIndices: number[] = [];
    let idx = leafIndex;

    for (let level = 0; level < depth; level++) {
      const nextLayer: bigint[] = [];

      // Record sibling
      const siblingIdx = idx % 2 === 0 ? idx + 1 : idx - 1;
      pathElements.push(currentLayer[siblingIdx] || zeroHashes[level]);
      pathIndices.push(idx % 2);

      // Compute next layer
      for (let i = 0; i < currentLayer.length; i += 2) {
        const left = currentLayer[i] || zeroHashes[level];
        const right = currentLayer[i + 1] || zeroHashes[level];
        nextLayer.push(poseidonHash([left, right]));
      }

      currentLayer = nextLayer;
      idx = Math.floor(idx / 2);
    }

    const root = currentLayer[0];
    return { root, pathElements, pathIndices };
  }

  describe("Deposit", function () {
    it("should accept deposit with Poseidon commitment", async function () {
      const { pool, qusd, alice } = await loadFixture(deployFixture);

      const secret = BigInt(ethers.hexlify(ethers.randomBytes(31)));
      const nullifier = BigInt(ethers.hexlify(ethers.randomBytes(31)));
      const commitment = poseidonHash([secret, nullifier]);

      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000);

      await expect(pool.connect(alice).deposit(commitment, DENOM_1000))
        .to.emit(pool, "DepositMade");

      expect(await pool.depositCount()).to.equal(1);
      expect(await pool.commitmentExists(commitment)).to.be.true;
    });
  });

  describe("Withdraw with Groth16 Proof", function () {
    it("should complete full deposit → prove → withdraw cycle", async function () {
      const { pool, qusd, alice, bob } = await loadFixture(deployFixture);

      // 1. Generate secret & nullifier (field elements < BN128 scalar field)
      const secret = BigInt(ethers.hexlify(ethers.randomBytes(31)));
      const nullifier = BigInt(ethers.hexlify(ethers.randomBytes(31)));
      const commitment = poseidonHash([secret, nullifier]);
      const nullifierHash = poseidonHash([nullifier]);

      // 2. Deposit
      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000);
      await pool.connect(alice).deposit(commitment, DENOM_1000);

      // 3. Build Merkle proof (off-chain)
      const { root, pathElements, pathIndices } = buildMerkleProof([commitment], 0);

      // 4. Generate Groth16 proof
      const input = {
        // Public
        root: root.toString(),
        nullifierHash: nullifierHash.toString(),
        recipient: BigInt(bob.address).toString(),
        denomination: DENOM_1000.toString(),
        // Private
        secret: secret.toString(),
        nullifier: nullifier.toString(),
        pathElements: pathElements.map(e => e.toString()),
        pathIndices: pathIndices,
      };

      const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        input,
        WASM_PATH,
        ZKEY_PATH
      );

      // 5. Format proof for Solidity
      const pA: [bigint, bigint] = [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])];
      const pB: [[bigint, bigint], [bigint, bigint]] = [
        [BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])],
        [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])],
      ];
      const pC: [bigint, bigint] = [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])];

      // 6. Withdraw from a different address (bob)
      const bobBalBefore = await qusd.balanceOf(bob.address);

      await pool.connect(bob).withdraw(
        pA, pB, pC,
        root,
        nullifierHash,
        bob.address,
        ethers.ZeroAddress,
        DENOM_1000
      );

      const bobBalAfter = await qusd.balanceOf(bob.address);
      expect(bobBalAfter - bobBalBefore).to.equal(DENOM_1000);

      // 7. Verify nullifier is spent
      expect(await pool.nullifierUsed(nullifierHash)).to.be.true;
    });

    it("should reject double-spend", async function () {
      const { pool, qusd, alice, bob } = await loadFixture(deployFixture);

      const secret = BigInt(ethers.hexlify(ethers.randomBytes(31)));
      const nullifier = BigInt(ethers.hexlify(ethers.randomBytes(31)));
      const commitment = poseidonHash([secret, nullifier]);
      const nullifierHash = poseidonHash([nullifier]);

      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000);
      await pool.connect(alice).deposit(commitment, DENOM_1000);

      const { root, pathElements, pathIndices } = buildMerkleProof([commitment], 0);

      const input = {
        root: root.toString(),
        nullifierHash: nullifierHash.toString(),
        recipient: BigInt(bob.address).toString(),
        denomination: DENOM_1000.toString(),
        secret: secret.toString(),
        nullifier: nullifier.toString(),
        pathElements: pathElements.map(e => e.toString()),
        pathIndices: pathIndices,
      };

      const { proof } = await snarkjs.groth16.fullProve(input, WASM_PATH, ZKEY_PATH);

      const pA: [bigint, bigint] = [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])];
      const pB: [[bigint, bigint], [bigint, bigint]] = [
        [BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])],
        [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])],
      ];
      const pC: [bigint, bigint] = [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])];

      // First withdrawal succeeds
      await pool.connect(bob).withdraw(pA, pB, pC, root, nullifierHash, bob.address, ethers.ZeroAddress, DENOM_1000);

      // Second withdrawal fails
      await expect(
        pool.connect(bob).withdraw(pA, pB, pC, root, nullifierHash, bob.address, ethers.ZeroAddress, DENOM_1000)
      ).to.be.revertedWithCustomError(pool, "NullifierAlreadyUsed");
    });
  });

  describe("Admin", function () {
    it("should return pool balance", async function () {
      const { pool, qusd, alice } = await loadFixture(deployFixture);

      const secret = BigInt(ethers.hexlify(ethers.randomBytes(31)));
      const nullifier = BigInt(ethers.hexlify(ethers.randomBytes(31)));
      const commitment = poseidonHash([secret, nullifier]);

      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000);
      await pool.connect(alice).deposit(commitment, DENOM_1000);

      expect(await pool.getPoolBalance()).to.equal(DENOM_1000);
    });
  });
});
