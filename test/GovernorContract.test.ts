import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("GovernorContract", function () {
  const VOTING_PERIOD = 3600; // 1 hour (testnet)
  const TIMELOCK = 600; // 10 min (testnet)
  const QUORUM_BPS = 400; // 4%
  const SUPPLY = ethers.parseEther("1000000"); // 1M tokens

  async function deployFixture() {
    const [admin, proposer, voter1, voter2, voter3] = await ethers.getSigners();

    // Deploy a simple ERC-20 for voting power
    const Token = await ethers.getContractFactory("QFCToken");
    const token = await Token.deploy("QFC", "QFC", SUPPLY, SUPPLY);
    await token.waitForDeployment();

    // Distribute tokens: proposer 10%, voter1 3%, voter2 2%, voter3 1%
    await token.transfer(proposer.address, ethers.parseEther("100000"));
    await token.transfer(voter1.address, ethers.parseEther("30000"));
    await token.transfer(voter2.address, ethers.parseEther("20000"));
    await token.transfer(voter3.address, ethers.parseEther("10000"));

    const Governor = await ethers.getContractFactory("GovernorContract");
    const governor = await Governor.deploy(
      await token.getAddress(),
      VOTING_PERIOD,
      TIMELOCK,
      QUORUM_BPS
    );
    await governor.waitForDeployment();

    return { governor, token, admin, proposer, voter1, voter2, voter3 };
  }

  describe("propose()", function () {
    it("creates proposal with correct state", async function () {
      const { governor, proposer } = await loadFixture(deployFixture);

      const tx = await governor
        .connect(proposer)
        .propose("Upgrade Protocol", "Description here", 1, "0x");

      const receipt = await tx.wait();
      expect(receipt).to.not.be.null;

      const proposal = await governor.getProposal(1);
      expect(proposal.id).to.equal(1);
      expect(proposal.proposer).to.equal(proposer.address);
      expect(proposal.title).to.equal("Upgrade Protocol");
      expect(proposal.ptype).to.equal(1); // ProtocolUpgrade
      expect(proposal.executed).to.be.false;
      expect(proposal.cancelled).to.be.false;

      const state = await governor.state(1);
      expect(state).to.equal(1); // Active
    });

    it("emits ProposalCreated event", async function () {
      const { governor, proposer } = await loadFixture(deployFixture);

      await expect(
        governor.connect(proposer).propose("Test", "Desc", 0, "0x")
      ).to.emit(governor, "ProposalCreated");
    });

    it("reverts on empty title", async function () {
      const { governor, proposer } = await loadFixture(deployFixture);

      await expect(
        governor.connect(proposer).propose("", "Desc", 0, "0x")
      ).to.be.revertedWithCustomError(governor, "EmptyTitle");
    });

    it("increments proposalCount", async function () {
      const { governor, proposer } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("First", "Desc", 0, "0x");
      await governor.connect(proposer).propose("Second", "Desc", 3, "0x");
      expect(await governor.proposalCount()).to.equal(2);
    });
  });

  describe("castVote()", function () {
    it("records vote and updates totals", async function () {
      const { governor, proposer, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, "0x");
      await governor.connect(voter1).castVote(1, 1); // vote for

      const receipt = await governor.getReceipt(1, voter1.address);
      expect(receipt.hasVoted).to.be.true;
      expect(receipt.support).to.equal(1);
      expect(receipt.votes).to.equal(ethers.parseEther("30000"));

      const proposal = await governor.getProposal(1);
      expect(proposal.forVotes).to.equal(ethers.parseEther("30000"));
    });

    it("prevents double voting", async function () {
      const { governor, proposer, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, "0x");
      await governor.connect(voter1).castVote(1, 1);

      await expect(
        governor.connect(voter1).castVote(1, 0)
      ).to.be.revertedWithCustomError(governor, "AlreadyVoted");
    });

    it("reverts if no voting power", async function () {
      const { governor, proposer } = await loadFixture(deployFixture);
      const [, , , , , noTokens] = await ethers.getSigners();

      await governor.connect(proposer).propose("Test", "Desc", 0, "0x");

      await expect(
        governor.connect(noTokens).castVote(1, 1)
      ).to.be.revertedWithCustomError(governor, "NoVotingPower");
    });

    it("reverts if voting period ended", async function () {
      const { governor, proposer, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, "0x");
      await time.increase(VOTING_PERIOD + 1);

      await expect(
        governor.connect(voter1).castVote(1, 1)
      ).to.be.revertedWithCustomError(governor, "NotActive");
    });

    it("handles abstain votes", async function () {
      const { governor, proposer, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, "0x");
      await governor.connect(voter1).castVote(1, 2); // abstain

      const proposal = await governor.getProposal(1);
      expect(proposal.abstainVotes).to.equal(ethers.parseEther("30000"));
      expect(proposal.forVotes).to.equal(0);
      expect(proposal.againstVotes).to.equal(0);
    });
  });

  describe("Quorum check on execution", function () {
    it("proposal is defeated without quorum", async function () {
      const { governor, proposer, voter3 } = await loadFixture(deployFixture);

      // voter3 has 10000 tokens = 1% of supply, below 4% quorum
      await governor.connect(proposer).propose("Test", "Desc", 0, "0x");
      await governor.connect(voter3).castVote(1, 1);
      await time.increase(VOTING_PERIOD + 1);

      const state = await governor.state(1);
      expect(state).to.equal(2); // Defeated
    });

    it("proposal succeeds with quorum met", async function () {
      const { governor, proposer, admin, voter1 } = await loadFixture(deployFixture);

      // admin(840k) + voter1(30k) = enough for quorum
      await governor.connect(proposer).propose("Test", "Desc", 0, "0x");
      await governor.connect(admin).castVote(1, 1);
      await governor.connect(voter1).castVote(1, 1);
      await time.increase(VOTING_PERIOD + 1);

      const state = await governor.state(1);
      expect(state).to.equal(4); // Queued (succeeded, in timelock)
    });
  });

  describe("Timelock enforcement", function () {
    it("cannot execute during timelock period", async function () {
      const { governor, proposer, admin, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, "0x");
      await governor.connect(admin).castVote(1, 1);
      await governor.connect(voter1).castVote(1, 1);
      await time.increase(VOTING_PERIOD + 1);

      // Still in timelock — state is Queued, not Succeeded
      await expect(
        governor.execute(1)
      ).to.be.revertedWithCustomError(governor, "NotSucceeded");
    });

    it("can execute after timelock expires", async function () {
      const { governor, proposer, admin, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, "0x");
      await governor.connect(admin).castVote(1, 1);
      await governor.connect(voter1).castVote(1, 1);
      await time.increase(VOTING_PERIOD + TIMELOCK + 1);

      // State should be Succeeded (past timelock)
      const state = await governor.state(1);
      expect(state).to.equal(3); // Succeeded

      await expect(governor.execute(1))
        .to.emit(governor, "ProposalExecuted")
        .withArgs(1);

      const proposal = await governor.getProposal(1);
      expect(proposal.executed).to.be.true;

      const finalState = await governor.state(1);
      expect(finalState).to.equal(5); // Executed
    });
  });

  describe("cancel()", function () {
    it("proposer can cancel", async function () {
      const { governor, proposer } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, "0x");
      await governor.connect(proposer).cancel(1);

      const state = await governor.state(1);
      expect(state).to.equal(6); // Cancelled
    });

    it("admin can cancel", async function () {
      const { governor, proposer, admin } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, "0x");
      await governor.connect(admin).cancel(1);

      const state = await governor.state(1);
      expect(state).to.equal(6); // Cancelled
    });

    it("others cannot cancel", async function () {
      const { governor, proposer, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, "0x");

      await expect(
        governor.connect(voter1).cancel(1)
      ).to.be.revertedWithCustomError(governor, "NotProposerOrAdmin");
    });
  });
});
