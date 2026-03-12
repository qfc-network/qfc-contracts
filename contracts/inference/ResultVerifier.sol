// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./TaskRegistry.sol";
import "./MinerRegistry.sol";

/**
 * @title ResultVerifier
 * @notice Challenge-response verification for inference results.
 *         Anyone can challenge a completed task within the challenge window.
 *         Validators vote on challenges; if upheld, the miner is slashed.
 *
 * Flow:
 *   1. Miner submits result + hash proof via TaskRegistry
 *   2. 10-min challenge window — any miner can dispute
 *   3. Validators vote on the challenge
 *   4. Owner resolves: upheld → miner slashed (10% reputation),
 *      challenger refunded; rejected → challenger loses stake
 */
contract ResultVerifier is Ownable, ReentrancyGuard {
    enum ChallengeStatus { Open, Upheld, Rejected, Expired }

    struct Challenge {
        bytes32 taskId;
        address challenger;
        bytes32 challengerResultHash;
        string reason;
        ChallengeStatus status;
        uint256 createdAt;
        uint256 stake;
        uint256 votesFor;     // votes to uphold (miner was wrong)
        uint256 votesAgainst; // votes to reject (miner was right)
    }

    TaskRegistry public immutable taskRegistry;
    MinerRegistry public immutable minerRegistry;

    /// @notice Challenge window in seconds after task completion (default 10 min)
    uint256 public challengeWindow = 600;

    /// @notice Reputation slash penalty in basis points (default 1000 = 10%)
    uint256 public slashPenaltyBps = 1000;

    /// @notice Minimum stake required to file a challenge
    uint256 public minChallengeStake;

    /// @notice Protocol's share of forfeited challenger stakes (basis points, default 5000 = 50%)
    uint256 public protocolShareBps = 5000;

    /// @notice Accumulated protocol revenue from forfeited stakes
    uint256 public protocolFees;

    uint256 public nextChallengeId;

    mapping(uint256 => Challenge) private _challenges;
    /// @dev taskId => challengeId (one challenge per task)
    mapping(bytes32 => uint256) public taskChallenge;
    /// @dev challengeId => validator => voted
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    /// @dev validator address => authorized
    mapping(address => bool) public validators;

    event ChallengeCreated(uint256 indexed challengeId, bytes32 indexed taskId, address indexed challenger);
    event VoteCast(uint256 indexed challengeId, address indexed validator, bool uphold);
    event ChallengeResolved(uint256 indexed challengeId, ChallengeStatus status);
    event ChallengeExpired(uint256 indexed challengeId);
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event ChallengeWindowUpdated(uint256 newWindow);
    event SlashPenaltyUpdated(uint256 newPenaltyBps);
    event ProtocolFeesClaimed(address indexed to, uint256 amount);

    error TaskNotCompleted(bytes32 taskId);
    error ChallengeWindowClosed(bytes32 taskId);
    error AlreadyChallenged(bytes32 taskId);
    error ChallengeNotFound(uint256 challengeId);
    error ChallengeNotOpen(uint256 challengeId);
    error NotValidator(address addr);
    error AlreadyVoted(uint256 challengeId, address validator);
    error InsufficientStake(uint256 required, uint256 provided);
    error NoProtocolFees();
    error TransferFailed();

    constructor(
        address _taskRegistry,
        address _minerRegistry,
        uint256 _minChallengeStake
    ) Ownable(msg.sender) {
        taskRegistry = TaskRegistry(_taskRegistry);
        minerRegistry = MinerRegistry(_minerRegistry);
        minChallengeStake = _minChallengeStake;
    }

    /// @notice Challenge a completed task's result
    /// @param taskId The completed task to challenge
    /// @param challengerResultHash Hash of the challenger's re-computed result
    /// @param reason Description of why the result is wrong
    function challengeResult(
        bytes32 taskId,
        bytes32 challengerResultHash,
        string calldata reason
    ) external payable returns (uint256 challengeId) {
        if (msg.value < minChallengeStake) revert InsufficientStake(minChallengeStake, msg.value);

        TaskRegistry.Task memory task = taskRegistry.getTask(taskId);
        if (task.status != TaskRegistry.TaskStatus.Completed) revert TaskNotCompleted(taskId);
        if (block.timestamp > task.completedAt + challengeWindow) revert ChallengeWindowClosed(taskId);
        if (taskChallenge[taskId] != 0) revert AlreadyChallenged(taskId);

        challengeId = ++nextChallengeId; // start from 1
        _challenges[challengeId] = Challenge({
            taskId: taskId,
            challenger: msg.sender,
            challengerResultHash: challengerResultHash,
            reason: reason,
            status: ChallengeStatus.Open,
            createdAt: block.timestamp,
            stake: msg.value,
            votesFor: 0,
            votesAgainst: 0
        });
        taskChallenge[taskId] = challengeId;

        emit ChallengeCreated(challengeId, taskId, msg.sender);
    }

    /// @notice Validator votes on a challenge
    /// @param challengeId The challenge ID
    /// @param uphold True = miner was wrong, False = miner was right
    function vote(uint256 challengeId, bool uphold) external {
        if (!validators[msg.sender]) revert NotValidator(msg.sender);
        Challenge storage c = _challenges[challengeId];
        if (c.createdAt == 0) revert ChallengeNotFound(challengeId);
        if (c.status != ChallengeStatus.Open) revert ChallengeNotOpen(challengeId);
        if (hasVoted[challengeId][msg.sender]) revert AlreadyVoted(challengeId, msg.sender);

        hasVoted[challengeId][msg.sender] = true;
        if (uphold) {
            c.votesFor++;
        } else {
            c.votesAgainst++;
        }

        emit VoteCast(challengeId, msg.sender, uphold);
    }

    /// @notice Resolve a challenge after voting
    /// @param challengeId The challenge to resolve
    function resolveChallenge(uint256 challengeId) external onlyOwner nonReentrant {
        Challenge storage c = _challenges[challengeId];
        if (c.createdAt == 0) revert ChallengeNotFound(challengeId);
        if (c.status != ChallengeStatus.Open) revert ChallengeNotOpen(challengeId);

        TaskRegistry.Task memory task = taskRegistry.getTask(c.taskId);

        if (c.votesFor > c.votesAgainst) {
            // Challenge upheld — slash miner, refund challenger
            c.status = ChallengeStatus.Upheld;

            // Slash miner reputation (10% default)
            minerRegistry.slash(task.miner, slashPenaltyBps);

            // Refund challenger stake
            (bool ok, ) = c.challenger.call{value: c.stake}("");
            if (!ok) revert TransferFailed();
        } else {
            // Challenge rejected — challenger loses stake
            c.status = ChallengeStatus.Rejected;

            // Split forfeited stake: 50% protocol, 50% to contract (can be extended for miner reward)
            uint256 protocolAmount = (c.stake * protocolShareBps) / 10000;
            protocolFees += protocolAmount;
            // Remaining stake stays in contract
        }

        emit ChallengeResolved(challengeId, c.status);
    }

    /// @notice Expire an unchallenged or unresolved challenge after the window
    /// @param challengeId The challenge to expire
    function expireChallenge(uint256 challengeId) external {
        Challenge storage c = _challenges[challengeId];
        if (c.createdAt == 0) revert ChallengeNotFound(challengeId);
        if (c.status != ChallengeStatus.Open) revert ChallengeNotOpen(challengeId);

        // Can only expire after challenge window has passed since creation
        require(block.timestamp > c.createdAt + challengeWindow, "Challenge window not expired");

        c.status = ChallengeStatus.Expired;

        // Refund challenger stake on expiry (no votes = inconclusive)
        (bool ok, ) = c.challenger.call{value: c.stake}("");
        if (!ok) revert TransferFailed();

        emit ChallengeExpired(challengeId);
    }

    /// @notice Get challenge details
    function getChallenge(uint256 challengeId) external view returns (Challenge memory) {
        if (_challenges[challengeId].createdAt == 0) revert ChallengeNotFound(challengeId);
        return _challenges[challengeId];
    }

    // --- Admin ---

    function addValidator(address validator) external onlyOwner {
        validators[validator] = true;
        emit ValidatorAdded(validator);
    }

    function removeValidator(address validator) external onlyOwner {
        validators[validator] = false;
        emit ValidatorRemoved(validator);
    }

    function setChallengeWindow(uint256 newWindow) external onlyOwner {
        challengeWindow = newWindow;
        emit ChallengeWindowUpdated(newWindow);
    }

    function setSlashPenalty(uint256 newPenaltyBps) external onlyOwner {
        require(newPenaltyBps <= 10000, "Exceeds 100%");
        slashPenaltyBps = newPenaltyBps;
        emit SlashPenaltyUpdated(newPenaltyBps);
    }

    function claimProtocolFees() external onlyOwner nonReentrant {
        if (protocolFees == 0) revert NoProtocolFees();
        uint256 amount = protocolFees;
        protocolFees = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ProtocolFeesClaimed(msg.sender, amount);
    }
}
