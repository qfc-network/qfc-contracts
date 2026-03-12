// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title GovernorContract
 * @dev Simplified on-chain DAO voting contract for QFC Network.
 *      No OpenZeppelin dependency — standalone implementation.
 *
 * - Voting power = token.getPastVotes() at proposal snapshot block (ERC20Votes)
 * - Quorum: 4% of total supply at snapshot
 * - Voting period: 3 days (testnet: 1 hour)
 * - Timelock: 2 days before execution (testnet: 10 min)
 * - Execution deadline: 14 days after timelock (prevents stale execution)
 * - Proposal types: ParameterChange / ProtocolUpgrade / Treasury / General
 */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IVotes {
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);
}

contract GovernorContract {
    // -------------------------------------------------------
    // Types
    // -------------------------------------------------------

    enum ProposalType { ParameterChange, ProtocolUpgrade, Treasury, General }
    enum ProposalState { Pending, Active, Defeated, Succeeded, Queued, Executed, Cancelled, Expired }

    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        ProposalType ptype;
        address target;           // execution target contract
        bytes callData;
        uint256 snapshotBlock;
        uint256 snapshotTotalSupply;  // total supply at snapshot for quorum calc
        uint256 voteStart;
        uint256 voteEnd;
        uint256 executableAfter;  // timelock: voteEnd + timelockDuration
        uint256 executionDeadline; // must execute before this timestamp
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
    IVotes public immutable votes;
    address public admin;

    uint256 public votingPeriod;       // seconds
    uint256 public timelockDuration;   // seconds
    uint256 public executionWindow;    // seconds after timelock where execution is allowed
    uint256 public quorumBps;          // basis points (400 = 4%)

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
        address target,
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
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

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
    error NotAdmin();
    error ZeroAddress();
    error ExecutionFailed();

    // -------------------------------------------------------
    // Constructor
    // -------------------------------------------------------

    /**
     * @param _token QFC ERC-20 token address (must implement ERC20Votes: getPastVotes, getPastTotalSupply)
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
        votes = IVotes(_token);
        admin = msg.sender;
        votingPeriod = _votingPeriod;
        timelockDuration = _timelockDuration;
        executionWindow = 14 days;  // proposals expire 14 days after timelock
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
     * @param target Target contract address for execution (address(0) for General/no-op)
     * @param callData Encoded call data for execution (can be empty)
     * @return proposalId The ID of the created proposal
     */
    function propose(
        string calldata title,
        string calldata description,
        ProposalType ptype,
        address target,
        bytes calldata callData
    ) external returns (uint256) {
        if (bytes(title).length == 0) revert EmptyTitle();

        proposalCount++;
        uint256 proposalId = proposalCount;

        uint256 voteStart = block.timestamp;
        uint256 voteEnd = voteStart + votingPeriod;
        uint256 execAfter = voteEnd + timelockDuration;

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            title: title,
            description: description,
            ptype: ptype,
            target: target,
            callData: callData,
            snapshotBlock: block.number,
            snapshotTotalSupply: token.totalSupply(),
            voteStart: voteStart,
            voteEnd: voteEnd,
            executableAfter: execAfter,
            executionDeadline: execAfter + executionWindow,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            executed: false,
            cancelled: false
        });

        emit ProposalCreated(proposalId, msg.sender, title, ptype, target, voteStart, voteEnd);
        return proposalId;
    }

    /**
     * @dev Cast a vote on a proposal.
     *      Voting power is read from the token's getPastVotes() at the proposal's
     *      snapshot block, preventing double-voting via token transfers.
     * @param proposalId The proposal to vote on
     * @param support 0=against, 1=for, 2=abstain
     */
    function castVote(uint256 proposalId, uint8 support) external {
        Proposal storage p = proposals[proposalId];
        if (p.id == 0) revert ProposalNotFound();
        if (state(proposalId) != ProposalState.Active) revert NotActive();

        Receipt storage r = receipts[proposalId][msg.sender];
        if (r.hasVoted) revert AlreadyVoted();

        uint256 votePower = votes.getPastVotes(msg.sender, p.snapshotBlock);
        if (votePower == 0) revert NoVotingPower();

        r.hasVoted = true;
        r.support = support;
        r.votes = votePower;

        if (support == 0) {
            p.againstVotes += votePower;
        } else if (support == 1) {
            p.forVotes += votePower;
        } else {
            p.abstainVotes += votePower;
        }

        emit VoteCast(proposalId, msg.sender, support, votePower);
    }

    /**
     * @dev Execute a succeeded proposal after timelock but before deadline.
     *      If the proposal has a target and callData, calls target with callData.
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

        // Execute callData on target if provided
        if (p.target != address(0) && p.callData.length > 0) {
            (bool ok, ) = p.target.call(p.callData);
            if (!ok) revert ExecutionFailed();
        }

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
    // Admin
    // -------------------------------------------------------

    /**
     * @dev Transfer admin role to a new address.
     * @param newAdmin The new admin address
     */
    function transferAdmin(address newAdmin) external {
        if (msg.sender != admin && msg.sender != address(this)) revert NotAdmin();
        if (newAdmin == address(0)) revert ZeroAddress();
        address oldAdmin = admin;
        admin = newAdmin;
        emit AdminTransferred(oldAdmin, newAdmin);
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

        // Voting ended — check quorum and result using snapshot total supply
        uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;
        uint256 quorumRequired = (p.snapshotTotalSupply * quorumBps) / 10000;

        if (totalVotes < quorumRequired || p.forVotes <= p.againstVotes) {
            return ProposalState.Defeated;
        }

        // Succeeded — check timelock and deadline
        if (block.timestamp < p.executableAfter) {
            return ProposalState.Queued;
        }

        if (block.timestamp > p.executionDeadline) {
            return ProposalState.Expired;
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
     * @dev Check if quorum is reached for a proposal (uses snapshot total supply).
     */
    function quorumReached(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;
        uint256 quorumRequired = (p.snapshotTotalSupply * quorumBps) / 10000;
        return totalVotes >= quorumRequired;
    }
}
