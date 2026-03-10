import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("QUSD Stablecoin System", function () {
  // QFC/USD price: $2.00 with 8 decimals
  const INITIAL_PRICE = 200_000_000n;

  async function deployFixture() {
    const [owner, alice, bob, liquidator] = await ethers.getSigners();

    const PriceFeed = await ethers.getContractFactory("PriceFeed");
    const priceFeed = await PriceFeed.deploy(INITIAL_PRICE);

    const QUSDToken = await ethers.getContractFactory("QUSDToken");
    const qusd = await QUSDToken.deploy();

    const CDPVault = await ethers.getContractFactory("CDPVault");
    const vault = await CDPVault.deploy(
      await qusd.getAddress(),
      await priceFeed.getAddress()
    );

    await qusd.setVault(await vault.getAddress());

    const Liquidator = await ethers.getContractFactory("Liquidator");
    const liquidatorContract = await Liquidator.deploy(await vault.getAddress());

    return { priceFeed, qusd, vault, liquidatorContract, owner, alice, bob, liquidator };
  }

  describe("QUSDToken", function () {
    it("should have correct name and symbol", async function () {
      const { qusd } = await loadFixture(deployFixture);
      expect(await qusd.name()).to.equal("QUSD Stablecoin");
      expect(await qusd.symbol()).to.equal("QUSD");
    });

    it("should only allow vault to mint", async function () {
      const { qusd, alice } = await loadFixture(deployFixture);
      await expect(
        qusd.connect(alice).mint(alice.address, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(qusd, "OnlyVault");
    });

    it("should only allow vault to burn", async function () {
      const { qusd, alice } = await loadFixture(deployFixture);
      await expect(
        qusd.connect(alice).burnFrom(alice.address, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(qusd, "OnlyVault");
    });

    it("should allow owner to set vault", async function () {
      const { qusd, owner, alice } = await loadFixture(deployFixture);
      await expect(qusd.setVault(alice.address))
        .to.emit(qusd, "VaultUpdated");
    });

    it("should reject zero address for vault", async function () {
      const { qusd } = await loadFixture(deployFixture);
      await expect(qusd.setVault(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(qusd, "ZeroAddress");
    });

    it("should not allow non-owner to set vault", async function () {
      const { qusd, alice } = await loadFixture(deployFixture);
      await expect(
        qusd.connect(alice).setVault(alice.address)
      ).to.be.revertedWithCustomError(qusd, "OwnableUnauthorizedAccount");
    });
  });

  describe("PriceFeed", function () {
    it("should return initial price", async function () {
      const { priceFeed } = await loadFixture(deployFixture);
      const [price, , decimals] = await priceFeed.getLatestPrice();
      expect(price).to.equal(INITIAL_PRICE);
      expect(decimals).to.equal(8);
    });

    it("should allow owner to update price", async function () {
      const { priceFeed } = await loadFixture(deployFixture);
      const newPrice = 300_000_000n; // $3.00
      await expect(priceFeed.setPrice(newPrice))
        .to.emit(priceFeed, "PriceUpdated")
        .withArgs(INITIAL_PRICE, newPrice, await time.latest() + 1);
    });

    it("should reject zero price", async function () {
      const { priceFeed } = await loadFixture(deployFixture);
      await expect(priceFeed.setPrice(0))
        .to.be.revertedWithCustomError(priceFeed, "InvalidPrice");
    });

    it("should reject non-owner price update", async function () {
      const { priceFeed, alice } = await loadFixture(deployFixture);
      await expect(priceFeed.connect(alice).setPrice(100_000_000n))
        .to.be.revertedWithCustomError(priceFeed, "OwnableUnauthorizedAccount");
    });
  });

  describe("CDPVault — Deposit & Mint", function () {
    it("should accept collateral deposits", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("10");

      await expect(vault.connect(alice).depositCollateral({ value: amount }))
        .to.emit(vault, "CollateralDeposited")
        .withArgs(alice.address, amount);

      const pos = await vault.positions(alice.address);
      expect(pos.collateral).to.equal(amount);
    });

    it("should reject zero deposit", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      await expect(
        vault.connect(alice).depositCollateral({ value: 0 })
      ).to.be.revertedWithCustomError(vault, "ZeroAmount");
    });

    it("should mint QUSD within collateral ratio", async function () {
      const { vault, qusd, alice } = await loadFixture(deployFixture);
      // Deposit 10 QFC at $2 = $20 collateral
      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });

      // Mint $13 QUSD (ratio = 20/13 = 153.8% > 150%)
      const mintAmount = ethers.parseEther("13");
      await expect(vault.connect(alice).mintQUSD(mintAmount))
        .to.emit(vault, "QUSDMinted")
        .withArgs(alice.address, mintAmount);

      expect(await qusd.balanceOf(alice.address)).to.equal(mintAmount);
    });

    it("should reject mint below 150% ratio", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      // Deposit 10 QFC at $2 = $20 collateral
      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });

      // Try to mint $14 QUSD (ratio = 20/14 = 142.8% < 150%)
      await expect(
        vault.connect(alice).mintQUSD(ethers.parseEther("14"))
      ).to.be.revertedWithCustomError(vault, "BelowMinCollateralRatio");
    });

    it("should reject zero mint amount", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      await expect(
        vault.connect(alice).mintQUSD(0)
      ).to.be.revertedWithCustomError(vault, "ZeroAmount");
    });
  });

  describe("CDPVault — Burn & Withdraw", function () {
    it("should allow burning QUSD to repay debt", async function () {
      const { vault, qusd, alice } = await loadFixture(deployFixture);
      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });
      await vault.connect(alice).mintQUSD(ethers.parseEther("10"));

      await expect(vault.connect(alice).burnQUSD(ethers.parseEther("5")))
        .to.emit(vault, "QUSDBurned")
        .withArgs(alice.address, ethers.parseEther("5"));

      expect(await qusd.balanceOf(alice.address)).to.equal(ethers.parseEther("5"));
      const pos = await vault.positions(alice.address);
      // Debt may have tiny accrued fee, so use closeTo
      expect(pos.debt).to.be.closeTo(ethers.parseEther("5"), ethers.parseEther("0.0001"));
    });

    it("should reject burn with no debt", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      await expect(
        vault.connect(alice).burnQUSD(ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(vault, "NoDebt");
    });

    it("should reject burn exceeding total debt", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });
      await vault.connect(alice).mintQUSD(ethers.parseEther("5"));

      await expect(
        vault.connect(alice).burnQUSD(ethers.parseEther("6"))
      ).to.be.revertedWithCustomError(vault, "ExcessRepayment");
    });

    it("should allow collateral withdrawal when ratio is safe", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });
      await vault.connect(alice).mintQUSD(ethers.parseEther("5"));

      // Withdraw 2 QFC: remaining = 8 QFC * $2 = $16, debt = $5, ratio = 320% > 150%
      await expect(vault.connect(alice).withdrawCollateral(ethers.parseEther("2")))
        .to.emit(vault, "CollateralWithdrawn")
        .withArgs(alice.address, ethers.parseEther("2"));
    });

    it("should reject withdrawal that breaks ratio", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });
      await vault.connect(alice).mintQUSD(ethers.parseEther("10"));

      // Try withdraw 5 QFC: remaining = 5 * $2 = $10, debt = $10, ratio = 100% < 150%
      await expect(
        vault.connect(alice).withdrawCollateral(ethers.parseEther("5"))
      ).to.be.revertedWithCustomError(vault, "BelowMinCollateralRatio");
    });

    it("should allow full withdrawal with no debt", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });

      await expect(vault.connect(alice).withdrawCollateral(ethers.parseEther("10")))
        .to.emit(vault, "CollateralWithdrawn");

      const pos = await vault.positions(alice.address);
      expect(pos.collateral).to.equal(0);
    });

    it("should reject withdrawal exceeding collateral", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("5") });

      await expect(
        vault.connect(alice).withdrawCollateral(ethers.parseEther("10"))
      ).to.be.revertedWithCustomError(vault, "InsufficientCollateral");
    });
  });

  describe("CDPVault — Liquidation", function () {
    it("should liquidate undercollateralized position", async function () {
      const { vault, qusd, priceFeed, alice, liquidator } = await loadFixture(deployFixture);

      // Alice deposits 10 QFC at $2 = $20, mints $13 QUSD (ratio ~153%)
      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });
      await vault.connect(alice).mintQUSD(ethers.parseEther("13"));

      // Give liquidator QUSD to repay (from a separate position)
      await vault.connect(liquidator).depositCollateral({ value: ethers.parseEther("100") });
      await vault.connect(liquidator).mintQUSD(ethers.parseEther("50"));

      // Price drops to $1.60 — Alice ratio = 10 * 1.6 / 13 = 123% < 130%
      await priceFeed.setPrice(160_000_000n);

      const liquidatorBalBefore = await ethers.provider.getBalance(liquidator.address);

      await expect(vault.connect(liquidator).liquidate(alice.address))
        .to.emit(vault, "Liquidated");

      // Alice's position should be cleared
      const pos = await vault.positions(alice.address);
      expect(pos.collateral).to.equal(0);
      expect(pos.debt).to.equal(0);
    });

    it("should reject liquidation of healthy position", async function () {
      const { vault, alice, liquidator } = await loadFixture(deployFixture);

      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });
      await vault.connect(alice).mintQUSD(ethers.parseEther("5"));

      // Ratio = 10 * $2 / 5 = 400% — well above 130%
      await expect(
        vault.connect(liquidator).liquidate(alice.address)
      ).to.be.revertedWithCustomError(vault, "NotLiquidatable");
    });

    it("should reject liquidation of empty position", async function () {
      const { vault, alice, liquidator } = await loadFixture(deployFixture);
      await expect(
        vault.connect(liquidator).liquidate(alice.address)
      ).to.be.revertedWithCustomError(vault, "NoDebt");
    });
  });

  describe("CDPVault — Stability Fee", function () {
    it("should accrue 2% annual stability fee", async function () {
      const { vault, alice } = await loadFixture(deployFixture);

      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("100") });
      await vault.connect(alice).mintQUSD(ethers.parseEther("10"));

      // Advance 1 year
      await time.increase(365.25 * 24 * 3600);

      const totalDebt = await vault.getTotalDebt(alice.address);
      const principal = ethers.parseEther("10");
      const expectedFee = (principal * 200n) / 10000n; // 2% of 10 = 0.2 QUSD

      // Allow small rounding tolerance (within 0.001 QUSD)
      expect(totalDebt).to.be.closeTo(
        principal + expectedFee,
        ethers.parseEther("0.001")
      );
    });

    it("should accrue proportional fees for partial year", async function () {
      const { vault, alice } = await loadFixture(deployFixture);

      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("100") });
      await vault.connect(alice).mintQUSD(ethers.parseEther("100"));

      // Advance 6 months
      await time.increase(Math.floor(365.25 * 24 * 3600 / 2));

      const totalDebt = await vault.getTotalDebt(alice.address);
      // 1% for half year on 100 QUSD = ~1 QUSD fee
      expect(totalDebt).to.be.closeTo(
        ethers.parseEther("101"),
        ethers.parseEther("0.01")
      );
    });

    it("should repay fees before principal", async function () {
      const { vault, alice } = await loadFixture(deployFixture);

      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("100") });
      await vault.connect(alice).mintQUSD(ethers.parseEther("10"));

      // Advance 1 year to accrue ~0.2 QUSD fee
      await time.increase(365.25 * 24 * 3600);

      // Burn 0.1 QUSD — should go to fees first
      await vault.connect(alice).burnQUSD(ethers.parseEther("0.1"));
      const pos = await vault.positions(alice.address);
      expect(pos.debt).to.equal(ethers.parseEther("10")); // principal unchanged
    });
  });

  describe("CDPVault — getCollateralRatio", function () {
    it("should return max uint for zero debt", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });
      const ratio = await vault.getCollateralRatio(alice.address);
      expect(ratio).to.equal(ethers.MaxUint256);
    });

    it("should return correct ratio", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      // 10 QFC at $2 = $20, debt = $10 → ratio = 200% = 20000 bp
      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });
      await vault.connect(alice).mintQUSD(ethers.parseEther("10"));

      const ratio = await vault.getCollateralRatio(alice.address);
      expect(ratio).to.be.closeTo(20000n, 10n); // 200% with small fee tolerance
    });
  });

  describe("CDPVault — receive()", function () {
    it("should accept direct QFC transfers as collateral", async function () {
      const { vault, alice } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("5");

      await expect(
        alice.sendTransaction({ to: await vault.getAddress(), value: amount })
      ).to.emit(vault, "CollateralDeposited")
        .withArgs(alice.address, amount);

      const pos = await vault.positions(alice.address);
      expect(pos.collateral).to.equal(amount);
    });
  });

  describe("Liquidator", function () {
    it("should identify liquidatable positions", async function () {
      const { vault, priceFeed, liquidatorContract, alice, bob } = await loadFixture(deployFixture);

      // Alice: 10 QFC, $13 QUSD debt (153% ratio)
      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });
      await vault.connect(alice).mintQUSD(ethers.parseEther("13"));

      // Bob: 10 QFC, $5 QUSD debt (400% ratio)
      await vault.connect(bob).depositCollateral({ value: ethers.parseEther("10") });
      await vault.connect(bob).mintQUSD(ethers.parseEther("5"));

      // Price drop to $1.60 — Alice ~123%, Bob ~320%
      await priceFeed.setPrice(160_000_000n);

      const [liquidatable, ratios] = await liquidatorContract.checkLiquidatable([
        alice.address,
        bob.address,
      ]);

      expect(liquidatable.length).to.equal(1);
      expect(liquidatable[0]).to.equal(alice.address);
      expect(ratios[0]).to.be.lt(13000n);
    });

    it("should return empty when no positions are liquidatable", async function () {
      const { vault, liquidatorContract, alice } = await loadFixture(deployFixture);

      await vault.connect(alice).depositCollateral({ value: ethers.parseEther("10") });
      await vault.connect(alice).mintQUSD(ethers.parseEther("5"));

      const [liquidatable] = await liquidatorContract.checkLiquidatable([alice.address]);
      expect(liquidatable.length).to.equal(0);
    });
  });
});
