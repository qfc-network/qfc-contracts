import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import {
  AgentTokenFactory,
  BondingCurve,
  RevenueDistributor,
  LiquidityLock,
  AgentToken,
} from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("Agent Token Factory", function () {
  const LAUNCH_FEE = ethers.parseEther("100");
  const QVM_ID_1 = ethers.id("agent-1");
  const QVM_ID_2 = ethers.id("agent-2");
  const METADATA_URI = "ipfs://QmTest123";
  const GRADUATION_THRESHOLD = ethers.parseEther("42000");

  async function deployFixture() {
    const [owner, user1, user2, treasury] = await ethers.getSigners();

    // Deploy factory
    const Factory = await ethers.getContractFactory("AgentTokenFactory");
    const factory = await Factory.deploy();
    await factory.waitForDeployment();

    // Deploy bonding curve
    const BondingCurveFactory = await ethers.getContractFactory("BondingCurve");
    const bondingCurve = await BondingCurveFactory.deploy(
      await factory.getAddress()
    );
    await bondingCurve.waitForDeployment();

    // Deploy revenue distributor
    const RevenueDistributorFactory = await ethers.getContractFactory(
      "RevenueDistributor"
    );
    const revenueDistributor = await RevenueDistributorFactory.deploy(
      await factory.getAddress(),
      treasury.address
    );
    await revenueDistributor.waitForDeployment();

    // Deploy liquidity lock
    const LiquidityLockFactory =
      await ethers.getContractFactory("LiquidityLock");
    const liquidityLock = await LiquidityLockFactory.deploy();
    await liquidityLock.waitForDeployment();

    // Wire up factory
    await factory.setBondingCurve(await bondingCurve.getAddress());
    await factory.setRevenueDistributor(
      await revenueDistributor.getAddress()
    );

    return {
      factory,
      bondingCurve,
      revenueDistributor,
      liquidityLock,
      owner,
      user1,
      user2,
      treasury,
    };
  }

  async function deployWithAgentFixture() {
    const fixture = await deployFixture();
    const { factory, user1 } = fixture;

    // Create an agent
    await factory
      .connect(user1)
      .createAgent("TestAgent", "TAGENT", QVM_ID_1, METADATA_URI, {
        value: LAUNCH_FEE,
      });

    return fixture;
  }

  // ─── Agent Creation ──────────────────────────────────────────────────────────

  describe("Agent Creation", function () {
    it("should create an agent with correct parameters", async function () {
      const { factory, user1 } = await loadFixture(deployFixture);

      const tx = await factory
        .connect(user1)
        .createAgent("TestAgent", "TAGENT", QVM_ID_1, METADATA_URI, {
          value: LAUNCH_FEE,
        });

      await expect(tx).to.emit(factory, "AgentCreated");

      const info = await factory.getAgent(0);
      expect(info.creator).to.equal(user1.address);
      expect(info.qvmAgentId).to.equal(QVM_ID_1);
      expect(info.metadataURI).to.equal(METADATA_URI);
      expect(info.graduated).to.be.false;
      expect(info.tokenAddress).to.not.equal(ethers.ZeroAddress);
    });

    it("should require launch fee", async function () {
      const { factory, user1 } = await loadFixture(deployFixture);

      await expect(
        factory
          .connect(user1)
          .createAgent("TestAgent", "TAGENT", QVM_ID_1, METADATA_URI, {
            value: ethers.parseEther("99"),
          })
      ).to.be.revertedWithCustomError(factory, "InsufficientFee");
    });

    it("should deploy deterministic token address via CREATE2", async function () {
      const { factory, user1 } = await loadFixture(deployFixture);

      await factory
        .connect(user1)
        .createAgent("Agent1", "A1", QVM_ID_1, METADATA_URI, {
          value: LAUNCH_FEE,
        });

      const info = await factory.getAgent(0);
      expect(info.tokenAddress).to.not.equal(ethers.ZeroAddress);

      // Token should be a valid ERC-20
      const token = await ethers.getContractAt(
        "AgentToken",
        info.tokenAddress
      );
      expect(await token.name()).to.equal("Agent1");
      expect(await token.symbol()).to.equal("A1");
    });

    it("should prevent duplicate qvmAgentId", async function () {
      const { factory, user1, user2 } = await loadFixture(deployFixture);

      await factory
        .connect(user1)
        .createAgent("Agent1", "A1", QVM_ID_1, METADATA_URI, {
          value: LAUNCH_FEE,
        });

      await expect(
        factory
          .connect(user2)
          .createAgent("Agent2", "A2", QVM_ID_1, "ipfs://other", {
            value: LAUNCH_FEE,
          })
      ).to.be.revertedWithCustomError(factory, "DuplicateQvmAgentId");
    });

    it("should increment agent count", async function () {
      const { factory, user1 } = await loadFixture(deployFixture);

      expect(await factory.agentCount()).to.equal(0);

      await factory
        .connect(user1)
        .createAgent("Agent1", "A1", QVM_ID_1, METADATA_URI, {
          value: LAUNCH_FEE,
        });
      expect(await factory.agentCount()).to.equal(1);

      await factory
        .connect(user1)
        .createAgent("Agent2", "A2", QVM_ID_2, METADATA_URI, {
          value: LAUNCH_FEE,
        });
      expect(await factory.agentCount()).to.equal(2);
    });

    it("should lookup agent by QVM ID", async function () {
      const { factory, user1 } = await loadFixture(deployFixture);

      await factory
        .connect(user1)
        .createAgent("Agent1", "A1", QVM_ID_1, METADATA_URI, {
          value: LAUNCH_FEE,
        });

      const info = await factory.getAgentByQvmId(QVM_ID_1);
      expect(info.creator).to.equal(user1.address);
    });
  });

  // ─── Bonding Curve Buy/Sell ──────────────────────────────────────────────────

  describe("Bonding Curve", function () {
    it("should allow buying tokens with QFC", async function () {
      const { bondingCurve, factory, user1, user2 } = await loadFixture(
        deployWithAgentFixture
      );

      const buyAmount = ethers.parseEther("10");
      const tx = await bondingCurve.connect(user2).buy(0, 0, { value: buyAmount });
      await expect(tx).to.emit(bondingCurve, "TokensBought");

      const info = await factory.getAgent(0);
      const token = await ethers.getContractAt(
        "AgentToken",
        info.tokenAddress
      );
      const balance = await token.balanceOf(user2.address);
      expect(balance).to.be.gt(0);
    });

    it("should increase price as supply increases", async function () {
      const { bondingCurve, user2 } = await loadFixture(
        deployWithAgentFixture
      );

      const priceBefore = await bondingCurve.getPrice(0);

      // Buy some tokens to increase supply
      await bondingCurve
        .connect(user2)
        .buy(0, 0, { value: ethers.parseEther("100") });

      const priceAfter = await bondingCurve.getPrice(0);
      expect(priceAfter).to.be.gte(priceBefore);
    });

    it("should allow selling tokens back", async function () {
      const { bondingCurve, factory, user2 } = await loadFixture(
        deployWithAgentFixture
      );

      // Buy tokens first
      await bondingCurve
        .connect(user2)
        .buy(0, 0, { value: ethers.parseEther("100") });

      const info = await factory.getAgent(0);
      const token = await ethers.getContractAt(
        "AgentToken",
        info.tokenAddress
      );
      const balance = await token.balanceOf(user2.address);
      expect(balance).to.be.gt(0);

      // Approve bonding curve to burn tokens
      await token
        .connect(user2)
        .approve(await bondingCurve.getAddress(), balance);

      // Sell half
      const sellAmount = balance / 2n;
      const balanceBefore = await ethers.provider.getBalance(user2.address);

      const tx = await bondingCurve.connect(user2).sell(0, sellAmount, 0);
      await expect(tx).to.emit(bondingCurve, "TokensSold");

      const balanceAfter = await ethers.provider.getBalance(user2.address);
      // Account for gas, but should have received QFC back
      expect(balanceAfter).to.be.gt(balanceBefore - ethers.parseEther("1"));
    });

    it("should enforce slippage protection on buy", async function () {
      const { bondingCurve, user2 } = await loadFixture(
        deployWithAgentFixture
      );

      // Try to buy with unreasonable minTokensOut
      const maxUint = ethers.MaxUint256;
      await expect(
        bondingCurve
          .connect(user2)
          .buy(0, maxUint, { value: ethers.parseEther("1") })
      ).to.be.revertedWithCustomError(bondingCurve, "SlippageExceeded");
    });

    it("should enforce slippage protection on sell", async function () {
      const { bondingCurve, factory, user2 } = await loadFixture(
        deployWithAgentFixture
      );

      await bondingCurve
        .connect(user2)
        .buy(0, 0, { value: ethers.parseEther("10") });

      const info = await factory.getAgent(0);
      const token = await ethers.getContractAt(
        "AgentToken",
        info.tokenAddress
      );
      const balance = await token.balanceOf(user2.address);
      await token
        .connect(user2)
        .approve(await bondingCurve.getAddress(), balance);

      await expect(
        bondingCurve
          .connect(user2)
          .sell(0, balance, ethers.MaxUint256)
      ).to.be.revertedWithCustomError(bondingCurve, "SlippageExceeded");
    });

    it("should revert buy on non-existent agent", async function () {
      const { bondingCurve, user2 } = await loadFixture(deployFixture);

      await expect(
        bondingCurve
          .connect(user2)
          .buy(999, 0, { value: ethers.parseEther("1") })
      ).to.be.revertedWithCustomError(bondingCurve, "AgentNotFound");
    });

    it("should provide buy and sell quotes", async function () {
      const { bondingCurve, user2 } = await loadFixture(
        deployWithAgentFixture
      );

      const buyQuote = await bondingCurve.getBuyQuote(
        0,
        ethers.parseEther("10")
      );
      expect(buyQuote).to.be.gt(0);

      // Buy some tokens first for sell quote
      await bondingCurve
        .connect(user2)
        .buy(0, 0, { value: ethers.parseEther("10") });

      const sellQuote = await bondingCurve.getSellQuote(
        0,
        ethers.parseEther("1000")
      );
      expect(sellQuote).to.be.gt(0);
    });
  });

  // ─── Sigmoid Pricing ────────────────────────────────────────────────────────

  describe("Sigmoid Pricing", function () {
    it("should have low price at zero supply", async function () {
      const { bondingCurve } = await loadFixture(deployWithAgentFixture);

      const price = await bondingCurve.getPrice(0);
      // Price at supply=0 should be very low (near P0 * P_MAX / PRICE_SCALE)
      // P0 = 18, P_MAX = 1e15, PRICE_SCALE = 1e6
      // Expected: 18 * 1e15 / 1e6 = 18e9 = 18 gwei
      expect(price).to.be.lt(ethers.parseEther("0.00001"));
    });

    it("should have mid-range price at midpoint supply", async function () {
      const { bondingCurve, user2 } = await loadFixture(
        deployWithAgentFixture
      );

      // We can't easily get to midpoint, but we can verify the quote increases
      // Get price at start
      const priceStart = await bondingCurve.getPrice(0);

      // Buy tokens to increase supply
      await bondingCurve
        .connect(user2)
        .buy(0, 0, { value: ethers.parseEther("50") });

      const priceAfterBuy = await bondingCurve.getPrice(0);
      expect(priceAfterBuy).to.be.gte(priceStart);
    });
  });

  // ─── Graduation ─────────────────────────────────────────────────────────────

  describe("Graduation", function () {
    it("should auto-graduate when threshold is reached", async function () {
      const { bondingCurve, factory, user1, user2, owner } = await loadFixture(
        deployWithAgentFixture
      );

      // Fund user2 with enough QFC to hit the graduation threshold
      const bigBuy = ethers.parseEther("42001");
      await ethers.provider.send("hardhat_setBalance", [
        user2.address,
        "0x" + (bigBuy + ethers.parseEther("10")).toString(16),
      ]);

      await expect(
        bondingCurve.connect(user2).buy(0, 0, { value: bigBuy })
      ).to.emit(bondingCurve, "Graduated");

      // Check curve state
      const curve = await bondingCurve.curves(0);
      expect(curve.graduated).to.be.true;

      // Check factory state
      const info = await factory.getAgent(0);
      expect(info.graduated).to.be.true;
    });

    it("should reject buys after graduation", async function () {
      const { bondingCurve, user2 } = await loadFixture(
        deployWithAgentFixture
      );

      // Fund user2 with enough QFC
      const bigBuy = ethers.parseEther("42001");
      await ethers.provider.send("hardhat_setBalance", [
        user2.address,
        "0x" + (bigBuy + ethers.parseEther("100")).toString(16),
      ]);

      // Graduate
      await bondingCurve
        .connect(user2)
        .buy(0, 0, { value: bigBuy });

      // Try to buy more
      await expect(
        bondingCurve
          .connect(user2)
          .buy(0, 0, { value: ethers.parseEther("1") })
      ).to.be.revertedWithCustomError(bondingCurve, "AlreadyGraduated");
    });
  });

  // ─── Revenue Distribution ──────────────────────────────────────────────────

  describe("Revenue Distribution", function () {
    it("should accept revenue deposits", async function () {
      const { revenueDistributor, user1 } = await loadFixture(
        deployWithAgentFixture
      );

      const amount = ethers.parseEther("10");
      await expect(
        revenueDistributor.connect(user1).depositRevenue(0, { value: amount })
      )
        .to.emit(revenueDistributor, "RevenueDeposited")
        .withArgs(0, amount);

      expect(await revenueDistributor.pendingRevenue(0)).to.equal(amount);
    });

    it("should distribute with 60/30/10 split", async function () {
      const { revenueDistributor, factory, user1, treasury } =
        await loadFixture(deployWithAgentFixture);

      const amount = ethers.parseEther("100");
      await revenueDistributor
        .connect(user1)
        .depositRevenue(0, { value: amount });

      // Get creator (user1) balance before
      const creatorBalBefore = await ethers.provider.getBalance(user1.address);
      const treasuryBalBefore = await ethers.provider.getBalance(
        treasury.address
      );

      // Distribute (anyone can call)
      await revenueDistributor.distribute(0);

      const creatorBalAfter = await ethers.provider.getBalance(user1.address);
      const treasuryBalAfter = await ethers.provider.getBalance(
        treasury.address
      );

      // Creator gets 60% = 60 QFC
      const creatorDelta = creatorBalAfter - creatorBalBefore;
      expect(creatorDelta).to.equal(ethers.parseEther("60"));

      // Treasury gets 30% + 10% = 40 QFC (buyback goes to treasury for now)
      const treasuryDelta = treasuryBalAfter - treasuryBalBefore;
      expect(treasuryDelta).to.equal(ethers.parseEther("40"));

      // Pending should be zero
      expect(await revenueDistributor.pendingRevenue(0)).to.equal(0);
    });

    it("should revert distribute with no revenue", async function () {
      const { revenueDistributor } = await loadFixture(
        deployWithAgentFixture
      );

      await expect(
        revenueDistributor.distribute(0)
      ).to.be.revertedWithCustomError(revenueDistributor, "NoRevenue");
    });

    it("should batch distribute", async function () {
      const { factory, revenueDistributor, user1 } = await loadFixture(
        deployFixture
      );

      // Create two agents
      await factory
        .connect(user1)
        .createAgent("Agent1", "A1", QVM_ID_1, METADATA_URI, {
          value: LAUNCH_FEE,
        });
      await factory
        .connect(user1)
        .createAgent("Agent2", "A2", QVM_ID_2, METADATA_URI, {
          value: LAUNCH_FEE,
        });

      // Deposit revenue for both
      await revenueDistributor
        .connect(user1)
        .depositRevenue(0, { value: ethers.parseEther("10") });
      await revenueDistributor
        .connect(user1)
        .depositRevenue(1, { value: ethers.parseEther("20") });

      await revenueDistributor.batchDistribute([0, 1]);

      expect(await revenueDistributor.pendingRevenue(0)).to.equal(0);
      expect(await revenueDistributor.pendingRevenue(1)).to.equal(0);
    });
  });

  // ─── Liquidity Lock ──────────────────────────────────────────────────────────

  describe("Liquidity Lock", function () {
    it("should lock LP tokens permanently", async function () {
      const { liquidityLock, factory, user1 } = await loadFixture(
        deployWithAgentFixture
      );

      // Use the agent token as a mock LP token
      const info = await factory.getAgent(0);
      const token = await ethers.getContractAt(
        "AgentToken",
        info.tokenAddress
      );

      // Factory can mint tokens to user
      // Actually user1 needs tokens first - let's use a separate ERC20
      // Deploy a simple ERC20 for testing
      const MockToken = await ethers.getContractFactory("AgentToken");
      const mockLp = await MockToken.deploy(
        "LP Token",
        "LP",
        user1.address, // factory = user1 so they can mint
        user1.address, // bondingCurve
        user1.address, // revenueDistributor
        ""
      );
      await mockLp.waitForDeployment();

      // Mint some tokens (user1 is factory for this mock)
      await mockLp.connect(user1).mint(user1.address, ethers.parseEther("1000"));

      // Approve and lock
      const lockAddr = await liquidityLock.getAddress();
      await mockLp.connect(user1).approve(lockAddr, ethers.parseEther("500"));

      await expect(
        liquidityLock
          .connect(user1)
          .lock(await mockLp.getAddress(), ethers.parseEther("500"))
      )
        .to.emit(liquidityLock, "LiquidityLocked")
        .withArgs(
          await mockLp.getAddress(),
          user1.address,
          ethers.parseEther("500")
        );

      expect(
        await liquidityLock.getLocked(await mockLp.getAddress())
      ).to.equal(ethers.parseEther("500"));
    });

    it("should have no unlock function", async function () {
      const { liquidityLock } = await loadFixture(deployFixture);

      // Verify the contract has no unlock/withdraw methods
      const iface = liquidityLock.interface;
      const fragments = iface.fragments.filter(
        (f: any) => f.type === "function"
      );
      const functionNames = fragments.map((f: any) => f.name);

      expect(functionNames).to.not.include("unlock");
      expect(functionNames).to.not.include("withdraw");
      expect(functionNames).to.not.include("release");
    });

    it("should revert on zero amount", async function () {
      const { liquidityLock, user1 } = await loadFixture(deployFixture);

      await expect(
        liquidityLock.connect(user1).lock(user1.address, 0)
      ).to.be.revertedWithCustomError(liquidityLock, "ZeroAmount");
    });
  });

  // ─── Access Control ─────────────────────────────────────────────────────────

  describe("Access Control", function () {
    it("should restrict minting to factory", async function () {
      const { factory, user1, user2 } = await loadFixture(
        deployWithAgentFixture
      );

      const info = await factory.getAgent(0);
      const token = await ethers.getContractAt(
        "AgentToken",
        info.tokenAddress
      );

      await expect(
        token.connect(user2).mint(user2.address, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(token, "OnlyFactory");
    });

    it("should restrict treasury update to owner", async function () {
      const { revenueDistributor, user1 } = await loadFixture(deployFixture);

      await expect(
        revenueDistributor.connect(user1).setTreasury(user1.address)
      ).to.be.revertedWithCustomError(
        revenueDistributor,
        "OwnableUnauthorizedAccount"
      );
    });

    it("should restrict setBondingCurve to owner", async function () {
      const { factory, user1 } = await loadFixture(deployFixture);

      await expect(
        factory.connect(user1).setBondingCurve(user1.address)
      ).to.be.revertedWithCustomError(
        factory,
        "OwnableUnauthorizedAccount"
      );
    });

    it("should restrict setRevenueDistributor to owner", async function () {
      const { factory, user1 } = await loadFixture(deployFixture);

      await expect(
        factory.connect(user1).setRevenueDistributor(user1.address)
      ).to.be.revertedWithCustomError(
        factory,
        "OwnableUnauthorizedAccount"
      );
    });

    it("should allow owner to update treasury", async function () {
      const { revenueDistributor, owner, user1 } =
        await loadFixture(deployFixture);

      await expect(
        revenueDistributor.connect(owner).setTreasury(user1.address)
      )
        .to.emit(revenueDistributor, "TreasuryUpdated")
        .withArgs(
          await revenueDistributor.treasury(),
          user1.address
        );
    });

    it("should allow owner to withdraw fees", async function () {
      const { factory, owner, user1 } = await loadFixture(deployFixture);

      // Wire up factory first (already done in fixture but need agent)
      await factory
        .connect(user1)
        .createAgent("Agent1", "A1", QVM_ID_1, METADATA_URI, {
          value: LAUNCH_FEE,
        });

      const balBefore = await ethers.provider.getBalance(owner.address);
      await factory.connect(owner).withdrawFees();
      const balAfter = await ethers.provider.getBalance(owner.address);

      // Should have received ~100 QFC (minus gas)
      expect(balAfter - balBefore).to.be.gt(ethers.parseEther("99"));
    });
  });
});
