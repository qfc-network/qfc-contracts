import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

describe("Launchpad", function () {
  // ─── Helpers ───

  async function deployTokenFixture() {
    const [owner, creator, user1, user2, user3] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("QFCToken");
    const token = await Token.deploy(
      "Test Token",
      "TT",
      ethers.parseEther("10000000"),
      ethers.parseEther("1000000")
    );

    return { token, owner, creator, user1, user2, user3 };
  }

  // ═══════════════════════════════════════════════════════
  // FairLaunch
  // ═══════════════════════════════════════════════════════

  describe("FairLaunch", function () {
    async function deployFairLaunchFixture() {
      const { token, owner, creator, user1, user2, user3 } =
        await loadFixture(deployTokenFixture);

      const FairLaunch = await ethers.getContractFactory("FairLaunch");
      const fairLaunch = await FairLaunch.deploy();

      // Transfer tokens to creator for launch setup
      await token.transfer(creator.address, ethers.parseEther("100000"));

      return { fairLaunch, token, owner, creator, user1, user2, user3 };
    }

    describe("createLaunch", function () {
      it("should create a launch with valid parameters", async function () {
        const { fairLaunch, token, creator } =
          await loadFixture(deployFairLaunchFixture);

        const now = await time.latest();
        const startTime = now + 60;
        const endTime = now + 3600;
        const softCap = ethers.parseEther("1");
        const hardCap = ethers.parseEther("10");
        const price = 1000n; // 1000 tokens per wei
        const maxPerWallet = ethers.parseEther("2");

        // Approve tokens for hardCap * price
        const tokensNeeded = hardCap * price;
        await token.connect(creator).approve(await fairLaunch.getAddress(), tokensNeeded);

        await expect(
          fairLaunch
            .connect(creator)
            .createLaunch(
              await token.getAddress(),
              softCap,
              hardCap,
              price,
              startTime,
              endTime,
              maxPerWallet
            )
        )
          .to.emit(fairLaunch, "LaunchCreated")
          .withArgs(
            0,
            await token.getAddress(),
            creator.address,
            softCap,
            hardCap,
            price,
            startTime,
            endTime,
            maxPerWallet
          );

        const launch = await fairLaunch.getLaunch(0);
        expect(launch.softCap).to.equal(softCap);
        expect(launch.hardCap).to.equal(hardCap);
        expect(launch.creator).to.equal(creator.address);
      });

      it("should revert with invalid caps", async function () {
        const { fairLaunch, token, creator } =
          await loadFixture(deployFairLaunchFixture);

        const now = await time.latest();
        await expect(
          fairLaunch
            .connect(creator)
            .createLaunch(await token.getAddress(), 0, 100, 1, now + 60, now + 3600, 50)
        ).to.be.revertedWithCustomError(fairLaunch, "InvalidCaps");
      });
    });

    describe("contribute", function () {
      it("should accept contributions within limits", async function () {
        const { fairLaunch, token, creator, user1 } =
          await loadFixture(deployFairLaunchFixture);

        const now = await time.latest();
        const startTime = now + 60;
        const endTime = now + 3600;
        const softCap = ethers.parseEther("1");
        const hardCap = ethers.parseEther("10");
        const price = 1000n;
        const maxPerWallet = ethers.parseEther("5");

        await token
          .connect(creator)
          .approve(await fairLaunch.getAddress(), hardCap * price);
        await fairLaunch
          .connect(creator)
          .createLaunch(
            await token.getAddress(),
            softCap,
            hardCap,
            price,
            startTime,
            endTime,
            maxPerWallet
          );

        await time.increaseTo(startTime);

        const contribution = ethers.parseEther("2");
        await expect(
          fairLaunch.connect(user1).contribute(0, { value: contribution })
        )
          .to.emit(fairLaunch, "Contributed")
          .withArgs(0, user1.address, contribution);

        expect(await fairLaunch.getContribution(0, user1.address)).to.equal(
          contribution
        );
      });

      it("should revert if exceeds max per wallet", async function () {
        const { fairLaunch, token, creator, user1 } =
          await loadFixture(deployFairLaunchFixture);

        const now = await time.latest();
        const softCap = ethers.parseEther("1");
        const hardCap = ethers.parseEther("10");
        const price = 1000n;
        const maxPerWallet = ethers.parseEther("1");

        await token
          .connect(creator)
          .approve(await fairLaunch.getAddress(), hardCap * price);
        await fairLaunch
          .connect(creator)
          .createLaunch(
            await token.getAddress(),
            softCap,
            hardCap,
            price,
            now + 60,
            now + 3600,
            maxPerWallet
          );

        await time.increaseTo(now + 60);

        await expect(
          fairLaunch
            .connect(user1)
            .contribute(0, { value: ethers.parseEther("2") })
        ).to.be.revertedWithCustomError(fairLaunch, "ExceedsMaxPerWallet");
      });

      it("should revert before start time", async function () {
        const { fairLaunch, token, creator, user1 } =
          await loadFixture(deployFairLaunchFixture);

        const now = await time.latest();
        const softCap = ethers.parseEther("1");
        const hardCap = ethers.parseEther("10");
        const price = 1000n;

        await token
          .connect(creator)
          .approve(await fairLaunch.getAddress(), hardCap * price);
        await fairLaunch
          .connect(creator)
          .createLaunch(
            await token.getAddress(),
            softCap,
            hardCap,
            price,
            now + 3600,
            now + 7200,
            ethers.parseEther("5")
          );

        await expect(
          fairLaunch
            .connect(user1)
            .contribute(0, { value: ethers.parseEther("1") })
        ).to.be.revertedWithCustomError(fairLaunch, "LaunchNotStarted");
      });
    });

    describe("finalize (success)", function () {
      it("should finalize and distribute fees correctly", async function () {
        const { fairLaunch, token, owner, creator, user1, user2 } =
          await loadFixture(deployFairLaunchFixture);

        const now = await time.latest();
        const softCap = ethers.parseEther("2");
        const hardCap = ethers.parseEther("10");
        const price = 1000n;
        const maxPerWallet = ethers.parseEther("5");

        await token
          .connect(creator)
          .approve(await fairLaunch.getAddress(), hardCap * price);
        await fairLaunch
          .connect(creator)
          .createLaunch(
            await token.getAddress(),
            softCap,
            hardCap,
            price,
            now + 60,
            now + 3600,
            maxPerWallet
          );

        await time.increaseTo(now + 60);

        // Two users contribute
        await fairLaunch
          .connect(user1)
          .contribute(0, { value: ethers.parseEther("3") });
        await fairLaunch
          .connect(user2)
          .contribute(0, { value: ethers.parseEther("2") });

        // Move past endTime
        await time.increaseTo(now + 3601);

        const totalRaised = ethers.parseEther("5");
        const protocolFee = totalRaised / 100n; // 1%

        const creatorBalBefore = await ethers.provider.getBalance(
          creator.address
        );
        const ownerBalBefore = await ethers.provider.getBalance(owner.address);

        await fairLaunch.finalize(0);

        const creatorBalAfter = await ethers.provider.getBalance(
          creator.address
        );
        const ownerBalAfter = await ethers.provider.getBalance(owner.address);

        expect(creatorBalAfter - creatorBalBefore).to.equal(
          totalRaised - protocolFee
        );
        expect(ownerBalAfter - ownerBalBefore).to.be.closeTo(
          protocolFee,
          ethers.parseEther("0.01") // gas tolerance
        );

        // Users can now claim tokens
        const user1Contribution = ethers.parseEther("3");
        const expectedTokens = user1Contribution * price;

        await fairLaunch.connect(user1).claimTokens(0);
        expect(await token.balanceOf(user1.address)).to.equal(expectedTokens);
      });
    });

    describe("refund (softCap miss)", function () {
      it("should allow refunds when softCap not met", async function () {
        const { fairLaunch, token, creator, user1 } =
          await loadFixture(deployFairLaunchFixture);

        const now = await time.latest();
        const softCap = ethers.parseEther("5");
        const hardCap = ethers.parseEther("10");
        const price = 1000n;

        await token
          .connect(creator)
          .approve(await fairLaunch.getAddress(), hardCap * price);
        await fairLaunch
          .connect(creator)
          .createLaunch(
            await token.getAddress(),
            softCap,
            hardCap,
            price,
            now + 60,
            now + 3600,
            ethers.parseEther("5")
          );

        await time.increaseTo(now + 60);

        const contribution = ethers.parseEther("1");
        await fairLaunch
          .connect(user1)
          .contribute(0, { value: contribution });

        // Move past endTime - softCap not met
        await time.increaseTo(now + 3601);

        const balBefore = await ethers.provider.getBalance(user1.address);
        const tx = await fairLaunch.connect(user1).refund(0);
        const receipt = await tx.wait();
        const gasCost = receipt!.gasUsed * receipt!.gasPrice;
        const balAfter = await ethers.provider.getBalance(user1.address);

        expect(balAfter + gasCost - balBefore).to.equal(contribution);

        // Tokens returned to creator
        const launch = await fairLaunch.getLaunch(0);
        expect(launch.status).to.equal(2); // Cancelled
      });

      it("should revert refund when softCap is met", async function () {
        const { fairLaunch, token, creator, user1 } =
          await loadFixture(deployFairLaunchFixture);

        const now = await time.latest();
        const softCap = ethers.parseEther("1");
        const hardCap = ethers.parseEther("10");
        const price = 1000n;

        await token
          .connect(creator)
          .approve(await fairLaunch.getAddress(), hardCap * price);
        await fairLaunch
          .connect(creator)
          .createLaunch(
            await token.getAddress(),
            softCap,
            hardCap,
            price,
            now + 60,
            now + 3600,
            ethers.parseEther("5")
          );

        await time.increaseTo(now + 60);
        await fairLaunch
          .connect(user1)
          .contribute(0, { value: ethers.parseEther("2") });
        await time.increaseTo(now + 3601);

        await expect(
          fairLaunch.connect(user1).refund(0)
        ).to.be.revertedWithCustomError(fairLaunch, "SoftCapMet");
      });
    });
  });

  // ═══════════════════════════════════════════════════════
  // WhitelistSale
  // ═══════════════════════════════════════════════════════

  describe("WhitelistSale", function () {
    async function deployWhitelistFixture() {
      const { token, owner, creator, user1, user2, user3 } =
        await loadFixture(deployTokenFixture);

      const WhitelistSale = await ethers.getContractFactory("WhitelistSale");
      const whitelistSale = await WhitelistSale.deploy();

      await token.transfer(creator.address, ethers.parseEther("100000"));

      // Build merkle tree: [address, maxAmount]
      const user1MaxAmount = ethers.parseEther("3");
      const user2MaxAmount = ethers.parseEther("5");

      const tree = StandardMerkleTree.of(
        [
          [user1.address, user1MaxAmount.toString()],
          [user2.address, user2MaxAmount.toString()],
        ],
        ["address", "uint256"]
      );

      return {
        whitelistSale,
        token,
        owner,
        creator,
        user1,
        user2,
        user3,
        tree,
        user1MaxAmount,
        user2MaxAmount,
      };
    }

    it("should allow whitelist contribution with valid proof", async function () {
      const {
        whitelistSale,
        token,
        creator,
        user1,
        tree,
        user1MaxAmount,
      } = await loadFixture(deployWhitelistFixture);

      const now = await time.latest();
      const startTime = now + 60;
      const whitelistEndTime = now + 1800;
      const endTime = now + 3600;
      const softCap = ethers.parseEther("1");
      const hardCap = ethers.parseEther("10");
      const price = 1000n;
      const maxPerWallet = ethers.parseEther("5");

      await token
        .connect(creator)
        .approve(await whitelistSale.getAddress(), hardCap * price);
      await whitelistSale
        .connect(creator)
        .createSale(
          await token.getAddress(),
          softCap,
          hardCap,
          price,
          startTime,
          whitelistEndTime,
          endTime,
          maxPerWallet
        );

      // Set merkle root
      await whitelistSale.connect(creator).setMerkleRoot(0, tree.root);

      await time.increaseTo(startTime);

      // Get proof for user1
      let proof: string[] = [];
      for (const [i, v] of tree.entries()) {
        if (v[0] === user1.address) {
          proof = tree.getProof(i);
          break;
        }
      }

      const contribution = ethers.parseEther("2");
      await expect(
        whitelistSale
          .connect(user1)
          .contributeWhitelist(0, proof, user1MaxAmount, { value: contribution })
      )
        .to.emit(whitelistSale, "Contributed")
        .withArgs(0, user1.address, contribution, true);
    });

    it("should reject invalid merkle proof", async function () {
      const { whitelistSale, token, creator, user3, tree } =
        await loadFixture(deployWhitelistFixture);

      const now = await time.latest();
      const softCap = ethers.parseEther("1");
      const hardCap = ethers.parseEther("10");
      const price = 1000n;

      await token
        .connect(creator)
        .approve(await whitelistSale.getAddress(), hardCap * price);
      await whitelistSale
        .connect(creator)
        .createSale(
          await token.getAddress(),
          softCap,
          hardCap,
          price,
          now + 60,
          now + 1800,
          now + 3600,
          ethers.parseEther("5")
        );

      await whitelistSale.connect(creator).setMerkleRoot(0, tree.root);
      await time.increaseTo(now + 60);

      // user3 is not in the tree — use an empty proof
      await expect(
        whitelistSale
          .connect(user3)
          .contributeWhitelist(0, [], ethers.parseEther("3"), {
            value: ethers.parseEther("1"),
          })
      ).to.be.revertedWithCustomError(whitelistSale, "InvalidProof");
    });

    it("should allow public contribution after whitelist phase", async function () {
      const { whitelistSale, token, creator, user3 } =
        await loadFixture(deployWhitelistFixture);

      const now = await time.latest();
      const softCap = ethers.parseEther("1");
      const hardCap = ethers.parseEther("10");
      const price = 1000n;

      await token
        .connect(creator)
        .approve(await whitelistSale.getAddress(), hardCap * price);
      await whitelistSale
        .connect(creator)
        .createSale(
          await token.getAddress(),
          softCap,
          hardCap,
          price,
          now + 60,
          now + 1800,
          now + 3600,
          ethers.parseEther("5")
        );

      // Jump to public phase
      await time.increaseTo(now + 1800);

      await expect(
        whitelistSale
          .connect(user3)
          .contributePublic(0, { value: ethers.parseEther("2") })
      )
        .to.emit(whitelistSale, "Contributed")
        .withArgs(0, user3.address, ethers.parseEther("2"), false);
    });

    it("should reject public contribution during whitelist phase", async function () {
      const { whitelistSale, token, creator, user3 } =
        await loadFixture(deployWhitelistFixture);

      const now = await time.latest();
      const softCap = ethers.parseEther("1");
      const hardCap = ethers.parseEther("10");
      const price = 1000n;

      await token
        .connect(creator)
        .approve(await whitelistSale.getAddress(), hardCap * price);
      await whitelistSale
        .connect(creator)
        .createSale(
          await token.getAddress(),
          softCap,
          hardCap,
          price,
          now + 60,
          now + 1800,
          now + 3600,
          ethers.parseEther("5")
        );

      await time.increaseTo(now + 60);

      await expect(
        whitelistSale
          .connect(user3)
          .contributePublic(0, { value: ethers.parseEther("1") })
      ).to.be.revertedWithCustomError(whitelistSale, "PublicPhaseOnly");
    });
  });

  // ═══════════════════════════════════════════════════════
  // DutchAuction
  // ═══════════════════════════════════════════════════════

  describe("DutchAuction", function () {
    async function deployDutchAuctionFixture() {
      const { token, owner, creator, user1, user2, user3 } =
        await loadFixture(deployTokenFixture);

      const DutchAuction = await ethers.getContractFactory("DutchAuction");
      const dutchAuction = await DutchAuction.deploy();

      await token.transfer(creator.address, ethers.parseEther("100000"));

      return { dutchAuction, token, owner, creator, user1, user2, user3 };
    }

    describe("price curve", function () {
      it("should return startPrice at the beginning", async function () {
        const { dutchAuction, token, creator } =
          await loadFixture(deployDutchAuctionFixture);

        const now = await time.latest();
        const startPrice = 100n; // tokens per wei
        const endPrice = 1000n;
        const hardCap = ethers.parseEther("10");
        const totalTokens = hardCap * endPrice; // enough for max price

        await token
          .connect(creator)
          .approve(await dutchAuction.getAddress(), totalTokens);
        await dutchAuction
          .connect(creator)
          .createAuction(
            await token.getAddress(),
            hardCap,
            startPrice,
            endPrice,
            now + 60,
            now + 3660,
            ethers.parseEther("5"),
            totalTokens
          );

        // Before start
        expect(await dutchAuction.getCurrentPrice(0)).to.equal(startPrice);
      });

      it("should return endPrice at the end", async function () {
        const { dutchAuction, token, creator } =
          await loadFixture(deployDutchAuctionFixture);

        const now = await time.latest();
        const startPrice = 100n;
        const endPrice = 1000n;
        const hardCap = ethers.parseEther("10");
        const totalTokens = hardCap * endPrice;

        await token
          .connect(creator)
          .approve(await dutchAuction.getAddress(), totalTokens);
        await dutchAuction
          .connect(creator)
          .createAuction(
            await token.getAddress(),
            hardCap,
            startPrice,
            endPrice,
            now + 60,
            now + 3660,
            ethers.parseEther("5"),
            totalTokens
          );

        await time.increaseTo(now + 3660);
        expect(await dutchAuction.getCurrentPrice(0)).to.equal(endPrice);
      });

      it("should interpolate linearly at midpoint", async function () {
        const { dutchAuction, token, creator } =
          await loadFixture(deployDutchAuctionFixture);

        const now = await time.latest();
        const startPrice = 100n;
        const endPrice = 1000n;
        const startTime = now + 60;
        const endTime = now + 3660; // 3600s duration
        const hardCap = ethers.parseEther("10");
        const totalTokens = hardCap * endPrice;

        await token
          .connect(creator)
          .approve(await dutchAuction.getAddress(), totalTokens);
        await dutchAuction
          .connect(creator)
          .createAuction(
            await token.getAddress(),
            hardCap,
            startPrice,
            endPrice,
            startTime,
            endTime,
            ethers.parseEther("5"),
            totalTokens
          );

        // Go to midpoint
        await time.increaseTo(startTime + 1800);
        const midPrice = await dutchAuction.getCurrentPrice(0);
        // At midpoint: 100 + (900 * 1800) / 3600 = 100 + 450 = 550
        expect(midPrice).to.equal(550n);
      });
    });

    describe("contribute", function () {
      it("should buy tokens at current price", async function () {
        const { dutchAuction, token, creator, user1 } =
          await loadFixture(deployDutchAuctionFixture);

        const now = await time.latest();
        const startPrice = 100n;
        const endPrice = 1000n;
        const hardCap = ethers.parseEther("10");
        const totalTokens = hardCap * endPrice;

        await token
          .connect(creator)
          .approve(await dutchAuction.getAddress(), totalTokens);
        await dutchAuction
          .connect(creator)
          .createAuction(
            await token.getAddress(),
            hardCap,
            startPrice,
            endPrice,
            now + 60,
            now + 3660,
            ethers.parseEther("5"),
            totalTokens
          );

        await time.increaseTo(now + 60);

        const contribution = ethers.parseEther("1");
        await dutchAuction
          .connect(user1)
          .contribute(0, { value: contribution });

        const allocation = await dutchAuction.getTokenAllocation(
          0,
          user1.address
        );
        expect(allocation).to.be.gt(0);
      });
    });

    describe("finalize", function () {
      it("should finalize and let users claim tokens", async function () {
        const { dutchAuction, token, owner, creator, user1 } =
          await loadFixture(deployDutchAuctionFixture);

        const now = await time.latest();
        const startPrice = 100n;
        const endPrice = 1000n;
        const hardCap = ethers.parseEther("10");
        const totalTokens = hardCap * endPrice;

        await token
          .connect(creator)
          .approve(await dutchAuction.getAddress(), totalTokens);
        await dutchAuction
          .connect(creator)
          .createAuction(
            await token.getAddress(),
            hardCap,
            startPrice,
            endPrice,
            now + 60,
            now + 3660,
            ethers.parseEther("5"),
            totalTokens
          );

        await time.increaseTo(now + 60);

        await dutchAuction
          .connect(user1)
          .contribute(0, { value: ethers.parseEther("2") });

        await time.increaseTo(now + 3661);

        await dutchAuction.finalize(0);

        const allocation = await dutchAuction.getTokenAllocation(
          0,
          user1.address
        );
        await dutchAuction.connect(user1).claimTokens(0);
        expect(await token.balanceOf(user1.address)).to.equal(allocation);
      });

      it("should cancel if no contributions", async function () {
        const { dutchAuction, token, creator } =
          await loadFixture(deployDutchAuctionFixture);

        const now = await time.latest();
        const hardCap = ethers.parseEther("10");
        const totalTokens = hardCap * 1000n;

        await token
          .connect(creator)
          .approve(await dutchAuction.getAddress(), totalTokens);
        await dutchAuction
          .connect(creator)
          .createAuction(
            await token.getAddress(),
            hardCap,
            100n,
            1000n,
            now + 60,
            now + 3660,
            ethers.parseEther("5"),
            totalTokens
          );

        await time.increaseTo(now + 3661);

        await expect(dutchAuction.finalize(0))
          .to.emit(dutchAuction, "AuctionCancelled")
          .withArgs(0);
      });
    });
  });

  // ═══════════════════════════════════════════════════════
  // VestingSchedule
  // ═══════════════════════════════════════════════════════

  describe("VestingSchedule", function () {
    async function deployVestingFixture() {
      const { token, owner, creator, user1, user2 } =
        await loadFixture(deployTokenFixture);

      const VestingSchedule =
        await ethers.getContractFactory("VestingSchedule");
      const vesting = await VestingSchedule.deploy();

      return { vesting, token, owner, creator, user1, user2 };
    }

    describe("createVesting", function () {
      it("should create a vesting schedule", async function () {
        const { vesting, token, owner, user1 } =
          await loadFixture(deployVestingFixture);

        const amount = ethers.parseEther("1000");
        const cliffDuration = 30 * 24 * 3600; // 30 days
        const totalDuration = 365 * 24 * 3600; // 1 year

        await token.approve(await vesting.getAddress(), amount);
        await expect(
          vesting.createVesting(
            user1.address,
            await token.getAddress(),
            amount,
            cliffDuration,
            totalDuration
          )
        )
          .to.emit(vesting, "VestingCreated")
          .withArgs(
            0,
            user1.address,
            await token.getAddress(),
            amount,
            await time.latest() + 1, // approximate
            cliffDuration,
            totalDuration
          );
      });
    });

    describe("cliff", function () {
      it("should not allow claims before cliff", async function () {
        const { vesting, token, owner, user1 } =
          await loadFixture(deployVestingFixture);

        const amount = ethers.parseEther("1000");
        const cliffDuration = 30 * 24 * 3600;
        const totalDuration = 365 * 24 * 3600;

        await token.approve(await vesting.getAddress(), amount);
        await vesting.createVesting(
          user1.address,
          await token.getAddress(),
          amount,
          cliffDuration,
          totalDuration
        );

        // Try to claim before cliff
        await time.increase(cliffDuration - 100);
        await expect(
          vesting.connect(user1).claim(0)
        ).to.be.revertedWithCustomError(vesting, "NothingToClaim");
      });

      it("should allow partial claim after cliff", async function () {
        const { vesting, token, owner, user1 } =
          await loadFixture(deployVestingFixture);

        const amount = ethers.parseEther("1000");
        const cliffDuration = 30 * 24 * 3600;
        const totalDuration = 365 * 24 * 3600;

        await token.approve(await vesting.getAddress(), amount);
        await vesting.createVesting(
          user1.address,
          await token.getAddress(),
          amount,
          cliffDuration,
          totalDuration
        );

        // Move past cliff
        await time.increase(cliffDuration + 1);

        await vesting.connect(user1).claim(0);
        const balance = await token.balanceOf(user1.address);
        expect(balance).to.be.gt(0);
        expect(balance).to.be.lt(amount);
      });
    });

    describe("linear vesting", function () {
      it("should vest 100% after total duration", async function () {
        const { vesting, token, owner, user1 } =
          await loadFixture(deployVestingFixture);

        const amount = ethers.parseEther("1000");
        const cliffDuration = 30 * 24 * 3600;
        const totalDuration = 365 * 24 * 3600;

        await token.approve(await vesting.getAddress(), amount);
        await vesting.createVesting(
          user1.address,
          await token.getAddress(),
          amount,
          cliffDuration,
          totalDuration
        );

        await time.increase(totalDuration + 1);

        await vesting.connect(user1).claim(0);
        expect(await token.balanceOf(user1.address)).to.equal(amount);
      });

      it("should vest approximately 50% at halfway point", async function () {
        const { vesting, token, owner, user1 } =
          await loadFixture(deployVestingFixture);

        const amount = ethers.parseEther("1000");
        const cliffDuration = 0; // No cliff for clean math
        const totalDuration = 365 * 24 * 3600;

        await token.approve(await vesting.getAddress(), amount);
        await vesting.createVesting(
          user1.address,
          await token.getAddress(),
          amount,
          cliffDuration,
          totalDuration
        );

        await time.increase(totalDuration / 2);

        const claimable = await vesting.getClaimable(0);
        const halfAmount = amount / 2n;
        // Allow 0.5% tolerance for block timestamp
        expect(claimable).to.be.closeTo(halfAmount, halfAmount / 200n);
      });
    });

    describe("revoke", function () {
      it("should revoke unvested tokens back to owner", async function () {
        const { vesting, token, owner, user1 } =
          await loadFixture(deployVestingFixture);

        const amount = ethers.parseEther("1000");
        const cliffDuration = 30 * 24 * 3600;
        const totalDuration = 365 * 24 * 3600;

        await token.approve(await vesting.getAddress(), amount);
        await vesting.createVesting(
          user1.address,
          await token.getAddress(),
          amount,
          cliffDuration,
          totalDuration
        );

        // Move past cliff
        await time.increase(cliffDuration + totalDuration / 4);

        const ownerBalBefore = await token.balanceOf(owner.address);

        await expect(vesting.revoke(0)).to.emit(vesting, "VestingRevoked");

        const schedule = await vesting.getSchedule(0);
        expect(schedule.revoked).to.be.true;

        // Owner received unvested tokens
        const ownerBalAfter = await token.balanceOf(owner.address);
        expect(ownerBalAfter).to.be.gt(ownerBalBefore);

        // Beneficiary received vested tokens
        expect(await token.balanceOf(user1.address)).to.be.gt(0);
      });

      it("should revert if already revoked", async function () {
        const { vesting, token, owner, user1 } =
          await loadFixture(deployVestingFixture);

        const amount = ethers.parseEther("1000");
        await token.approve(await vesting.getAddress(), amount);
        await vesting.createVesting(
          user1.address,
          await token.getAddress(),
          amount,
          0,
          365 * 24 * 3600
        );

        await vesting.revoke(0);
        await expect(vesting.revoke(0)).to.be.revertedWithCustomError(
          vesting,
          "AlreadyRevoked"
        );
      });

      it("should revert if not owner", async function () {
        const { vesting, token, owner, user1 } =
          await loadFixture(deployVestingFixture);

        const amount = ethers.parseEther("1000");
        await token.approve(await vesting.getAddress(), amount);
        await vesting.createVesting(
          user1.address,
          await token.getAddress(),
          amount,
          0,
          365 * 24 * 3600
        );

        await expect(
          vesting.connect(user1).revoke(0)
        ).to.be.revertedWithCustomError(vesting, "OwnableUnauthorizedAccount");
      });
    });
  });

  // ═══════════════════════════════════════════════════════
  // LaunchpadFactory
  // ═══════════════════════════════════════════════════════

  describe("LaunchpadFactory", function () {
    async function deployFactoryFixture() {
      const [owner, user1] = await ethers.getSigners();

      const LaunchpadFactory =
        await ethers.getContractFactory("LaunchpadFactory");
      const factory = await LaunchpadFactory.deploy();

      return { factory, owner, user1 };
    }

    it("should deploy FairLaunch and track it", async function () {
      const { factory, user1 } = await loadFixture(deployFactoryFixture);

      await expect(factory.connect(user1).deployFairLaunch()).to.emit(
        factory,
        "FairLaunchDeployed"
      );

      expect(await factory.getFairLaunchCount()).to.equal(1);
      const launches = await factory.getAllFairLaunches();
      expect(launches.length).to.equal(1);
    });

    it("should deploy WhitelistSale and track it", async function () {
      const { factory, user1 } = await loadFixture(deployFactoryFixture);

      await expect(factory.connect(user1).deployWhitelistSale()).to.emit(
        factory,
        "WhitelistSaleDeployed"
      );

      expect(await factory.getWhitelistSaleCount()).to.equal(1);
    });

    it("should deploy DutchAuction and track it", async function () {
      const { factory, user1 } = await loadFixture(deployFactoryFixture);

      await expect(factory.connect(user1).deployDutchAuction()).to.emit(
        factory,
        "DutchAuctionDeployed"
      );

      expect(await factory.getDutchAuctionCount()).to.equal(1);
    });

    it("should transfer ownership of deployed contracts to caller", async function () {
      const { factory, user1 } = await loadFixture(deployFactoryFixture);

      await factory.connect(user1).deployFairLaunch();
      const launchAddr = await factory.fairLaunches(0);

      const FairLaunch = await ethers.getContractFactory("FairLaunch");
      const launch = FairLaunch.attach(launchAddr);
      expect(await (launch as any).owner()).to.equal(user1.address);
    });
  });
});
