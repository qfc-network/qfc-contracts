import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("Inference Marketplace", function () {
  // Model IDs
  const LLAMA3_8B = ethers.id("llama3-8b");
  const LLAMA3_70B = ethers.id("llama3-70b");
  const WHISPER = ethers.id("whisper-large-v3");

  const BASE_FEE_8B = ethers.parseEther("0.01");
  const BASE_FEE_70B = ethers.parseEther("0.05");
  const BASE_FEE_WHISPER = ethers.parseEther("0.005");

  const INPUT_HASH = ethers.id("test-input-data");
  const RESULT_HASH = ethers.id("test-result-data");
  const PROOF = ethers.id("test-proof");

  const MIN_CHALLENGE_STAKE = ethers.parseEther("0.1");
  const CHALLENGER_RESULT = ethers.id("challenger-result-data");

  async function deployFixture() {
    const [owner, router, miner1, miner2, user1, user2, validator1, validator2] = await ethers.getSigners();

    // Deploy contracts
    const ModelRegistry = await ethers.getContractFactory("ModelRegistry");
    const modelRegistry = await ModelRegistry.deploy();

    const MinerRegistry = await ethers.getContractFactory("MinerRegistry");
    const minerRegistry = await MinerRegistry.deploy();

    const FeeEscrow = await ethers.getContractFactory("FeeEscrow");
    const feeEscrow = await FeeEscrow.deploy();

    const TaskRegistry = await ethers.getContractFactory("TaskRegistry");
    const taskRegistry = await TaskRegistry.deploy(
      await modelRegistry.getAddress(),
      await minerRegistry.getAddress(),
      await feeEscrow.getAddress()
    );

    const ResultVerifier = await ethers.getContractFactory("ResultVerifier");
    const resultVerifier = await ResultVerifier.deploy(
      await taskRegistry.getAddress(),
      await minerRegistry.getAddress(),
      MIN_CHALLENGE_STAKE
    );

    // Wire together
    await minerRegistry.setTaskRegistry(await taskRegistry.getAddress());
    await minerRegistry.setResultVerifier(await resultVerifier.getAddress());
    await feeEscrow.setTaskRegistry(await taskRegistry.getAddress());
    await taskRegistry.setRouter(router.address);

    // Register models
    await modelRegistry.registerModel(LLAMA3_8B, "llama3-8b", 1, BASE_FEE_8B);
    await modelRegistry.registerModel(LLAMA3_70B, "llama3-70b", 2, BASE_FEE_70B);
    await modelRegistry.registerModel(WHISPER, "whisper-large-v3", 1, BASE_FEE_WHISPER);

    return { modelRegistry, minerRegistry, feeEscrow, taskRegistry, resultVerifier, owner, router, miner1, miner2, user1, user2, validator1, validator2 };
  }

  // ─── ModelRegistry ─────────────────────────────────────────────

  describe("ModelRegistry", function () {
    it("Should register models with correct data", async function () {
      const { modelRegistry } = await loadFixture(deployFixture);

      const model = await modelRegistry.getModel(LLAMA3_8B);
      expect(model.name).to.equal("llama3-8b");
      expect(model.minTier).to.equal(1);
      expect(model.baseFee).to.equal(BASE_FEE_8B);
      expect(model.active).to.be.true;
    });

    it("Should track model count", async function () {
      const { modelRegistry } = await loadFixture(deployFixture);
      expect(await modelRegistry.getModelCount()).to.equal(3);
    });

    it("Should not allow duplicate model registration", async function () {
      const { modelRegistry } = await loadFixture(deployFixture);
      await expect(
        modelRegistry.registerModel(LLAMA3_8B, "duplicate", 1, BASE_FEE_8B)
      ).to.be.revertedWithCustomError(modelRegistry, "ModelAlreadyExists");
    });

    it("Should reject invalid tier", async function () {
      const { modelRegistry } = await loadFixture(deployFixture);
      const id = ethers.id("bad-tier");
      await expect(
        modelRegistry.registerModel(id, "bad", 0, BASE_FEE_8B)
      ).to.be.revertedWithCustomError(modelRegistry, "InvalidTier");
      await expect(
        modelRegistry.registerModel(id, "bad", 4, BASE_FEE_8B)
      ).to.be.revertedWithCustomError(modelRegistry, "InvalidTier");
    });

    it("Should toggle model active status", async function () {
      const { modelRegistry } = await loadFixture(deployFixture);

      await expect(modelRegistry.setModelActive(LLAMA3_8B, false))
        .to.emit(modelRegistry, "ModelActiveChanged")
        .withArgs(LLAMA3_8B, false);

      const model = await modelRegistry.getModel(LLAMA3_8B);
      expect(model.active).to.be.false;
    });

    it("Should revert on non-owner registration", async function () {
      const { modelRegistry, user1 } = await loadFixture(deployFixture);
      await expect(
        modelRegistry.connect(user1).registerModel(ethers.id("x"), "x", 1, BASE_FEE_8B)
      ).to.be.revertedWithCustomError(modelRegistry, "OwnableUnauthorizedAccount");
    });
  });

  // ─── MinerRegistry ─────────────────────────────────────────────

  describe("MinerRegistry", function () {
    it("Should register a miner", async function () {
      const { minerRegistry, miner1 } = await loadFixture(deployFixture);

      await expect(minerRegistry.connect(miner1).registerMiner(2, "https://miner1.example.com"))
        .to.emit(minerRegistry, "MinerRegistered")
        .withArgs(miner1.address, 2, "https://miner1.example.com");

      const info = await minerRegistry.getMiner(miner1.address);
      expect(info.tier).to.equal(2);
      expect(info.status).to.equal(1); // Online
      expect(info.reputation).to.equal(10000);
    });

    it("Should prevent duplicate registration", async function () {
      const { minerRegistry, miner1 } = await loadFixture(deployFixture);
      await minerRegistry.connect(miner1).registerMiner(1, "https://m1.example.com");
      await expect(
        minerRegistry.connect(miner1).registerMiner(2, "https://m1.example.com")
      ).to.be.revertedWithCustomError(minerRegistry, "AlreadyRegistered");
    });

    it("Should update miner status", async function () {
      const { minerRegistry, miner1 } = await loadFixture(deployFixture);
      await minerRegistry.connect(miner1).registerMiner(1, "https://m1.example.com");

      await expect(minerRegistry.connect(miner1).updateStatus(0)) // Offline
        .to.emit(minerRegistry, "MinerStatusUpdated")
        .withArgs(miner1.address, 0);
    });

    it("Should return miner stats", async function () {
      const { minerRegistry, miner1 } = await loadFixture(deployFixture);
      await minerRegistry.connect(miner1).registerMiner(1, "https://m1.example.com");

      const [completed, failed, reputation] = await minerRegistry.getMinerStats(miner1.address);
      expect(completed).to.equal(0);
      expect(failed).to.equal(0);
      expect(reputation).to.equal(10000);
    });

    it("Should revert getMinerStats for unregistered miner", async function () {
      const { minerRegistry, user1 } = await loadFixture(deployFixture);
      await expect(
        minerRegistry.getMinerStats(user1.address)
      ).to.be.revertedWithCustomError(minerRegistry, "NotRegistered");
    });
  });

  // ─── Task Submit ────────────────────────────────────────────────

  describe("Task Submission", function () {
    it("Should submit a task and lock fee", async function () {
      const { taskRegistry, feeEscrow, user1 } = await loadFixture(deployFixture);

      const tx = await taskRegistry
        .connect(user1)
        .submitTask(LLAMA3_8B, INPUT_HASH, BASE_FEE_8B, { value: BASE_FEE_8B });

      const receipt = await tx.wait();
      const event = receipt?.logs.find(
        (log: any) => log.fragment?.name === "TaskSubmitted"
      ) as any;
      expect(event).to.not.be.undefined;

      // Verify escrow balance
      expect(await ethers.provider.getBalance(await feeEscrow.getAddress()))
        .to.equal(BASE_FEE_8B);

      // Verify open tasks
      const openTasks = await taskRegistry.getOpenTasks();
      expect(openTasks.length).to.equal(1);
    });

    it("Should reject submission with insufficient fee", async function () {
      const { taskRegistry, user1 } = await loadFixture(deployFixture);
      const lowFee = ethers.parseEther("0.001");

      await expect(
        taskRegistry.connect(user1).submitTask(LLAMA3_8B, INPUT_HASH, lowFee, { value: lowFee })
      ).to.be.revertedWithCustomError(taskRegistry, "InsufficientFee");
    });

    it("Should reject submission for inactive model", async function () {
      const { modelRegistry, taskRegistry, user1 } = await loadFixture(deployFixture);
      await modelRegistry.setModelActive(LLAMA3_8B, false);

      await expect(
        taskRegistry.connect(user1).submitTask(LLAMA3_8B, INPUT_HASH, BASE_FEE_8B, { value: BASE_FEE_8B })
      ).to.be.revertedWithCustomError(taskRegistry, "ModelNotActive");
    });
  });

  // ─── Task Assignment ────────────────────────────────────────────

  describe("Task Assignment", function () {
    async function submitAndRegisterFixture() {
      const fixture = await deployFixture();
      const { taskRegistry, minerRegistry, miner1, user1, router } = fixture;

      // Register miner (tier 2 — eligible for tier 1 and 2 models)
      await minerRegistry.connect(miner1).registerMiner(2, "https://miner1.example.com");

      // Submit task
      const tx = await taskRegistry
        .connect(user1)
        .submitTask(LLAMA3_8B, INPUT_HASH, BASE_FEE_8B, { value: BASE_FEE_8B });
      const receipt = await tx.wait();
      const event = receipt?.logs.find(
        (log: any) => log.fragment?.name === "TaskSubmitted"
      ) as any;
      const taskId = event.args[0];

      return { ...fixture, taskId };
    }

    it("Should assign a task to an eligible miner", async function () {
      const { taskRegistry, router, miner1, taskId } = await loadFixture(submitAndRegisterFixture);

      await expect(taskRegistry.connect(router).assignTask(taskId, miner1.address))
        .to.emit(taskRegistry, "TaskAssigned")
        .withArgs(taskId, miner1.address);

      const task = await taskRegistry.tasks(taskId);
      expect(task.status).to.equal(1); // Assigned
      expect(task.miner).to.equal(miner1.address);

      // Removed from open tasks
      const openTasks = await taskRegistry.getOpenTasks();
      expect(openTasks.length).to.equal(0);
    });

    it("Should reject assignment from non-router", async function () {
      const { taskRegistry, user1, miner1, taskId } = await loadFixture(submitAndRegisterFixture);

      await expect(
        taskRegistry.connect(user1).assignTask(taskId, miner1.address)
      ).to.be.revertedWithCustomError(taskRegistry, "OnlyRouter");
    });

    it("Should reject assignment of ineligible miner", async function () {
      const { taskRegistry, minerRegistry, miner2, router, user1 } = await loadFixture(deployFixture);

      // Register miner2 as tier 1
      await minerRegistry.connect(miner2).registerMiner(1, "https://miner2.example.com");

      // Submit task requiring tier 2
      const tx = await taskRegistry
        .connect(user1)
        .submitTask(LLAMA3_70B, INPUT_HASH, BASE_FEE_70B, { value: BASE_FEE_70B });
      const receipt = await tx.wait();
      const event = receipt?.logs.find(
        (log: any) => log.fragment?.name === "TaskSubmitted"
      ) as any;
      const taskId = event.args[0];

      await expect(
        taskRegistry.connect(router).assignTask(taskId, miner2.address)
      ).to.be.revertedWithCustomError(taskRegistry, "MinerNotEligible");
    });
  });

  // ─── Task Completion & Fee Release ──────────────────────────────

  describe("Task Completion", function () {
    async function assignedTaskFixture() {
      const fixture = await deployFixture();
      const { taskRegistry, minerRegistry, miner1, user1, router } = fixture;

      await minerRegistry.connect(miner1).registerMiner(2, "https://miner1.example.com");

      const tx = await taskRegistry
        .connect(user1)
        .submitTask(LLAMA3_8B, INPUT_HASH, BASE_FEE_8B, { value: BASE_FEE_8B });
      const receipt = await tx.wait();
      const event = receipt?.logs.find(
        (log: any) => log.fragment?.name === "TaskSubmitted"
      ) as any;
      const taskId = event.args[0];

      await taskRegistry.connect(router).assignTask(taskId, miner1.address);

      return { ...fixture, taskId };
    }

    it("Should complete task and release fee to miner", async function () {
      const { taskRegistry, feeEscrow, miner1, taskId } = await loadFixture(assignedTaskFixture);

      const minerBalanceBefore = await ethers.provider.getBalance(miner1.address);

      const tx = await taskRegistry.connect(miner1).submitResult(taskId, RESULT_HASH, PROOF);
      const receipt = await tx.wait();
      const gasUsed = receipt!.gasUsed * receipt!.gasPrice;

      const minerBalanceAfter = await ethers.provider.getBalance(miner1.address);

      // Miner should receive 95% of fee (5% protocol fee)
      const expectedPayout = (BASE_FEE_8B * 9500n) / 10000n;
      expect(minerBalanceAfter - minerBalanceBefore + gasUsed).to.equal(expectedPayout);

      // Task should be completed
      const task = await taskRegistry.tasks(taskId);
      expect(task.status).to.equal(2); // Completed
      expect(task.resultHash).to.equal(RESULT_HASH);
      expect(task.proof).to.equal(PROOF);

      // Protocol fees accumulated
      expect(await feeEscrow.protocolFees()).to.equal((BASE_FEE_8B * 500n) / 10000n);
    });

    it("Should update miner stats on completion", async function () {
      const { taskRegistry, minerRegistry, miner1, taskId } = await loadFixture(assignedTaskFixture);

      await taskRegistry.connect(miner1).submitResult(taskId, RESULT_HASH, PROOF);

      const [completed, failed, reputation] = await minerRegistry.getMinerStats(miner1.address);
      expect(completed).to.equal(1);
      expect(failed).to.equal(0);
      expect(reputation).to.equal(10000);
    });

    it("Should reject result from non-assigned miner", async function () {
      const { taskRegistry, minerRegistry, miner2, taskId } = await loadFixture(assignedTaskFixture);

      await minerRegistry.connect(miner2).registerMiner(2, "https://miner2.example.com");

      await expect(
        taskRegistry.connect(miner2).submitResult(taskId, RESULT_HASH, PROOF)
      ).to.be.revertedWithCustomError(taskRegistry, "OnlyAssignedMiner");
    });
  });

  // ─── Task Cancellation & Refund ─────────────────────────────────

  describe("Task Cancellation", function () {
    async function pendingTaskFixture() {
      const fixture = await deployFixture();
      const { taskRegistry, user1 } = fixture;

      const tx = await taskRegistry
        .connect(user1)
        .submitTask(LLAMA3_8B, INPUT_HASH, BASE_FEE_8B, { value: BASE_FEE_8B });
      const receipt = await tx.wait();
      const event = receipt?.logs.find(
        (log: any) => log.fragment?.name === "TaskSubmitted"
      ) as any;
      const taskId = event.args[0];

      return { ...fixture, taskId };
    }

    it("Should cancel a pending task and refund fee", async function () {
      const { taskRegistry, user1, taskId } = await loadFixture(pendingTaskFixture);

      const balanceBefore = await ethers.provider.getBalance(user1.address);

      const tx = await taskRegistry.connect(user1).cancelTask(taskId);
      const receipt = await tx.wait();
      const gasUsed = receipt!.gasUsed * receipt!.gasPrice;

      const balanceAfter = await ethers.provider.getBalance(user1.address);

      // User should get full refund minus gas
      expect(balanceAfter - balanceBefore + gasUsed).to.equal(BASE_FEE_8B);

      // Task should be cancelled
      const task = await taskRegistry.tasks(taskId);
      expect(task.status).to.equal(4); // Cancelled

      // Removed from open tasks
      const openTasks = await taskRegistry.getOpenTasks();
      expect(openTasks.length).to.equal(0);
    });

    it("Should reject cancel from non-submitter", async function () {
      const { taskRegistry, user2, taskId } = await loadFixture(pendingTaskFixture);

      await expect(
        taskRegistry.connect(user2).cancelTask(taskId)
      ).to.be.revertedWithCustomError(taskRegistry, "OnlySubmitter");
    });

    it("Should reject cancel of non-pending task", async function () {
      const { taskRegistry, minerRegistry, miner1, router, user1, taskId } =
        await loadFixture(pendingTaskFixture);

      await minerRegistry.connect(miner1).registerMiner(2, "https://m1.example.com");
      await taskRegistry.connect(router).assignTask(taskId, miner1.address);

      await expect(
        taskRegistry.connect(user1).cancelTask(taskId)
      ).to.be.revertedWithCustomError(taskRegistry, "InvalidStatus");
    });
  });

  // ─── FeeEscrow Protocol Fees ────────────────────────────────────

  describe("Protocol Fees", function () {
    it("Should allow owner to claim protocol fees", async function () {
      const fixture = await deployFixture();
      const { taskRegistry, minerRegistry, feeEscrow, miner1, user1, router, owner } = fixture;

      // Complete a task to generate protocol fees
      await minerRegistry.connect(miner1).registerMiner(2, "https://m1.example.com");
      const tx = await taskRegistry
        .connect(user1)
        .submitTask(LLAMA3_8B, INPUT_HASH, BASE_FEE_8B, { value: BASE_FEE_8B });
      const receipt = await tx.wait();
      const event = receipt?.logs.find(
        (log: any) => log.fragment?.name === "TaskSubmitted"
      ) as any;
      const taskId = event.args[0];

      await taskRegistry.connect(router).assignTask(taskId, miner1.address);
      await taskRegistry.connect(miner1).submitResult(taskId, RESULT_HASH, PROOF);

      const expectedProtocolFee = (BASE_FEE_8B * 500n) / 10000n;
      expect(await feeEscrow.protocolFees()).to.equal(expectedProtocolFee);

      // Claim
      const balanceBefore = await ethers.provider.getBalance(owner.address);
      const claimTx = await feeEscrow.connect(owner).claimProtocolFees();
      const claimReceipt = await claimTx.wait();
      const gasUsed = claimReceipt!.gasUsed * claimReceipt!.gasPrice;
      const balanceAfter = await ethers.provider.getBalance(owner.address);

      expect(balanceAfter - balanceBefore + gasUsed).to.equal(expectedProtocolFee);
      expect(await feeEscrow.protocolFees()).to.equal(0);
    });

    it("Should revert claim when no protocol fees", async function () {
      const { feeEscrow } = await loadFixture(deployFixture);
      await expect(
        feeEscrow.claimProtocolFees()
      ).to.be.revertedWithCustomError(feeEscrow, "NoProtocolFees");
    });
  });

  // ─── ResultVerifier ──────────────────────────────────────────────

  describe("ResultVerifier", function () {
    async function completedTaskFixture() {
      const fixture = await deployFixture();
      const { taskRegistry, minerRegistry, resultVerifier, miner1, user1, router, owner, validator1, validator2 } = fixture;

      await minerRegistry.connect(miner1).registerMiner(2, "https://miner1.example.com");

      // Submit + assign + complete task
      const tx = await taskRegistry
        .connect(user1)
        .submitTask(LLAMA3_8B, INPUT_HASH, BASE_FEE_8B, { value: BASE_FEE_8B });
      const receipt = await tx.wait();
      const event = receipt?.logs.find(
        (log: any) => log.fragment?.name === "TaskSubmitted"
      ) as any;
      const taskId = event.args[0];

      await taskRegistry.connect(router).assignTask(taskId, miner1.address);
      await taskRegistry.connect(miner1).submitResult(taskId, RESULT_HASH, PROOF);

      // Add validators
      await resultVerifier.addValidator(validator1.address);
      await resultVerifier.addValidator(validator2.address);

      return { ...fixture, taskId };
    }

    it("Should create a challenge on a completed task", async function () {
      const { resultVerifier, user2, taskId } = await loadFixture(completedTaskFixture);

      await expect(
        resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Wrong output", { value: MIN_CHALLENGE_STAKE })
      ).to.emit(resultVerifier, "ChallengeCreated")
        .withArgs(1, taskId, user2.address);

      const challenge = await resultVerifier.getChallenge(1);
      expect(challenge.taskId).to.equal(taskId);
      expect(challenge.challenger).to.equal(user2.address);
      expect(challenge.challengerResultHash).to.equal(CHALLENGER_RESULT);
      expect(challenge.status).to.equal(0); // Open
      expect(challenge.stake).to.equal(MIN_CHALLENGE_STAKE);
    });

    it("Should reject challenge with insufficient stake", async function () {
      const { resultVerifier, user2, taskId } = await loadFixture(completedTaskFixture);
      const lowStake = ethers.parseEther("0.01");

      await expect(
        resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Wrong", { value: lowStake })
      ).to.be.revertedWithCustomError(resultVerifier, "InsufficientStake");
    });

    it("Should reject challenge on non-completed task", async function () {
      const { taskRegistry, resultVerifier, user1, user2 } = await loadFixture(deployFixture);

      // Submit but don't complete
      const tx = await taskRegistry
        .connect(user1)
        .submitTask(LLAMA3_8B, INPUT_HASH, BASE_FEE_8B, { value: BASE_FEE_8B });
      const receipt = await tx.wait();
      const event = receipt?.logs.find(
        (log: any) => log.fragment?.name === "TaskSubmitted"
      ) as any;
      const taskId = event.args[0];

      await expect(
        resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Wrong", { value: MIN_CHALLENGE_STAKE })
      ).to.be.revertedWithCustomError(resultVerifier, "TaskNotCompleted");
    });

    it("Should reject duplicate challenge", async function () {
      const { resultVerifier, user1, user2, taskId } = await loadFixture(completedTaskFixture);

      await resultVerifier.connect(user1).challengeResult(taskId, CHALLENGER_RESULT, "Wrong 1", { value: MIN_CHALLENGE_STAKE });

      await expect(
        resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Wrong 2", { value: MIN_CHALLENGE_STAKE })
      ).to.be.revertedWithCustomError(resultVerifier, "AlreadyChallenged");
    });

    it("Should reject challenge after window closes", async function () {
      const { resultVerifier, user2, taskId } = await loadFixture(completedTaskFixture);

      // Fast forward past challenge window (600s)
      await ethers.provider.send("evm_increaseTime", [601]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Too late", { value: MIN_CHALLENGE_STAKE })
      ).to.be.revertedWithCustomError(resultVerifier, "ChallengeWindowClosed");
    });

    it("Should allow validators to vote", async function () {
      const { resultVerifier, user2, validator1, validator2, taskId } = await loadFixture(completedTaskFixture);

      await resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Wrong", { value: MIN_CHALLENGE_STAKE });

      await expect(resultVerifier.connect(validator1).vote(1, true))
        .to.emit(resultVerifier, "VoteCast")
        .withArgs(1, validator1.address, true);

      await expect(resultVerifier.connect(validator2).vote(1, false))
        .to.emit(resultVerifier, "VoteCast")
        .withArgs(1, validator2.address, false);

      const challenge = await resultVerifier.getChallenge(1);
      expect(challenge.votesFor).to.equal(1);
      expect(challenge.votesAgainst).to.equal(1);
    });

    it("Should reject vote from non-validator", async function () {
      const { resultVerifier, user1, user2, taskId } = await loadFixture(completedTaskFixture);

      await resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Wrong", { value: MIN_CHALLENGE_STAKE });

      await expect(
        resultVerifier.connect(user1).vote(1, true)
      ).to.be.revertedWithCustomError(resultVerifier, "NotValidator");
    });

    it("Should reject duplicate vote", async function () {
      const { resultVerifier, user2, validator1, taskId } = await loadFixture(completedTaskFixture);

      await resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Wrong", { value: MIN_CHALLENGE_STAKE });
      await resultVerifier.connect(validator1).vote(1, true);

      await expect(
        resultVerifier.connect(validator1).vote(1, false)
      ).to.be.revertedWithCustomError(resultVerifier, "AlreadyVoted");
    });

    it("Should resolve upheld challenge — slash miner, refund challenger", async function () {
      const { resultVerifier, minerRegistry, user2, validator1, validator2, miner1, taskId } =
        await loadFixture(completedTaskFixture);

      // File challenge
      await resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Wrong output", { value: MIN_CHALLENGE_STAKE });

      // Validators vote to uphold (2-0)
      await resultVerifier.connect(validator1).vote(1, true);
      await resultVerifier.connect(validator2).vote(1, true);

      // Check miner reputation before
      const [, , repBefore] = await minerRegistry.getMinerStats(miner1.address);
      expect(repBefore).to.equal(10000);

      // Resolve
      const challengerBalBefore = await ethers.provider.getBalance(user2.address);

      await expect(resultVerifier.resolveChallenge(1))
        .to.emit(resultVerifier, "ChallengeResolved")
        .withArgs(1, 1); // Upheld

      // Miner reputation slashed by 10% (1000 bps)
      const [completed, failed, repAfter] = await minerRegistry.getMinerStats(miner1.address);
      expect(failed).to.equal(1);
      expect(repAfter).to.equal(9000); // 10000 - 10%

      // Challenger refunded
      const challengerBalAfter = await ethers.provider.getBalance(user2.address);
      expect(challengerBalAfter - challengerBalBefore).to.equal(MIN_CHALLENGE_STAKE);

      // Challenge is upheld
      const challenge = await resultVerifier.getChallenge(1);
      expect(challenge.status).to.equal(1); // Upheld
    });

    it("Should resolve rejected challenge — challenger loses stake", async function () {
      const { resultVerifier, minerRegistry, user2, validator1, validator2, miner1, taskId } =
        await loadFixture(completedTaskFixture);

      await resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Wrong", { value: MIN_CHALLENGE_STAKE });

      // Validators vote to reject (0-2)
      await resultVerifier.connect(validator1).vote(1, false);
      await resultVerifier.connect(validator2).vote(1, false);

      const challengerBalBefore = await ethers.provider.getBalance(user2.address);

      await expect(resultVerifier.resolveChallenge(1))
        .to.emit(resultVerifier, "ChallengeResolved")
        .withArgs(1, 2); // Rejected

      // Miner reputation unchanged
      const [, , rep] = await minerRegistry.getMinerStats(miner1.address);
      expect(rep).to.equal(10000);

      // Challenger NOT refunded
      const challengerBalAfter = await ethers.provider.getBalance(user2.address);
      expect(challengerBalAfter).to.equal(challengerBalBefore);

      // 50% of stake goes to protocol fees
      const expectedProtocol = (MIN_CHALLENGE_STAKE * 5000n) / 10000n;
      expect(await resultVerifier.protocolFees()).to.equal(expectedProtocol);
    });

    it("Should expire challenge after window with no resolution", async function () {
      const { resultVerifier, user2, taskId } = await loadFixture(completedTaskFixture);

      await resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Wrong", { value: MIN_CHALLENGE_STAKE });

      // Can't expire before window
      await expect(
        resultVerifier.expireChallenge(1)
      ).to.be.revertedWith("Challenge window not expired");

      // Fast forward past window
      await ethers.provider.send("evm_increaseTime", [601]);
      await ethers.provider.send("evm_mine", []);

      const balBefore = await ethers.provider.getBalance(user2.address);

      await expect(resultVerifier.expireChallenge(1))
        .to.emit(resultVerifier, "ChallengeExpired")
        .withArgs(1);

      // Challenger refunded on expiry
      const balAfter = await ethers.provider.getBalance(user2.address);
      expect(balAfter - balBefore).to.equal(MIN_CHALLENGE_STAKE);

      const challenge = await resultVerifier.getChallenge(1);
      expect(challenge.status).to.equal(3); // Expired
    });

    it("Should reject resolve from non-owner", async function () {
      const { resultVerifier, user1, user2, taskId } = await loadFixture(completedTaskFixture);

      await resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Wrong", { value: MIN_CHALLENGE_STAKE });

      await expect(
        resultVerifier.connect(user1).resolveChallenge(1)
      ).to.be.revertedWithCustomError(resultVerifier, "OwnableUnauthorizedAccount");
    });

    it("Should allow owner to claim protocol fees from rejected challenges", async function () {
      const { resultVerifier, owner, user2, validator1, taskId } = await loadFixture(completedTaskFixture);

      await resultVerifier.connect(user2).challengeResult(taskId, CHALLENGER_RESULT, "Wrong", { value: MIN_CHALLENGE_STAKE });
      await resultVerifier.connect(validator1).vote(1, false);
      await resultVerifier.resolveChallenge(1);

      const expectedFees = (MIN_CHALLENGE_STAKE * 5000n) / 10000n;
      const balBefore = await ethers.provider.getBalance(owner.address);
      const tx = await resultVerifier.claimProtocolFees();
      const receipt = await tx.wait();
      const gasUsed = receipt!.gasUsed * receipt!.gasPrice;
      const balAfter = await ethers.provider.getBalance(owner.address);

      expect(balAfter - balBefore + gasUsed).to.equal(expectedFees);
      expect(await resultVerifier.protocolFees()).to.equal(0);
    });

    it("Should allow admin to update challenge window and slash penalty", async function () {
      const { resultVerifier } = await loadFixture(completedTaskFixture);

      await expect(resultVerifier.setChallengeWindow(1200))
        .to.emit(resultVerifier, "ChallengeWindowUpdated")
        .withArgs(1200);
      expect(await resultVerifier.challengeWindow()).to.equal(1200);

      await expect(resultVerifier.setSlashPenalty(2000))
        .to.emit(resultVerifier, "SlashPenaltyUpdated")
        .withArgs(2000);
      expect(await resultVerifier.slashPenaltyBps()).to.equal(2000);
    });

    it("Should allow add/remove validators", async function () {
      const { resultVerifier, user1 } = await loadFixture(completedTaskFixture);

      await expect(resultVerifier.addValidator(user1.address))
        .to.emit(resultVerifier, "ValidatorAdded")
        .withArgs(user1.address);
      expect(await resultVerifier.validators(user1.address)).to.be.true;

      await expect(resultVerifier.removeValidator(user1.address))
        .to.emit(resultVerifier, "ValidatorRemoved")
        .withArgs(user1.address);
      expect(await resultVerifier.validators(user1.address)).to.be.false;
    });

    it("Should store completedAt timestamp on task", async function () {
      const { taskRegistry, taskId } = await loadFixture(completedTaskFixture);

      const task = await taskRegistry.getTask(taskId);
      expect(task.completedAt).to.be.greaterThan(0);
      expect(task.status).to.equal(2); // Completed
    });
  });
});
