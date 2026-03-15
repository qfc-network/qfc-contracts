import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("PriceFeedV2", function () {
  const INITIAL_PRICE = 200_000_000n; // $2.00

  async function deployFixture() {
    const [admin, reporter1, reporter2, reporter3, user] = await ethers.getSigners();

    const PriceFeedV2 = await ethers.getContractFactory("PriceFeedV2");
    const priceFeed = await PriceFeedV2.deploy(INITIAL_PRICE, admin.address);

    const REPORTER_ROLE = await priceFeed.REPORTER_ROLE();
    const EMERGENCY_ROLE = await priceFeed.EMERGENCY_ROLE();

    // Grant reporter role to reporter1, reporter2, reporter3
    await priceFeed.grantRole(REPORTER_ROLE, reporter1.address);
    await priceFeed.grantRole(REPORTER_ROLE, reporter2.address);
    await priceFeed.grantRole(REPORTER_ROLE, reporter3.address);

    return { priceFeed, admin, reporter1, reporter2, reporter3, user, REPORTER_ROLE, EMERGENCY_ROLE };
  }

  describe("Initialization", function () {
    it("should set initial price and round 1", async function () {
      const { priceFeed } = await loadFixture(deployFixture);
      const [price, , decimals] = await priceFeed.getLatestPrice();
      expect(price).to.equal(INITIAL_PRICE);
      expect(decimals).to.equal(8);
      expect(await priceFeed.currentRoundId()).to.equal(1);
    });

    it("should reject zero initial price", async function () {
      const [admin] = await ethers.getSigners();
      const PriceFeedV2 = await ethers.getContractFactory("PriceFeedV2");
      await expect(PriceFeedV2.deploy(0, admin.address))
        .to.be.revertedWithCustomError(PriceFeedV2, "InvalidPrice");
    });
  });

  describe("V1 Compatibility — setPrice", function () {
    it("should allow admin to set price directly", async function () {
      const { priceFeed, admin } = await loadFixture(deployFixture);
      const newPrice = 210_000_000n; // $2.10

      await expect(priceFeed.setPrice(newPrice))
        .to.emit(priceFeed, "PriceUpdated");

      expect(await priceFeed.price()).to.equal(newPrice);
      expect(await priceFeed.currentRoundId()).to.equal(2);
    });

    it("should reject non-admin setPrice", async function () {
      const { priceFeed, user } = await loadFixture(deployFixture);
      await expect(priceFeed.connect(user).setPrice(210_000_000n))
        .to.be.reverted;
    });

    it("should reject zero price", async function () {
      const { priceFeed } = await loadFixture(deployFixture);
      await expect(priceFeed.setPrice(0))
        .to.be.revertedWithCustomError(priceFeed, "InvalidPrice");
    });
  });

  describe("Multi-reporter Price Reporting", function () {
    it("should accept a single reporter (minReporters=1)", async function () {
      const { priceFeed, reporter1 } = await loadFixture(deployFixture);

      await expect(priceFeed.connect(reporter1).reportPrice(205_000_000n))
        .to.emit(priceFeed, "PriceUpdated");

      expect(await priceFeed.price()).to.equal(205_000_000n);
    });

    it("should calculate median with 3 reporters", async function () {
      const { priceFeed, reporter1, reporter2, reporter3 } = await loadFixture(deployFixture);

      // Set minReporters to 3
      await priceFeed.setMinReporters(3);

      // Reports: $2.05, $2.10, $2.08 → median = $2.08
      await priceFeed.connect(reporter1).reportPrice(205_000_000n);
      await priceFeed.connect(reporter2).reportPrice(210_000_000n);

      await expect(priceFeed.connect(reporter3).reportPrice(208_000_000n))
        .to.emit(priceFeed, "PriceUpdated");

      expect(await priceFeed.price()).to.equal(208_000_000n);
    });

    it("should calculate median with 2 reporters (average)", async function () {
      const { priceFeed, reporter1, reporter2 } = await loadFixture(deployFixture);
      await priceFeed.setMinReporters(2);

      // Reports: $2.00, $2.10 → median = $2.05
      await priceFeed.connect(reporter1).reportPrice(200_000_000n);
      await expect(priceFeed.connect(reporter2).reportPrice(210_000_000n))
        .to.emit(priceFeed, "PriceUpdated");

      expect(await priceFeed.price()).to.equal(205_000_000n);
    });

    it("should prevent double-reporting in same round", async function () {
      const { priceFeed, reporter1 } = await loadFixture(deployFixture);
      await priceFeed.setMinReporters(2);

      await priceFeed.connect(reporter1).reportPrice(205_000_000n);
      await expect(priceFeed.connect(reporter1).reportPrice(206_000_000n))
        .to.be.revertedWithCustomError(priceFeed, "AlreadyReported");
    });

    it("should reject unauthorized reporter", async function () {
      const { priceFeed, user } = await loadFixture(deployFixture);
      await expect(priceFeed.connect(user).reportPrice(200_000_000n))
        .to.be.reverted;
    });
  });

  describe("Circuit Breaker", function () {
    it("should revert on >5% deviation via setPrice", async function () {
      const { priceFeed } = await loadFixture(deployFixture);

      // Current price: $2.00. Try $2.12 (6% deviation) — reverts and rolls back state
      await expect(priceFeed.setPrice(212_000_000n))
        .to.be.revertedWithCustomError(priceFeed, "DeviationTooHigh");

      // State is rolled back on revert, so circuitBroken remains false
      // Use reportPrice to trip the breaker (it doesn't revert, it silently breaks)
      expect(await priceFeed.price()).to.equal(INITIAL_PRICE);
    });

    it("should trip on >5% deviation via reportPrice", async function () {
      const { priceFeed, reporter1 } = await loadFixture(deployFixture);

      // Report $2.12 (6% deviation from $2.00)
      await priceFeed.connect(reporter1).reportPrice(212_000_000n);

      // Circuit should be broken, price unchanged
      expect(await priceFeed.circuitBroken()).to.be.true;
      expect(await priceFeed.price()).to.equal(INITIAL_PRICE);
    });

    it("should block reporting when circuit is broken", async function () {
      const { priceFeed, reporter1 } = await loadFixture(deployFixture);

      // Trip the breaker
      await priceFeed.connect(reporter1).reportPrice(212_000_000n);

      await expect(priceFeed.connect(reporter1).reportPrice(200_000_000n))
        .to.be.revertedWithCustomError(priceFeed, "CircuitBreakerActive");
    });

    it("should block getLatestPrice when circuit is broken", async function () {
      const { priceFeed, reporter1 } = await loadFixture(deployFixture);

      await priceFeed.connect(reporter1).reportPrice(212_000_000n);

      await expect(priceFeed.getLatestPrice())
        .to.be.revertedWithCustomError(priceFeed, "CircuitBreakerActive");
    });

    it("should allow emergency reset of circuit breaker", async function () {
      const { priceFeed, admin, reporter1 } = await loadFixture(deployFixture);

      // Trip
      await priceFeed.connect(reporter1).reportPrice(212_000_000n);
      expect(await priceFeed.circuitBroken()).to.be.true;

      // Reset
      await expect(priceFeed.connect(admin).resetCircuitBreaker())
        .to.emit(priceFeed, "CircuitBreakerReset");

      expect(await priceFeed.circuitBroken()).to.be.false;
    });

    it("should allow price within 5% deviation", async function () {
      const { priceFeed } = await loadFixture(deployFixture);

      // $2.00 → $2.09 (4.5% deviation) — should be fine
      await expect(priceFeed.setPrice(209_000_000n)).to.not.be.reverted;
      expect(await priceFeed.price()).to.equal(209_000_000n);
    });
  });

  describe("Heartbeat / Stale Price", function () {
    it("should revert on stale price", async function () {
      const { priceFeed } = await loadFixture(deployFixture);

      // Advance past heartbeat (1 hour)
      await time.increase(3601);

      await expect(priceFeed.getLatestPrice())
        .to.be.revertedWithCustomError(priceFeed, "StalePrice");
    });

    it("should return fresh price within heartbeat", async function () {
      const { priceFeed } = await loadFixture(deployFixture);

      // Advance 30 minutes (within 1 hour heartbeat)
      await time.increase(1800);

      const [price] = await priceFeed.getLatestPrice();
      expect(price).to.equal(INITIAL_PRICE);
    });
  });

  describe("Emergency Price Override", function () {
    it("should allow emergency price set", async function () {
      const { priceFeed, admin } = await loadFixture(deployFixture);

      await expect(priceFeed.connect(admin).setEmergencyPrice(150_000_000n))
        .to.emit(priceFeed, "EmergencyPriceSet")
        .withArgs(150_000_000n, admin.address);

      expect(await priceFeed.price()).to.equal(150_000_000n);
    });

    it("should reset circuit breaker on emergency price", async function () {
      const { priceFeed, admin, reporter1 } = await loadFixture(deployFixture);

      // Trip circuit breaker
      await priceFeed.connect(reporter1).reportPrice(212_000_000n);
      expect(await priceFeed.circuitBroken()).to.be.true;

      // Emergency price resets it
      await priceFeed.connect(admin).setEmergencyPrice(180_000_000n);
      expect(await priceFeed.circuitBroken()).to.be.false;
    });

    it("should reject unauthorized emergency price", async function () {
      const { priceFeed, user } = await loadFixture(deployFixture);
      await expect(priceFeed.connect(user).setEmergencyPrice(150_000_000n))
        .to.be.reverted;
    });
  });

  describe("TWAP", function () {
    it("should return spot price when not enough observations", async function () {
      const { priceFeed } = await loadFixture(deployFixture);
      const twap = await priceFeed.getTWAP();
      expect(twap).to.equal(INITIAL_PRICE);
    });

    it("should calculate TWAP over multiple price updates", async function () {
      const { priceFeed } = await loadFixture(deployFixture);

      // Price $2.00 for 30 minutes
      await time.increase(1800);
      await priceFeed.setPrice(204_000_000n); // $2.04

      // Price $2.04 for 30 minutes
      await time.increase(1800);
      await priceFeed.setPrice(208_000_000n); // $2.08

      const twap = await priceFeed.getTWAP();
      // TWAP should be between $2.00 and $2.08
      expect(twap).to.be.gte(200_000_000n);
      expect(twap).to.be.lte(208_000_000n);
    });
  });

  describe("Price History", function () {
    it("should store round data", async function () {
      const { priceFeed } = await loadFixture(deployFixture);

      await priceFeed.setPrice(205_000_000n);
      await priceFeed.setPrice(208_000_000n);

      const [price1, , count1] = await priceFeed.getRoundData(1);
      expect(price1).to.equal(INITIAL_PRICE);
      expect(count1).to.equal(1);

      const [price3] = await priceFeed.getRoundData(3);
      expect(price3).to.equal(208_000_000n);
    });
  });

  describe("Configuration", function () {
    it("should allow admin to change max deviation", async function () {
      const { priceFeed } = await loadFixture(deployFixture);
      await priceFeed.setMaxDeviationBps(1000); // 10%
      expect(await priceFeed.maxDeviationBps()).to.equal(1000);

      // Now 6% deviation should be ok
      await expect(priceFeed.setPrice(212_000_000n)).to.not.be.reverted;
    });

    it("should allow admin to change heartbeat", async function () {
      const { priceFeed } = await loadFixture(deployFixture);
      await priceFeed.setHeartbeatInterval(7200); // 2 hours

      await time.increase(3601);
      // Should still be valid with 2-hour heartbeat
      const [price] = await priceFeed.getLatestPrice();
      expect(price).to.equal(INITIAL_PRICE);
    });

    it("should reject invalid config values", async function () {
      const { priceFeed } = await loadFixture(deployFixture);
      await expect(priceFeed.setMaxDeviationBps(0))
        .to.be.revertedWithCustomError(priceFeed, "InvalidConfiguration");
      await expect(priceFeed.setHeartbeatInterval(30))
        .to.be.revertedWithCustomError(priceFeed, "InvalidConfiguration");
      await expect(priceFeed.setMinReporters(0))
        .to.be.revertedWithCustomError(priceFeed, "InvalidConfiguration");
    });
  });

  describe("Pause", function () {
    it("should block reporting when paused", async function () {
      const { priceFeed, admin, reporter1 } = await loadFixture(deployFixture);

      await priceFeed.connect(admin).pause();

      await expect(priceFeed.connect(reporter1).reportPrice(205_000_000n))
        .to.be.reverted; // Pausable: paused
    });

    it("should allow reporting after unpause", async function () {
      const { priceFeed, admin, reporter1 } = await loadFixture(deployFixture);

      await priceFeed.connect(admin).pause();
      await priceFeed.connect(admin).unpause();

      await expect(priceFeed.connect(reporter1).reportPrice(205_000_000n))
        .to.not.be.reverted;
    });
  });
});
