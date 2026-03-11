import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import {
  BridgeLock,
  BridgeMint,
  BridgeRelayerManager,
  WrappedToken,
} from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// Sentinel for native ETH
const NATIVE_TOKEN = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
const SRC_CHAIN_ID = 1; // Ethereum
const DEST_CHAIN_ID = 9000; // QFC

describe("QFC Cross-Chain Bridge", function () {
  // ── Fixture ─────────────────────────────────────────────────────────

  async function deployBridgeFixture() {
    const [owner, user, recipient, relayer1, relayer2, relayer3, relayer4, relayer5, nonRelayer] =
      await ethers.getSigners();

    const relayers = [relayer1, relayer2, relayer3, relayer4, relayer5];
    const relayerAddresses = relayers.map((r) => r.address);
    const quorum = 3;

    // Deploy RelayerManager
    const RelayerManager = await ethers.getContractFactory("BridgeRelayerManager");
    const relayerManager = await RelayerManager.deploy(relayerAddresses, quorum);
    await relayerManager.waitForDeployment();
    const relayerManagerAddr = await relayerManager.getAddress();

    // Deploy BridgeLock
    const BridgeLock = await ethers.getContractFactory("BridgeLock");
    const bridgeLock = await BridgeLock.deploy(relayerManagerAddr);
    await bridgeLock.waitForDeployment();

    // Deploy BridgeMint
    const BridgeMint = await ethers.getContractFactory("BridgeMint");
    const bridgeMint = await BridgeMint.deploy(relayerManagerAddr);
    await bridgeMint.waitForDeployment();
    const bridgeMintAddr = await bridgeMint.getAddress();

    // Deploy a mock ERC-20 for testing
    const MockToken = await ethers.getContractFactory("QFCToken");
    const mockToken = await MockToken.deploy(
      "Mock Token",
      "MOCK",
      ethers.parseEther("1000000000"),
      ethers.parseEther("1000000")
    );
    await mockToken.waitForDeployment();

    // Deploy WrappedToken (wETH)
    const WrappedToken = await ethers.getContractFactory("WrappedToken");
    const wETH = await WrappedToken.deploy("Wrapped Ether", "wETH", bridgeMintAddr, 18);
    await wETH.waitForDeployment();

    // Deploy WrappedToken for mock ERC-20
    const wMOCK = await WrappedToken.deploy("Wrapped Mock", "wMOCK", bridgeMintAddr, 18);
    await wMOCK.waitForDeployment();

    // Register wrapped tokens
    const mockTokenAddr = await mockToken.getAddress();
    await bridgeMint.registerWrappedToken(NATIVE_TOKEN, await wETH.getAddress());
    await bridgeMint.registerWrappedToken(mockTokenAddr, await wMOCK.getAddress());

    // Transfer some mock tokens to user
    await mockToken.transfer(user.address, ethers.parseEther("10000"));

    return {
      owner,
      user,
      recipient,
      relayers,
      relayer1,
      relayer2,
      relayer3,
      relayer4,
      relayer5,
      nonRelayer,
      relayerManager,
      bridgeLock,
      bridgeMint,
      mockToken,
      wETH,
      wMOCK,
    };
  }

  // ── Helper: sign a message hash with multiple relayers ──────────────

  async function signWithRelayers(
    hash: string,
    signers: HardhatEthersSigner[]
  ): Promise<string[]> {
    // Sort signers by address (ascending) for valid signature ordering
    const sorted = [...signers].sort((a, b) =>
      a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1
    );
    const signatures: string[] = [];
    for (const signer of sorted) {
      const sig = await signer.signMessage(ethers.getBytes(hash));
      signatures.push(sig);
    }
    return signatures;
  }

  // ══════════════════════════════════════════════════════════════════════
  // BridgeRelayerManager
  // ══════════════════════════════════════════════════════════════════════

  describe("BridgeRelayerManager", function () {
    describe("Deployment", function () {
      it("Should initialize with correct relayers and quorum", async function () {
        const { relayerManager, relayer1, relayer2, relayer3 } = await loadFixture(
          deployBridgeFixture
        );
        expect(await relayerManager.quorum()).to.equal(3);
        expect(await relayerManager.relayerCount()).to.equal(5);
        expect(await relayerManager.isRelayer(relayer1.address)).to.be.true;
        expect(await relayerManager.isRelayer(relayer2.address)).to.be.true;
        expect(await relayerManager.isRelayer(relayer3.address)).to.be.true;
      });
    });

    describe("Relayer Management", function () {
      it("Should add a new relayer", async function () {
        const { relayerManager, nonRelayer } = await loadFixture(deployBridgeFixture);
        await expect(relayerManager.addRelayer(nonRelayer.address))
          .to.emit(relayerManager, "RelayerAdded")
          .withArgs(nonRelayer.address);
        expect(await relayerManager.isRelayer(nonRelayer.address)).to.be.true;
        expect(await relayerManager.relayerCount()).to.equal(6);
      });

      it("Should remove a relayer", async function () {
        const { relayerManager, relayer5 } = await loadFixture(deployBridgeFixture);
        await expect(relayerManager.removeRelayer(relayer5.address))
          .to.emit(relayerManager, "RelayerRemoved")
          .withArgs(relayer5.address);
        expect(await relayerManager.isRelayer(relayer5.address)).to.be.false;
        expect(await relayerManager.relayerCount()).to.equal(4);
      });

      it("Should revert adding duplicate relayer", async function () {
        const { relayerManager, relayer1 } = await loadFixture(deployBridgeFixture);
        await expect(relayerManager.addRelayer(relayer1.address))
          .to.be.revertedWithCustomError(relayerManager, "AlreadyRelayer");
      });

      it("Should revert removing non-relayer", async function () {
        const { relayerManager, nonRelayer } = await loadFixture(deployBridgeFixture);
        await expect(relayerManager.removeRelayer(nonRelayer.address))
          .to.be.revertedWithCustomError(relayerManager, "NotRelayer");
      });

      it("Should revert removing relayer if it would break quorum", async function () {
        const { relayerManager, relayer1, relayer2, relayer3, relayer4, relayer5 } =
          await loadFixture(deployBridgeFixture);
        // Remove until only quorum remains
        await relayerManager.removeRelayer(relayer5.address);
        await relayerManager.removeRelayer(relayer4.address);
        // Now 3 relayers = quorum, removing another should fail
        await expect(relayerManager.removeRelayer(relayer3.address))
          .to.be.revertedWithCustomError(relayerManager, "InvalidQuorum");
      });

      it("Should only allow owner to manage relayers", async function () {
        const { relayerManager, user, nonRelayer } = await loadFixture(deployBridgeFixture);
        await expect(relayerManager.connect(user).addRelayer(nonRelayer.address))
          .to.be.revertedWithCustomError(relayerManager, "OwnableUnauthorizedAccount");
      });
    });

    describe("Signature Validation", function () {
      it("Should validate 3-of-5 signatures", async function () {
        const { relayerManager, relayer1, relayer2, relayer3 } = await loadFixture(
          deployBridgeFixture
        );
        const hash = ethers.keccak256(ethers.toUtf8Bytes("test message"));
        const signatures = await signWithRelayers(hash, [relayer1, relayer2, relayer3]);
        expect(await relayerManager.isValidSignatureSet(hash, signatures)).to.be.true;
      });

      it("Should reject insufficient signatures", async function () {
        const { relayerManager, relayer1, relayer2 } = await loadFixture(deployBridgeFixture);
        const hash = ethers.keccak256(ethers.toUtf8Bytes("test message"));
        const signatures = await signWithRelayers(hash, [relayer1, relayer2]);
        await expect(relayerManager.isValidSignatureSet(hash, signatures))
          .to.be.revertedWithCustomError(relayerManager, "InsufficientSignatures");
      });

      it("Should reject signatures from non-relayers", async function () {
        const { relayerManager, relayer1, relayer2, nonRelayer } = await loadFixture(
          deployBridgeFixture
        );
        const hash = ethers.keccak256(ethers.toUtf8Bytes("test message"));
        const signatures = await signWithRelayers(hash, [relayer1, relayer2, nonRelayer]);
        // 2 valid + 1 invalid = only 2 valid, less than quorum of 3
        expect(await relayerManager.isValidSignatureSet(hash, signatures)).to.be.false;
      });
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // BridgeLock
  // ══════════════════════════════════════════════════════════════════════

  describe("BridgeLock", function () {
    describe("Lock ERC-20", function () {
      it("Should lock ERC-20 tokens and emit BridgeRequest", async function () {
        const { bridgeLock, mockToken, user, recipient } = await loadFixture(
          deployBridgeFixture
        );
        const amount = ethers.parseEther("1000");
        const fee = amount / 10000n * 10n; // 0.1%
        const netAmount = amount - fee;

        const bridgeLockAddr = await bridgeLock.getAddress();
        await mockToken.connect(user).approve(bridgeLockAddr, amount);

        await expect(
          bridgeLock.connect(user).lock(
            await mockToken.getAddress(),
            amount,
            DEST_CHAIN_ID,
            recipient.address
          )
        )
          .to.emit(bridgeLock, "BridgeRequest")
          .withArgs(
            0, // nonce
            await mockToken.getAddress(),
            user.address,
            netAmount,
            fee,
            DEST_CHAIN_ID,
            recipient.address
          );

        // Verify tokens were transferred to bridge
        expect(await mockToken.balanceOf(bridgeLockAddr)).to.equal(amount);
      });

      it("Should increment nonce on each lock", async function () {
        const { bridgeLock, mockToken, user, recipient } = await loadFixture(
          deployBridgeFixture
        );
        const amount = ethers.parseEther("100");
        const bridgeLockAddr = await bridgeLock.getAddress();
        await mockToken.connect(user).approve(bridgeLockAddr, amount * 2n);

        await bridgeLock
          .connect(user)
          .lock(await mockToken.getAddress(), amount, DEST_CHAIN_ID, recipient.address);
        await bridgeLock
          .connect(user)
          .lock(await mockToken.getAddress(), amount, DEST_CHAIN_ID, recipient.address);

        expect(await bridgeLock.nonce()).to.equal(2);
      });

      it("Should revert lock with zero amount", async function () {
        const { bridgeLock, mockToken, user, recipient } = await loadFixture(
          deployBridgeFixture
        );
        await expect(
          bridgeLock
            .connect(user)
            .lock(await mockToken.getAddress(), 0, DEST_CHAIN_ID, recipient.address)
        ).to.be.revertedWithCustomError(bridgeLock, "ZeroAmount");
      });
    });

    describe("Lock ETH", function () {
      it("Should lock native ETH and emit BridgeRequest", async function () {
        const { bridgeLock, user, recipient } = await loadFixture(deployBridgeFixture);
        const amount = ethers.parseEther("1");
        const fee = amount / 10000n * 10n;
        const netAmount = amount - fee;

        await expect(
          bridgeLock
            .connect(user)
            .lockETH(DEST_CHAIN_ID, recipient.address, { value: amount })
        )
          .to.emit(bridgeLock, "BridgeRequest")
          .withArgs(0, NATIVE_TOKEN, user.address, netAmount, fee, DEST_CHAIN_ID, recipient.address);
      });

      it("Should revert lockETH with zero value", async function () {
        const { bridgeLock, user, recipient } = await loadFixture(deployBridgeFixture);
        await expect(
          bridgeLock.connect(user).lockETH(DEST_CHAIN_ID, recipient.address, { value: 0 })
        ).to.be.revertedWithCustomError(bridgeLock, "ZeroAmount");
      });
    });

    describe("Fee Collection", function () {
      it("Should track collected fees", async function () {
        const { bridgeLock, mockToken, user, recipient } = await loadFixture(
          deployBridgeFixture
        );
        const amount = ethers.parseEther("1000");
        const expectedFee = amount / 10000n * 10n;

        const bridgeLockAddr = await bridgeLock.getAddress();
        await mockToken.connect(user).approve(bridgeLockAddr, amount);
        await bridgeLock
          .connect(user)
          .lock(await mockToken.getAddress(), amount, DEST_CHAIN_ID, recipient.address);

        expect(await bridgeLock.collectedFees(await mockToken.getAddress())).to.equal(
          expectedFee
        );
      });

      it("Should allow owner to withdraw fees", async function () {
        const { bridgeLock, mockToken, owner, user, recipient } = await loadFixture(
          deployBridgeFixture
        );
        const amount = ethers.parseEther("1000");
        const bridgeLockAddr = await bridgeLock.getAddress();
        await mockToken.connect(user).approve(bridgeLockAddr, amount);
        await bridgeLock
          .connect(user)
          .lock(await mockToken.getAddress(), amount, DEST_CHAIN_ID, recipient.address);

        const fees = await bridgeLock.collectedFees(await mockToken.getAddress());

        await expect(bridgeLock.withdrawFees(await mockToken.getAddress(), owner.address))
          .to.emit(bridgeLock, "FeesWithdrawn")
          .withArgs(await mockToken.getAddress(), owner.address, fees);
      });

      it("Should revert fee withdrawal with no fees", async function () {
        const { bridgeLock, mockToken, owner } = await loadFixture(deployBridgeFixture);
        await expect(
          bridgeLock.withdrawFees(await mockToken.getAddress(), owner.address)
        ).to.be.revertedWithCustomError(bridgeLock, "NoFeesToWithdraw");
      });
    });

    describe("Unlock", function () {
      it("Should unlock ERC-20 tokens with valid signatures", async function () {
        const { bridgeLock, mockToken, user, recipient, relayer1, relayer2, relayer3, owner } =
          await loadFixture(deployBridgeFixture);

        // First lock tokens so bridge has funds
        const amount = ethers.parseEther("1000");
        const bridgeLockAddr = await bridgeLock.getAddress();
        await mockToken.connect(user).approve(bridgeLockAddr, amount);
        await bridgeLock
          .connect(user)
          .lock(await mockToken.getAddress(), amount, DEST_CHAIN_ID, recipient.address);

        // Now unlock
        const unlockAmount = ethers.parseEther("500");
        const unlockNonce = 0;
        const tokenAddr = await mockToken.getAddress();

        const messageHash = ethers.keccak256(
          ethers.solidityPacked(
            ["address", "address", "uint256", "uint256", "uint256"],
            [tokenAddr, recipient.address, unlockAmount, SRC_CHAIN_ID, unlockNonce]
          )
        );

        const signatures = await signWithRelayers(messageHash, [relayer1, relayer2, relayer3]);

        await expect(
          bridgeLock.unlock(tokenAddr, recipient.address, unlockAmount, SRC_CHAIN_ID, unlockNonce, signatures)
        ).to.emit(bridgeLock, "Unlocked");

        expect(await mockToken.balanceOf(recipient.address)).to.equal(unlockAmount);
      });

      it("Should reject replay of processed unlock", async function () {
        const { bridgeLock, mockToken, user, recipient, relayer1, relayer2, relayer3 } =
          await loadFixture(deployBridgeFixture);

        const amount = ethers.parseEther("1000");
        const bridgeLockAddr = await bridgeLock.getAddress();
        await mockToken.connect(user).approve(bridgeLockAddr, amount);
        await bridgeLock
          .connect(user)
          .lock(await mockToken.getAddress(), amount, DEST_CHAIN_ID, recipient.address);

        const unlockAmount = ethers.parseEther("100");
        const tokenAddr = await mockToken.getAddress();

        const messageHash = ethers.keccak256(
          ethers.solidityPacked(
            ["address", "address", "uint256", "uint256", "uint256"],
            [tokenAddr, recipient.address, unlockAmount, SRC_CHAIN_ID, 0]
          )
        );

        const signatures = await signWithRelayers(messageHash, [relayer1, relayer2, relayer3]);

        // First unlock succeeds
        await bridgeLock.unlock(tokenAddr, recipient.address, unlockAmount, SRC_CHAIN_ID, 0, signatures);

        // Replay should fail
        await expect(
          bridgeLock.unlock(tokenAddr, recipient.address, unlockAmount, SRC_CHAIN_ID, 0, signatures)
        ).to.be.revertedWithCustomError(bridgeLock, "AlreadyProcessed");
      });
    });

    describe("Pause", function () {
      it("Should pause and unpause", async function () {
        const { bridgeLock, mockToken, user, recipient } = await loadFixture(
          deployBridgeFixture
        );

        await bridgeLock.pause();

        await expect(
          bridgeLock.connect(user).lockETH(DEST_CHAIN_ID, recipient.address, { value: 1000 })
        ).to.be.revertedWithCustomError(bridgeLock, "EnforcedPause");

        await bridgeLock.unpause();

        // Should work again
        await expect(
          bridgeLock.connect(user).lockETH(DEST_CHAIN_ID, recipient.address, { value: 1000 })
        ).to.emit(bridgeLock, "BridgeRequest");
      });

      it("Should only allow owner to pause", async function () {
        const { bridgeLock, user } = await loadFixture(deployBridgeFixture);
        await expect(bridgeLock.connect(user).pause())
          .to.be.revertedWithCustomError(bridgeLock, "OwnableUnauthorizedAccount");
      });
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // BridgeMint
  // ══════════════════════════════════════════════════════════════════════

  describe("BridgeMint", function () {
    describe("Mint", function () {
      it("Should mint wrapped tokens with valid signatures", async function () {
        const { bridgeMint, wETH, recipient, relayer1, relayer2, relayer3 } = await loadFixture(
          deployBridgeFixture
        );

        const amount = ethers.parseEther("5");
        const nonce = 0;

        const messageHash = ethers.keccak256(
          ethers.solidityPacked(
            ["address", "address", "uint256", "uint256", "uint256"],
            [NATIVE_TOKEN, recipient.address, amount, SRC_CHAIN_ID, nonce]
          )
        );

        const signatures = await signWithRelayers(messageHash, [relayer1, relayer2, relayer3]);

        await expect(
          bridgeMint.mint(NATIVE_TOKEN, recipient.address, amount, SRC_CHAIN_ID, nonce, signatures)
        )
          .to.emit(bridgeMint, "TokenMinted")
          .withArgs(
            NATIVE_TOKEN,
            await wETH.getAddress(),
            recipient.address,
            amount,
            SRC_CHAIN_ID,
            nonce
          );

        expect(await wETH.balanceOf(recipient.address)).to.equal(amount);
      });

      it("Should reject mint with insufficient signatures", async function () {
        const { bridgeMint, recipient, relayer1, relayer2 } = await loadFixture(
          deployBridgeFixture
        );

        const amount = ethers.parseEther("5");
        const messageHash = ethers.keccak256(
          ethers.solidityPacked(
            ["address", "address", "uint256", "uint256", "uint256"],
            [NATIVE_TOKEN, recipient.address, amount, SRC_CHAIN_ID, 0]
          )
        );

        const signatures = await signWithRelayers(messageHash, [relayer1, relayer2]);

        await expect(
          bridgeMint.mint(NATIVE_TOKEN, recipient.address, amount, SRC_CHAIN_ID, 0, signatures)
        ).to.be.reverted;
      });

      it("Should reject mint for unregistered token", async function () {
        const { bridgeMint, recipient, relayer1, relayer2, relayer3 } = await loadFixture(
          deployBridgeFixture
        );

        const fakeToken = "0x0000000000000000000000000000000000000001";
        const amount = ethers.parseEther("5");

        const messageHash = ethers.keccak256(
          ethers.solidityPacked(
            ["address", "address", "uint256", "uint256", "uint256"],
            [fakeToken, recipient.address, amount, SRC_CHAIN_ID, 0]
          )
        );

        const signatures = await signWithRelayers(messageHash, [relayer1, relayer2, relayer3]);

        await expect(
          bridgeMint.mint(fakeToken, recipient.address, amount, SRC_CHAIN_ID, 0, signatures)
        ).to.be.revertedWithCustomError(bridgeMint, "TokenNotRegistered");
      });
    });

    describe("Replay Protection", function () {
      it("Should reject duplicate mint with same nonce", async function () {
        const { bridgeMint, recipient, relayer1, relayer2, relayer3 } = await loadFixture(
          deployBridgeFixture
        );

        const amount = ethers.parseEther("5");
        const nonce = 42;

        const messageHash = ethers.keccak256(
          ethers.solidityPacked(
            ["address", "address", "uint256", "uint256", "uint256"],
            [NATIVE_TOKEN, recipient.address, amount, SRC_CHAIN_ID, nonce]
          )
        );

        const signatures = await signWithRelayers(messageHash, [relayer1, relayer2, relayer3]);

        // First mint succeeds
        await bridgeMint.mint(
          NATIVE_TOKEN,
          recipient.address,
          amount,
          SRC_CHAIN_ID,
          nonce,
          signatures
        );

        // Replay should fail
        await expect(
          bridgeMint.mint(NATIVE_TOKEN, recipient.address, amount, SRC_CHAIN_ID, nonce, signatures)
        ).to.be.revertedWithCustomError(bridgeMint, "AlreadyProcessed");
      });
    });

    describe("Burn (Bridge Back)", function () {
      it("Should burn wrapped tokens and emit BurnRequest", async function () {
        const { bridgeMint, wETH, recipient, relayer1, relayer2, relayer3 } = await loadFixture(
          deployBridgeFixture
        );

        // First mint some wrapped tokens
        const amount = ethers.parseEther("10");
        const messageHash = ethers.keccak256(
          ethers.solidityPacked(
            ["address", "address", "uint256", "uint256", "uint256"],
            [NATIVE_TOKEN, recipient.address, amount, SRC_CHAIN_ID, 0]
          )
        );
        const signatures = await signWithRelayers(messageHash, [relayer1, relayer2, relayer3]);
        await bridgeMint.mint(NATIVE_TOKEN, recipient.address, amount, SRC_CHAIN_ID, 0, signatures);

        // Now burn to bridge back
        const burnAmount = ethers.parseEther("3");
        const destRecipient = recipient.address; // same address on dest chain

        await expect(
          bridgeMint
            .connect(recipient)
            .burn(NATIVE_TOKEN, burnAmount, SRC_CHAIN_ID, destRecipient)
        )
          .to.emit(bridgeMint, "BurnRequest")
          .withArgs(0, await wETH.getAddress(), recipient.address, burnAmount, SRC_CHAIN_ID, destRecipient);

        // Verify balance decreased
        expect(await wETH.balanceOf(recipient.address)).to.equal(amount - burnAmount);
      });

      it("Should revert burn with zero amount", async function () {
        const { bridgeMint, recipient } = await loadFixture(deployBridgeFixture);
        await expect(
          bridgeMint.connect(recipient).burn(NATIVE_TOKEN, 0, SRC_CHAIN_ID, recipient.address)
        ).to.be.revertedWithCustomError(bridgeMint, "ZeroAmount");
      });
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // WrappedToken
  // ══════════════════════════════════════════════════════════════════════

  describe("WrappedToken", function () {
    it("Should only allow bridge to mint", async function () {
      const { wETH, user } = await loadFixture(deployBridgeFixture);
      await expect(
        wETH.connect(user).mint(user.address, ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(wETH, "OnlyBridge");
    });

    it("Should only allow bridge to burn", async function () {
      const { wETH, user } = await loadFixture(deployBridgeFixture);
      await expect(
        wETH.connect(user).bridgeBurn(user.address, ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(wETH, "OnlyBridge");
    });

    it("Should return correct decimals", async function () {
      const { wETH } = await loadFixture(deployBridgeFixture);
      expect(await wETH.decimals()).to.equal(18);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // End-to-End Flow
  // ══════════════════════════════════════════════════════════════════════

  describe("End-to-End: Lock → Mint → Burn → Unlock", function () {
    it("Should complete full bridge round-trip for ERC-20", async function () {
      const {
        bridgeLock,
        bridgeMint,
        mockToken,
        wMOCK,
        user,
        recipient,
        relayer1,
        relayer2,
        relayer3,
      } = await loadFixture(deployBridgeFixture);

      const lockAmount = ethers.parseEther("1000");
      const fee = lockAmount / 10000n * 10n;
      const netAmount = lockAmount - fee;
      const mockTokenAddr = await mockToken.getAddress();
      const bridgeLockAddr = await bridgeLock.getAddress();

      // Step 1: Lock tokens on source chain
      await mockToken.connect(user).approve(bridgeLockAddr, lockAmount);
      await bridgeLock
        .connect(user)
        .lock(mockTokenAddr, lockAmount, DEST_CHAIN_ID, recipient.address);

      expect(await mockToken.balanceOf(bridgeLockAddr)).to.equal(lockAmount);

      // Step 2: Mint wrapped tokens on QFC chain (relayers validate)
      const mintHash = ethers.keccak256(
        ethers.solidityPacked(
          ["address", "address", "uint256", "uint256", "uint256"],
          [mockTokenAddr, recipient.address, netAmount, SRC_CHAIN_ID, 0]
        )
      );
      const mintSigs = await signWithRelayers(mintHash, [relayer1, relayer2, relayer3]);
      await bridgeMint.mint(mockTokenAddr, recipient.address, netAmount, SRC_CHAIN_ID, 0, mintSigs);

      expect(await wMOCK.balanceOf(recipient.address)).to.equal(netAmount);

      // Step 3: Burn wrapped tokens to bridge back
      const burnAmount = ethers.parseEther("500");
      await bridgeMint
        .connect(recipient)
        .burn(mockTokenAddr, burnAmount, SRC_CHAIN_ID, recipient.address);

      expect(await wMOCK.balanceOf(recipient.address)).to.equal(netAmount - burnAmount);

      // Step 4: Unlock on source chain (relayers validate burn)
      const unlockHash = ethers.keccak256(
        ethers.solidityPacked(
          ["address", "address", "uint256", "uint256", "uint256"],
          [mockTokenAddr, recipient.address, burnAmount, DEST_CHAIN_ID, 0]
        )
      );
      const unlockSigs = await signWithRelayers(unlockHash, [relayer1, relayer2, relayer3]);
      await bridgeLock.unlock(
        mockTokenAddr,
        recipient.address,
        burnAmount,
        DEST_CHAIN_ID,
        0,
        unlockSigs
      );

      expect(await mockToken.balanceOf(recipient.address)).to.equal(burnAmount);
    });
  });
});
