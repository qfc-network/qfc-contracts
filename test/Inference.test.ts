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

  async function deployFixture() {
    const [owner, router, miner1, miner2, user1, user2] = await ethers.getSigners();

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

    // Wire together
    await minerRegistry.setTaskRegistry(await taskRegistry.getAddress());
    await feeEscrow.setTaskRegistry(await taskRegistry.getAddress());
    await taskRegistry.setRouter(router.address);

    // Register models
    await modelRegistry.registerModel(LLAMA3_8B, "llama3-8b", 1, BASE_FEE_8B);
    await modelRegistry.registerModel(LLAMA3_70B, "llama3-70b", 2, BASE_FEE_70B);
    await modelRegistry.registerModel(WHISPER, "whisper-large-v3", 1, BASE_FEE_WHISPER);

    return { modelRegistry, minerRegistry, feeEscrow, taskRegistry, owner, router, miner1, miner2, user1, user2 };
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
});
