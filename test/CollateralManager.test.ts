import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("CollateralManager (Multi-Collateral CDP)", function () {
  const WETH_PRICE = 300000000000n; // $3000 with 8 decimals
  const WBTC_PRICE = 6000000000000n; // $60000 with 8 decimals

  async function deployFixture() {
    const [owner, alice, bob, liquidator] = await ethers.getSigners();

    // Deploy QUSDToken
    const QUSDToken = await ethers.getContractFactory("QUSDToken");
    const qusd = await QUSDToken.deploy();

    // Deploy mock tokens
    const MockToken = await ethers.getContractFactory("QFCToken");
    const weth = await MockToken.deploy("Wrapped Ether", "WETH", ethers.parseEther("1000000"), ethers.parseEther("100000"));
    const wbtc = await MockToken.deploy("Wrapped Bitcoin", "WBTC", ethers.parseUnits("1000000", 8), ethers.parseUnits("100000", 8));

    // Deploy price feeds
    const PriceFeed = await ethers.getContractFactory("PriceFeed");
    const wethFeed = await PriceFeed.deploy(WETH_PRICE);
    const wbtcFeed = await PriceFeed.deploy(WBTC_PRICE);

    // Deploy CollateralManager
    const CollateralManager = await ethers.getContractFactory("CollateralManager");
    const cm = await CollateralManager.deploy(
      await qusd.getAddress(),
      ethers.parseEther("100000000") // 100M global ceiling
    );

    // Authorize CM as vault
    await qusd.setVault(await cm.getAddress());

    // Add WETH: 18 decimals, 150% min, 130% liq, 10% penalty, 2% fee, 50M ceiling
    await cm.addCollateral(
      await weth.getAddress(),
      await wethFeed.getAddress(),
      18,
      15000, // 150%
      13000, // 130%
      1000,  // 10%
      200,   // 2% annual
      ethers.parseEther("50000000")
    );

    // Add WBTC: 8 decimals, 160% min, 140% liq, 10% penalty, 1.5% fee, 30M ceiling
    await cm.addCollateral(
      await wbtc.getAddress(),
      await wbtcFeed.getAddress(),
      8,
      16000, // 160%
      14000, // 140%
      1000,  // 10%
      150,   // 1.5% annual
      ethers.parseEther("30000000")
    );

    // Give tokens to users
    await weth.transfer(alice.address, ethers.parseEther("100"));
    await weth.transfer(bob.address, ethers.parseEther("100"));
    await weth.transfer(liquidator.address, ethers.parseEther("100"));
    await wbtc.transfer(alice.address, ethers.parseUnits("10", 8));

    return { qusd, weth, wbtc, wethFeed, wbtcFeed, cm, owner, alice, bob, liquidator };
  }

  describe("Collateral Management", function () {
    it("should add collateral types", async function () {
      const { cm } = await loadFixture(deployFixture);
      expect(await cm.collateralCount()).to.equal(2);
    });

    it("should reject duplicate collateral", async function () {
      const { cm, weth, wethFeed } = await loadFixture(deployFixture);
      await expect(cm.addCollateral(await weth.getAddress(), await wethFeed.getAddress(), 18, 15000, 13000, 1000, 200, 1000))
        .to.be.revertedWithCustomError(cm, "CollateralAlreadyAdded");
    });

    it("should reject invalid ratio (min <= 100%)", async function () {
      const { cm, wethFeed } = await loadFixture(deployFixture);
      await expect(cm.addCollateral(ethers.ZeroAddress, await wethFeed.getAddress(), 18, 10000, 9000, 1000, 200, 1000))
        .to.be.revertedWithCustomError(cm, "InvalidParameters");
    });

    it("should update collateral parameters", async function () {
      const { cm, weth } = await loadFixture(deployFixture);
      await cm.updateCollateral(await weth.getAddress(), 17000, 14000, 1500, 300, ethers.parseEther("80000000"));
      const ct = await cm.collateralTypes(await weth.getAddress());
      expect(ct.minCollateralRatio).to.equal(17000);
      expect(ct.debtCeiling).to.equal(ethers.parseEther("80000000"));
    });
  });

  describe("Deposit & Mint", function () {
    it("should deposit WETH as collateral", async function () {
      const { cm, weth, alice } = await loadFixture(deployFixture);

      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await expect(cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10")))
        .to.emit(cm, "Deposited")
        .withArgs(alice.address, await weth.getAddress(), ethers.parseEther("10"));

      const pos = await cm.positions(alice.address, await weth.getAddress());
      expect(pos.collateral).to.equal(ethers.parseEther("10"));
    });

    it("should mint qUSD against WETH collateral", async function () {
      const { cm, weth, qusd, alice } = await loadFixture(deployFixture);

      // Deposit 10 WETH ($30,000)
      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));

      // Mint 19000 qUSD (ratio = 30000/19000 = 157.9% > 150%)
      await expect(cm.connect(alice).mint(await weth.getAddress(), ethers.parseEther("19000")))
        .to.emit(cm, "Minted");

      expect(await qusd.balanceOf(alice.address)).to.equal(ethers.parseEther("19000"));
    });

    it("should reject mint below min collateral ratio", async function () {
      const { cm, weth, alice } = await loadFixture(deployFixture);

      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));

      // Try 21000 qUSD (ratio = 30000/21000 = 142.8% < 150%)
      await expect(cm.connect(alice).mint(await weth.getAddress(), ethers.parseEther("21000")))
        .to.be.revertedWithCustomError(cm, "BelowMinCollateralRatio");
    });

    it("should deposit WBTC (8 decimals) and mint qUSD", async function () {
      const { cm, wbtc, qusd, alice } = await loadFixture(deployFixture);

      // Deposit 1 WBTC ($60,000)
      const oneWbtc = ethers.parseUnits("1", 8);
      await wbtc.connect(alice).approve(await cm.getAddress(), oneWbtc);
      await cm.connect(alice).deposit(await wbtc.getAddress(), oneWbtc);

      // Mint 35000 qUSD (ratio = 60000/35000 = 171% > 160%)
      await cm.connect(alice).mint(await wbtc.getAddress(), ethers.parseEther("35000"));
      expect(await qusd.balanceOf(alice.address)).to.equal(ethers.parseEther("35000"));
    });

    it("should reject mint exceeding per-asset debt ceiling", async function () {
      const { cm, weth, alice } = await loadFixture(deployFixture);

      // Set a tiny ceiling
      await cm.updateCollateral(await weth.getAddress(), 15000, 13000, 1000, 200, ethers.parseEther("100"));

      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));

      await expect(cm.connect(alice).mint(await weth.getAddress(), ethers.parseEther("200")))
        .to.be.revertedWithCustomError(cm, "DebtCeilingExceeded");
    });

    it("should reject mint exceeding global debt ceiling", async function () {
      const { cm, weth, alice } = await loadFixture(deployFixture);

      await cm.setGlobalDebtCeiling(ethers.parseEther("100"));

      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));

      await expect(cm.connect(alice).mint(await weth.getAddress(), ethers.parseEther("200")))
        .to.be.revertedWithCustomError(cm, "GlobalDebtCeilingExceeded");
    });
  });

  describe("Burn & Withdraw", function () {
    it("should burn qUSD to repay debt", async function () {
      const { cm, weth, qusd, alice } = await loadFixture(deployFixture);

      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).mint(await weth.getAddress(), ethers.parseEther("10000"));

      await expect(cm.connect(alice).burn(await weth.getAddress(), ethers.parseEther("5000")))
        .to.emit(cm, "Burned");

      const pos = await cm.positions(alice.address, await weth.getAddress());
      expect(pos.debt).to.be.closeTo(ethers.parseEther("5000"), ethers.parseEther("1"));
    });

    it("should withdraw collateral when ratio is safe", async function () {
      const { cm, weth, alice } = await loadFixture(deployFixture);

      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).mint(await weth.getAddress(), ethers.parseEther("5000"));

      // Withdraw 5 WETH: remaining 5 * $3000 = $15000, debt $5000 → 300% > 150%
      await expect(cm.connect(alice).withdraw(await weth.getAddress(), ethers.parseEther("5")))
        .to.emit(cm, "Withdrawn");
    });

    it("should reject withdrawal that breaks ratio", async function () {
      const { cm, weth, alice } = await loadFixture(deployFixture);

      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).mint(await weth.getAddress(), ethers.parseEther("15000"));

      // Withdraw 8 WETH: remaining 2 * $3000 = $6000, debt $15000 → 40% < 150%
      await expect(cm.connect(alice).withdraw(await weth.getAddress(), ethers.parseEther("8")))
        .to.be.revertedWithCustomError(cm, "BelowMinCollateralRatio");
    });
  });

  describe("Liquidation", function () {
    it("should liquidate undercollateralized position", async function () {
      const { cm, weth, wethFeed, qusd, alice, liquidator } = await loadFixture(deployFixture);

      // Alice: 10 WETH @ $3000 = $30000, mint 19000 qUSD (ratio ~157%)
      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).mint(await weth.getAddress(), ethers.parseEther("19000"));

      // Liquidator gets qUSD
      await weth.connect(liquidator).approve(await cm.getAddress(), ethers.parseEther("50"));
      await cm.connect(liquidator).deposit(await weth.getAddress(), ethers.parseEther("50"));
      await cm.connect(liquidator).mint(await weth.getAddress(), ethers.parseEther("50000"));

      // Price drops to $2400 → ratio = 24000/19000 = 126% < 130%
      await wethFeed.setPrice(240000000000n);

      await expect(cm.connect(liquidator).liquidate(alice.address, await weth.getAddress()))
        .to.emit(cm, "Liquidated");

      const pos = await cm.positions(alice.address, await weth.getAddress());
      expect(pos.collateral).to.equal(0);
      expect(pos.debt).to.equal(0);
    });

    it("should reject liquidation of healthy position", async function () {
      const { cm, weth, alice, liquidator } = await loadFixture(deployFixture);

      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).mint(await weth.getAddress(), ethers.parseEther("5000"));

      await expect(cm.connect(liquidator).liquidate(alice.address, await weth.getAddress()))
        .to.be.revertedWithCustomError(cm, "NotLiquidatable");
    });
  });

  describe("Stability Fee", function () {
    it("should accrue stability fees over time", async function () {
      const { cm, weth, alice } = await loadFixture(deployFixture);

      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).mint(await weth.getAddress(), ethers.parseEther("10000"));

      // Advance 1 year
      await time.increase(365.25 * 24 * 3600);

      const totalDebt = await cm.getTotalDebt(alice.address, await weth.getAddress());
      // 2% of 10000 = 200 fee
      expect(totalDebt).to.be.closeTo(ethers.parseEther("10200"), ethers.parseEther("1"));
    });
  });

  describe("View Functions", function () {
    it("should return collateral ratio", async function () {
      const { cm, weth, alice } = await loadFixture(deployFixture);

      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).mint(await weth.getAddress(), ethers.parseEther("10000"));

      // 10 WETH * $3000 = $30000, debt = $10000 → 300% = 30000 bp
      const ratio = await cm.getCollateralRatio(alice.address, await weth.getAddress());
      expect(ratio).to.be.closeTo(30000n, 10n);
    });

    it("should return max uint for zero debt", async function () {
      const { cm, weth, alice } = await loadFixture(deployFixture);

      await weth.connect(alice).approve(await cm.getAddress(), ethers.parseEther("10"));
      await cm.connect(alice).deposit(await weth.getAddress(), ethers.parseEther("10"));

      const ratio = await cm.getCollateralRatio(alice.address, await weth.getAddress());
      expect(ratio).to.equal(ethers.MaxUint256);
    });
  });
});
