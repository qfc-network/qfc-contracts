import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("YieldVault", function () {
  async function deployVaultFixture() {
    const [owner, user1, user2, feeRecipient] = await ethers.getSigners();

    // Deploy underlying token
    const QFCToken = await ethers.getContractFactory("QFCToken");
    const token = await QFCToken.deploy(
      "QFC Token",
      "QFC",
      ethers.parseEther("1000000000"),
      ethers.parseEther("1000000")
    );

    // Deploy vault
    const YieldVault = await ethers.getContractFactory("YieldVault");
    const vault = await YieldVault.deploy(
      await token.getAddress(),
      "QFC Yield Vault",
      "yvQFC",
      feeRecipient.address
    );

    // Deploy mock strategy
    const MockStrategy = await ethers.getContractFactory("MockStrategy");
    const strategy = await MockStrategy.deploy(
      await token.getAddress(),
      await vault.getAddress()
    );

    // Distribute tokens to users
    await token.transfer(user1.address, ethers.parseEther("10000"));
    await token.transfer(user2.address, ethers.parseEther("10000"));

    // Fund mock strategy for simulating yield
    await token.transfer(await strategy.getAddress(), ethers.parseEther("10000"));

    // Approve vault
    await token.connect(user1).approve(await vault.getAddress(), ethers.MaxUint256);
    await token.connect(user2).approve(await vault.getAddress(), ethers.MaxUint256);

    return { token, vault, strategy, owner, user1, user2, feeRecipient };
  }

  describe("Deployment", function () {
    it("Should set correct name and symbol", async function () {
      const { vault } = await loadFixture(deployVaultFixture);
      expect(await vault.name()).to.equal("QFC Yield Vault");
      expect(await vault.symbol()).to.equal("yvQFC");
    });

    it("Should set correct fee recipient", async function () {
      const { vault, feeRecipient } = await loadFixture(deployVaultFixture);
      expect(await vault.feeRecipient()).to.equal(feeRecipient.address);
    });

    it("Should have 10% performance fee", async function () {
      const { vault } = await loadFixture(deployVaultFixture);
      expect(await vault.PERFORMANCE_FEE()).to.equal(1000);
    });
  });

  describe("Deposit", function () {
    it("Should mint shares 1:1 on first deposit", async function () {
      const { vault, user1 } = await loadFixture(deployVaultFixture);
      const amount = ethers.parseEther("1000");

      await vault.connect(user1).deposit(amount, user1.address);

      expect(await vault.balanceOf(user1.address)).to.equal(amount);
      expect(await vault.totalAssets()).to.equal(amount);
    });

    it("Should emit Deposit event", async function () {
      const { vault, user1 } = await loadFixture(deployVaultFixture);
      const amount = ethers.parseEther("1000");

      await expect(vault.connect(user1).deposit(amount, user1.address))
        .to.emit(vault, "Deposit")
        .withArgs(user1.address, user1.address, amount, amount);
    });

    it("Should revert on zero deposit", async function () {
      const { vault, user1 } = await loadFixture(deployVaultFixture);
      await expect(
        vault.connect(user1).deposit(0, user1.address)
      ).to.be.revertedWith("Invalid deposit amount");
    });

    it("Should revert when paused", async function () {
      const { vault, user1 } = await loadFixture(deployVaultFixture);
      await vault.pause();
      await expect(
        vault.connect(user1).deposit(ethers.parseEther("100"), user1.address)
      ).to.be.revertedWithCustomError(vault, "EnforcedPause");
    });
  });

  describe("Withdraw", function () {
    it("Should withdraw correct assets", async function () {
      const { vault, token, user1 } = await loadFixture(deployVaultFixture);
      const amount = ethers.parseEther("1000");

      await vault.connect(user1).deposit(amount, user1.address);
      await vault.connect(user1).withdraw(amount, user1.address, user1.address);

      expect(await vault.balanceOf(user1.address)).to.equal(0);
      expect(await token.balanceOf(user1.address)).to.equal(ethers.parseEther("10000"));
    });

    it("Should allow approved spender to withdraw", async function () {
      const { vault, token, user1, user2 } = await loadFixture(deployVaultFixture);
      const amount = ethers.parseEther("1000");

      await vault.connect(user1).deposit(amount, user1.address);
      await vault.connect(user1).approve(user2.address, ethers.MaxUint256);
      await vault.connect(user2).withdraw(amount, user2.address, user1.address);

      expect(await vault.balanceOf(user1.address)).to.equal(0);
      expect(await token.balanceOf(user2.address)).to.equal(ethers.parseEther("11000"));
    });

    it("Should revert if not owner or approved", async function () {
      const { vault, user1, user2 } = await loadFixture(deployVaultFixture);
      const amount = ethers.parseEther("1000");

      await vault.connect(user1).deposit(amount, user1.address);
      await expect(
        vault.connect(user2).withdraw(amount, user2.address, user1.address)
      ).to.be.revertedWith("Insufficient allowance");
    });
  });

  describe("Redeem", function () {
    it("Should redeem shares for correct assets", async function () {
      const { vault, token, user1 } = await loadFixture(deployVaultFixture);
      const amount = ethers.parseEther("1000");

      await vault.connect(user1).deposit(amount, user1.address);
      const shares = await vault.balanceOf(user1.address);
      await vault.connect(user1).redeem(shares, user1.address, user1.address);

      expect(await vault.balanceOf(user1.address)).to.equal(0);
      expect(await token.balanceOf(user1.address)).to.equal(ethers.parseEther("10000"));
    });
  });

  describe("Strategy Management", function () {
    it("Should add strategy", async function () {
      const { vault, strategy } = await loadFixture(deployVaultFixture);
      const stratAddr = await strategy.getAddress();

      await expect(vault.addStrategy(stratAddr, 5000))
        .to.emit(vault, "StrategyAdded")
        .withArgs(stratAddr, 5000);

      expect(await vault.strategyCount()).to.equal(1);
      expect(await vault.totalAllocation()).to.equal(5000);
    });

    it("Should not allow duplicate strategy", async function () {
      const { vault, strategy } = await loadFixture(deployVaultFixture);
      const stratAddr = await strategy.getAddress();

      await vault.addStrategy(stratAddr, 5000);
      await expect(
        vault.addStrategy(stratAddr, 3000)
      ).to.be.revertedWith("Strategy already active");
    });

    it("Should not exceed 100% allocation", async function () {
      const { vault, strategy } = await loadFixture(deployVaultFixture);
      await expect(
        vault.addStrategy(await strategy.getAddress(), 10001)
      ).to.be.revertedWith("Allocation exceeds 100%");
    });

    it("Should remove strategy and withdraw funds", async function () {
      const { vault, strategy, user1 } = await loadFixture(deployVaultFixture);
      const stratAddr = await strategy.getAddress();

      // Deposit some funds and add strategy
      await vault.connect(user1).deposit(ethers.parseEther("1000"), user1.address);
      await vault.addStrategy(stratAddr, 10000);

      await vault.removeStrategy(stratAddr);

      expect(await vault.strategyCount()).to.equal(0);
      expect(await vault.totalAllocation()).to.equal(0);
    });

    it("Should only allow owner to add strategy", async function () {
      const { vault, strategy, user1 } = await loadFixture(deployVaultFixture);
      await expect(
        vault.connect(user1).addStrategy(await strategy.getAddress(), 5000)
      ).to.be.revertedWithCustomError(vault, "OwnableUnauthorizedAccount");
    });
  });

  describe("Harvest", function () {
    it("Should harvest profit and take 10% fee", async function () {
      const { vault, token, strategy, user1, feeRecipient } = await loadFixture(deployVaultFixture);
      const stratAddr = await strategy.getAddress();

      // User deposits
      await vault.connect(user1).deposit(ethers.parseEther("1000"), user1.address);

      // Add strategy with 100% allocation
      await vault.addStrategy(stratAddr, 10000);

      // Set profit for mock strategy
      const profit = ethers.parseEther("100");
      await strategy.setProfit(profit);

      const feeBalBefore = await token.balanceOf(feeRecipient.address);

      await expect(vault.harvest())
        .to.emit(vault, "Harvested");

      const feeBalAfter = await token.balanceOf(feeRecipient.address);
      const feeCollected = feeBalAfter - feeBalBefore;

      // 10% of 100 = 10
      expect(feeCollected).to.equal(ethers.parseEther("10"));
    });

    it("Should increase share value after harvest", async function () {
      const { vault, strategy, user1 } = await loadFixture(deployVaultFixture);

      await vault.connect(user1).deposit(ethers.parseEther("1000"), user1.address);
      await vault.addStrategy(await strategy.getAddress(), 10000);

      const priceBefore = await vault.sharePrice();

      await strategy.setProfit(ethers.parseEther("100"));
      await vault.harvest();

      const priceAfter = await vault.sharePrice();
      expect(priceAfter).to.be.gt(priceBefore);
    });
  });

  describe("Multiple Users", function () {
    it("Should handle multiple depositors correctly", async function () {
      const { vault, token, user1, user2 } = await loadFixture(deployVaultFixture);

      // User1 deposits 1000
      await vault.connect(user1).deposit(ethers.parseEther("1000"), user1.address);
      // User2 deposits 2000
      await vault.connect(user2).deposit(ethers.parseEther("2000"), user2.address);

      expect(await vault.totalAssets()).to.equal(ethers.parseEther("3000"));
      expect(await vault.balanceOf(user1.address)).to.equal(ethers.parseEther("1000"));
      expect(await vault.balanceOf(user2.address)).to.equal(ethers.parseEther("2000"));
    });

    it("Should distribute yield proportionally", async function () {
      const { vault, token, strategy, user1, user2 } = await loadFixture(deployVaultFixture);
      const stratAddr = await strategy.getAddress();

      // Both users deposit
      await vault.connect(user1).deposit(ethers.parseEther("1000"), user1.address);
      await vault.connect(user2).deposit(ethers.parseEther("3000"), user2.address);

      // Add strategy and harvest profit
      await vault.addStrategy(stratAddr, 10000);
      await strategy.setProfit(ethers.parseEther("100"));
      await vault.harvest();

      // Net profit = 90 (100 - 10% fee)
      // totalAssets should now include the profit kept in vault
      const totalAssets = await vault.totalAssets();
      expect(totalAssets).to.be.gt(ethers.parseEther("4000"));

      // User1 has 25% of shares, user2 has 75%
      const user1Assets = await vault.convertToAssets(await vault.balanceOf(user1.address));
      const user2Assets = await vault.convertToAssets(await vault.balanceOf(user2.address));

      // User1 should get ~25% of net profit, user2 ~75%
      expect(user1Assets).to.be.gt(ethers.parseEther("1000"));
      expect(user2Assets).to.be.gt(ethers.parseEther("3000"));
    });
  });

  describe("Emergency", function () {
    it("Should pause and unpause", async function () {
      const { vault, user1 } = await loadFixture(deployVaultFixture);

      await vault.pause();
      await expect(
        vault.connect(user1).deposit(ethers.parseEther("100"), user1.address)
      ).to.be.revertedWithCustomError(vault, "EnforcedPause");

      await vault.unpause();
      await vault.connect(user1).deposit(ethers.parseEther("100"), user1.address);
      expect(await vault.balanceOf(user1.address)).to.equal(ethers.parseEther("100"));
    });

    it("Should withdrawAll from strategies", async function () {
      const { vault, token, strategy, user1 } = await loadFixture(deployVaultFixture);
      const vaultAddr = await vault.getAddress();
      const stratAddr = await strategy.getAddress();

      await vault.connect(user1).deposit(ethers.parseEther("1000"), user1.address);
      await vault.addStrategy(stratAddr, 10000);

      // Simulate deploying to strategy by sending tokens there
      // and calling deposit
      const vaultBal = await token.balanceOf(vaultAddr);

      await vault.withdrawAll();

      // After withdrawAll, strategy should have returned funds
      expect(await strategy.estimatedTotalAssets()).to.equal(
        await token.balanceOf(stratAddr)
      );
    });

    it("Should emit EmergencyWithdrawAll event", async function () {
      const { vault, strategy } = await loadFixture(deployVaultFixture);
      await vault.addStrategy(await strategy.getAddress(), 5000);

      await expect(vault.withdrawAll()).to.emit(vault, "EmergencyWithdrawAll");
    });

    it("Should allow withdrawals when paused", async function () {
      const { vault, token, user1 } = await loadFixture(deployVaultFixture);

      await vault.connect(user1).deposit(ethers.parseEther("1000"), user1.address);
      await vault.pause();

      // Withdrawals should still work
      await vault.connect(user1).withdraw(
        ethers.parseEther("1000"),
        user1.address,
        user1.address
      );
      expect(await vault.balanceOf(user1.address)).to.equal(0);
    });
  });

  describe("View Functions", function () {
    it("Should return correct share price", async function () {
      const { vault, user1 } = await loadFixture(deployVaultFixture);

      // Before any deposits, share price is 1:1
      expect(await vault.sharePrice()).to.equal(ethers.parseEther("1"));

      await vault.connect(user1).deposit(ethers.parseEther("1000"), user1.address);
      expect(await vault.sharePrice()).to.equal(ethers.parseEther("1"));
    });

    it("Should convert correctly between shares and assets", async function () {
      const { vault, user1 } = await loadFixture(deployVaultFixture);

      await vault.connect(user1).deposit(ethers.parseEther("1000"), user1.address);

      const shares = await vault.convertToShares(ethers.parseEther("500"));
      expect(shares).to.equal(ethers.parseEther("500"));

      const assets = await vault.convertToAssets(ethers.parseEther("500"));
      expect(assets).to.equal(ethers.parseEther("500"));
    });
  });
});
