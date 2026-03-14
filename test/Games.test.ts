import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("Game Contracts", function () {
  // ─── GameLeaderboard ───────────────────────────────────────

  describe("GameLeaderboard", function () {
    async function deployLeaderboardFixture() {
      const [owner, server, player1, player2, player3] = await ethers.getSigners();

      const Leaderboard = await ethers.getContractFactory("GameLeaderboard");
      const leaderboard = await Leaderboard.deploy();

      const gameId = ethers.keccak256(ethers.toUtf8Bytes("dungeon"));

      // Register game with server as signer
      await leaderboard.registerGame(gameId, server.address);

      // Start a season (30 days)
      await leaderboard.startSeason(gameId, 30 * 24 * 3600);

      return { leaderboard, owner, server, player1, player2, player3, gameId };
    }

    async function signScore(
      server: any,
      gameId: string,
      player: string,
      score: bigint,
      nonce: string,
      chainId: bigint
    ) {
      const messageHash = ethers.solidityPackedKeccak256(
        ["bytes32", "address", "uint256", "bytes32", "uint256"],
        [gameId, player, score, nonce, chainId]
      );
      return server.signMessage(ethers.getBytes(messageHash));
    }

    it("Should register a game", async function () {
      const { leaderboard, server, gameId } = await loadFixture(deployLeaderboardFixture);
      expect(await leaderboard.gameSigner(gameId)).to.equal(server.address);
    });

    it("Should submit a score with valid signature", async function () {
      const { leaderboard, server, player1, gameId } = await loadFixture(deployLeaderboardFixture);

      const nonce = ethers.randomBytes(32);
      const nonceHex = ethers.hexlify(nonce);
      const chainId = (await ethers.provider.getNetwork()).chainId;

      const sig = await signScore(server, gameId, player1.address, 1000n, nonceHex, chainId);

      await expect(leaderboard.connect(player1).submitScore(gameId, 1000, nonceHex, sig))
        .to.emit(leaderboard, "ScoreSubmitted");

      const seasonId = await leaderboard.currentSeason(gameId);
      expect(await leaderboard.playerBestScore(gameId, seasonId, player1.address)).to.equal(1000);
    });

    it("Should reject replayed nonce", async function () {
      const { leaderboard, server, player1, gameId } = await loadFixture(deployLeaderboardFixture);

      const nonceHex = ethers.hexlify(ethers.randomBytes(32));
      const chainId = (await ethers.provider.getNetwork()).chainId;
      const sig = await signScore(server, gameId, player1.address, 500n, nonceHex, chainId);

      await leaderboard.connect(player1).submitScore(gameId, 500, nonceHex, sig);

      await expect(
        leaderboard.connect(player1).submitScore(gameId, 500, nonceHex, sig)
      ).to.be.revertedWith("Nonce already used");
    });

    it("Should reject invalid signature", async function () {
      const { leaderboard, player1, player2, gameId } = await loadFixture(deployLeaderboardFixture);

      const nonceHex = ethers.hexlify(ethers.randomBytes(32));
      const chainId = (await ethers.provider.getNetwork()).chainId;
      // player2 is not the game server
      const sig = await signScore(player2, gameId, player1.address, 500n, nonceHex, chainId);

      await expect(
        leaderboard.connect(player1).submitScore(gameId, 500, nonceHex, sig)
      ).to.be.revertedWith("Invalid signature");
    });

    it("Should maintain sorted leaderboard", async function () {
      const { leaderboard, server, player1, player2, player3, gameId } =
        await loadFixture(deployLeaderboardFixture);

      const chainId = (await ethers.provider.getNetwork()).chainId;
      const seasonId = await leaderboard.currentSeason(gameId);

      // Submit scores: p2=500, p1=1000, p3=750
      for (const [player, score] of [
        [player2, 500n],
        [player1, 1000n],
        [player3, 750n],
      ] as const) {
        const nonce = ethers.hexlify(ethers.randomBytes(32));
        const sig = await signScore(server, gameId, player.address, score, nonce, chainId);
        await leaderboard.connect(player).submitScore(gameId, score, nonce, sig);
      }

      const board = await leaderboard.getLeaderboard(gameId, seasonId);
      expect(board.length).to.equal(3);
      expect(board[0].player).to.equal(player1.address); // 1000
      expect(board[1].player).to.equal(player3.address); // 750
      expect(board[2].player).to.equal(player2.address); // 500
    });
  });

  // ─── GameRewards ───────────────────────────────────────────

  describe("GameRewards", function () {
    async function deployRewardsFixture() {
      const [owner, server, player1, player2] = await ethers.getSigners();

      // Deploy reward token
      const Token = await ethers.getContractFactory("QFCToken");
      const token = await Token.deploy(
        "QFC Token", "QFC", ethers.parseEther("1000000"), ethers.parseEther("1000000")
      );

      // Deploy leaderboard
      const Leaderboard = await ethers.getContractFactory("GameLeaderboard");
      const leaderboard = await Leaderboard.deploy();

      // Deploy rewards
      const Rewards = await ethers.getContractFactory("GameRewards");
      const rewards = await Rewards.deploy(await token.getAddress(), await leaderboard.getAddress());

      // Fund rewards contract
      await token.transfer(await rewards.getAddress(), ethers.parseEther("10000"));

      // Setup game
      const gameId = ethers.keccak256(ethers.toUtf8Bytes("dungeon"));
      await leaderboard.registerGame(gameId, server.address);
      await leaderboard.startSeason(gameId, 30 * 24 * 3600);

      // Set reward tiers: 1st=100, 2nd=50, 3rd=25
      await rewards.setRewardTiers(gameId, [
        ethers.parseEther("100"),
        ethers.parseEther("50"),
        ethers.parseEther("25"),
      ]);

      return { token, leaderboard, rewards, owner, server, player1, player2, gameId };
    }

    it("Should set reward tiers", async function () {
      const { rewards, gameId } = await loadFixture(deployRewardsFixture);
      expect(await rewards.seasonRewardTiers(gameId, 0)).to.equal(ethers.parseEther("100"));
    });

    it("Should grant and claim achievement reward", async function () {
      const { token, rewards, owner, player1 } = await loadFixture(deployRewardsFixture);

      const achievementId = ethers.keccak256(ethers.toUtf8Bytes("first_kill"));
      await rewards.setAchievementReward(achievementId, ethers.parseEther("10"));
      await rewards.setDistributor(owner.address, true);

      await rewards.grantAchievement(player1.address, achievementId);

      const balanceBefore = await token.balanceOf(player1.address);
      await rewards.connect(player1).claim();
      const balanceAfter = await token.balanceOf(player1.address);

      expect(balanceAfter - balanceBefore).to.equal(ethers.parseEther("10"));
    });

    it("Should prevent double achievement claim", async function () {
      const { rewards, owner, player1 } = await loadFixture(deployRewardsFixture);

      const achievementId = ethers.keccak256(ethers.toUtf8Bytes("first_kill"));
      await rewards.setAchievementReward(achievementId, ethers.parseEther("10"));
      await rewards.setDistributor(owner.address, true);

      await rewards.grantAchievement(player1.address, achievementId);
      await expect(
        rewards.grantAchievement(player1.address, achievementId)
      ).to.be.revertedWith("Already claimed");
    });
  });

  // ─── GameItems ─────────────────────────────────────────────

  describe("GameItems", function () {
    async function deployItemsFixture() {
      const [owner, minter, player1, player2] = await ethers.getSigners();

      const Items = await ethers.getContractFactory("GameItems");
      const items = await Items.deploy(250, owner.address); // 2.5% royalty

      // Grant minter role
      const MINTER_ROLE = await items.MINTER_ROLE();
      await items.grantRole(MINTER_ROLE, minter.address);

      const gameId = ethers.keccak256(ethers.toUtf8Bytes("dungeon"));

      return { items, owner, minter, player1, player2, gameId, MINTER_ROLE };
    }

    it("Should mint an item", async function () {
      const { items, minter, player1, gameId } = await loadFixture(deployItemsFixture);

      await expect(
        items.connect(minter).mintItem(player1.address, gameId, 3, false, "ipfs://item1")
      ).to.emit(items, "ItemMinted");

      expect(await items.ownerOf(0)).to.equal(player1.address);
      expect(await items.tokenURI(0)).to.equal("ipfs://item1");

      const item = await items.getItem(0);
      expect(item.rarity).to.equal(3); // Epic
      expect(item.soulbound).to.equal(false);
    });

    it("Should batch mint items", async function () {
      const { items, minter, player1, gameId } = await loadFixture(deployItemsFixture);

      const rarities = [0, 1, 2]; // Common, Uncommon, Rare
      const uris = ["ipfs://a", "ipfs://b", "ipfs://c"];

      await items.connect(minter).batchMint(player1.address, gameId, rarities, false, uris);

      expect(await items.balanceOf(player1.address)).to.equal(3);
      expect(await items.gameItemCount(gameId)).to.equal(3);
    });

    it("Should prevent transfer of soulbound items", async function () {
      const { items, minter, player1, player2, gameId } = await loadFixture(deployItemsFixture);

      await items.connect(minter).mintItem(player1.address, gameId, 4, true, "ipfs://sb");

      await expect(
        items.connect(player1).transferFrom(player1.address, player2.address, 0)
      ).to.be.revertedWith("Soulbound: non-transferable");
    });

    it("Should allow transfer of non-soulbound items", async function () {
      const { items, minter, player1, player2, gameId } = await loadFixture(deployItemsFixture);

      await items.connect(minter).mintItem(player1.address, gameId, 2, false, "ipfs://item");
      await items.connect(player1).transferFrom(player1.address, player2.address, 0);

      expect(await items.ownerOf(0)).to.equal(player2.address);
    });

    it("Should reject minting from unauthorized address", async function () {
      const { items, player1, gameId } = await loadFixture(deployItemsFixture);

      await expect(
        items.connect(player1).mintItem(player1.address, gameId, 0, false, "ipfs://x")
      ).to.be.reverted;
    });
  });

  // ─── GamePassport ──────────────────────────────────────────

  describe("GamePassport", function () {
    async function deployPassportFixture() {
      const [owner, gameServer, player1, player2] = await ethers.getSigners();

      const Passport = await ethers.getContractFactory("GamePassport");
      const passport = await Passport.deploy();

      // Grant game role to gameServer
      const GAME_ROLE = await passport.GAME_ROLE();
      await passport.grantRole(GAME_ROLE, gameServer.address);

      const gameId = ethers.keccak256(ethers.toUtf8Bytes("dungeon"));

      return { passport, owner, gameServer, player1, player2, gameId, GAME_ROLE };
    }

    it("Should mint a passport", async function () {
      const { passport, player1 } = await loadFixture(deployPassportFixture);

      await expect(passport.connect(player1).mint())
        .to.emit(passport, "PassportMinted");

      expect(await passport.balanceOf(player1.address)).to.equal(1);
    });

    it("Should prevent duplicate passport", async function () {
      const { passport, player1 } = await loadFixture(deployPassportFixture);

      await passport.connect(player1).mint();
      await expect(passport.connect(player1).mint())
        .to.be.revertedWith("Already has passport");
    });

    it("Should prevent passport transfer (soulbound)", async function () {
      const { passport, player1, player2 } = await loadFixture(deployPassportFixture);

      await passport.connect(player1).mint();
      const tokenId = await passport.passportOf(player1.address);

      await expect(
        passport.connect(player1).transferFrom(player1.address, player2.address, tokenId)
      ).to.be.revertedWith("Soulbound: non-transferable");
    });

    it("Should record game and award XP", async function () {
      const { passport, gameServer, player1, gameId } = await loadFixture(deployPassportFixture);

      await passport.connect(player1).mint();

      await expect(
        passport.connect(gameServer).recordGame(player1.address, gameId, true, 500, 50)
      ).to.emit(passport, "XPEarned");

      const data = await passport.getPassport(player1.address);
      expect(data.totalXP).to.equal(50);
      expect(data.gamesPlayed).to.equal(1);
      expect(data.totalWins).to.equal(1);
    });

    it("Should level up at thresholds", async function () {
      const { passport, gameServer, player1, gameId } = await loadFixture(deployPassportFixture);

      await passport.connect(player1).mint();

      // Award 100 XP → level 1
      await expect(
        passport.connect(gameServer).recordGame(player1.address, gameId, true, 100, 100)
      ).to.emit(passport, "LevelUp").withArgs(1, 1);

      const data = await passport.getPassport(player1.address);
      expect(data.level).to.equal(1);
    });

    it("Should track per-game scores", async function () {
      const { passport, gameServer, player1, gameId } = await loadFixture(deployPassportFixture);

      const cardsId = ethers.keccak256(ethers.toUtf8Bytes("cards"));

      await passport.connect(player1).mint();
      await passport.connect(gameServer).recordGame(player1.address, gameId, true, 500, 10);
      await passport.connect(gameServer).recordGame(player1.address, cardsId, false, 300, 5);

      expect(await passport.getGameScore(player1.address, gameId)).to.equal(500);
      expect(await passport.getGameScore(player1.address, cardsId)).to.equal(300);
    });
  });
});
