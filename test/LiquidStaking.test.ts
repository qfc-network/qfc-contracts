import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("LiquidStaking", function () {
  async function deployLiquidStakingFixture() {
    const [owner, user1, user2] = await ethers.getSigners();

    const LiquidStaking = await ethers.getContractFactory("LiquidStaking");
    const liquidStaking = await LiquidStaking.deploy();
    await liquidStaking.waitForDeployment();

    const stQFCAddress = await liquidStaking.stQFC();
    const stQFC = await ethers.getContractAt("StQFC", stQFCAddress);

    return { liquidStaking, stQFC, owner, user1, user2 };
  }

  describe("Staking", function () {
    it("Should stake QFC and receive stQFC 1:1 initially", async function () {
      const { liquidStaking, stQFC, user1 } = await loadFixture(deployLiquidStakingFixture);

      const stakeAmount = ethers.parseEther("10");
      await liquidStaking.connect(user1).stake({ value: stakeAmount });

      expect(await stQFC.balanceOf(user1.address)).to.equal(stakeAmount);
      expect(await liquidStaking.totalPooledQFC()).to.equal(stakeAmount);
    });

    it("Should revert when staking 0", async function () {
      const { liquidStaking, user1 } = await loadFixture(deployLiquidStakingFixture);

      await expect(
        liquidStaking.connect(user1).stake({ value: 0 })
      ).to.be.revertedWithCustomError(liquidStaking, "ZeroAmount");
    });

    it("Should emit Staked event", async function () {
      const { liquidStaking, user1 } = await loadFixture(deployLiquidStakingFixture);

      const stakeAmount = ethers.parseEther("5");
      await expect(liquidStaking.connect(user1).stake({ value: stakeAmount }))
        .to.emit(liquidStaking, "Staked")
        .withArgs(user1.address, stakeAmount, stakeAmount);
    });
  });

  describe("Exchange Rate", function () {
    it("Should start at 1:1", async function () {
      const { liquidStaking } = await loadFixture(deployLiquidStakingFixture);

      expect(await liquidStaking.getExchangeRate()).to.equal(ethers.parseEther("1"));
    });

    it("Should increase after rewards distribution", async function () {
      const { liquidStaking, stQFC, owner, user1 } = await loadFixture(deployLiquidStakingFixture);

      // User stakes 100 QFC
      await liquidStaking.connect(user1).stake({ value: ethers.parseEther("100") });

      // Owner distributes 10 QFC rewards
      await liquidStaking.connect(owner).distributeRewards({ value: ethers.parseEther("10") });

      // Exchange rate should be 110/100 = 1.1
      const rate = await liquidStaking.getExchangeRate();
      expect(rate).to.equal(ethers.parseEther("1.1"));
    });

    it("Should give fewer stQFC after rate increase", async function () {
      const { liquidStaking, stQFC, owner, user1, user2 } = await loadFixture(deployLiquidStakingFixture);

      // User1 stakes 100 QFC at 1:1
      await liquidStaking.connect(user1).stake({ value: ethers.parseEther("100") });
      expect(await stQFC.balanceOf(user1.address)).to.equal(ethers.parseEther("100"));

      // Distribute 100 QFC rewards → rate = 200/100 = 2.0
      await liquidStaking.connect(owner).distributeRewards({ value: ethers.parseEther("100") });

      // User2 stakes 100 QFC at 2:1 → gets 50 stQFC
      await liquidStaking.connect(user2).stake({ value: ethers.parseEther("100") });
      expect(await stQFC.balanceOf(user2.address)).to.equal(ethers.parseEther("50"));
    });
  });

  describe("Unstaking", function () {
    it("Should request unstake and queue withdrawal", async function () {
      const { liquidStaking, stQFC, user1 } = await loadFixture(deployLiquidStakingFixture);

      await liquidStaking.connect(user1).stake({ value: ethers.parseEther("10") });

      await expect(liquidStaking.connect(user1).requestUnstake(ethers.parseEther("5")))
        .to.emit(liquidStaking, "UnstakeRequested");

      expect(await stQFC.balanceOf(user1.address)).to.equal(ethers.parseEther("5"));
    });

    it("Should revert unstake with insufficient balance", async function () {
      const { liquidStaking, user1 } = await loadFixture(deployLiquidStakingFixture);

      await liquidStaking.connect(user1).stake({ value: ethers.parseEther("10") });

      await expect(
        liquidStaking.connect(user1).requestUnstake(ethers.parseEther("20"))
      ).to.be.revertedWithCustomError(liquidStaking, "InsufficientBalance");
    });

    it("Should revert unstake with zero amount", async function () {
      const { liquidStaking, user1 } = await loadFixture(deployLiquidStakingFixture);

      await expect(
        liquidStaking.connect(user1).requestUnstake(0)
      ).to.be.revertedWithCustomError(liquidStaking, "ZeroAmount");
    });
  });

  describe("Cooldown & Claim", function () {
    it("Should not allow claim before cooldown", async function () {
      const { liquidStaking, user1 } = await loadFixture(deployLiquidStakingFixture);

      await liquidStaking.connect(user1).stake({ value: ethers.parseEther("10") });
      await liquidStaking.connect(user1).requestUnstake(ethers.parseEther("10"));

      await expect(
        liquidStaking.connect(user1).claimUnstake(1)
      ).to.be.revertedWith("Cooldown not passed");
    });

    it("Should allow claim after 7-day cooldown", async function () {
      const { liquidStaking, user1 } = await loadFixture(deployLiquidStakingFixture);

      const stakeAmount = ethers.parseEther("10");
      await liquidStaking.connect(user1).stake({ value: stakeAmount });
      await liquidStaking.connect(user1).requestUnstake(stakeAmount);

      // Advance 7 days
      await time.increase(7 * 24 * 60 * 60);

      const balanceBefore = await ethers.provider.getBalance(user1.address);
      const tx = await liquidStaking.connect(user1).claimUnstake(1);
      const receipt = await tx.wait();
      const gasCost = receipt!.gasUsed * receipt!.gasPrice;
      const balanceAfter = await ethers.provider.getBalance(user1.address);

      expect(balanceAfter - balanceBefore + gasCost).to.equal(stakeAmount);
    });

    it("Should not allow double claim", async function () {
      const { liquidStaking, user1 } = await loadFixture(deployLiquidStakingFixture);

      await liquidStaking.connect(user1).stake({ value: ethers.parseEther("10") });
      await liquidStaking.connect(user1).requestUnstake(ethers.parseEther("10"));

      await time.increase(7 * 24 * 60 * 60);

      await liquidStaking.connect(user1).claimUnstake(1);

      await expect(
        liquidStaking.connect(user1).claimUnstake(1)
      ).to.be.revertedWith("Already claimed");
    });

    it("Should not allow another user to claim", async function () {
      const { liquidStaking, user1, user2 } = await loadFixture(deployLiquidStakingFixture);

      await liquidStaking.connect(user1).stake({ value: ethers.parseEther("10") });
      await liquidStaking.connect(user1).requestUnstake(ethers.parseEther("10"));

      await time.increase(7 * 24 * 60 * 60);

      await expect(
        liquidStaking.connect(user2).claimUnstake(1)
      ).to.be.revertedWithCustomError(liquidStaking, "NotRequestOwner");
    });
  });

  describe("Multiple Users", function () {
    it("Should handle multiple stakers with correct exchange rates", async function () {
      const { liquidStaking, stQFC, owner, user1, user2 } = await loadFixture(deployLiquidStakingFixture);

      // User1 stakes 100 QFC → 100 stQFC
      await liquidStaking.connect(user1).stake({ value: ethers.parseEther("100") });

      // Rewards: +50 QFC → rate = 150/100 = 1.5
      await liquidStaking.connect(owner).distributeRewards({ value: ethers.parseEther("50") });

      // User2 stakes 150 QFC → 100 stQFC (at 1.5 rate)
      await liquidStaking.connect(user2).stake({ value: ethers.parseEther("150") });
      expect(await stQFC.balanceOf(user2.address)).to.equal(ethers.parseEther("100"));

      // Total: 300 QFC pooled, 200 stQFC → rate still 1.5
      expect(await liquidStaking.getExchangeRate()).to.equal(ethers.parseEther("1.5"));

      // User1 unstakes 100 stQFC → gets 150 QFC (profit from rewards)
      await liquidStaking.connect(user1).requestUnstake(ethers.parseEther("100"));
      await time.increase(7 * 24 * 60 * 60);

      const balanceBefore = await ethers.provider.getBalance(user1.address);
      const tx = await liquidStaking.connect(user1).claimUnstake(1);
      const receipt = await tx.wait();
      const gasCost = receipt!.gasUsed * receipt!.gasPrice;
      const balanceAfter = await ethers.provider.getBalance(user1.address);

      expect(balanceAfter - balanceBefore + gasCost).to.equal(ethers.parseEther("150"));
    });

    it("Should handle multiple withdrawal requests", async function () {
      const { liquidStaking, user1 } = await loadFixture(deployLiquidStakingFixture);

      await liquidStaking.connect(user1).stake({ value: ethers.parseEther("30") });

      // Create 3 withdrawal requests
      await liquidStaking.connect(user1).requestUnstake(ethers.parseEther("10"));
      await liquidStaking.connect(user1).requestUnstake(ethers.parseEther("10"));
      await liquidStaking.connect(user1).requestUnstake(ethers.parseEther("10"));

      const requestIds = await liquidStaking.getUserRequests(user1.address);
      expect(requestIds.length).to.equal(3);

      await time.increase(7 * 24 * 60 * 60);

      // Claim all
      await liquidStaking.connect(user1).claimUnstake(1);
      await liquidStaking.connect(user1).claimUnstake(2);
      await liquidStaking.connect(user1).claimUnstake(3);
    });
  });

  describe("StQFC Token", function () {
    it("Should have correct name and symbol", async function () {
      const { stQFC } = await loadFixture(deployLiquidStakingFixture);

      expect(await stQFC.name()).to.equal("Staked QFC");
      expect(await stQFC.symbol()).to.equal("stQFC");
    });

    it("Should be transferable between users", async function () {
      const { liquidStaking, stQFC, user1, user2 } = await loadFixture(deployLiquidStakingFixture);

      await liquidStaking.connect(user1).stake({ value: ethers.parseEther("10") });
      await stQFC.connect(user1).transfer(user2.address, ethers.parseEther("5"));

      expect(await stQFC.balanceOf(user1.address)).to.equal(ethers.parseEther("5"));
      expect(await stQFC.balanceOf(user2.address)).to.equal(ethers.parseEther("5"));
    });

    it("Should not allow minting by non-LiquidStaking", async function () {
      const { stQFC, user1 } = await loadFixture(deployLiquidStakingFixture);

      await expect(
        stQFC.connect(user1).mint(user1.address, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(stQFC, "OnlyLiquidStaking");
    });
  });

  describe("Rewards Distribution", function () {
    it("Should only allow owner to distribute rewards", async function () {
      const { liquidStaking, user1 } = await loadFixture(deployLiquidStakingFixture);

      await liquidStaking.connect(user1).stake({ value: ethers.parseEther("10") });

      await expect(
        liquidStaking.connect(user1).distributeRewards({ value: ethers.parseEther("1") })
      ).to.be.revertedWithCustomError(liquidStaking, "OwnableUnauthorizedAccount");
    });

    it("Should revert with zero rewards", async function () {
      const { liquidStaking, owner } = await loadFixture(deployLiquidStakingFixture);

      await expect(
        liquidStaking.connect(owner).distributeRewards({ value: 0 })
      ).to.be.revertedWithCustomError(liquidStaking, "ZeroAmount");
    });

    it("Should emit RewardsDistributed event", async function () {
      const { liquidStaking, owner, user1 } = await loadFixture(deployLiquidStakingFixture);

      await liquidStaking.connect(user1).stake({ value: ethers.parseEther("100") });

      await expect(liquidStaking.connect(owner).distributeRewards({ value: ethers.parseEther("10") }))
        .to.emit(liquidStaking, "RewardsDistributed")
        .withArgs(ethers.parseEther("10"), ethers.parseEther("1.1"));
    });
  });
});
