// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./TaskRegistry.sol";
import "./MinerRegistry.sol";

/**
 * @title ResultVerifier
 * @notice Challenge-response verification for inference results.
 *         Anyone can challenge a completed task within the challenge window.
 *         Validators vote on challenges; if upheld, the miner is slashed.
 */
contract ResultVerifier is Ownable {
    enum ChallengeStatus { Open, Upheld, Rejected, Expired }

    struct Challenge {
        bytes32 taskId;
        address challenger;
        string reason;
        ChallengeStatus status;
        uint256 createdAt;
        uint256 votesFor;     // votes to uphold (miner was wrong)
        uint256 votesAgainst; // votes to reject (miner was right)
    }

    TaskRegistry public immutable taskRegistry;
    MinerRegistry public immutable minerRegistry;

    uint256 public challengeWindow = 600; // 10 minutes after completion
    uint256 public slashAmount;
    uint256 public minChallengeStake;
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
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event ChallengeWindowUpdated(uint256 newWindow);
    event SlashAmountUpdated(uint256 newAmount);

    error TaskNotCompleted(bytes32 taskId);
    error ChallengeWindowClosed(bytes32 taskId);
    error AlreadyChallenged(bytes32 taskId);
    error ChallengeNotFound(uint256 challengeId);
    error ChallengeNotOpen(uint256 challengeId);
    error NotValidator(address addr);
    error AlreadyVoted(uint256 challengeId, address validator);
    error InsufficientStake(uint256 required, uint256 provided);

    constructor(
        address _taskRegistry,
        address _minerRegistry,
        uint256 _slashAmount,
        uint256 _minChallengeStake
    ) Ownable(msg.sender) {
        taskRegistry = TaskRegistry(_taskRegistry);
        minerRegistry = MinerRegistry(_minerRegistry);
        slashAmount = _slashAmount;
        minChallengeStake = _minChallengeStake;
    }

    /// @notice Challenge a completed task's result
    /// @param taskId The completed task to challenge
    /// @param reason Description of why the result is wrong
    function challenge(bytes32 taskId, string calldata reason) external payable returns (uint256 challengeId) {
        if (msg.value < minChallengeStake) revert InsufficientStake(minChallengeStake, msg.value);

        TaskRegistry.Task memory task = taskRegistry.getTask(taskId);
        if (task.status != TaskRegistry.TaskStatus.Completed) revert TaskNotCompleted(taskId);
        if (block.timestamp > task.completedAt + challengeWindow) revert ChallengeWindowClosed(taskId);
        if (taskChallenge[taskId] != 0) revert AlreadyChallenged(taskId);

        challengeId = ++nextChallengeId; // start from 1
        _challenges[challengeId] = Challenge({
            taskId: taskId,
            challenger: msg.sender,
            reason: reason,
            status: ChallengeStatus.Open,
            createdAt: block.timestamp,
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

    /// @notice Resolve a challenge after voting (owner/automated)
    /// @param challengeId The challenge to resolve
    function resolve(uint256 challengeId) external onlyOwner {
        Challenge storage c = _challenges[challengeId];
        if (c.createdAt == 0) revert ChallengeNotFound(challengeId);
        if (c.status != ChallengeStatus.Open) revert ChallengeNotOpen(challengeId);

        TaskRegistry.Task memory task = taskRegistry.getTask(c.taskId);

        if (c.votesFor > c.votesAgainst) {
            // Challenge upheld — slash miner, refund challenger
            c.status = ChallengeStatus.Upheld;
            minerRegistry.slash(task.miner, slashAmount);

            // Refund challenger stake
            (bool ok, ) = c.challenger.call{value: minChallengeStake}("");
            if (!ok) { /* challenger can't receive, stake stays in contract */ }
        } else {
            // Challenge rejected — challenger loses stake
            c.status = ChallengeStatus.Rejected;
        }

        emit ChallengeResolved(challengeId, c.status);
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

    function setSlashAmount(uint256 newAmount) external onlyOwner {
        slashAmount = newAmount;
        emit SlashAmountUpdated(newAmount);
    }
}
