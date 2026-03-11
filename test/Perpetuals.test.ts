import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("Perpetuals", function () {
  async function deployPerpsFixture() {
    const [owner, trader1, trader2, liquidator, lp1, lp2] =
      await ethers.getSigners();

    // Deploy QUSD mock token
    const QFCToken = await ethers.getContractFactory("QFCToken");
    const qusd = await QFCToken.deploy(
      "QFC USD",
      "QUSD",
      ethers.parseEther("1000000000"),
      ethers.parseEther("100000000")
    );

    // Deploy PriceOracle
    const Oracle = await ethers.getContractFactory("contracts/perps/PriceOracle.sol:PriceOracle");
    const oracle = await Oracle.deploy();

    // Set prices
    await oracle.setPrices(
      ["QFC", "TTK", "QDOGE"],
      [
        ethers.parseEther("25"),
        ethers.parseEther("100"),
        ethers.parseEther("0.001"),
      ]
    );

    // Deploy LiquidityPool
    const Pool = await ethers.getContractFactory("LiquidityPool");
    const pool = await Pool.deploy(await qusd.getAddress());

    // Deploy PositionManager
    const PM = await ethers.getContractFactory("PositionManager");
    const positionManager = await PM.deploy(
      await qusd.getAddress(),
      await oracle.getAddress()
    );

    // Deploy FundingRate
    const FR = await ethers.getContractFactory("FundingRate");
    const fundingRate = await FR.deploy();

    // Deploy PerpRouter
    const Router = await ethers.getContractFactory("PerpRouter");
    const router = await Router.deploy(
      await qusd.getAddress(),
      await positionManager.getAddress(),
      await pool.getAddress(),
      owner.address
    );

    // Wire contracts
    await pool.setPositionManager(await positionManager.getAddress());
    await pool.setRouter(await router.getAddress());
    await positionManager.setPool(await pool.getAddress());
    await positionManager.setRouter(await router.getAddress());
    await positionManager.setFundingRate(await fundingRate.getAddress());
    await fundingRate.setPositionManager(await positionManager.getAddress());
    await router.setFundingRate(await fundingRate.getAddress());

    // Fund accounts
    const fundAmount = ethers.parseEther("1000000");
    await qusd.transfer(trader1.address, fundAmount);
    await qusd.transfer(trader2.address, fundAmount);
    await qusd.transfer(lp1.address, fundAmount);
    await qusd.transfer(lp2.address, fundAmount);

    // Approve router and pool
    const maxApproval = ethers.MaxUint256;
    await qusd.connect(trader1).approve(await router.getAddress(), maxApproval);
    await qusd.connect(trader2).approve(await router.getAddress(), maxApproval);
    await qusd.connect(lp1).approve(await pool.getAddress(), maxApproval);
    await qusd.connect(lp2).approve(await pool.getAddress(), maxApproval);

    return {
      qusd,
      oracle,
      pool,
      positionManager,
      fundingRate,
      router,
      owner,
      trader1,
      trader2,
      liquidator,
      lp1,
      lp2,
    };
  }

  describe("PriceOracle", function () {
    it("should set and get prices", async function () {
      const { oracle } = await loadFixture(deployPerpsFixture);
      expect(await oracle.getPrice("QFC")).to.equal(ethers.parseEther("25"));
      expect(await oracle.getPrice("TTK")).to.equal(ethers.parseEther("100"));
      expect(await oracle.getPrice("QDOGE")).to.equal(ethers.parseEther("0.001"));
    });

    it("should revert for unsupported assets", async function () {
      const { oracle } = await loadFixture(deployPerpsFixture);
      await expect(oracle.getPrice("INVALID")).to.be.revertedWithCustomError(
        oracle,
        "UnsupportedAsset"
      );
    });

    it("should update prices", async function () {
      const { oracle } = await loadFixture(deployPerpsFixture);
      await oracle.setPrice("QFC", ethers.parseEther("30"));
      expect(await oracle.getPrice("QFC")).to.equal(ethers.parseEther("30"));
    });

    it("should revert zero price", async function () {
      const { oracle } = await loadFixture(deployPerpsFixture);
      await expect(oracle.setPrice("QFC", 0)).to.be.revertedWithCustomError(
        oracle,
        "ZeroPrice"
      );
    });
  });

  describe("LiquidityPool", function () {
    it("should add liquidity and receive LP tokens", async function () {
      const { pool, lp1 } = await loadFixture(deployPerpsFixture);
      const amount = ethers.parseEther("10000");

      await expect(pool.connect(lp1).addLiquidity(amount))
        .to.emit(pool, "LiquidityAdded")
        .withArgs(lp1.address, amount, amount); // First deposit: 1:1

      expect(await pool.balanceOf(lp1.address)).to.equal(amount);
      expect(await pool.totalAssets()).to.equal(amount);
    });

    it("should add liquidity proportionally after first deposit", async function () {
      const { pool, lp1, lp2 } = await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("10000"));
      await pool.connect(lp2).addLiquidity(ethers.parseEther("5000"));

      expect(await pool.balanceOf(lp2.address)).to.equal(
        ethers.parseEther("5000")
      );
    });

    it("should remove liquidity and receive QUSD", async function () {
      const { pool, qusd, lp1 } = await loadFixture(deployPerpsFixture);
      const amount = ethers.parseEther("10000");

      await pool.connect(lp1).addLiquidity(amount);

      const balBefore = await qusd.balanceOf(lp1.address);
      await pool.connect(lp1).removeLiquidity(amount);
      const balAfter = await qusd.balanceOf(lp1.address);

      expect(balAfter - balBefore).to.equal(amount);
      expect(await pool.balanceOf(lp1.address)).to.equal(0);
    });

    it("should revert add liquidity with zero amount", async function () {
      const { pool, lp1 } = await loadFixture(deployPerpsFixture);
      await expect(
        pool.connect(lp1).addLiquidity(0)
      ).to.be.revertedWithCustomError(pool, "ZeroAmount");
    });
  });

  describe("Open Long Position", function () {
    it("should open a long position via router", async function () {
      const { router, pool, positionManager, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      // LP seeds pool
      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("10000");
      const collateral = ethers.parseEther("1000"); // 10x leverage
      const deadline = (await time.latest()) + 3600;

      await expect(
        router.connect(trader1).openLong("QFC", size, collateral, deadline)
      ).to.emit(router, "LongOpened");

      const pos = await positionManager.getPosition(0);
      expect(pos.trader).to.equal(trader1.address);
      expect(pos.isLong).to.be.true;
      expect(pos.size).to.equal(size);
      expect(pos.collateral).to.equal(collateral);
      expect(pos.entryPrice).to.equal(ethers.parseEther("25"));
      expect(pos.isOpen).to.be.true;
    });

    it("should reject leverage exceeding 10x", async function () {
      const { router, pool, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("11000");
      const collateral = ethers.parseEther("1000"); // >10x
      const deadline = (await time.latest()) + 3600;

      await expect(
        router.connect(trader1).openLong("QFC", size, collateral, deadline)
      ).to.be.reverted;
    });

    it("should reject expired deadline", async function () {
      const { router, pool, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const deadline = (await time.latest()) - 1;

      await expect(
        router
          .connect(trader1)
          .openLong(
            "QFC",
            ethers.parseEther("1000"),
            ethers.parseEther("100"),
            deadline
          )
      ).to.be.revertedWithCustomError(router, "DeadlineExpired");
    });
  });

  describe("Open Short Position", function () {
    it("should open a short position via router", async function () {
      const { router, pool, positionManager, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("5000");
      const collateral = ethers.parseEther("1000"); // 5x
      const deadline = (await time.latest()) + 3600;

      await expect(
        router.connect(trader1).openShort("QFC", size, collateral, deadline)
      ).to.emit(router, "ShortOpened");

      const pos = await positionManager.getPosition(0);
      expect(pos.isLong).to.be.false;
      expect(pos.size).to.equal(size);
    });
  });

  describe("PnL Calculation", function () {
    it("should calculate positive PnL for long when price goes up", async function () {
      const { router, pool, oracle, positionManager, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("10000");
      const collateral = ethers.parseEther("1000");
      const deadline = (await time.latest()) + 3600;

      await router
        .connect(trader1)
        .openLong("QFC", size, collateral, deadline);

      // Price goes up 10%: $25 -> $27.5
      await oracle.setPrice("QFC", ethers.parseEther("27.5"));

      // PnL = (27.5 - 25) / 25 * 10000 = 1000
      const pnl = await positionManager.getUnrealizedPnL(0);
      expect(pnl).to.equal(ethers.parseEther("1000"));
    });

    it("should calculate negative PnL for long when price goes down", async function () {
      const { router, pool, oracle, positionManager, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("10000");
      const collateral = ethers.parseEther("1000");
      const deadline = (await time.latest()) + 3600;

      await router
        .connect(trader1)
        .openLong("QFC", size, collateral, deadline);

      // Price drops 5%: $25 -> $23.75
      await oracle.setPrice("QFC", ethers.parseEther("23.75"));

      // PnL = (23.75 - 25) / 25 * 10000 = -500
      const pnl = await positionManager.getUnrealizedPnL(0);
      expect(pnl).to.equal(ethers.parseEther("-500"));
    });

    it("should calculate positive PnL for short when price goes down", async function () {
      const { router, pool, oracle, positionManager, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("10000");
      const collateral = ethers.parseEther("2000");
      const deadline = (await time.latest()) + 3600;

      await router
        .connect(trader1)
        .openShort("QFC", size, collateral, deadline);

      // Price drops 20%: $25 -> $20
      await oracle.setPrice("QFC", ethers.parseEther("20"));

      // PnL = -((20 - 25) / 25 * 10000) = 2000
      const pnl = await positionManager.getUnrealizedPnL(0);
      expect(pnl).to.equal(ethers.parseEther("2000"));
    });
  });

  describe("Close Position", function () {
    it("should close long with profit", async function () {
      const { router, pool, oracle, qusd, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("10000");
      const collateral = ethers.parseEther("1000");
      const deadline = (await time.latest()) + 3600;

      await router
        .connect(trader1)
        .openLong("QFC", size, collateral, deadline);

      const balBefore = await qusd.balanceOf(trader1.address);

      // Price up 10%
      await oracle.setPrice("QFC", ethers.parseEther("27.5"));

      await router.connect(trader1).close(0, 0);

      const balAfter = await qusd.balanceOf(trader1.address);
      // Trader should receive collateral + profit - close fee
      // Profit = 1000, close fee = 10000 * 0.1% = 10
      const received = balAfter - balBefore;
      // collateral(1000) + profit(1000) - closeFee(10) = 1990
      expect(received).to.equal(ethers.parseEther("1990"));
    });

    it("should close long with loss", async function () {
      const { router, pool, oracle, qusd, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("10000");
      const collateral = ethers.parseEther("1000");
      const deadline = (await time.latest()) + 3600;

      await router
        .connect(trader1)
        .openLong("QFC", size, collateral, deadline);

      const balBefore = await qusd.balanceOf(trader1.address);

      // Price down 5%
      await oracle.setPrice("QFC", ethers.parseEther("23.75"));

      await router.connect(trader1).close(0, ethers.parseEther("-600"));

      const balAfter = await qusd.balanceOf(trader1.address);
      // collateral(1000) - loss(500) - closeFee(10) = 490
      const received = balAfter - balBefore;
      expect(received).to.equal(ethers.parseEther("490"));
    });

    it("should close short with profit", async function () {
      const { router, pool, oracle, qusd, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("5000");
      const collateral = ethers.parseEther("1000");
      const deadline = (await time.latest()) + 3600;

      await router
        .connect(trader1)
        .openShort("QFC", size, collateral, deadline);

      const balBefore = await qusd.balanceOf(trader1.address);

      // Price drops 10%: $25 -> $22.5
      await oracle.setPrice("QFC", ethers.parseEther("22.5"));

      await router.connect(trader1).close(0, 0);

      const balAfter = await qusd.balanceOf(trader1.address);
      // Short profit = (25-22.5)/25 * 5000 = 500
      // collateral(1000) + profit(500) - closeFee(5) = 1495
      const received = balAfter - balBefore;
      expect(received).to.equal(ethers.parseEther("1495"));
    });

    it("should reject minPnL not met", async function () {
      const { router, pool, oracle, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("10000");
      const collateral = ethers.parseEther("1000");
      const deadline = (await time.latest()) + 3600;

      await router
        .connect(trader1)
        .openLong("QFC", size, collateral, deadline);

      // Price drops 5%
      await oracle.setPrice("QFC", ethers.parseEther("23.75"));

      // minPnL = 0 but actual PnL = -500, should revert
      await expect(
        router.connect(trader1).close(0, ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(router, "MinPnLNotMet");
    });
  });

  describe("Liquidation", function () {
    it("should liquidate position below 5% margin", async function () {
      const { router, pool, oracle, positionManager, qusd, trader1, liquidator, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      // Open 10x leveraged long: size=10000, collateral=1000
      const size = ethers.parseEther("10000");
      const collateral = ethers.parseEther("1000");
      const deadline = (await time.latest()) + 3600;

      await router
        .connect(trader1)
        .openLong("QFC", size, collateral, deadline);

      // Price drops ~96% of collateral: health < 5%
      // Need: (1000 + pnl) / 10000 < 0.05 => 1000 + pnl < 500 => pnl < -500
      // pnl = (newPrice - 25) / 25 * 10000
      // -600 = (newPrice - 25) / 25 * 10000 => newPrice = 23.5
      await oracle.setPrice("QFC", ethers.parseEther("23.5"));

      const liqBalBefore = await qusd.balanceOf(liquidator.address);

      await positionManager.connect(liquidator).liquidatePosition(0);

      const liqBalAfter = await qusd.balanceOf(liquidator.address);
      // Liquidator bonus = 0.5% of 10000 = 50
      expect(liqBalAfter - liqBalBefore).to.equal(ethers.parseEther("50"));

      const pos = await positionManager.getPosition(0);
      expect(pos.isOpen).to.be.false;
    });

    it("should reject liquidation of healthy position", async function () {
      const { router, pool, positionManager, trader1, liquidator, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("5000");
      const collateral = ethers.parseEther("1000");
      const deadline = (await time.latest()) + 3600;

      await router
        .connect(trader1)
        .openLong("QFC", size, collateral, deadline);

      await expect(
        positionManager.connect(liquidator).liquidatePosition(0)
      ).to.be.revertedWithCustomError(positionManager, "NotLiquidatable");
    });
  });

  describe("Funding Rate", function () {
    it("should update funding rate", async function () {
      const { router, pool, fundingRate, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const deadline = (await time.latest()) + 3600;
      await router
        .connect(trader1)
        .openLong(
          "QFC",
          ethers.parseEther("10000"),
          ethers.parseEther("1000"),
          deadline
        );

      await expect(fundingRate.updateFundingRate("QFC")).to.emit(
        fundingRate,
        "FundingRateUpdated"
      );

      // With only longs, funding rate should be positive
      const rate = await fundingRate.getCurrentFundingRate("QFC");
      expect(rate).to.be.gt(0);
    });

    it("should prevent too-frequent updates", async function () {
      const { router, pool, fundingRate, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const deadline = (await time.latest()) + 3600;
      await router
        .connect(trader1)
        .openLong(
          "QFC",
          ethers.parseEther("10000"),
          ethers.parseEther("1000"),
          deadline
        );

      await fundingRate.updateFundingRate("QFC");

      await expect(
        fundingRate.updateFundingRate("QFC")
      ).to.be.revertedWithCustomError(fundingRate, "TooEarlyForUpdate");
    });

    it("should allow update after interval", async function () {
      const { router, pool, fundingRate, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const deadline = (await time.latest()) + 7200;
      await router
        .connect(trader1)
        .openLong(
          "QFC",
          ethers.parseEther("10000"),
          ethers.parseEther("1000"),
          deadline
        );

      await fundingRate.updateFundingRate("QFC");
      await time.increase(3601); // Advance 1 hour+
      await expect(fundingRate.updateFundingRate("QFC")).to.not.be.reverted;
    });
  });

  describe("Fees", function () {
    it("should collect opening and closing fees", async function () {
      const { router, pool, qusd, oracle, owner, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("10000");
      const collateral = ethers.parseEther("1000");
      const deadline = (await time.latest()) + 3600;

      const ownerBalBefore = await qusd.balanceOf(owner.address);

      await router
        .connect(trader1)
        .openLong("QFC", size, collateral, deadline);

      // Open fee = 0.1% of 10000 = 10
      // Protocol share = 40% of 10 = 4
      const ownerBalAfterOpen = await qusd.balanceOf(owner.address);
      expect(ownerBalAfterOpen - ownerBalBefore).to.equal(
        ethers.parseEther("4")
      );

      // Close
      await oracle.setPrice("QFC", ethers.parseEther("27.5")); // profit so minPnL=0 works
      await router.connect(trader1).close(0, 0);

      // Close fee = 0.1% of 10000 = 10, protocol = 4
      const ownerBalAfterClose = await qusd.balanceOf(owner.address);
      expect(ownerBalAfterClose - ownerBalAfterOpen).to.equal(
        ethers.parseEther("4")
      );
    });

    it("should send 60% of fees to LP pool", async function () {
      const { router, pool, trader1, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      const size = ethers.parseEther("10000");
      const collateral = ethers.parseEther("1000");
      const deadline = (await time.latest()) + 3600;

      await router
        .connect(trader1)
        .openLong("QFC", size, collateral, deadline);

      // Open fee = 10, LP share = 60% of 10 = 6
      expect(await pool.accumulatedFees()).to.equal(ethers.parseEther("6"));
    });
  });

  describe("Open Interest Tracking", function () {
    it("should track open interest correctly", async function () {
      const { router, pool, positionManager, trader1, trader2, lp1 } =
        await loadFixture(deployPerpsFixture);

      await pool.connect(lp1).addLiquidity(ethers.parseEther("100000"));

      // Approve trader2 for router
      const qusd = await ethers.getContractAt(
        "QFCToken",
        await pool.qusd()
      );
      await qusd
        .connect(trader2)
        .approve(await router.getAddress(), ethers.MaxUint256);

      const deadline = (await time.latest()) + 3600;

      await router
        .connect(trader1)
        .openLong(
          "QFC",
          ethers.parseEther("10000"),
          ethers.parseEther("1000"),
          deadline
        );
      await router
        .connect(trader2)
        .openShort(
          "QFC",
          ethers.parseEther("5000"),
          ethers.parseEther("1000"),
          deadline
        );

      const [longOI, shortOI] = await positionManager.getOpenInterest("QFC");
      expect(longOI).to.equal(ethers.parseEther("10000"));
      expect(shortOI).to.equal(ethers.parseEther("5000"));
    });
  });
});
