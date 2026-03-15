import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("ShieldedPool (Privacy Pool)", function () {
  const DENOM_100 = ethers.parseEther("100");
  const DENOM_1000 = ethers.parseEther("1000");

  async function deployFixture() {
    const [owner, alice, bob, relayer] = await ethers.getSigners();

    // Deploy mock qUSD token
    const MockToken = await ethers.getContractFactory("QFCToken");
    const qusd = await MockToken.deploy("qUSD Stablecoin", "qUSD", ethers.parseEther("1000000000"), ethers.parseEther("10000000"));

    // Deploy ShieldedPool
    const ShieldedPool = await ethers.getContractFactory("ShieldedPool");
    const pool = await ShieldedPool.deploy(await qusd.getAddress());

    // Give alice and bob qUSD
    await qusd.transfer(alice.address, ethers.parseEther("100000"));
    await qusd.transfer(bob.address, ethers.parseEther("100000"));

    return { qusd, pool, owner, alice, bob, relayer };
  }

  // Helper: generate commitment from secret + nullifier
  function generateCommitment() {
    const secret = ethers.randomBytes(32);
    const nullifier = ethers.randomBytes(32);
    const commitment = ethers.keccak256(
      ethers.solidityPacked(["bytes32", "bytes32"], [secret, nullifier])
    );
    const nullifierHash = ethers.keccak256(
      ethers.solidityPacked(["bytes32"], [nullifier])
    );
    return { secret, nullifier, commitment, nullifierHash };
  }

  // Helper: encode proof
  function encodeProof(secret: Uint8Array, nullifier: Uint8Array, commitment: string) {
    return ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "bytes32", "bytes32"],
      [secret, nullifier, commitment]
    );
  }

  describe("Merkle Tree", function () {
    it("should initialize with valid root", async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.currentRoot()).to.not.equal(ethers.ZeroHash);
      expect(await pool.nextLeafIndex()).to.equal(0);
    });
  });

  describe("Deposit", function () {
    it("should accept a deposit and insert commitment into Merkle tree", async function () {
      const { pool, qusd, alice } = await loadFixture(deployFixture);
      const { commitment } = generateCommitment();

      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000);

      await expect(pool.connect(alice).deposit(commitment, DENOM_1000))
        .to.emit(pool, "DepositMade");

      expect(await pool.nextLeafIndex()).to.equal(1);
      expect(await pool.depositCount()).to.equal(1);

      const dep = await pool.deposits(commitment);
      expect(dep.commitment).to.equal(commitment);
      expect(dep.denomination).to.equal(DENOM_1000);
    });

    it("should reject unsupported denomination", async function () {
      const { pool, alice } = await loadFixture(deployFixture);
      const { commitment } = generateCommitment();

      await expect(pool.connect(alice).deposit(commitment, ethers.parseEther("500")))
        .to.be.revertedWithCustomError(pool, "InvalidDenomination");
    });

    it("should reject duplicate commitment", async function () {
      const { pool, qusd, alice } = await loadFixture(deployFixture);
      const { commitment } = generateCommitment();

      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000 * 2n);
      await pool.connect(alice).deposit(commitment, DENOM_1000);

      await expect(pool.connect(alice).deposit(commitment, DENOM_1000))
        .to.be.revertedWithCustomError(pool, "DuplicateCommitment");
    });

    it("should update Merkle root after deposit", async function () {
      const { pool, qusd, alice } = await loadFixture(deployFixture);
      const rootBefore = await pool.currentRoot();

      const { commitment } = generateCommitment();
      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_100);
      await pool.connect(alice).deposit(commitment, DENOM_100);

      const rootAfter = await pool.currentRoot();
      expect(rootAfter).to.not.equal(rootBefore);
    });

    it("should handle multiple deposits", async function () {
      const { pool, qusd, alice, bob } = await loadFixture(deployFixture);

      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000 * 3n);
      await qusd.connect(bob).approve(await pool.getAddress(), DENOM_1000 * 3n);

      for (let i = 0; i < 3; i++) {
        const { commitment } = generateCommitment();
        await pool.connect(alice).deposit(commitment, DENOM_1000);
      }

      expect(await pool.nextLeafIndex()).to.equal(3);
      expect(await pool.depositCount()).to.equal(3);
    });
  });

  describe("Withdraw", function () {
    it("should withdraw with valid proof", async function () {
      const { pool, qusd, alice, bob } = await loadFixture(deployFixture);
      const { secret, nullifier, commitment, nullifierHash } = generateCommitment();

      // Alice deposits
      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000);
      await pool.connect(alice).deposit(commitment, DENOM_1000);

      const root = await pool.currentRoot();
      const proof = encodeProof(secret, nullifier, commitment);

      // Bob withdraws (different address — that's the point!)
      const bobBalBefore = await qusd.balanceOf(bob.address);

      await expect(pool.connect(bob).withdraw(
        proof,
        root,
        nullifierHash,
        bob.address,
        ethers.ZeroAddress, // no relayer
        DENOM_1000
      )).to.emit(pool, "WithdrawalMade");

      const bobBalAfter = await qusd.balanceOf(bob.address);
      expect(bobBalAfter - bobBalBefore).to.equal(DENOM_1000);
    });

    it("should pay relayer fee on relayed withdrawal", async function () {
      const { pool, qusd, alice, bob, relayer } = await loadFixture(deployFixture);
      const { secret, nullifier, commitment, nullifierHash } = generateCommitment();

      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000);
      await pool.connect(alice).deposit(commitment, DENOM_1000);

      const root = await pool.currentRoot();
      const proof = encodeProof(secret, nullifier, commitment);

      const relayerBalBefore = await qusd.balanceOf(relayer.address);

      // 0.5% relayer fee on 1000 = 5 qUSD
      await pool.connect(relayer).withdraw(
        proof, root, nullifierHash, bob.address, relayer.address, DENOM_1000
      );

      const relayerBalAfter = await qusd.balanceOf(relayer.address);
      expect(relayerBalAfter - relayerBalBefore).to.equal(ethers.parseEther("5"));

      // Bob gets 995 qUSD
      expect(await qusd.balanceOf(bob.address)).to.equal(
        ethers.parseEther("100000") + ethers.parseEther("995")
      );
    });

    it("should reject double-spend (same nullifier)", async function () {
      const { pool, qusd, alice, bob } = await loadFixture(deployFixture);
      const { secret, nullifier, commitment, nullifierHash } = generateCommitment();

      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000);
      await pool.connect(alice).deposit(commitment, DENOM_1000);

      const root = await pool.currentRoot();
      const proof = encodeProof(secret, nullifier, commitment);

      await pool.connect(bob).withdraw(proof, root, nullifierHash, bob.address, ethers.ZeroAddress, DENOM_1000);

      await expect(pool.connect(bob).withdraw(proof, root, nullifierHash, bob.address, ethers.ZeroAddress, DENOM_1000))
        .to.be.revertedWithCustomError(pool, "NullifierAlreadyUsed");
    });

    it("should reject invalid proof", async function () {
      const { pool, qusd, alice, bob } = await loadFixture(deployFixture);
      const { commitment, nullifierHash } = generateCommitment();

      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000);
      await pool.connect(alice).deposit(commitment, DENOM_1000);

      const root = await pool.currentRoot();
      // Bad proof with wrong secret
      const fakeProof = encodeProof(ethers.randomBytes(32), ethers.randomBytes(32), commitment);

      await expect(pool.connect(bob).withdraw(fakeProof, root, nullifierHash, bob.address, ethers.ZeroAddress, DENOM_1000))
        .to.be.revertedWithCustomError(pool, "InvalidProof");
    });

    it("should reject wrong denomination", async function () {
      const { pool, qusd, alice, bob } = await loadFixture(deployFixture);
      const { secret, nullifier, commitment, nullifierHash } = generateCommitment();

      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000);
      await pool.connect(alice).deposit(commitment, DENOM_1000);

      const root = await pool.currentRoot();
      const proof = encodeProof(secret, nullifier, commitment);

      await expect(pool.connect(bob).withdraw(proof, root, nullifierHash, bob.address, ethers.ZeroAddress, DENOM_100))
        .to.be.revertedWithCustomError(pool, "InvalidProof");
    });

    it("should reject invalid root", async function () {
      const { pool, qusd, alice, bob } = await loadFixture(deployFixture);
      const { secret, nullifier, commitment, nullifierHash } = generateCommitment();

      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000);
      await pool.connect(alice).deposit(commitment, DENOM_1000);

      const proof = encodeProof(secret, nullifier, commitment);

      await expect(pool.connect(bob).withdraw(proof, ethers.randomBytes(32), nullifierHash, bob.address, ethers.ZeroAddress, DENOM_1000))
        .to.be.revertedWithCustomError(pool, "InvalidRoot");
    });
  });

  describe("Admin", function () {
    it("should add new denomination", async function () {
      const { pool } = await loadFixture(deployFixture);
      const newDenom = ethers.parseEther("500");

      await expect(pool.addDenomination(newDenom))
        .to.emit(pool, "DenominationAdded")
        .withArgs(newDenom);

      expect(await pool.supportedDenominations(newDenom)).to.be.true;
    });

    it("should reject duplicate denomination", async function () {
      const { pool } = await loadFixture(deployFixture);
      await expect(pool.addDenomination(DENOM_1000))
        .to.be.revertedWithCustomError(pool, "DenominationAlreadyExists");
    });

    it("should update relayer fee", async function () {
      const { pool } = await loadFixture(deployFixture);
      await pool.setRelayerFee(100); // 1%
      expect(await pool.relayerFeeBps()).to.equal(100);
    });

    it("should reject excessive relayer fee", async function () {
      const { pool } = await loadFixture(deployFixture);
      await expect(pool.setRelayerFee(600))
        .to.be.revertedWithCustomError(pool, "FeeTooHigh");
    });

    it("should pause and unpause", async function () {
      const { pool, qusd, alice } = await loadFixture(deployFixture);
      const { commitment } = generateCommitment();

      await pool.pause();
      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_100);
      await expect(pool.connect(alice).deposit(commitment, DENOM_100)).to.be.reverted;

      await pool.unpause();
      await expect(pool.connect(alice).deposit(commitment, DENOM_100)).to.not.be.reverted;
    });

    it("should return denominations list", async function () {
      const { pool } = await loadFixture(deployFixture);
      const denoms = await pool.getDenominations();
      expect(denoms.length).to.equal(4);
    });

    it("should return pool balance", async function () {
      const { pool, qusd, alice } = await loadFixture(deployFixture);

      await qusd.connect(alice).approve(await pool.getAddress(), DENOM_1000);
      const { commitment } = generateCommitment();
      await pool.connect(alice).deposit(commitment, DENOM_1000);

      expect(await pool.getPoolBalance()).to.equal(DENOM_1000);
    });
  });
});
