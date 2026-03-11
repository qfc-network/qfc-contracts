import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { QFCAgentAccount, QFCAccountFactory, QFCPaymaster, MockEntryPoint } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("AgentWallet", function () {
  async function deployFixture() {
    const [owner, sessionKeySigner, user, sponsor, beneficiary] = await ethers.getSigners();

    // Deploy MockEntryPoint
    const MockEP = await ethers.getContractFactory("MockEntryPoint");
    const entryPoint = await MockEP.deploy();

    // Deploy Factory (which also deploys the implementation)
    const Factory = await ethers.getContractFactory("QFCAccountFactory");
    const factory = await Factory.deploy(await entryPoint.getAddress());

    // Create an account via factory
    const salt = 0;
    const tx = await factory.createAccount(owner.address, salt);
    const receipt = await tx.wait();
    const accountAddr = await factory.getAccountAddress(owner.address, salt);
    const account = await ethers.getContractAt("QFCAgentAccount", accountAddr) as unknown as QFCAgentAccount;

    // Fund the account
    await owner.sendTransaction({ to: accountAddr, value: ethers.parseEther("10") });

    // Deploy Paymaster
    const PM = await ethers.getContractFactory("QFCPaymaster");
    const paymaster = await PM.deploy(await entryPoint.getAddress());

    return { owner, sessionKeySigner, user, sponsor, beneficiary, entryPoint, factory, account, paymaster, accountAddr, salt };
  }

  describe("Account Creation", function () {
    it("Should create account and store address", async function () {
      const { factory, owner } = await loadFixture(deployFixture);
      const tx = await factory.createAccount(owner.address, 42);
      await tx.wait();
      const addr = await factory.getAccountAddress(owner.address, 42);
      expect(addr).to.not.equal(ethers.ZeroAddress);
      const code = await ethers.provider.getCode(addr);
      expect(code).to.not.equal("0x");
    });

    it("Should revert on duplicate account creation", async function () {
      const { factory, owner, salt } = await loadFixture(deployFixture);
      await expect(factory.createAccount(owner.address, salt))
        .to.be.revertedWithCustomError(factory, "AccountAlreadyDeployed");
    });

    it("Should initialize owner correctly", async function () {
      const { account, owner } = await loadFixture(deployFixture);
      expect(await account.owner()).to.equal(owner.address);
    });

    it("Should set entryPoint correctly", async function () {
      const { account, entryPoint } = await loadFixture(deployFixture);
      expect(await account.entryPoint()).to.equal(await entryPoint.getAddress());
    });
  });

  describe("Session Keys", function () {
    it("Should add a session key", async function () {
      const { account, owner, sessionKeySigner } = await loadFixture(deployFixture);

      const PERM_INFERENCE = 0x01;
      const spendingLimit = ethers.parseEther("1");
      const periodDuration = 86400; // 1 day
      const ttl = 3600; // 1 hour

      await expect(account.connect(owner).addSessionKey(
        sessionKeySigner.address, PERM_INFERENCE, spendingLimit, periodDuration, ttl
      )).to.emit(account, "SessionKeyAdded");

      const sk = await account.sessionKeys(sessionKeySigner.address);
      expect(sk.active).to.be.true;
      expect(sk.permissions).to.equal(PERM_INFERENCE);
      expect(sk.spendingLimit).to.equal(spendingLimit);
    });

    it("Should remove a session key", async function () {
      const { account, owner, sessionKeySigner } = await loadFixture(deployFixture);
      await account.connect(owner).addSessionKey(sessionKeySigner.address, 0x01, ethers.parseEther("1"), 86400, 3600);
      await expect(account.connect(owner).removeSessionKey(sessionKeySigner.address))
        .to.emit(account, "SessionKeyRemoved")
        .withArgs(sessionKeySigner.address);

      const sk = await account.sessionKeys(sessionKeySigner.address);
      expect(sk.active).to.be.false;
    });

    it("Should reject session key management from non-owner", async function () {
      const { account, user, sessionKeySigner } = await loadFixture(deployFixture);
      await expect(account.connect(user).addSessionKey(sessionKeySigner.address, 0x01, 0, 86400, 3600))
        .to.be.revertedWithCustomError(account, "NotOwner");
    });

    it("Should validate owner signature in validateUserOp", async function () {
      const { account, owner, entryPoint, accountAddr } = await loadFixture(deployFixture);

      // Create a fake userOp
      const callData = account.interface.encodeFunctionData("execute", [
        owner.address, 0, "0x"
      ]);
      const userOp = {
        sender: accountAddr,
        nonce: 0,
        initCode: "0x",
        callData: callData,
        accountGasLimits: ethers.zeroPadValue("0x", 32),
        preVerificationGas: 0,
        gasFees: ethers.zeroPadValue("0x", 32),
        paymasterAndData: "0x",
        signature: "0x"
      };

      const userOpHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["address", "uint256", "bytes"],
          [userOp.sender, userOp.nonce, userOp.callData]
        )
      );

      // Sign as owner
      const ethHash = ethers.hashMessage(ethers.getBytes(userOpHash));
      const signature = await owner.signMessage(ethers.getBytes(userOpHash));
      userOp.signature = signature;

      // Call validateUserOp from entryPoint
      const epAddr = await entryPoint.getAddress();
      const accountAsEP = account.connect(await ethers.getImpersonatedSigner(epAddr));
      // Fund the impersonated signer
      await owner.sendTransaction({ to: epAddr, value: ethers.parseEther("1") });

      const result = await accountAsEP.validateUserOp.staticCall(userOp, userOpHash, 0);
      expect(result).to.equal(0); // SIG_VALIDATION_SUCCESS
    });

    it("Should validate session key signature in validateUserOp", async function () {
      const { account, owner, sessionKeySigner, entryPoint, accountAddr } = await loadFixture(deployFixture);

      // Add session key
      await account.connect(owner).addSessionKey(sessionKeySigner.address, 0xFF, ethers.parseEther("10"), 86400, 7200);

      const callData = account.interface.encodeFunctionData("execute", [
        owner.address, 0, "0x"
      ]);
      const userOp = {
        sender: accountAddr,
        nonce: 0,
        initCode: "0x",
        callData: callData,
        accountGasLimits: ethers.zeroPadValue("0x", 32),
        preVerificationGas: 0,
        gasFees: ethers.zeroPadValue("0x", 32),
        paymasterAndData: "0x",
        signature: "0x"
      };

      const userOpHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["address", "uint256", "bytes"],
          [userOp.sender, userOp.nonce, userOp.callData]
        )
      );

      // Sign with session key
      userOp.signature = await sessionKeySigner.signMessage(ethers.getBytes(userOpHash));

      const epAddr = await entryPoint.getAddress();
      await owner.sendTransaction({ to: epAddr, value: ethers.parseEther("1") });
      const accountAsEP = account.connect(await ethers.getImpersonatedSigner(epAddr));

      const result = await accountAsEP.validateUserOp.staticCall(userOp, userOpHash, 0);
      // Should return packed validation data with validUntil (not 0 and not 1)
      expect(result).to.not.equal(1); // not SIG_VALIDATION_FAILED
    });

    it("Should reject invalid signature", async function () {
      const { account, owner, user, entryPoint, accountAddr } = await loadFixture(deployFixture);

      const userOp = {
        sender: accountAddr,
        nonce: 0,
        initCode: "0x",
        callData: "0x",
        accountGasLimits: ethers.zeroPadValue("0x", 32),
        preVerificationGas: 0,
        gasFees: ethers.zeroPadValue("0x", 32),
        paymasterAndData: "0x",
        signature: "0x"
      };

      const userOpHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["address", "uint256", "bytes"],
          [userOp.sender, userOp.nonce, userOp.callData]
        )
      );

      // Sign with random user (not owner, not session key)
      userOp.signature = await user.signMessage(ethers.getBytes(userOpHash));

      const epAddr = await entryPoint.getAddress();
      await owner.sendTransaction({ to: epAddr, value: ethers.parseEther("1") });
      const accountAsEP = account.connect(await ethers.getImpersonatedSigner(epAddr));

      const result = await accountAsEP.validateUserOp.staticCall(userOp, userOpHash, 0);
      expect(result).to.equal(1); // SIG_VALIDATION_FAILED
    });

    it("Should reject expired session key", async function () {
      const { account, owner, sessionKeySigner, entryPoint, accountAddr } = await loadFixture(deployFixture);

      // Add session key with 1 second TTL
      await account.connect(owner).addSessionKey(sessionKeySigner.address, 0xFF, ethers.parseEther("10"), 86400, 1);

      // Advance time past expiry
      await time.increase(10);

      const userOp = {
        sender: accountAddr,
        nonce: 0,
        initCode: "0x",
        callData: "0x",
        accountGasLimits: ethers.zeroPadValue("0x", 32),
        preVerificationGas: 0,
        gasFees: ethers.zeroPadValue("0x", 32),
        paymasterAndData: "0x",
        signature: "0x"
      };

      const userOpHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["address", "uint256", "bytes"],
          [userOp.sender, userOp.nonce, userOp.callData]
        )
      );

      userOp.signature = await sessionKeySigner.signMessage(ethers.getBytes(userOpHash));

      const epAddr = await entryPoint.getAddress();
      await owner.sendTransaction({ to: epAddr, value: ethers.parseEther("1") });
      const accountAsEP = account.connect(await ethers.getImpersonatedSigner(epAddr));

      const result = await accountAsEP.validateUserOp.staticCall(userOp, userOpHash, 0);
      expect(result).to.equal(1); // SIG_VALIDATION_FAILED (expired)
    });
  });

  describe("Execution with Policy Enforcement", function () {
    it("Should execute a simple ETH transfer", async function () {
      const { account, owner, user } = await loadFixture(deployFixture);
      const balBefore = await ethers.provider.getBalance(user.address);
      await account.connect(owner).execute(user.address, ethers.parseEther("1"), "0x");
      const balAfter = await ethers.provider.getBalance(user.address);
      expect(balAfter - balBefore).to.equal(ethers.parseEther("1"));
    });

    it("Should enforce per-tx limit", async function () {
      const { account, owner, user } = await loadFixture(deployFixture);
      await account.connect(owner).setPerTxLimit(ethers.parseEther("0.5"));
      await expect(account.connect(owner).execute(user.address, ethers.parseEther("1"), "0x"))
        .to.be.revertedWithCustomError({ interface: (await ethers.getContractFactory("PolicyManager")).interface } as any, "PerTxLimitExceeded");
    });

    it("Should enforce per-period limit", async function () {
      const { account, owner, user } = await loadFixture(deployFixture);
      await account.connect(owner).setPerPeriodLimit(ethers.parseEther("2"), 86400);

      // First tx should succeed
      await account.connect(owner).execute(user.address, ethers.parseEther("1.5"), "0x");

      // Second tx should exceed period limit
      await expect(account.connect(owner).execute(user.address, ethers.parseEther("1"), "0x"))
        .to.be.reverted;
    });

    it("Should enforce contract allowlist", async function () {
      const { account, owner, entryPoint } = await loadFixture(deployFixture);
      const targetAddr = await entryPoint.getAddress();

      // Add an allowed contract (enables allowlist)
      await account.connect(owner).addAllowedContract(owner.address);

      // Calling a non-allowed contract with calldata should fail
      const dummyData = "0x12345678";
      await expect(account.connect(owner).execute(targetAddr, 0, dummyData))
        .to.be.reverted;
    });

    it("Should allow calls to allowed contracts", async function () {
      const { account, owner, entryPoint } = await loadFixture(deployFixture);
      const targetAddr = await entryPoint.getAddress();

      await account.connect(owner).addAllowedContract(targetAddr);

      // Deposit call should work since entryPoint is allowed
      const depositData = (await ethers.getContractFactory("MockEntryPoint")).interface.encodeFunctionData("depositTo", [await account.getAddress()]);
      await expect(account.connect(owner).execute(targetAddr, ethers.parseEther("0.1"), depositData))
        .to.not.be.reverted;
    });

    it("Should reject execution from non-owner", async function () {
      const { account, user } = await loadFixture(deployFixture);
      await expect(account.connect(user).execute(user.address, 0, "0x"))
        .to.be.revertedWithCustomError(account, "NotOwnerOrEntryPoint");
    });
  });

  describe("Batch Execution", function () {
    it("Should execute batch transactions", async function () {
      const { account, owner, user, sessionKeySigner } = await loadFixture(deployFixture);
      const bal1Before = await ethers.provider.getBalance(user.address);
      const bal2Before = await ethers.provider.getBalance(sessionKeySigner.address);

      await account.connect(owner).executeBatch(
        [user.address, sessionKeySigner.address],
        [ethers.parseEther("1"), ethers.parseEther("0.5")],
        ["0x", "0x"]
      );

      const bal1After = await ethers.provider.getBalance(user.address);
      const bal2After = await ethers.provider.getBalance(sessionKeySigner.address);
      expect(bal1After - bal1Before).to.equal(ethers.parseEther("1"));
      expect(bal2After - bal2Before).to.equal(ethers.parseEther("0.5"));
    });

    it("Should revert batch with mismatched array lengths", async function () {
      const { account, owner, user } = await loadFixture(deployFixture);
      await expect(account.connect(owner).executeBatch(
        [user.address],
        [ethers.parseEther("1"), ethers.parseEther("0.5")],
        ["0x"]
      )).to.be.revertedWithCustomError(account, "ArrayLengthMismatch");
    });
  });

  describe("Paymaster", function () {
    it("Should accept deposits", async function () {
      const { paymaster, sponsor } = await loadFixture(deployFixture);
      await paymaster.connect(sponsor).deposit({ value: ethers.parseEther("5") });
      expect(await paymaster.deposits(sponsor.address)).to.equal(ethers.parseEther("5"));
    });

    it("Should allow withdrawal", async function () {
      const { paymaster, sponsor } = await loadFixture(deployFixture);
      await paymaster.connect(sponsor).deposit({ value: ethers.parseEther("5") });

      const balBefore = await ethers.provider.getBalance(sponsor.address);
      const tx = await paymaster.connect(sponsor).withdraw(ethers.parseEther("2"));
      const receipt = await tx.wait();
      const gasCost = receipt!.gasUsed * receipt!.gasPrice;
      const balAfter = await ethers.provider.getBalance(sponsor.address);

      expect(balAfter + gasCost - balBefore).to.equal(ethers.parseEther("2"));
      expect(await paymaster.deposits(sponsor.address)).to.equal(ethers.parseEther("3"));
    });

    it("Should revert withdraw with insufficient deposit", async function () {
      const { paymaster, sponsor } = await loadFixture(deployFixture);
      await expect(paymaster.connect(sponsor).withdraw(ethers.parseEther("1")))
        .to.be.revertedWithCustomError(paymaster, "InsufficientDeposit");
    });

    it("Should sponsor an agent", async function () {
      const { paymaster, sponsor, accountAddr } = await loadFixture(deployFixture);
      await expect(paymaster.connect(sponsor).sponsorAgent(
        accountAddr, ethers.parseEther("0.1"), ethers.parseEther("1")
      )).to.emit(paymaster, "AgentSponsored");

      const cfg = await paymaster.sponsorConfigs(accountAddr);
      expect(cfg.active).to.be.true;
      expect(cfg.sponsor).to.equal(sponsor.address);
      expect(cfg.maxPerOp).to.equal(ethers.parseEther("0.1"));
      expect(cfg.maxPerDay).to.equal(ethers.parseEther("1"));
    });

    it("Should revoke sponsorship", async function () {
      const { paymaster, sponsor, accountAddr } = await loadFixture(deployFixture);
      await paymaster.connect(sponsor).sponsorAgent(accountAddr, ethers.parseEther("0.1"), ethers.parseEther("1"));
      await expect(paymaster.connect(sponsor).revokeSponsorship(accountAddr))
        .to.emit(paymaster, "SponsorshipRevoked")
        .withArgs(accountAddr);

      const cfg = await paymaster.sponsorConfigs(accountAddr);
      expect(cfg.active).to.be.false;
    });

    it("Should enforce daily cap in validatePaymasterUserOp", async function () {
      const { paymaster, sponsor, owner, accountAddr, entryPoint } = await loadFixture(deployFixture);

      // Setup: deposit and sponsor
      await paymaster.connect(sponsor).deposit({ value: ethers.parseEther("10") });
      await paymaster.connect(sponsor).sponsorAgent(
        accountAddr, ethers.parseEther("0.5"), ethers.parseEther("0.8")
      );

      // Call validatePaymasterUserOp from entryPoint
      const epAddr = await entryPoint.getAddress();
      await owner.sendTransaction({ to: epAddr, value: ethers.parseEther("1") });
      const paymasterAsEP = paymaster.connect(await ethers.getImpersonatedSigner(epAddr));

      const userOp = {
        sender: accountAddr,
        nonce: 0,
        initCode: "0x",
        callData: "0x",
        accountGasLimits: ethers.zeroPadValue("0x", 32),
        preVerificationGas: 0,
        gasFees: ethers.zeroPadValue("0x", 32),
        paymasterAndData: "0x",
        signature: "0x"
      };

      const hash = ethers.keccak256("0x1234");

      // First call within limits should succeed
      await paymasterAsEP.validatePaymasterUserOp(userOp, hash, ethers.parseEther("0.5"));

      // Second call should exceed daily limit
      await expect(paymasterAsEP.validatePaymasterUserOp(userOp, hash, ethers.parseEther("0.5")))
        .to.be.revertedWithCustomError(paymaster, "ExceedsDailyLimit");
    });
  });

  describe("Ownership Transfer", function () {
    it("Should transfer ownership", async function () {
      const { account, owner, user } = await loadFixture(deployFixture);
      await expect(account.connect(owner).transferOwnership(user.address))
        .to.emit(account, "OwnershipTransferred")
        .withArgs(owner.address, user.address);
      expect(await account.owner()).to.equal(user.address);
    });

    it("Should reject transfer to zero address", async function () {
      const { account, owner } = await loadFixture(deployFixture);
      await expect(account.connect(owner).transferOwnership(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(account, "ZeroAddress");
    });

    it("Should reject transfer from non-owner", async function () {
      const { account, user } = await loadFixture(deployFixture);
      await expect(account.connect(user).transferOwnership(user.address))
        .to.be.revertedWithCustomError(account, "NotOwner");
    });

    it("New owner should be able to execute", async function () {
      const { account, owner, user, beneficiary } = await loadFixture(deployFixture);
      await account.connect(owner).transferOwnership(user.address);

      const balBefore = await ethers.provider.getBalance(beneficiary.address);
      await account.connect(user).execute(beneficiary.address, ethers.parseEther("1"), "0x");
      const balAfter = await ethers.provider.getBalance(beneficiary.address);
      expect(balAfter - balBefore).to.equal(ethers.parseEther("1"));
    });
  });
});
