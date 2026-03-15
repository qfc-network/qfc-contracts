import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("QUSDGovernance", function () {
  async function deployFixture() {
    const [governor, user, alice] = await ethers.getSigners();

    // Deploy a simple target contract to test execution
    // We'll use PriceFeed as a target (has setPrice we can call)
    const PriceFeed = await ethers.getContractFactory("PriceFeed");
    const priceFeed = await PriceFeed.deploy(200_000_000n); // $2.00

    // Deploy QUSDGovernance with governor as owner
    const QUSDGovernance = await ethers.getContractFactory("QUSDGovernance");
    const gov = await QUSDGovernance.deploy(governor.address);

    // Transfer ownership of PriceFeed to governance contract
    await priceFeed.transferOwnership(await gov.getAddress());

    return { gov, priceFeed, governor, user, alice };
  }

  describe("Queue & Execute", function () {
    it("should queue a proposal", async function () {
      const { gov, priceFeed, governor } = await loadFixture(deployFixture);

      const callData = priceFeed.interface.encodeFunctionData("setPrice", [210_000_000n]);

      await expect(gov.connect(governor).queueProposal(
        await priceFeed.getAddress(),
        callData,
        "Update QFC/USD price to $2.10"
      )).to.emit(gov, "ProposalQueued");

      expect(await gov.proposalCount()).to.equal(1);
    });

    it("should execute after timelock", async function () {
      const { gov, priceFeed, governor } = await loadFixture(deployFixture);

      const callData = priceFeed.interface.encodeFunctionData("setPrice", [210_000_000n]);
      await gov.connect(governor).queueProposal(await priceFeed.getAddress(), callData, "Price update");

      // Advance past timelock (2 days)
      await time.increase(2 * 24 * 3600 + 1);

      await expect(gov.executeProposal(1))
        .to.emit(gov, "ProposalExecuted")
        .withArgs(1);

      // Verify the price was updated
      expect(await priceFeed.price()).to.equal(210_000_000n);
    });

    it("should reject execution before timelock", async function () {
      const { gov, priceFeed, governor } = await loadFixture(deployFixture);

      const callData = priceFeed.interface.encodeFunctionData("setPrice", [210_000_000n]);
      await gov.connect(governor).queueProposal(await priceFeed.getAddress(), callData, "Price update");

      // Only advance 1 hour (need 2 days)
      await time.increase(3600);

      await expect(gov.executeProposal(1))
        .to.be.revertedWithCustomError(gov, "ProposalNotReady");
    });

    it("should reject execution after deadline", async function () {
      const { gov, priceFeed, governor } = await loadFixture(deployFixture);

      const callData = priceFeed.interface.encodeFunctionData("setPrice", [210_000_000n]);
      await gov.connect(governor).queueProposal(await priceFeed.getAddress(), callData, "Price update");

      // Advance past deadline (2 days timelock + 7 days window + 1)
      await time.increase(9 * 24 * 3600 + 1);

      await expect(gov.executeProposal(1))
        .to.be.revertedWithCustomError(gov, "ProposalExpired");
    });

    it("should reject double execution", async function () {
      const { gov, priceFeed, governor } = await loadFixture(deployFixture);

      const callData = priceFeed.interface.encodeFunctionData("setPrice", [210_000_000n]);
      await gov.connect(governor).queueProposal(await priceFeed.getAddress(), callData, "Price update");

      await time.increase(2 * 24 * 3600 + 1);
      await gov.executeProposal(1);

      await expect(gov.executeProposal(1))
        .to.be.revertedWithCustomError(gov, "ProposalAlreadyExecuted");
    });

    it("should allow anyone to execute after timelock", async function () {
      const { gov, priceFeed, governor, user } = await loadFixture(deployFixture);

      const callData = priceFeed.interface.encodeFunctionData("setPrice", [210_000_000n]);
      await gov.connect(governor).queueProposal(await priceFeed.getAddress(), callData, "Price update");

      await time.increase(2 * 24 * 3600 + 1);

      // Non-governor user can execute
      await expect(gov.connect(user).executeProposal(1))
        .to.emit(gov, "ProposalExecuted");
    });

    it("should reject non-governor queueing", async function () {
      const { gov, priceFeed, user } = await loadFixture(deployFixture);

      const callData = priceFeed.interface.encodeFunctionData("setPrice", [210_000_000n]);
      await expect(gov.connect(user).queueProposal(await priceFeed.getAddress(), callData, "Unauthorized"))
        .to.be.revertedWithCustomError(gov, "OwnableUnauthorizedAccount");
    });
  });

  describe("Cancel", function () {
    it("should cancel a pending proposal", async function () {
      const { gov, priceFeed, governor } = await loadFixture(deployFixture);

      const callData = priceFeed.interface.encodeFunctionData("setPrice", [210_000_000n]);
      await gov.connect(governor).queueProposal(await priceFeed.getAddress(), callData, "Will cancel");

      await expect(gov.connect(governor).cancelProposal(1))
        .to.emit(gov, "ProposalCancelled");

      // Cannot execute cancelled proposal
      await time.increase(2 * 24 * 3600 + 1);
      await expect(gov.executeProposal(1))
        .to.be.revertedWithCustomError(gov, "ProposalIsCancelled");
    });

    it("should reject non-governor cancellation", async function () {
      const { gov, priceFeed, governor, user } = await loadFixture(deployFixture);

      const callData = priceFeed.interface.encodeFunctionData("setPrice", [210_000_000n]);
      await gov.connect(governor).queueProposal(await priceFeed.getAddress(), callData, "Test");

      await expect(gov.connect(user).cancelProposal(1))
        .to.be.revertedWithCustomError(gov, "OwnableUnauthorizedAccount");
    });
  });

  describe("Parameter Validation — ±20% Change Limit", function () {
    it("should accept change within ±20%", async function () {
      const { gov } = await loadFixture(deployFixture);

      // 150% → 170% (13.3% increase) — OK
      await expect(gov.validateChange(15000, 17000)).to.not.be.reverted;

      // 150% → 130% (13.3% decrease) — OK
      await expect(gov.validateChange(15000, 13000)).to.not.be.reverted;

      // 200 bps → 240 bps (20% increase) — OK
      await expect(gov.validateChange(200, 240)).to.not.be.reverted;
    });

    it("should reject change exceeding ±20%", async function () {
      const { gov } = await loadFixture(deployFixture);

      // 150% → 190% (26.7% increase) — too much
      await expect(gov.validateChange(15000, 19000))
        .to.be.revertedWithCustomError(gov, "ChangeExceedsLimit");

      // 150% → 110% (26.7% decrease) — too much
      await expect(gov.validateChange(15000, 11000))
        .to.be.revertedWithCustomError(gov, "ChangeExceedsLimit");
    });

    it("should allow any change from zero (first-time set)", async function () {
      const { gov } = await loadFixture(deployFixture);
      await expect(gov.validateChange(0, 50000)).to.not.be.reverted;
    });
  });

  describe("Parameter Bounds", function () {
    it("should validate stability fee bounds (0-20%)", async function () {
      const { gov } = await loadFixture(deployFixture);
      const paramId = ethers.keccak256(ethers.toUtf8Bytes("stabilityFee"));

      // 5% = 500 bps — OK
      await expect(gov.validateBounds(paramId, 500)).to.not.be.reverted;

      // 25% = 2500 bps — exceeds 20% max
      await expect(gov.validateBounds(paramId, 2500))
        .to.be.revertedWithCustomError(gov, "ValueOutOfBounds");
    });

    it("should validate collateral ratio bounds (110-300%)", async function () {
      const { gov } = await loadFixture(deployFixture);
      const paramId = ethers.keccak256(ethers.toUtf8Bytes("minCollateralRatio"));

      // 150% — OK
      await expect(gov.validateBounds(paramId, 15000)).to.not.be.reverted;

      // 100% — below minimum
      await expect(gov.validateBounds(paramId, 10000))
        .to.be.revertedWithCustomError(gov, "ValueOutOfBounds");

      // 400% — above maximum
      await expect(gov.validateBounds(paramId, 40000))
        .to.be.revertedWithCustomError(gov, "ValueOutOfBounds");
    });

    it("should validate PSM fee bounds (0-5%)", async function () {
      const { gov } = await loadFixture(deployFixture);
      const paramId = ethers.keccak256(ethers.toUtf8Bytes("psmFee"));

      await expect(gov.validateBounds(paramId, 100)).to.not.be.reverted; // 1%
      await expect(gov.validateBounds(paramId, 600))
        .to.be.revertedWithCustomError(gov, "ValueOutOfBounds"); // 6%
    });

    it("should allow owner to update bounds", async function () {
      const { gov, governor } = await loadFixture(deployFixture);
      const paramId = ethers.keccak256(ethers.toUtf8Bytes("stabilityFee"));

      await gov.connect(governor).setParameterBounds(paramId, 0, 5000); // 0-50%

      // Now 25% should be valid
      await expect(gov.validateBounds(paramId, 2500)).to.not.be.reverted;
    });

    it("should do combined validation", async function () {
      const { gov } = await loadFixture(deployFixture);
      const paramId = ethers.keccak256(ethers.toUtf8Bytes("stabilityFee"));

      // Current 200 (2%), proposed 220 (2.2%) — within bounds and ±20%
      await expect(gov.validateParameterChange(paramId, 200, 220)).to.not.be.reverted;

      // Current 200, proposed 300 (50% increase) — within bounds but exceeds ±20%
      await expect(gov.validateParameterChange(paramId, 200, 300))
        .to.be.revertedWithCustomError(gov, "ChangeExceedsLimit");

      // Current 200, proposed 2500 — exceeds bounds
      await expect(gov.validateParameterChange(paramId, 200, 2500))
        .to.be.revertedWithCustomError(gov, "ValueOutOfBounds");
    });
  });

  describe("Timelock Configuration", function () {
    it("should allow governor to change timelock delay", async function () {
      const { gov, governor } = await loadFixture(deployFixture);

      await expect(gov.connect(governor).setTimelockDelay(3 * 24 * 3600))
        .to.emit(gov, "TimelockDelayUpdated");

      expect(await gov.timelockDelay()).to.equal(3 * 24 * 3600);
    });

    it("should reject invalid delay", async function () {
      const { gov, governor } = await loadFixture(deployFixture);

      // Too short (< 1 hour)
      await expect(gov.connect(governor).setTimelockDelay(60))
        .to.be.revertedWithCustomError(gov, "InvalidDelay");

      // Too long (> 14 days)
      await expect(gov.connect(governor).setTimelockDelay(15 * 24 * 3600))
        .to.be.revertedWithCustomError(gov, "InvalidDelay");
    });
  });

  describe("View Functions", function () {
    it("should return proposal details", async function () {
      const { gov, priceFeed, governor } = await loadFixture(deployFixture);

      const callData = priceFeed.interface.encodeFunctionData("setPrice", [210_000_000n]);
      await gov.connect(governor).queueProposal(await priceFeed.getAddress(), callData, "Test proposal");

      const p = await gov.getProposal(1);
      expect(p.target).to.equal(await priceFeed.getAddress());
      expect(p.description).to.equal("Test proposal");
      expect(p.executed).to.be.false;
    });

    it("should report executability", async function () {
      const { gov, priceFeed, governor } = await loadFixture(deployFixture);

      const callData = priceFeed.interface.encodeFunctionData("setPrice", [210_000_000n]);
      await gov.connect(governor).queueProposal(await priceFeed.getAddress(), callData, "Test");

      // Not yet executable
      expect(await gov.isExecutable(1)).to.be.false;

      // After timelock
      await time.increase(2 * 24 * 3600 + 1);
      expect(await gov.isExecutable(1)).to.be.true;

      // After deadline
      await time.increase(7 * 24 * 3600 + 1);
      expect(await gov.isExecutable(1)).to.be.false;
    });
  });
});
