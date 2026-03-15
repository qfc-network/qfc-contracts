import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import {
  InterestRateModel,
  PriceOracle,
  QToken,
  LendingPool,
  QFCToken,
} from "../typechain-types";

describe("QFC Lending Protocol", function () {
  const PRECISION = ethers.parseEther("1");

  async function deployLendingFixture() {
    const [owner, alice, bob, charlie] = await ethers.getSigners();

    // Deploy underlying tokens
    const Token = await ethers.getContractFactory("QFCToken");
    const qfc = await Token.deploy("QFC Token", "QFC", ethers.parseEther("1000000000"), ethers.parseEther("1000000"));
    const ttk = await Token.deploy("Test Token", "TTK", ethers.parseEther("1000000000"), ethers.parseEther("1000000"));
    const qusd = await Token.deploy("qUSD Stablecoin", "qUSD", ethers.parseEther("1000000000"), ethers.parseEther("1000000"));

    // Deploy InterestRateModel: 2% base, ~20% at 80% util, jump to 100% at 100%
    const InterestRateModel = await ethers.getContractFactory("InterestRateModel");
    const irm = await InterestRateModel.deploy(
      ethers.parseEther("0.02"),   // 2% base
      ethers.parseEther("0.225"),  // multiplier
      ethers.parseEther("4.0"),    // jump multiplier
      ethers.parseEther("0.8")     // 80% kink
    );

    // Deploy PriceOracle
    const PriceOracle = await ethers.getContractFactory("contracts/lending/PriceOracle.sol:PriceOracle");
    const oracle = await PriceOracle.deploy();

    // Set prices: QFC=$10, TTK=$5, QUSD=$1
    await oracle.setPrices(
      [await qfc.getAddress(), await ttk.getAddress(), await qusd.getAddress()],
      [ethers.parseEther("10"), ethers.parseEther("5"), ethers.parseEther("1")]
    );

    // Deploy LendingPool
    const LendingPool = await ethers.getContractFactory("LendingPool");
    const pool = await LendingPool.deploy(await oracle.getAddress());
    const poolAddr = await pool.getAddress();

    // Deploy QTokens
    const QTokenFactory = await ethers.getContractFactory("QToken");
    const qQFC = await QTokenFactory.deploy("QFC Lending QFC", "qQFC", await qfc.getAddress(), await irm.getAddress(), poolAddr);
    const qTTK = await QTokenFactory.deploy("QFC Lending TTK", "qTTK", await ttk.getAddress(), await irm.getAddress(), poolAddr);
    const qQUSD = await QTokenFactory.deploy("QFC Lending QUSD", "qQUSD", await qusd.getAddress(), await irm.getAddress(), poolAddr);

    // List markets
    await pool.listMarket(await qfc.getAddress(), await qQFC.getAddress(), ethers.parseEther("0.75"));
    await pool.listMarket(await ttk.getAddress(), await qTTK.getAddress(), ethers.parseEther("0.6"));
    await pool.listMarket(await qusd.getAddress(), await qQUSD.getAddress(), ethers.parseEther("0.8"));

    // Distribute tokens to users
    const amount = ethers.parseEther("100000");
    for (const user of [alice, bob, charlie]) {
      await qfc.transfer(user.address, amount);
      await ttk.transfer(user.address, amount);
      await qusd.transfer(user.address, amount);
    }

    // Approve LendingPool for all users
    const maxApproval = ethers.MaxUint256;
    for (const user of [owner, alice, bob, charlie]) {
      await qfc.connect(user).approve(poolAddr, maxApproval);
      await ttk.connect(user).approve(poolAddr, maxApproval);
      await qusd.connect(user).approve(poolAddr, maxApproval);
    }

    return { owner, alice, bob, charlie, qfc, ttk, qusd, irm, oracle, pool, qQFC, qTTK, qQUSD };
  }

  // ─── InterestRateModel ──────────────────────────────────────────────

  describe("InterestRateModel", function () {
    it("should return 0 utilization when no borrows", async function () {
      const { irm } = await loadFixture(deployLendingFixture);
      expect(await irm.utilizationRate(1000, 0, 0)).to.equal(0);
    });

    it("should calculate utilization correctly", async function () {
      const { irm } = await loadFixture(deployLendingFixture);
      // 200 borrows, 800 cash, 0 reserves → 200/1000 = 20%
      const util = await irm.utilizationRate(800, 200, 0);
      expect(util).to.equal(ethers.parseEther("0.2"));
    });

    it("should return higher borrow rate above kink", async function () {
      const { irm } = await loadFixture(deployLendingFixture);
      const rateLow = await irm.getBorrowRate(900, 100, 0);   // 10% util
      const rateHigh = await irm.getBorrowRate(100, 900, 0);  // 90% util (above kink)
      expect(rateHigh).to.be.gt(rateLow);
    });

    it("should allow owner to update rate model", async function () {
      const { irm } = await loadFixture(deployLendingFixture);
      await expect(irm.updateRateModel(
        ethers.parseEther("0.03"),
        ethers.parseEther("0.3"),
        ethers.parseEther("5.0"),
        ethers.parseEther("0.7")
      )).to.emit(irm, "RateModelUpdated");
    });

    it("should reject kink > 100%", async function () {
      const { irm } = await loadFixture(deployLendingFixture);
      await expect(irm.updateRateModel(
        ethers.parseEther("0.02"),
        ethers.parseEther("0.225"),
        ethers.parseEther("4.0"),
        ethers.parseEther("1.1")
      )).to.be.revertedWith("InterestRateModel: kink > 100%");
    });
  });

  // ─── PriceOracle ────────────────────────────────────────────────────

  describe("PriceOracle", function () {
    it("should return set prices", async function () {
      const { oracle, qfc } = await loadFixture(deployLendingFixture);
      expect(await oracle.getPrice(await qfc.getAddress())).to.equal(ethers.parseEther("10"));
    });

    it("should revert for unset prices", async function () {
      const { oracle } = await loadFixture(deployLendingFixture);
      await expect(oracle.getPrice(ethers.ZeroAddress)).to.be.revertedWith("PriceOracle: price not set");
    });

    it("should reject zero price", async function () {
      const { oracle, qfc } = await loadFixture(deployLendingFixture);
      await expect(oracle.setPrice(await qfc.getAddress(), 0)).to.be.revertedWith("PriceOracle: price must be > 0");
    });

    it("should allow owner to update prices", async function () {
      const { oracle, qfc } = await loadFixture(deployLendingFixture);
      await oracle.setPrice(await qfc.getAddress(), ethers.parseEther("20"));
      expect(await oracle.getPrice(await qfc.getAddress())).to.equal(ethers.parseEther("20"));
    });

    it("should reject non-owner price updates", async function () {
      const { oracle, qfc, alice } = await loadFixture(deployLendingFixture);
      await expect(
        oracle.connect(alice).setPrice(await qfc.getAddress(), ethers.parseEther("20"))
      ).to.be.revertedWithCustomError(oracle, "OwnableUnauthorizedAccount");
    });
  });

  // ─── Supply ─────────────────────────────────────────────────────────

  describe("Supply", function () {
    it("should mint qTokens on supply", async function () {
      const { pool, qfc, qQFC, alice } = await loadFixture(deployLendingFixture);
      const supplyAmount = ethers.parseEther("1000");

      await pool.connect(alice).supply(await qfc.getAddress(), supplyAmount);

      const qTokenBal = await qQFC.balanceOf(alice.address);
      expect(qTokenBal).to.be.gt(0);
    });

    it("should track underlying balance correctly", async function () {
      const { pool, qfc, qQFC, alice } = await loadFixture(deployLendingFixture);
      const supplyAmount = ethers.parseEther("1000");

      await pool.connect(alice).supply(await qfc.getAddress(), supplyAmount);

      const underlyingBal = await qQFC.balanceOfUnderlying(alice.address);
      // Should be approximately equal (minor rounding)
      expect(underlyingBal).to.be.closeTo(supplyAmount, ethers.parseEther("0.01"));
    });

    it("should emit Supply event", async function () {
      const { pool, qfc, alice } = await loadFixture(deployLendingFixture);
      const supplyAmount = ethers.parseEther("1000");

      await expect(pool.connect(alice).supply(await qfc.getAddress(), supplyAmount))
        .to.emit(pool, "Supply")
        .withArgs(alice.address, await qfc.getAddress(), supplyAmount);
    });

    it("should reject zero supply", async function () {
      const { pool, qfc, alice } = await loadFixture(deployLendingFixture);
      await expect(
        pool.connect(alice).supply(await qfc.getAddress(), 0)
      ).to.be.revertedWith("LendingPool: zero amount");
    });

    it("should reject supply to unlisted market", async function () {
      const { pool, alice } = await loadFixture(deployLendingFixture);
      await expect(
        pool.connect(alice).supply(ethers.ZeroAddress, ethers.parseEther("100"))
      ).to.be.revertedWith("LendingPool: not listed");
    });
  });

  // ─── Withdraw ───────────────────────────────────────────────────────

  describe("Withdraw", function () {
    it("should return underlying on withdraw", async function () {
      const { pool, qfc, qQFC, alice } = await loadFixture(deployLendingFixture);
      const supplyAmount = ethers.parseEther("1000");
      const qfcAddr = await qfc.getAddress();

      await pool.connect(alice).supply(qfcAddr, supplyAmount);
      const balBefore = await qfc.balanceOf(alice.address);
      const qTokenBal = await qQFC.balanceOf(alice.address);

      await pool.connect(alice).withdraw(qfcAddr, qTokenBal);

      const balAfter = await qfc.balanceOf(alice.address);
      expect(balAfter - balBefore).to.be.closeTo(supplyAmount, ethers.parseEther("0.01"));
    });

    it("should reject withdraw that would under-collateralize", async function () {
      const { pool, qfc, qQFC, qusd, alice, bob } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      // Alice supplies QFC and enters market
      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);

      // Bob supplies QUSD for liquidity
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));

      // Alice borrows QUSD
      await pool.connect(alice).borrow(qusdAddr, ethers.parseEther("5000"));

      // Alice tries to withdraw all QFC — should fail
      const qTokenBal = await qQFC.balanceOf(alice.address);
      await expect(
        pool.connect(alice).withdraw(qfcAddr, qTokenBal)
      ).to.be.revertedWith("LendingPool: insufficient collateral after withdraw");
    });
  });

  // ─── Borrow ─────────────────────────────────────────────────────────

  describe("Borrow", function () {
    it("should allow borrowing against collateral", async function () {
      const { pool, qfc, qusd, alice, bob } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      // Alice supplies QFC as collateral
      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);

      // Bob supplies QUSD for borrowing
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));

      // Alice borrows QUSD: 1000 QFC * $10 * 75% CF = $7500 max borrow
      const borrowAmount = ethers.parseEther("5000"); // $5000 < $7500
      const balBefore = await qusd.balanceOf(alice.address);

      await pool.connect(alice).borrow(qusdAddr, borrowAmount);

      const balAfter = await qusd.balanceOf(alice.address);
      expect(balAfter - balBefore).to.equal(borrowAmount);
    });

    it("should reject borrowing beyond collateral factor", async function () {
      const { pool, qfc, qusd, alice, bob } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      // Alice supplies 1000 QFC ($10k value, $7.5k borrow limit at 75%)
      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);

      // Bob supplies QUSD
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));

      // Alice tries to borrow $8000 > $7500 limit
      await expect(
        pool.connect(alice).borrow(qusdAddr, ethers.parseEther("8000"))
      ).to.be.revertedWith("LendingPool: insufficient collateral");
    });

    it("should reject borrowing without collateral", async function () {
      const { pool, qusd, alice, bob } = await loadFixture(deployLendingFixture);
      const qusdAddr = await qusd.getAddress();

      // Bob supplies QUSD
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));

      // Alice tries to borrow without supplying collateral
      await expect(
        pool.connect(alice).borrow(qusdAddr, ethers.parseEther("100"))
      ).to.be.revertedWith("LendingPool: insufficient collateral");
    });

    it("should track health factor correctly", async function () {
      const { pool, qfc, qusd, alice, bob } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      // Alice supplies 1000 QFC and borrows 5000 QUSD
      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));
      await pool.connect(alice).borrow(qusdAddr, ethers.parseEther("5000"));

      // HF = ($10000 * 0.75) / $5000 = 1.5
      const hf = await pool.getHealthFactor(alice.address);
      expect(hf).to.be.closeTo(ethers.parseEther("1.5"), ethers.parseEther("0.01"));
    });

    it("should return max health factor with no borrows", async function () {
      const { pool, alice } = await loadFixture(deployLendingFixture);
      const hf = await pool.getHealthFactor(alice.address);
      expect(hf).to.equal(ethers.MaxUint256);
    });
  });

  // ─── Repay ──────────────────────────────────────────────────────────

  describe("Repay", function () {
    it("should reduce borrow balance on repay", async function () {
      const { pool, qfc, qusd, qQUSD, alice, bob } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      // Setup: Alice supplies QFC, borrows QUSD
      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));
      await pool.connect(alice).borrow(qusdAddr, ethers.parseEther("5000"));

      // Repay half
      await qusd.connect(alice).approve(await pool.getAddress(), ethers.MaxUint256);
      await pool.connect(alice).repay(qusdAddr, ethers.parseEther("2500"));

      const borrowBal = await qQUSD.borrowBalanceCurrent(alice.address);
      expect(borrowBal).to.be.closeTo(ethers.parseEther("2500"), ethers.parseEther("1"));
    });

    it("should allow full repayment with max uint", async function () {
      const { pool, qfc, qusd, qQUSD, alice, bob } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));
      await pool.connect(alice).borrow(qusdAddr, ethers.parseEther("5000"));

      // Full repay
      await qusd.connect(alice).approve(await pool.getAddress(), ethers.MaxUint256);
      await pool.connect(alice).repay(qusdAddr, ethers.MaxUint256);

      const borrowBal = await qQUSD.borrowBalanceCurrent(alice.address);
      expect(borrowBal).to.equal(0);
    });
  });

  // ─── Interest Accrual ───────────────────────────────────────────────

  describe("Interest Accrual", function () {
    it("should increase exchange rate over time", async function () {
      const { pool, qfc, qusd, qQFC, alice, bob } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      // Alice supplies QFC
      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("10000"));
      const rateBefore = await qQFC.exchangeRate();

      // Bob supplies QFC and borrows (to generate interest)
      await pool.connect(bob).supply(qfcAddr, ethers.parseEther("5000"));
      await pool.connect(bob).enterMarket(qfcAddr);
      // Bob supplies QUSD as additional collateral
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));
      await pool.connect(bob).enterMarket(qusdAddr);
      // Bob borrows QFC against his collateral
      await pool.connect(bob).borrow(qfcAddr, ethers.parseEther("3000"));

      // Advance time by 1 year
      await time.increase(365 * 24 * 60 * 60);

      // Trigger accrual
      await qQFC.accrueInterest();
      const rateAfter = await qQFC.exchangeRate();

      expect(rateAfter).to.be.gt(rateBefore);
    });

    it("should increase borrow balance over time", async function () {
      const { pool, qfc, qusd, qQFC, alice, bob } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      // Alice supplies QFC as collateral
      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("10000"));
      await pool.connect(alice).enterMarket(qfcAddr);

      // Bob provides QUSD and QFC liquidity
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));
      await pool.connect(bob).supply(qfcAddr, ethers.parseEther("50000"));

      // Alice borrows QFC
      await pool.connect(alice).borrow(qfcAddr, ethers.parseEther("1000"));

      // Advance time by 1 year
      await time.increase(365 * 24 * 60 * 60);
      await qQFC.accrueInterest();

      const borrowBal = await qQFC.borrowBalanceCurrent(alice.address);
      // Should be > original 1000 due to interest
      expect(borrowBal).to.be.gt(ethers.parseEther("1000"));
    });
  });

  // ─── Liquidation ────────────────────────────────────────────────────

  describe("Liquidation", function () {
    it("should liquidate under-collateralized position", async function () {
      const { pool, qfc, qusd, qQFC, oracle, alice, bob, charlie } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      // Alice supplies 1000 QFC ($10k) and borrows 7000 QUSD ($7k)
      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));
      await pool.connect(alice).borrow(qusdAddr, ethers.parseEther("7000"));

      // Price drop: QFC $10 → $5 → collateral = $5000 * 0.75 = $3750 < $7000 borrow
      await oracle.setPrice(qfcAddr, ethers.parseEther("5"));

      const hf = await pool.getHealthFactor(alice.address);
      expect(hf).to.be.lt(PRECISION); // Under-collateralized

      // Charlie liquidates: repay up to 50% of borrow = 3500 QUSD
      const repayAmount = ethers.parseEther("3500");
      await qusd.connect(charlie).approve(await pool.getAddress(), ethers.MaxUint256);

      const charlieBefore = await qQFC.balanceOf(charlie.address);
      await pool.connect(charlie).liquidate(alice.address, qusdAddr, qfcAddr, repayAmount);
      const charlieAfter = await qQFC.balanceOf(charlie.address);

      // Charlie should have received qQFC tokens
      expect(charlieAfter).to.be.gt(charlieBefore);
    });

    it("should reject liquidation of healthy position", async function () {
      const { pool, qfc, qusd, alice, bob, charlie } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));
      await pool.connect(alice).borrow(qusdAddr, ethers.parseEther("5000"));

      await qusd.connect(charlie).approve(await pool.getAddress(), ethers.MaxUint256);
      await expect(
        pool.connect(charlie).liquidate(alice.address, qusdAddr, qfcAddr, ethers.parseEther("1000"))
      ).to.be.revertedWith("LendingPool: health factor >= 1");
    });

    it("should reject self-liquidation", async function () {
      const { pool, qfc, qusd, alice, bob } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));
      await pool.connect(alice).borrow(qusdAddr, ethers.parseEther("5000"));

      await expect(
        pool.connect(alice).liquidate(alice.address, qusdAddr, qfcAddr, ethers.parseEther("1000"))
      ).to.be.revertedWith("LendingPool: cannot self-liquidate");
    });

    it("should reject exceeding close factor", async function () {
      const { pool, qfc, qusd, oracle, alice, bob, charlie } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));
      await pool.connect(alice).borrow(qusdAddr, ethers.parseEther("7000"));

      // Drop price to make liquidatable
      await oracle.setPrice(qfcAddr, ethers.parseEther("5"));

      // Try to repay more than 50% of borrow (>3500)
      await qusd.connect(charlie).approve(await pool.getAddress(), ethers.MaxUint256);
      await expect(
        pool.connect(charlie).liquidate(alice.address, qusdAddr, qfcAddr, ethers.parseEther("4000"))
      ).to.be.revertedWith("LendingPool: exceeds close factor");
    });

    it("should give liquidator 5% bonus", async function () {
      const { pool, qfc, qusd, qQFC, oracle, alice, bob, charlie } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));
      await pool.connect(alice).borrow(qusdAddr, ethers.parseEther("7000"));

      // Drop QFC price to $5
      await oracle.setPrice(qfcAddr, ethers.parseEther("5"));

      const repayAmount = ethers.parseEther("1000"); // $1000 QUSD
      await qusd.connect(charlie).approve(await pool.getAddress(), ethers.MaxUint256);

      await pool.connect(charlie).liquidate(alice.address, qusdAddr, qfcAddr, repayAmount);

      // Charlie repaid $1000 QUSD, should receive ~$1050 worth of QFC (5% bonus)
      // At QFC=$5: $1050 / $5 = 210 QFC underlying
      const charlieQTokenBal = await qQFC.balanceOf(charlie.address);
      const exchangeRate = await qQFC.exchangeRate();
      const charlieUnderlying = (charlieQTokenBal * exchangeRate) / PRECISION;

      // Should be approximately 210 QFC (with some tolerance for rounding)
      expect(charlieUnderlying).to.be.closeTo(ethers.parseEther("210"), ethers.parseEther("1"));
    });
  });

  // ─── Collateral Management ──────────────────────────────────────────

  describe("Collateral Management", function () {
    it("should allow entering and exiting markets", async function () {
      const { pool, qfc, alice } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();

      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);

      expect(await pool.isInMarket(alice.address, qfcAddr)).to.be.true;

      await pool.connect(alice).exitMarket(qfcAddr);
      expect(await pool.isInMarket(alice.address, qfcAddr)).to.be.false;
    });

    it("should reject exiting market with outstanding borrows", async function () {
      const { pool, qfc, qusd, alice, bob } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("1000"));
      await pool.connect(alice).enterMarket(qfcAddr);
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));
      await pool.connect(alice).borrow(qusdAddr, ethers.parseEther("5000"));

      await expect(
        pool.connect(alice).exitMarket(qfcAddr)
      ).to.be.revertedWith("LendingPool: insufficient collateral after exit");
    });

    it("should reject entering unlisted market", async function () {
      const { pool, alice } = await loadFixture(deployLendingFixture);
      await expect(
        pool.connect(alice).enterMarket(ethers.ZeroAddress)
      ).to.be.revertedWith("LendingPool: not listed");
    });

    it("should reject double enter", async function () {
      const { pool, qfc, alice } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      await pool.connect(alice).enterMarket(qfcAddr);
      await expect(
        pool.connect(alice).enterMarket(qfcAddr)
      ).to.be.revertedWith("LendingPool: already entered");
    });
  });

  // ─── Admin ──────────────────────────────────────────────────────────

  describe("Admin", function () {
    it("should reject listing duplicate market", async function () {
      const { pool, qfc, qQFC } = await loadFixture(deployLendingFixture);
      await expect(
        pool.listMarket(await qfc.getAddress(), await qQFC.getAddress(), ethers.parseEther("0.75"))
      ).to.be.revertedWith("LendingPool: already listed");
    });

    it("should reject collateral factor > 90%", async function () {
      const { pool, qfc } = await loadFixture(deployLendingFixture);
      await expect(
        pool.setCollateralFactor(await qfc.getAddress(), ethers.parseEther("0.95"))
      ).to.be.revertedWith("LendingPool: CF too high");
    });

    it("should update oracle", async function () {
      const { pool, owner } = await loadFixture(deployLendingFixture);
      const NewOracle = await ethers.getContractFactory("contracts/lending/PriceOracle.sol:PriceOracle");
      const newOracle = await NewOracle.deploy();
      await expect(pool.setOracle(await newOracle.getAddress()))
        .to.emit(pool, "OracleUpdated");
    });

    it("should return correct market count", async function () {
      const { pool } = await loadFixture(deployLendingFixture);
      expect(await pool.marketCount()).to.equal(3); // QFC, TTK, QUSD
    });

    it("should reject non-owner admin calls", async function () {
      const { pool, alice } = await loadFixture(deployLendingFixture);
      await expect(
        pool.connect(alice).setCollateralFactor(ethers.ZeroAddress, 0)
      ).to.be.revertedWithCustomError(pool, "OwnableUnauthorizedAccount");
    });
  });

  // ─── QToken ─────────────────────────────────────────────────────────

  describe("QToken", function () {
    it("should reject direct calls (not from LendingPool)", async function () {
      const { qQFC, alice } = await loadFixture(deployLendingFixture);
      await expect(
        qQFC.connect(alice).mintForAccount(alice.address, ethers.parseEther("100"))
      ).to.be.revertedWith("QToken: caller is not LendingPool");
    });

    it("should have correct initial exchange rate", async function () {
      const { qQFC } = await loadFixture(deployLendingFixture);
      // Before any supply, exchange rate = INITIAL_EXCHANGE_RATE = 0.02e18
      expect(await qQFC.exchangeRate()).to.equal(ethers.parseEther("0.02"));
    });

    it("should collect reserves", async function () {
      const { pool, qfc, qusd, qQFC, alice, bob, owner } = await loadFixture(deployLendingFixture);
      const qfcAddr = await qfc.getAddress();
      const qusdAddr = await qusd.getAddress();

      // Create activity to generate reserves
      await pool.connect(alice).supply(qfcAddr, ethers.parseEther("10000"));
      await pool.connect(bob).supply(qfcAddr, ethers.parseEther("10000"));
      await pool.connect(bob).enterMarket(qfcAddr);
      await pool.connect(bob).supply(qusdAddr, ethers.parseEther("50000"));
      await pool.connect(bob).enterMarket(qusdAddr);
      await pool.connect(bob).borrow(qfcAddr, ethers.parseEther("5000"));

      // Advance time to accrue interest
      await time.increase(365 * 24 * 60 * 60);
      await qQFC.accrueInterest();

      const reserves = await qQFC.totalReserves();
      expect(reserves).to.be.gt(0);
    });
  });
});
