import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time, mine } from "@nomicfoundation/hardhat-network-helpers";

describe("GovernorContract", function () {
  const VOTING_PERIOD = 3600; // 1 hour (testnet)
  const TIMELOCK = 600; // 10 min (testnet)
  const QUORUM_BPS = 400; // 4%
  const SUPPLY = ethers.parseEther("1000000"); // 1M tokens

  async function deployFixture() {
    const [admin, proposer, voter1, voter2, voter3] = await ethers.getSigners();

    // Deploy ERC20Votes token
    const Token = await ethers.getContractFactory("MockERC20Votes");
    const token = await Token.deploy("QFC", "QFC", SUPPLY);
    await token.waitForDeployment();

    // Distribute tokens
    await token.transfer(proposer.address, ethers.parseEther("100000"));
    await token.transfer(voter1.address, ethers.parseEther("30000"));
    await token.transfer(voter2.address, ethers.parseEther("20000"));
    await token.transfer(voter3.address, ethers.parseEther("10000"));

    // Delegate to self to activate voting power (required by ERC20Votes)
    await token.connect(admin).delegate(admin.address);
    await token.connect(proposer).delegate(proposer.address);
    await token.connect(voter1).delegate(voter1.address);
    await token.connect(voter2).delegate(voter2.address);
    await token.connect(voter3).delegate(voter3.address);

    // Mine a block so getPastVotes works (needs at least 1 block after delegation)
    await mine(1);

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
        .propose("Upgrade Protocol", "Description here", 1, ethers.ZeroAddress, "0x");

      const receipt = await tx.wait();
      expect(receipt).to.not.be.null;

      const proposal = await governor.getProposal(1);
      expect(proposal.id).to.equal(1);
      expect(proposal.proposer).to.equal(proposer.address);
      expect(proposal.title).to.equal("Upgrade Protocol");
      expect(proposal.ptype).to.equal(1); // ProtocolUpgrade
      expect(proposal.target).to.equal(ethers.ZeroAddress);
      expect(proposal.executed).to.be.false;
      expect(proposal.cancelled).to.be.false;
      expect(proposal.snapshotTotalSupply).to.equal(SUPPLY);

      const state = await governor.state(1);
      expect(state).to.equal(1); // Active
    });

    it("emits ProposalCreated event", async function () {
      const { governor, proposer } = await loadFixture(deployFixture);

      await expect(
        governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x")
      ).to.emit(governor, "ProposalCreated");
    });

    it("reverts on empty title", async function () {
      const { governor, proposer } = await loadFixture(deployFixture);

      await expect(
        governor.connect(proposer).propose("", "Desc", 0, ethers.ZeroAddress, "0x")
      ).to.be.revertedWithCustomError(governor, "EmptyTitle");
    });

    it("increments proposalCount", async function () {
      const { governor, proposer } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("First", "Desc", 0, ethers.ZeroAddress, "0x");
      await governor.connect(proposer).propose("Second", "Desc", 3, ethers.ZeroAddress, "0x");
      expect(await governor.proposalCount()).to.equal(2);
    });
  });

  describe("castVote()", function () {
    it("records vote using snapshot voting power", async function () {
      const { governor, proposer, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");
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

      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");
      await governor.connect(voter1).castVote(1, 1);

      await expect(
        governor.connect(voter1).castVote(1, 0)
      ).to.be.revertedWithCustomError(governor, "AlreadyVoted");
    });

    it("prevents double-voting via token transfer", async function () {
      const { governor, token, proposer, voter1, voter2 } = await loadFixture(deployFixture);

      // Create proposal — snapshot taken at this block
      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");

      // voter1 votes
      await governor.connect(voter1).castVote(1, 1);

      // voter1 transfers all tokens to voter2 AFTER voting
      await token.connect(voter1).transfer(voter2.address, ethers.parseEther("30000"));

      // voter2 votes — but their voting power is from the snapshot block,
      // before the transfer, so they only have their original 20000
      await governor.connect(voter2).castVote(1, 1);

      const proposal = await governor.getProposal(1);
      // voter1 had 30000, voter2 had 20000 at snapshot — total 50000 (not 50000+30000)
      expect(proposal.forVotes).to.equal(ethers.parseEther("50000"));
    });

    it("reverts if no voting power", async function () {
      const { governor, proposer } = await loadFixture(deployFixture);
      const [, , , , , noTokens] = await ethers.getSigners();

      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");

      await expect(
        governor.connect(noTokens).castVote(1, 1)
      ).to.be.revertedWithCustomError(governor, "NoVotingPower");
    });

    it("reverts if voting period ended", async function () {
      const { governor, proposer, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");
      await time.increase(VOTING_PERIOD + 1);

      await expect(
        governor.connect(voter1).castVote(1, 1)
      ).to.be.revertedWithCustomError(governor, "NotActive");
    });

    it("handles abstain votes", async function () {
      const { governor, proposer, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");
      await governor.connect(voter1).castVote(1, 2); // abstain

      const proposal = await governor.getProposal(1);
      expect(proposal.abstainVotes).to.equal(ethers.parseEther("30000"));
      expect(proposal.forVotes).to.equal(0);
      expect(proposal.againstVotes).to.equal(0);
    });
  });

  describe("Quorum check", function () {
    it("proposal is defeated without quorum", async function () {
      const { governor, proposer, voter3 } = await loadFixture(deployFixture);

      // voter3 has 10000 tokens = 1% of supply, below 4% quorum
      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");
      await governor.connect(voter3).castVote(1, 1);
      await time.increase(VOTING_PERIOD + 1);

      const state = await governor.state(1);
      expect(state).to.equal(2); // Defeated
    });

    it("proposal succeeds with quorum met", async function () {
      const { governor, proposer, admin, voter1 } = await loadFixture(deployFixture);

      // admin(840k) + voter1(30k) = enough for quorum
      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");
      await governor.connect(admin).castVote(1, 1);
      await governor.connect(voter1).castVote(1, 1);
      await time.increase(VOTING_PERIOD + 1);

      const state = await governor.state(1);
      expect(state).to.equal(4); // Queued (succeeded, in timelock)
    });

    it("uses snapshot total supply for quorum (not live)", async function () {
      const { governor, token, proposer, admin, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");

      // Snapshot total supply is 1M. Quorum = 4% = 40k.
      // snapshotTotalSupply is stored at proposal creation
      const proposal = await governor.getProposal(1);
      expect(proposal.snapshotTotalSupply).to.equal(SUPPLY);

      await governor.connect(admin).castVote(1, 1);
      await governor.connect(voter1).castVote(1, 1);

      expect(await governor.quorumReached(1)).to.be.true;
    });
  });

  describe("Timelock enforcement", function () {
    it("cannot execute during timelock period", async function () {
      const { governor, proposer, admin, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");
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

      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");
      await governor.connect(admin).castVote(1, 1);
      await governor.connect(voter1).castVote(1, 1);
      await time.increase(VOTING_PERIOD + TIMELOCK + 1);

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

  describe("Execution deadline", function () {
    it("proposal expires after execution deadline", async function () {
      const { governor, proposer, admin, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");
      await governor.connect(admin).castVote(1, 1);
      await governor.connect(voter1).castVote(1, 1);

      // Fast forward past execution deadline (votingPeriod + timelock + 14 days + 1)
      await time.increase(VOTING_PERIOD + TIMELOCK + 14 * 86400 + 1);

      const state = await governor.state(1);
      expect(state).to.equal(7); // Expired

      await expect(
        governor.execute(1)
      ).to.be.revertedWithCustomError(governor, "NotSucceeded");
    });
  });

  describe("External execution", function () {
    it("executes callData on target contract", async function () {
      const { governor, proposer, admin, voter1 } = await loadFixture(deployFixture);

      // Use governor's own transferAdmin as a simple target to test execution
      const governorAddr = await governor.getAddress();
      const newAdmin = voter1.address;
      const callData = governor.interface.encodeFunctionData("transferAdmin", [newAdmin]);

      await governor.connect(proposer).propose("Transfer Admin", "Desc", 0, governorAddr, callData);
      await governor.connect(admin).castVote(1, 1);
      await governor.connect(voter1).castVote(1, 1);
      await time.increase(VOTING_PERIOD + TIMELOCK + 1);

      await governor.execute(1);

      expect(await governor.admin()).to.equal(newAdmin);
    });

    it("reverts if target call fails", async function () {
      const { governor, proposer, admin, voter1 } = await loadFixture(deployFixture);

      // Call transferAdmin with zero address — should revert
      const governorAddr = await governor.getAddress();
      const callData = governor.interface.encodeFunctionData("transferAdmin", [ethers.ZeroAddress]);

      await governor.connect(proposer).propose("Bad Transfer", "Desc", 0, governorAddr, callData);
      await governor.connect(admin).castVote(1, 1);
      await governor.connect(voter1).castVote(1, 1);
      await time.increase(VOTING_PERIOD + TIMELOCK + 1);

      await expect(
        governor.execute(1)
      ).to.be.revertedWithCustomError(governor, "ExecutionFailed");
    });
  });

  describe("cancel()", function () {
    it("proposer can cancel", async function () {
      const { governor, proposer } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");
      await governor.connect(proposer).cancel(1);

      const state = await governor.state(1);
      expect(state).to.equal(6); // Cancelled
    });

    it("admin can cancel", async function () {
      const { governor, proposer, admin } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");
      await governor.connect(admin).cancel(1);

      const state = await governor.state(1);
      expect(state).to.equal(6); // Cancelled
    });

    it("others cannot cancel", async function () {
      const { governor, proposer, voter1 } = await loadFixture(deployFixture);

      await governor.connect(proposer).propose("Test", "Desc", 0, ethers.ZeroAddress, "0x");

      await expect(
        governor.connect(voter1).cancel(1)
      ).to.be.revertedWithCustomError(governor, "NotProposerOrAdmin");
    });
  });

  describe("transferAdmin()", function () {
    it("admin can transfer admin role", async function () {
      const { governor, admin, voter1 } = await loadFixture(deployFixture);

      await expect(governor.connect(admin).transferAdmin(voter1.address))
        .to.emit(governor, "AdminTransferred")
        .withArgs(admin.address, voter1.address);

      expect(await governor.admin()).to.equal(voter1.address);
    });

    it("non-admin cannot transfer", async function () {
      const { governor, voter1 } = await loadFixture(deployFixture);

      await expect(
        governor.connect(voter1).transferAdmin(voter1.address)
      ).to.be.revertedWithCustomError(governor, "NotAdmin");
    });

    it("cannot transfer to zero address", async function () {
      const { governor, admin } = await loadFixture(deployFixture);

      await expect(
        governor.connect(admin).transferAdmin(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(governor, "ZeroAddress");
    });
  });
});
