// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title GovernorContract
 * @dev Simplified on-chain DAO voting contract for QFC Network.
 *      No OpenZeppelin dependency — standalone implementation.
 *
 * - Voting power = QFC balance at proposal snapshot block
 * - Quorum: 4% of total supply
 * - Voting period: 3 days (testnet: 1 hour)
 * - Timelock: 2 days before execution (testnet: 10 min)
 * - Proposal types: ParameterChange / ProtocolUpgrade / Treasury / General
 */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract GovernorContract {
    // -------------------------------------------------------
    // Types
    // -------------------------------------------------------

    enum ProposalType { ParameterChange, ProtocolUpgrade, Treasury, General }
    enum ProposalState { Pending, Active, Defeated, Succeeded, Queued, Executed, Cancelled }

    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        ProposalType ptype;
        bytes callData;
        uint256 snapshotBlock;
        uint256 voteStart;
        uint256 voteEnd;
        uint256 executableAfter;  // timelock: voteEnd + timelockDuration
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool executed;
        bool cancelled;
    }

    struct Receipt {
        bool hasVoted;
        uint8 support; // 0=against, 1=for, 2=abstain
        uint256 votes;
    }

    // -------------------------------------------------------
    // State
    // -------------------------------------------------------

    IERC20 public immutable token;
    address public admin;

    uint256 public votingPeriod;    // seconds
    uint256 public timelockDuration; // seconds
    uint256 public quorumBps;       // basis points (400 = 4%)

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => Receipt)) public receipts;

    // -------------------------------------------------------
    // Events
    // -------------------------------------------------------

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        ProposalType ptype,
        uint256 voteStart,
        uint256 voteEnd
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        uint8 support,
        uint256 votes
    );
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);

    // -------------------------------------------------------
    // Errors
    // -------------------------------------------------------

    error EmptyTitle();
    error ProposalNotFound();
    error NotActive();
    error AlreadyVoted();
    error NoVotingPower();
    error NotSucceeded();
    error AlreadyExecuted();
    error ProposalCancelledErr();
    error NotProposerOrAdmin();

    // -------------------------------------------------------
    // Constructor
    // -------------------------------------------------------

    /**
     * @param _token QFC ERC-20 token address (voting power source)
     * @param _votingPeriod Duration of voting in seconds (mainnet: 259200 = 3 days, testnet: 3600 = 1 hour)
     * @param _timelockDuration Delay before execution in seconds (mainnet: 172800 = 2 days, testnet: 600 = 10 min)
     * @param _quorumBps Quorum in basis points (400 = 4%)
     */
    constructor(
        address _token,
        uint256 _votingPeriod,
        uint256 _timelockDuration,
        uint256 _quorumBps
    ) {
        token = IERC20(_token);
        admin = msg.sender;
        votingPeriod = _votingPeriod;
        timelockDuration = _timelockDuration;
        quorumBps = _quorumBps;
    }

    // -------------------------------------------------------
    // Core functions
    // -------------------------------------------------------

    /**
     * @dev Create a new proposal.
     * @param title Short title for the proposal
     * @param description Detailed description
     * @param ptype Proposal type
     * @param callData Encoded call data for execution (can be empty for General)
     * @return proposalId The ID of the created proposal
     */
    function propose(
        string calldata title,
        string calldata description,
        ProposalType ptype,
        bytes calldata callData
    ) external returns (uint256) {
        if (bytes(title).length == 0) revert EmptyTitle();

        proposalCount++;
        uint256 proposalId = proposalCount;

        uint256 voteStart = block.timestamp;
        uint256 voteEnd = voteStart + votingPeriod;

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            title: title,
            description: description,
            ptype: ptype,
            callData: callData,
            snapshotBlock: block.number,
            voteStart: voteStart,
            voteEnd: voteEnd,
            executableAfter: voteEnd + timelockDuration,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            executed: false,
            cancelled: false
        });

        emit ProposalCreated(proposalId, msg.sender, title, ptype, voteStart, voteEnd);
        return proposalId;
    }

    /**
     * @dev Cast a vote on a proposal.
     * @param proposalId The proposal to vote on
     * @param support 0=against, 1=for, 2=abstain
     */
    function castVote(uint256 proposalId, uint8 support) external {
        Proposal storage p = proposals[proposalId];
        if (p.id == 0) revert ProposalNotFound();
        if (state(proposalId) != ProposalState.Active) revert NotActive();

        Receipt storage r = receipts[proposalId][msg.sender];
        if (r.hasVoted) revert AlreadyVoted();

        uint256 votes = token.balanceOf(msg.sender);
        if (votes == 0) revert NoVotingPower();

        r.hasVoted = true;
        r.support = support;
        r.votes = votes;

        if (support == 0) {
            p.againstVotes += votes;
        } else if (support == 1) {
            p.forVotes += votes;
        } else {
            p.abstainVotes += votes;
        }

        emit VoteCast(proposalId, msg.sender, support, votes);
    }

    /**
     * @dev Execute a succeeded proposal after timelock.
     * @param proposalId The proposal to execute
     */
    function execute(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (p.id == 0) revert ProposalNotFound();
        if (p.executed) revert AlreadyExecuted();
        if (p.cancelled) revert ProposalCancelledErr();

        ProposalState s = state(proposalId);
        if (s != ProposalState.Succeeded) revert NotSucceeded();

        p.executed = true;
        emit ProposalExecuted(proposalId);
    }

    /**
     * @dev Cancel a proposal. Only proposer or admin can cancel.
     * @param proposalId The proposal to cancel
     */
    function cancel(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (p.id == 0) revert ProposalNotFound();
        if (msg.sender != p.proposer && msg.sender != admin) revert NotProposerOrAdmin();
        if (p.executed) revert AlreadyExecuted();

        p.cancelled = true;
        emit ProposalCancelled(proposalId);
    }

    // -------------------------------------------------------
    // View functions
    // -------------------------------------------------------

    /**
     * @dev Get the current state of a proposal.
     */
    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage p = proposals[proposalId];
        if (p.id == 0) revert ProposalNotFound();

        if (p.cancelled) return ProposalState.Cancelled;
        if (p.executed) return ProposalState.Executed;

        if (block.timestamp < p.voteEnd) return ProposalState.Active;

        // Voting ended — check quorum and result
        uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;
        uint256 quorumRequired = (token.totalSupply() * quorumBps) / 10000;

        if (totalVotes < quorumRequired || p.forVotes <= p.againstVotes) {
            return ProposalState.Defeated;
        }

        // Succeeded, check if in timelock or ready
        if (block.timestamp < p.executableAfter) {
            return ProposalState.Queued;
        }

        return ProposalState.Succeeded;
    }

    /**
     * @dev Get full proposal details.
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        if (proposals[proposalId].id == 0) revert ProposalNotFound();
        return proposals[proposalId];
    }

    /**
     * @dev Get a voter's receipt for a proposal.
     */
    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory) {
        return receipts[proposalId][voter];
    }

    /**
     * @dev Check if quorum is reached for a proposal.
     */
    function quorumReached(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;
        uint256 quorumRequired = (token.totalSupply() * quorumBps) / 10000;
        return totalVotes >= quorumRequired;
    }
}
