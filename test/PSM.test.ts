import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("PSM (Peg Stability Module)", function () {
  async function deployFixture() {
    const [owner, alice, bob] = await ethers.getSigners();

    // Deploy QUSDToken
    const QUSDToken = await ethers.getContractFactory("QUSDToken");
    const qusd = await QUSDToken.deploy();

    // Deploy mock USDC (6 decimals)
    const MockToken = await ethers.getContractFactory("QFCToken");
    const usdc = await MockToken.deploy("USD Coin", "USDC", ethers.parseUnits("1000000000", 6), ethers.parseUnits("1000000", 6));

    // Deploy mock DAI (18 decimals)
    const dai = await MockToken.deploy("Dai Stablecoin", "DAI", ethers.parseEther("1000000000"), ethers.parseEther("1000000"));

    // Deploy PSM
    const PSM = await ethers.getContractFactory("PSM");
    const psm = await PSM.deploy(await qusd.getAddress());

    // Authorize PSM as vault on QUSDToken
    await qusd.setVault(await psm.getAddress());

    // Add USDC gem: 6 decimals, 10M ceiling, 0.1% tin, 0.1% tout
    await psm.addGem(
      await usdc.getAddress(),
      6,                                       // decimals
      ethers.parseEther("10000000"),            // 10M debt ceiling
      10,                                      // 0.1% tin
      10                                       // 0.1% tout
    );

    // Add DAI gem: 18 decimals, 5M ceiling, 0% tin, 0% tout
    await psm.addGem(
      await dai.getAddress(),
      18,
      ethers.parseEther("5000000"),
      0,  // no fee
      0
    );

    // Give alice and bob some USDC and DAI
    await usdc.transfer(alice.address, ethers.parseUnits("100000", 6));
    await usdc.transfer(bob.address, ethers.parseUnits("100000", 6));
    await dai.transfer(alice.address, ethers.parseEther("100000"));

    return { qusd, usdc, dai, psm, owner, alice, bob };
  }

  describe("Gem Management", function () {
    it("should add a gem with correct parameters", async function () {
      const { psm, usdc } = await loadFixture(deployFixture);
      const info = await psm.gems(await usdc.getAddress());
      expect(info.active).to.be.true;
      expect(info.decimals).to.equal(6);
      expect(info.debtCeiling).to.equal(ethers.parseEther("10000000"));
      expect(info.tin).to.equal(10);
      expect(info.tout).to.equal(10);
    });

    it("should reject duplicate gem", async function () {
      const { psm, usdc } = await loadFixture(deployFixture);
      await expect(psm.addGem(await usdc.getAddress(), 6, 1000, 0, 0))
        .to.be.revertedWithCustomError(psm, "GemAlreadyAdded");
    });

    it("should reject fee > 5%", async function () {
      const { psm } = await loadFixture(deployFixture);
      await expect(psm.addGem(ethers.ZeroAddress, 18, 1000, 501, 0))
        .to.be.revertedWithCustomError(psm, "FeeTooHigh");
    });

    it("should remove a gem", async function () {
      const { psm, usdc } = await loadFixture(deployFixture);
      await psm.removeGem(await usdc.getAddress());
      const info = await psm.gems(await usdc.getAddress());
      expect(info.active).to.be.false;
    });

    it("should update gem parameters", async function () {
      const { psm, usdc } = await loadFixture(deployFixture);
      await psm.updateGem(await usdc.getAddress(), ethers.parseEther("20000000"), 20, 30);
      const info = await psm.gems(await usdc.getAddress());
      expect(info.debtCeiling).to.equal(ethers.parseEther("20000000"));
      expect(info.tin).to.equal(20);
      expect(info.tout).to.equal(30);
    });

    it("should return gem list", async function () {
      const { psm } = await loadFixture(deployFixture);
      const list = await psm.getGemList();
      expect(list.length).to.equal(2);
    });
  });

  describe("SwapIn (Stablecoin → qUSD)", function () {
    it("should swap USDC for qUSD (6 decimals → 18 decimals)", async function () {
      const { psm, usdc, qusd, alice } = await loadFixture(deployFixture);

      const usdcAmount = ethers.parseUnits("1000", 6); // 1000 USDC
      await usdc.connect(alice).approve(await psm.getAddress(), usdcAmount);

      await expect(psm.connect(alice).swapIn(await usdc.getAddress(), usdcAmount))
        .to.emit(psm, "SwapIn");

      // 1000 USDC → 999 qUSD (0.1% fee = 1 qUSD)
      const balance = await qusd.balanceOf(alice.address);
      expect(balance).to.equal(ethers.parseEther("999"));
    });

    it("should swap DAI for qUSD with no fee", async function () {
      const { psm, dai, qusd, alice } = await loadFixture(deployFixture);

      const daiAmount = ethers.parseEther("1000");
      await dai.connect(alice).approve(await psm.getAddress(), daiAmount);

      await psm.connect(alice).swapIn(await dai.getAddress(), daiAmount);

      expect(await qusd.balanceOf(alice.address)).to.equal(ethers.parseEther("1000"));
    });

    it("should accumulate protocol fees", async function () {
      const { psm, usdc, alice } = await loadFixture(deployFixture);

      const usdcAmount = ethers.parseUnits("10000", 6);
      await usdc.connect(alice).approve(await psm.getAddress(), usdcAmount);
      await psm.connect(alice).swapIn(await usdc.getAddress(), usdcAmount);

      // 0.1% of 10000 = 10 qUSD fee
      expect(await psm.accumulatedFees()).to.equal(ethers.parseEther("10"));
    });

    it("should reject swap exceeding debt ceiling", async function () {
      const { psm, dai, alice } = await loadFixture(deployFixture);

      // DAI ceiling is 5M, try to swap 6M
      const amount = ethers.parseEther("6000000");
      await dai.connect(alice).approve(await psm.getAddress(), amount);

      // Alice only has 100K, but the ceiling check should fail first
      // Let's use a smaller amount but set a tiny ceiling
      await psm.updateGem(await dai.getAddress(), ethers.parseEther("500"), 0, 0);

      const smallAmount = ethers.parseEther("1000");
      await dai.connect(alice).approve(await psm.getAddress(), smallAmount);
      await expect(psm.connect(alice).swapIn(await dai.getAddress(), smallAmount))
        .to.be.revertedWithCustomError(psm, "DebtCeilingExceeded");
    });

    it("should reject zero amount", async function () {
      const { psm, usdc, alice } = await loadFixture(deployFixture);
      await expect(psm.connect(alice).swapIn(await usdc.getAddress(), 0))
        .to.be.revertedWithCustomError(psm, "ZeroAmount");
    });

    it("should reject inactive gem", async function () {
      const { psm, usdc, alice } = await loadFixture(deployFixture);
      await psm.removeGem(await usdc.getAddress());
      await expect(psm.connect(alice).swapIn(await usdc.getAddress(), 1000))
        .to.be.revertedWithCustomError(psm, "GemNotActive");
    });
  });

  describe("SwapOut (qUSD → Stablecoin)", function () {
    it("should swap qUSD for USDC", async function () {
      const { psm, usdc, qusd, alice } = await loadFixture(deployFixture);

      // First swap in to get qUSD and create reserves
      const usdcIn = ethers.parseUnits("10000", 6);
      await usdc.connect(alice).approve(await psm.getAddress(), usdcIn);
      await psm.connect(alice).swapIn(await usdc.getAddress(), usdcIn);

      // Now swap out 500 qUSD
      const qusdAmount = ethers.parseEther("500");
      await qusd.connect(alice).approve(await psm.getAddress(), qusdAmount);

      const usdcBefore = await usdc.balanceOf(alice.address);

      await expect(psm.connect(alice).swapOut(await usdc.getAddress(), qusdAmount))
        .to.emit(psm, "SwapOut");

      // 500 qUSD - 0.1% fee = 499.5 qUSD net → 499.5 USDC (truncated to 6 decimals = 499500000)
      const usdcAfter = await usdc.balanceOf(alice.address);
      const received = usdcAfter - usdcBefore;
      expect(received).to.equal(ethers.parseUnits("499.5", 6));
    });

    it("should reject swap with insufficient reserves", async function () {
      const { psm, usdc, qusd, alice, bob } = await loadFixture(deployFixture);

      // Alice swaps in 100 USDC
      await usdc.connect(alice).approve(await psm.getAddress(), ethers.parseUnits("100", 6));
      await psm.connect(alice).swapIn(await usdc.getAddress(), ethers.parseUnits("100", 6));

      // Transfer some qUSD to Bob
      await qusd.connect(alice).transfer(bob.address, ethers.parseEther("50"));

      // Bob tries to swap out 200 qUSD (only 100 USDC in reserves)
      await qusd.connect(bob).approve(await psm.getAddress(), ethers.parseEther("200"));
      await expect(psm.connect(bob).swapOut(await usdc.getAddress(), ethers.parseEther("200")))
        .to.be.revertedWithCustomError(psm, "InsufficientReserves");
    });
  });

  describe("Reserves", function () {
    it("should track reserves correctly", async function () {
      const { psm, usdc, alice } = await loadFixture(deployFixture);

      await usdc.connect(alice).approve(await psm.getAddress(), ethers.parseUnits("5000", 6));
      await psm.connect(alice).swapIn(await usdc.getAddress(), ethers.parseUnits("5000", 6));

      expect(await psm.getReserves(await usdc.getAddress())).to.equal(ethers.parseUnits("5000", 6));
    });

    it("should track available debt", async function () {
      const { psm, dai, alice } = await loadFixture(deployFixture);

      await dai.connect(alice).approve(await psm.getAddress(), ethers.parseEther("1000"));
      await psm.connect(alice).swapIn(await dai.getAddress(), ethers.parseEther("1000"));

      const available = await psm.getAvailableDebt(await dai.getAddress());
      expect(available).to.equal(ethers.parseEther("4999000")); // 5M - 1000
    });
  });

  describe("Admin", function () {
    it("should withdraw accumulated fees", async function () {
      const { psm, usdc, qusd, owner, alice } = await loadFixture(deployFixture);

      // Generate fees via swapIn
      await usdc.connect(alice).approve(await psm.getAddress(), ethers.parseUnits("10000", 6));
      await psm.connect(alice).swapIn(await usdc.getAddress(), ethers.parseUnits("10000", 6));

      const feesBefore = await psm.accumulatedFees();
      expect(feesBefore).to.be.gt(0);

      await expect(psm.withdrawFees(owner.address))
        .to.emit(psm, "FeesWithdrawn");

      expect(await psm.accumulatedFees()).to.equal(0);
      expect(await qusd.balanceOf(owner.address)).to.equal(feesBefore);
    });

    it("should pause and unpause", async function () {
      const { psm, usdc, alice } = await loadFixture(deployFixture);

      await psm.pause();

      await usdc.connect(alice).approve(await psm.getAddress(), ethers.parseUnits("100", 6));
      await expect(psm.connect(alice).swapIn(await usdc.getAddress(), ethers.parseUnits("100", 6)))
        .to.be.reverted;

      await psm.unpause();

      await expect(psm.connect(alice).swapIn(await usdc.getAddress(), ethers.parseUnits("100", 6)))
        .to.not.be.reverted;
    });

    it("should reject non-owner operations", async function () {
      const { psm, alice } = await loadFixture(deployFixture);
      await expect(psm.connect(alice).addGem(ethers.ZeroAddress, 18, 1000, 0, 0))
        .to.be.revertedWithCustomError(psm, "OwnableUnauthorizedAccount");
    });
  });
});
