import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("Inference Contracts", function () {
  async function deployInferenceFixture() {
    const [owner, submitter, miner, miner2, validator, challenger] =
      await ethers.getSigners();

    // Deploy ModelRegistry
    const ModelRegistry = await ethers.getContractFactory("ModelRegistry");
    const modelRegistry = await ModelRegistry.deploy();

    // Deploy MinerRegistry (min stake = 1 ETH)
    const MinerRegistry = await ethers.getContractFactory("MinerRegistry");
    const minerRegistry = await MinerRegistry.deploy(ethers.parseEther("1"));

    // Deploy FeeEscrow (2.5% protocol fee)
    const FeeEscrow = await ethers.getContractFactory("FeeEscrow");
    const feeEscrow = await FeeEscrow.deploy(250, owner.address);

    // Deploy TaskRegistry
    const TaskRegistry = await ethers.getContractFactory("TaskRegistry");
    const taskRegistry = await TaskRegistry.deploy(
      await modelRegistry.getAddress(),
      await minerRegistry.getAddress(),
      await feeEscrow.getAddress()
    );

    // Deploy ResultVerifier (slash 0.5 ETH, min challenge stake 0.1 ETH)
    const ResultVerifier = await ethers.getContractFactory("ResultVerifier");
    const resultVerifier = await ResultVerifier.deploy(
      await taskRegistry.getAddress(),
      await minerRegistry.getAddress(),
      ethers.parseEther("0.5"),
      ethers.parseEther("0.1")
    );

    // Transfer FeeEscrow ownership to TaskRegistry (so it can deposit/release/refund)
    await feeEscrow.transferOwnership(await taskRegistry.getAddress());

    // Authorize TaskRegistry and ResultVerifier on MinerRegistry
    await minerRegistry.authorizeCaller(await taskRegistry.getAddress());
    await minerRegistry.authorizeCaller(await resultVerifier.getAddress());

    // Register a model
    await modelRegistry.registerModel(
      "llama-3-70b",
      "Llama 3 70B",
      ethers.parseEther("0.01"), // base fee
      1 // min tier
    );

    return {
      modelRegistry,
      minerRegistry,
      feeEscrow,
      taskRegistry,
      resultVerifier,
      owner,
      submitter,
      miner,
      miner2,
      validator,
      challenger,
    };
  }

  describe("ModelRegistry", function () {
    it("should register a model", async function () {
      const { modelRegistry } = await loadFixture(deployInferenceFixture);

      const model = await modelRegistry.getModel("llama-3-70b");
      expect(model.name).to.equal("Llama 3 70B");
      expect(model.approved).to.be.true;
      expect(model.minTier).to.equal(1);
    });

    it("should reject duplicate model", async function () {
      const { modelRegistry } = await loadFixture(deployInferenceFixture);

      await expect(
        modelRegistry.registerModel("llama-3-70b", "Dup", ethers.parseEther("0.01"), 1)
      ).to.be.revertedWithCustomError(modelRegistry, "ModelAlreadyExists");
    });

    it("should reject invalid tier", async function () {
      const { modelRegistry } = await loadFixture(deployInferenceFixture);

      await expect(
        modelRegistry.registerModel("test", "Test", ethers.parseEther("0.01"), 4)
      ).to.be.revertedWithCustomError(modelRegistry, "InvalidTier");
    });

    it("should revoke and approve model", async function () {
      const { modelRegistry } = await loadFixture(deployInferenceFixture);

      await modelRegistry.revokeModel("llama-3-70b");
      expect(await modelRegistry.isApproved("llama-3-70b")).to.be.false;

      await modelRegistry.approveModel("llama-3-70b");
      expect(await modelRegistry.isApproved("llama-3-70b")).to.be.true;
    });

    it("should update base fee", async function () {
      const { modelRegistry } = await loadFixture(deployInferenceFixture);

      await modelRegistry.updateBaseFee("llama-3-70b", ethers.parseEther("0.02"));
      expect(await modelRegistry.getBaseFee("llama-3-70b")).to.equal(
        ethers.parseEther("0.02")
      );
    });

    it("should enumerate models", async function () {
      const { modelRegistry } = await loadFixture(deployInferenceFixture);

      expect(await modelRegistry.modelCount()).to.equal(1);
      const model = await modelRegistry.modelAtIndex(0);
      expect(model.modelId).to.equal("llama-3-70b");
    });
  });

  describe("MinerRegistry", function () {
    it("should register a miner with stake", async function () {
      const { minerRegistry, miner } = await loadFixture(deployInferenceFixture);

      await minerRegistry.connect(miner).register("RTX 4090", 2, {
        value: ethers.parseEther("1"),
      });

      const info = await minerRegistry.getMiner(miner.address);
      expect(info.gpuModel).to.equal("RTX 4090");
      expect(info.tier).to.equal(2);
      expect(info.stake).to.equal(ethers.parseEther("1"));
      expect(info.status).to.equal(1); // Active
    });

    it("should reject insufficient stake", async function () {
      const { minerRegistry, miner } = await loadFixture(deployInferenceFixture);

      await expect(
        minerRegistry.connect(miner).register("RTX 4090", 2, {
          value: ethers.parseEther("0.5"),
        })
      ).to.be.revertedWithCustomError(minerRegistry, "InsufficientStake");
    });

    it("should reject duplicate registration", async function () {
      const { minerRegistry, miner } = await loadFixture(deployInferenceFixture);

      await minerRegistry.connect(miner).register("RTX 4090", 2, {
        value: ethers.parseEther("1"),
      });
      await expect(
        minerRegistry.connect(miner).register("A100", 3, {
          value: ethers.parseEther("1"),
        })
      ).to.be.revertedWithCustomError(minerRegistry, "AlreadyRegistered");
    });

    it("should deactivate and reactivate", async function () {
      const { minerRegistry, miner } = await loadFixture(deployInferenceFixture);

      await minerRegistry.connect(miner).register("RTX 4090", 2, {
        value: ethers.parseEther("1"),
      });

      await minerRegistry.connect(miner).deactivate();
      expect((await minerRegistry.getMiner(miner.address)).status).to.equal(0); // Inactive

      await minerRegistry.connect(miner).activate();
      expect((await minerRegistry.getMiner(miner.address)).status).to.equal(1); // Active
    });

    it("should withdraw stake when inactive", async function () {
      const { minerRegistry, miner } = await loadFixture(deployInferenceFixture);

      await minerRegistry.connect(miner).register("RTX 4090", 2, {
        value: ethers.parseEther("2"),
      });
      await minerRegistry.connect(miner).deactivate();

      await expect(
        minerRegistry.connect(miner).withdrawStake(ethers.parseEther("1"))
      ).to.changeEtherBalance(miner, ethers.parseEther("1"));
    });

    it("should check eligibility", async function () {
      const { minerRegistry, miner } = await loadFixture(deployInferenceFixture);

      await minerRegistry.connect(miner).register("RTX 4090", 2, {
        value: ethers.parseEther("1"),
      });

      expect(await minerRegistry.isEligible(miner.address, 1)).to.be.true;
      expect(await minerRegistry.isEligible(miner.address, 2)).to.be.true;
      expect(await minerRegistry.isEligible(miner.address, 3)).to.be.false;
    });

    it("should slash miner stake", async function () {
      const { minerRegistry, miner } = await loadFixture(deployInferenceFixture);

      await minerRegistry.connect(miner).register("RTX 4090", 2, {
        value: ethers.parseEther("2"),
      });

      await minerRegistry.slash(miner.address, ethers.parseEther("0.5"));
      expect((await minerRegistry.getMiner(miner.address)).stake).to.equal(
        ethers.parseEther("1.5")
      );
    });
  });

  describe("TaskRegistry + FeeEscrow", function () {
    async function setupWithMiner() {
      const fixture = await loadFixture(deployInferenceFixture);
      const { minerRegistry, miner } = fixture;

      // Register miner
      await minerRegistry.connect(miner).register("RTX 4090", 2, {
        value: ethers.parseEther("1"),
      });

      return fixture;
    }

    it("should submit a task", async function () {
      const { taskRegistry, submitter } = await setupWithMiner();

      const tx = await taskRegistry
        .connect(submitter)
        .submitTask("llama-3-70b", "0x1234", {
          value: ethers.parseEther("0.01"),
        });

      await expect(tx)
        .to.emit(taskRegistry, "TaskSubmitted")
        .withArgs(0, submitter.address, "llama-3-70b", ethers.parseEther("0.01"));

      const task = await taskRegistry.getTask(0);
      expect(task.submitter).to.equal(submitter.address);
      expect(task.status).to.equal(0); // Pending
    });

    it("should reject task with unapproved model", async function () {
      const { taskRegistry, submitter } = await setupWithMiner();

      await expect(
        taskRegistry.connect(submitter).submitTask("unknown-model", "0x1234", {
          value: ethers.parseEther("0.01"),
        })
      ).to.be.revertedWithCustomError(taskRegistry, "ModelNotApproved");
    });

    it("should reject task with insufficient fee", async function () {
      const { taskRegistry, submitter } = await setupWithMiner();

      await expect(
        taskRegistry.connect(submitter).submitTask("llama-3-70b", "0x1234", {
          value: ethers.parseEther("0.005"),
        })
      ).to.be.revertedWithCustomError(taskRegistry, "FeeBelowMinimum");
    });

    it("should claim and complete a task", async function () {
      const { taskRegistry, submitter, miner } = await setupWithMiner();

      // Submit
      await taskRegistry.connect(submitter).submitTask("llama-3-70b", "0x1234", {
        value: ethers.parseEther("0.01"),
      });

      // Claim
      await taskRegistry.connect(miner).claimTask(0);
      const claimed = await taskRegistry.getTask(0);
      expect(claimed.status).to.equal(1); // Claimed
      expect(claimed.miner).to.equal(miner.address);

      // Complete
      await taskRegistry.connect(miner).completeTask(0, "0xaabbccdd");
      const completed = await taskRegistry.getTask(0);
      expect(completed.status).to.equal(2); // Completed
    });

    it("should pay miner on completion (minus protocol fee)", async function () {
      const { taskRegistry, submitter, miner, owner } = await setupWithMiner();

      await taskRegistry.connect(submitter).submitTask("llama-3-70b", "0x1234", {
        value: ethers.parseEther("1"),
      });
      await taskRegistry.connect(miner).claimTask(0);

      // 2.5% fee = 0.025 ETH, miner gets 0.975 ETH
      await expect(
        taskRegistry.connect(miner).completeTask(0, "0xaabbccdd")
      ).to.changeEtherBalances(
        [miner, owner],
        [ethers.parseEther("0.975"), ethers.parseEther("0.025")]
      );
    });

    it("should cancel a pending task and refund", async function () {
      const { taskRegistry, submitter } = await setupWithMiner();

      await taskRegistry.connect(submitter).submitTask("llama-3-70b", "0x1234", {
        value: ethers.parseEther("0.5"),
      });

      await expect(
        taskRegistry.connect(submitter).cancelTask(0)
      ).to.changeEtherBalance(submitter, ethers.parseEther("0.5"));

      const task = await taskRegistry.getTask(0);
      expect(task.status).to.equal(4); // Cancelled
    });

    it("should fail a claimed task and refund submitter", async function () {
      const { taskRegistry, submitter, miner, owner } = await setupWithMiner();

      await taskRegistry.connect(submitter).submitTask("llama-3-70b", "0x1234", {
        value: ethers.parseEther("0.5"),
      });
      await taskRegistry.connect(miner).claimTask(0);

      await expect(
        taskRegistry.connect(owner).failTask(0, "miner timeout")
      ).to.changeEtherBalance(submitter, ethers.parseEther("0.5"));

      const task = await taskRegistry.getTask(0);
      expect(task.status).to.equal(3); // Failed
    });

    it("should reject claim from ineligible miner", async function () {
      const { taskRegistry, submitter, miner2, modelRegistry } = await setupWithMiner();

      // Register a model requiring tier 3
      await modelRegistry.registerModel("big-model", "Big", ethers.parseEther("0.01"), 3);

      await taskRegistry.connect(submitter).submitTask("big-model", "0x1234", {
        value: ethers.parseEther("0.01"),
      });

      // miner2 is not registered at all
      await expect(
        taskRegistry.connect(miner2).claimTask(0)
      ).to.be.revertedWithCustomError(taskRegistry, "MinerNotEligible");
    });

    it("should reject completion after timeout", async function () {
      const { taskRegistry, submitter, miner } = await setupWithMiner();

      await taskRegistry.connect(submitter).submitTask("llama-3-70b", "0x1234", {
        value: ethers.parseEther("0.01"),
      });
      await taskRegistry.connect(miner).claimTask(0);

      // Advance time past claim timeout (600s)
      await time.increase(601);

      await expect(
        taskRegistry.connect(miner).completeTask(0, "0xaabbccdd")
      ).to.be.revertedWithCustomError(taskRegistry, "ClaimExpired");
    });
  });

  describe("ResultVerifier", function () {
    async function setupCompletedTask() {
      const fixture = await loadFixture(deployInferenceFixture);
      const { minerRegistry, taskRegistry, resultVerifier, miner, submitter, validator, owner } =
        fixture;

      // Register miner
      await minerRegistry.connect(miner).register("RTX 4090", 2, {
        value: ethers.parseEther("2"),
      });

      // Submit and complete task
      await taskRegistry.connect(submitter).submitTask("llama-3-70b", "0x1234", {
        value: ethers.parseEther("0.5"),
      });
      await taskRegistry.connect(miner).claimTask(0);
      await taskRegistry.connect(miner).completeTask(0, "0xaabbccdd");

      // Add validator
      await resultVerifier.addValidator(validator.address);

      return fixture;
    }

    it("should create a challenge", async function () {
      const { resultVerifier, challenger } = await setupCompletedTask();

      const tx = await resultVerifier
        .connect(challenger)
        .challenge(0, "wrong output", { value: ethers.parseEther("0.1") });

      await expect(tx).to.emit(resultVerifier, "ChallengeCreated").withArgs(1, 0, challenger.address);

      const ch = await resultVerifier.getChallenge(1);
      expect(ch.taskId).to.equal(0);
      expect(ch.status).to.equal(0); // Open
    });

    it("should reject challenge with insufficient stake", async function () {
      const { resultVerifier, challenger } = await setupCompletedTask();

      await expect(
        resultVerifier.connect(challenger).challenge(0, "wrong", {
          value: ethers.parseEther("0.05"),
        })
      ).to.be.revertedWithCustomError(resultVerifier, "InsufficientStake");
    });

    it("should reject challenge after window", async function () {
      const { resultVerifier, challenger } = await setupCompletedTask();

      await time.increase(601);

      await expect(
        resultVerifier.connect(challenger).challenge(0, "too late", {
          value: ethers.parseEther("0.1"),
        })
      ).to.be.revertedWithCustomError(resultVerifier, "ChallengeWindowClosed");
    });

    it("should allow validator voting", async function () {
      const { resultVerifier, challenger, validator } = await setupCompletedTask();

      await resultVerifier
        .connect(challenger)
        .challenge(0, "wrong", { value: ethers.parseEther("0.1") });

      await expect(resultVerifier.connect(validator).vote(1, true))
        .to.emit(resultVerifier, "VoteCast")
        .withArgs(1, validator.address, true);
    });

    it("should reject non-validator votes", async function () {
      const { resultVerifier, challenger, submitter } = await setupCompletedTask();

      await resultVerifier
        .connect(challenger)
        .challenge(0, "wrong", { value: ethers.parseEther("0.1") });

      await expect(
        resultVerifier.connect(submitter).vote(1, true)
      ).to.be.revertedWithCustomError(resultVerifier, "NotValidator");
    });

    it("should reject duplicate votes", async function () {
      const { resultVerifier, challenger, validator } = await setupCompletedTask();

      await resultVerifier
        .connect(challenger)
        .challenge(0, "wrong", { value: ethers.parseEther("0.1") });

      await resultVerifier.connect(validator).vote(1, true);
      await expect(
        resultVerifier.connect(validator).vote(1, true)
      ).to.be.revertedWithCustomError(resultVerifier, "AlreadyVoted");
    });

    it("should resolve upheld challenge (slash miner)", async function () {
      const { resultVerifier, minerRegistry, challenger, validator, miner, owner } =
        await setupCompletedTask();

      await resultVerifier
        .connect(challenger)
        .challenge(0, "wrong", { value: ethers.parseEther("0.1") });

      await resultVerifier.connect(validator).vote(1, true); // uphold

      await resultVerifier.connect(owner).resolve(1);

      const ch = await resultVerifier.getChallenge(1);
      expect(ch.status).to.equal(1); // Upheld

      // Miner should have been slashed 0.5 ETH
      const minerInfo = await minerRegistry.getMiner(miner.address);
      expect(minerInfo.stake).to.equal(ethers.parseEther("1.5"));
    });

    it("should resolve rejected challenge", async function () {
      const { resultVerifier, challenger, validator, owner } = await setupCompletedTask();

      await resultVerifier
        .connect(challenger)
        .challenge(0, "wrong", { value: ethers.parseEther("0.1") });

      await resultVerifier.connect(validator).vote(1, false); // reject

      await resultVerifier.connect(owner).resolve(1);

      const ch = await resultVerifier.getChallenge(1);
      expect(ch.status).to.equal(2); // Rejected
    });
  });
});
