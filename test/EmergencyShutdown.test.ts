import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("EmergencyShutdown", function () {
  const INITIAL_PRICE = 200_000_000n; // $2.00

  async function deployFixture() {
    const [admin, guardian1, guardian2, guardian3, alice, bob] = await ethers.getSigners();

    // Deploy QUSD system
    const QUSDToken = await ethers.getContractFactory("QUSDToken");
    const qusd = await QUSDToken.deploy();

    const PriceFeed = await ethers.getContractFactory("PriceFeed");
    const priceFeed = await PriceFeed.deploy(INITIAL_PRICE);

    const CDPVault = await ethers.getContractFactory("CDPVault");
    const vault = await CDPVault.deploy(await qusd.getAddress(), await priceFeed.getAddress());

    await qusd.setVault(await vault.getAddress());

    // Deploy EmergencyShutdown
    const EmergencyShutdown = await ethers.getContractFactory("EmergencyShutdown");
    const shutdown = await EmergencyShutdown.deploy(await qusd.getAddress(), admin.address);

    const GUARDIAN_ROLE = await shutdown.GUARDIAN_ROLE();
    await shutdown.grantRole(GUARDIAN_ROLE, guardian1.address);
    await shutdown.grantRole(GUARDIAN_ROLE, guardian2.address);
    await shutdown.grantRole(GUARDIAN_ROLE, guardian3.address);

    // Set up positions: Alice deposits 10 QFC, mints 10 QUSD; Bob deposits 20 QFC, mints 20 QUSD
    await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });
    await vault.connect(alice).mintQUSD(ethers.parseEther("10"));

    await vault.connect(bob).depositCollateral({ value: ethers.parseEther("20") });
    await vault.connect(bob).mintQUSD(ethers.parseEther("20"));

    return { qusd, priceFeed, vault, shutdown, admin, guardian1, guardian2, guardian3, alice, bob, GUARDIAN_ROLE };
  }

  describe("Pause Levels", function () {
    it("should start at Normal (level 0)", async function () {
      const { shutdown } = await loadFixture(deployFixture);
      expect(await shutdown.pauseLevel()).to.equal(0);
    });

    it("should allow guardian to escalate to PauseMint", async function () {
      const { shutdown, guardian1 } = await loadFixture(deployFixture);

      await expect(shutdown.connect(guardian1).setPauseLevel(1))
        .to.emit(shutdown, "PauseLevelChanged")
        .withArgs(0, 1, guardian1.address);

      expect(await shutdown.isMintAllowed()).to.be.false;
      expect(await shutdown.isOperationAllowed()).to.be.true;
      expect(await shutdown.isRepayAllowed()).to.be.true;
    });

    it("should allow guardian to escalate to PauseAll", async function () {
      const { shutdown, guardian1 } = await loadFixture(deployFixture);

      await shutdown.connect(guardian1).setPauseLevel(2);

      expect(await shutdown.isMintAllowed()).to.be.false;
      expect(await shutdown.isOperationAllowed()).to.be.false;
      expect(await shutdown.isRepayAllowed()).to.be.true;
    });

    it("should only allow admin to de-escalate", async function () {
      const { shutdown, admin, guardian1 } = await loadFixture(deployFixture);

      await shutdown.connect(guardian1).setPauseLevel(2);

      // Guardian cannot de-escalate
      await expect(shutdown.connect(guardian1).setPauseLevel(1))
        .to.be.reverted;

      // Admin can de-escalate
      await expect(shutdown.connect(admin).setPauseLevel(0))
        .to.emit(shutdown, "PauseLevelChanged")
        .withArgs(2, 0, admin.address);
    });

    it("should not allow setting Settlement via setPauseLevel", async function () {
      const { shutdown, guardian1 } = await loadFixture(deployFixture);
      await expect(shutdown.connect(guardian1).setPauseLevel(3))
        .to.be.revertedWithCustomError(shutdown, "InvalidPauseLevel");
    });

    it("should reject unauthorized pause level changes", async function () {
      const { shutdown, alice } = await loadFixture(deployFixture);
      await expect(shutdown.connect(alice).setPauseLevel(1))
        .to.be.reverted;
    });
  });

  describe("Multi-sig Shutdown Proposal", function () {
    it("should allow guardian to propose shutdown", async function () {
      const { shutdown, guardian1 } = await loadFixture(deployFixture);

      await expect(shutdown.connect(guardian1).proposeShutdown())
        .to.emit(shutdown, "ShutdownProposed");
    });

    it("should collect signatures from multiple guardians", async function () {
      const { shutdown, guardian1, guardian2, guardian3 } = await loadFixture(deployFixture);

      await shutdown.connect(guardian1).proposeShutdown();

      await expect(shutdown.connect(guardian2).signShutdown())
        .to.emit(shutdown, "ShutdownSigned")
        .withArgs(guardian2.address, 2);

      await expect(shutdown.connect(guardian3).signShutdown())
        .to.emit(shutdown, "ShutdownSigned")
        .withArgs(guardian3.address, 3);
    });

    it("should prevent double-signing", async function () {
      const { shutdown, guardian1 } = await loadFixture(deployFixture);

      await shutdown.connect(guardian1).proposeShutdown();

      await expect(shutdown.connect(guardian1).signShutdown())
        .to.be.revertedWithCustomError(shutdown, "AlreadySigned");
    });

    it("should reject signing without active proposal", async function () {
      const { shutdown, guardian1 } = await loadFixture(deployFixture);
      await expect(shutdown.connect(guardian1).signShutdown())
        .to.be.revertedWithCustomError(shutdown, "NoActiveProposal");
    });
  });

  describe("Global Settlement Execution", function () {
    async function settledFixture() {
      const fixture = await deployFixture();
      const { shutdown, guardian1, guardian2, guardian3, alice, bob } = fixture;

      // Propose and collect 3 signatures
      await shutdown.connect(guardian1).proposeShutdown();
      await shutdown.connect(guardian2).signShutdown();
      await shutdown.connect(guardian3).signShutdown();

      const totalCollateral = ethers.parseEther("30"); // 10 + 20
      const totalDebt = ethers.parseEther("30");       // 10 + 20

      // Fund the shutdown contract with collateral (simulating vault transfer)
      await guardian1.sendTransaction({
        to: await shutdown.getAddress(),
        value: totalCollateral,
      });

      // Execute settlement
      await shutdown.connect(guardian1).executeSettlement(
        INITIAL_PRICE,        // $2.00
        totalCollateral,      // 30 QFC
        totalDebt,            // 30 QUSD
        [alice.address, bob.address],
        [ethers.parseEther("10"), ethers.parseEther("20")],
        [ethers.parseEther("10"), ethers.parseEther("20")]
      );

      return fixture;
    }

    it("should execute settlement with enough signatures", async function () {
      const { shutdown } = await loadFixture(settledFixture);

      expect(await shutdown.settled()).to.be.true;
      expect(await shutdown.pauseLevel()).to.equal(3);
      expect(await shutdown.settlementPrice()).to.equal(INITIAL_PRICE);
    });

    it("should reject settlement without enough signatures", async function () {
      const { shutdown, guardian1, alice } = await loadFixture(deployFixture);

      await shutdown.connect(guardian1).proposeShutdown();
      // Only 1 signature, need 3

      await expect(
        shutdown.connect(guardian1).executeSettlement(
          INITIAL_PRICE,
          ethers.parseEther("30"),
          ethers.parseEther("30"),
          [alice.address],
          [ethers.parseEther("10")],
          [ethers.parseEther("10")]
        )
      ).to.be.revertedWithCustomError(shutdown, "NotEnoughSignatures");
    });

    it("should reject double settlement", async function () {
      const { shutdown, guardian1, alice } = await loadFixture(settledFixture);

      await expect(
        shutdown.connect(guardian1).executeSettlement(
          INITIAL_PRICE,
          ethers.parseEther("30"),
          ethers.parseEther("30"),
          [alice.address],
          [ethers.parseEther("10")],
          [ethers.parseEther("10")]
        )
      ).to.be.revertedWithCustomError(shutdown, "AlreadySettled");
    });

    it("should block all operations after settlement", async function () {
      const { shutdown } = await loadFixture(settledFixture);

      expect(await shutdown.isMintAllowed()).to.be.false;
      expect(await shutdown.isOperationAllowed()).to.be.false;
      expect(await shutdown.isRepayAllowed()).to.be.false;
    });

    it("should calculate correct redemption rate (fully backed)", async function () {
      const { shutdown } = await loadFixture(settledFixture);

      // Price $2.00, total collateral 30 QFC = $60, total debt 30 QUSD
      // Fully backed: 1 QUSD = 1e8 / 2e8 = 0.5 QFC
      const rate = await shutdown.redemptionRate();
      expect(rate).to.equal(ethers.parseEther("0.5"));
    });
  });

  describe("QUSD Redemption", function () {
    it("should allow QUSD holders to redeem for QFC", async function () {
      const { shutdown, qusd, vault, guardian1, guardian2, guardian3, alice, bob } = await loadFixture(deployFixture);

      // Set up settlement
      await shutdown.connect(guardian1).proposeShutdown();
      await shutdown.connect(guardian2).signShutdown();
      await shutdown.connect(guardian3).signShutdown();

      const totalCollateral = ethers.parseEther("30");
      await guardian1.sendTransaction({
        to: await shutdown.getAddress(),
        value: totalCollateral,
      });

      // Authorize shutdown contract to burn QUSD
      await qusd.setVault(await shutdown.getAddress());

      await shutdown.connect(guardian1).executeSettlement(
        INITIAL_PRICE,
        totalCollateral,
        ethers.parseEther("30"),
        [alice.address, bob.address],
        [ethers.parseEther("10"), ethers.parseEther("20")],
        [ethers.parseEther("10"), ethers.parseEther("20")]
      );

      // Alice has 10 QUSD, redeems for 5 QFC (at $2/QFC)
      const aliceBalBefore = await ethers.provider.getBalance(alice.address);

      await expect(shutdown.connect(alice).redeemQUSD(ethers.parseEther("10")))
        .to.emit(shutdown, "QUSDRedeemed");

      const aliceBalAfter = await ethers.provider.getBalance(alice.address);
      // Should have received ~5 QFC (minus gas)
      const received = aliceBalAfter - aliceBalBefore;
      expect(received).to.be.closeTo(ethers.parseEther("5"), ethers.parseEther("0.01"));

      // QUSD should be burned
      expect(await qusd.balanceOf(alice.address)).to.equal(0);
    });

    it("should reject redemption before settlement", async function () {
      const { shutdown, alice } = await loadFixture(deployFixture);
      await expect(shutdown.connect(alice).redeemQUSD(ethers.parseEther("10")))
        .to.be.revertedWithCustomError(shutdown, "NotSettled");
    });

    it("should reject zero amount redemption", async function () {
      const { shutdown, qusd, guardian1, guardian2, guardian3, alice, bob } = await loadFixture(deployFixture);

      await shutdown.connect(guardian1).proposeShutdown();
      await shutdown.connect(guardian2).signShutdown();
      await shutdown.connect(guardian3).signShutdown();
      await guardian1.sendTransaction({ to: await shutdown.getAddress(), value: ethers.parseEther("30") });
      await qusd.setVault(await shutdown.getAddress());

      await shutdown.connect(guardian1).executeSettlement(
        INITIAL_PRICE, ethers.parseEther("30"), ethers.parseEther("30"),
        [alice.address, bob.address],
        [ethers.parseEther("10"), ethers.parseEther("20")],
        [ethers.parseEther("10"), ethers.parseEther("20")]
      );

      await expect(shutdown.connect(alice).redeemQUSD(0))
        .to.be.revertedWithCustomError(shutdown, "NothingToRedeem");
    });
  });

  describe("Excess Collateral Withdrawal", function () {
    it("should allow CDP owners to withdraw excess after settlement", async function () {
      const { shutdown, qusd, guardian1, guardian2, guardian3, alice, bob } = await loadFixture(deployFixture);

      await shutdown.connect(guardian1).proposeShutdown();
      await shutdown.connect(guardian2).signShutdown();
      await shutdown.connect(guardian3).signShutdown();

      // Fund with enough collateral
      await guardian1.sendTransaction({ to: await shutdown.getAddress(), value: ethers.parseEther("30") });
      await qusd.setVault(await shutdown.getAddress());

      // Settlement at $2.00: Alice has 10 QFC collateral, 10 QUSD debt
      // Debt cost in QFC = 10 * 0.5 = 5 QFC. Excess = 10 - 5 = 5 QFC
      await shutdown.connect(guardian1).executeSettlement(
        INITIAL_PRICE, ethers.parseEther("30"), ethers.parseEther("30"),
        [alice.address, bob.address],
        [ethers.parseEther("10"), ethers.parseEther("20")],
        [ethers.parseEther("10"), ethers.parseEther("20")]
      );

      const aliceBalBefore = await ethers.provider.getBalance(alice.address);

      await expect(shutdown.connect(alice).withdrawExcessCollateral())
        .to.emit(shutdown, "ExcessCollateralWithdrawn");

      const aliceBalAfter = await ethers.provider.getBalance(alice.address);
      const received = aliceBalAfter - aliceBalBefore;
      expect(received).to.be.closeTo(ethers.parseEther("5"), ethers.parseEther("0.01"));
    });

    it("should reject double withdrawal", async function () {
      const { shutdown, qusd, guardian1, guardian2, guardian3, alice, bob } = await loadFixture(deployFixture);

      await shutdown.connect(guardian1).proposeShutdown();
      await shutdown.connect(guardian2).signShutdown();
      await shutdown.connect(guardian3).signShutdown();
      await guardian1.sendTransaction({ to: await shutdown.getAddress(), value: ethers.parseEther("30") });
      await qusd.setVault(await shutdown.getAddress());

      await shutdown.connect(guardian1).executeSettlement(
        INITIAL_PRICE, ethers.parseEther("30"), ethers.parseEther("30"),
        [alice.address, bob.address],
        [ethers.parseEther("10"), ethers.parseEther("20")],
        [ethers.parseEther("10"), ethers.parseEther("20")]
      );

      await shutdown.connect(alice).withdrawExcessCollateral();

      await expect(shutdown.connect(alice).withdrawExcessCollateral())
        .to.be.revertedWithCustomError(shutdown, "AlreadyWithdrawn");
    });

    it("should reject withdrawal before settlement", async function () {
      const { shutdown, alice } = await loadFixture(deployFixture);
      await expect(shutdown.connect(alice).withdrawExcessCollateral())
        .to.be.revertedWithCustomError(shutdown, "NotSettled");
    });
  });

  describe("Admin Configuration", function () {
    it("should allow changing required signatures", async function () {
      const { shutdown, admin } = await loadFixture(deployFixture);
      await shutdown.connect(admin).setRequiredSignatures(5);
      expect(await shutdown.requiredSignatures()).to.equal(5);
    });

    it("should reject invalid required signatures", async function () {
      const { shutdown, admin } = await loadFixture(deployFixture);
      await expect(shutdown.connect(admin).setRequiredSignatures(0))
        .to.be.revertedWithCustomError(shutdown, "InvalidConfiguration");
      await expect(shutdown.connect(admin).setRequiredSignatures(11))
        .to.be.revertedWithCustomError(shutdown, "InvalidConfiguration");
    });
  });
});
