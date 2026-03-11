// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ModelRegistry.sol";
import "./MinerRegistry.sol";
import "./FeeEscrow.sol";

/**
 * @title TaskRegistry
 * @notice On-chain AI inference task submission and lifecycle management.
 *         Tasks flow: Pending → Claimed → Completed | Failed | Cancelled.
 */
contract TaskRegistry is Ownable, ReentrancyGuard {
    enum TaskStatus { Pending, Claimed, Completed, Failed, Cancelled }

    struct Task {
        uint256 id;
        address submitter;
        string modelId;
        bytes input;           // serialized inference input
        uint256 maxFee;        // max QFC willing to pay (wei)
        TaskStatus status;
        address miner;
        bytes result;          // serialized inference output
        uint256 createdAt;
        uint256 claimedAt;
        uint256 completedAt;
    }

    ModelRegistry public immutable modelRegistry;
    MinerRegistry public immutable minerRegistry;
    FeeEscrow public immutable feeEscrow;

    uint256 public nextTaskId;
    uint256 public claimTimeout = 600; // 10 minutes to submit result

    mapping(uint256 => Task) private _tasks;

    event TaskSubmitted(uint256 indexed taskId, address indexed submitter, string modelId, uint256 maxFee);
    event TaskClaimed(uint256 indexed taskId, address indexed miner);
    event TaskCompleted(uint256 indexed taskId, address indexed miner, bytes result);
    event TaskFailed(uint256 indexed taskId, address indexed miner, string reason);
    event TaskCancelled(uint256 indexed taskId);
    event ClaimTimeoutUpdated(uint256 newTimeout);

    error ModelNotApproved(string modelId);
    error FeeBelowMinimum(uint256 required, uint256 provided);
    error TaskNotFound(uint256 taskId);
    error TaskNotPending(uint256 taskId);
    error TaskNotClaimed(uint256 taskId);
    error MinerNotEligible(address miner);
    error NotTaskMiner(uint256 taskId);
    error ClaimExpired(uint256 taskId);
    error OnlySubmitter(uint256 taskId);

    constructor(
        address _modelRegistry,
        address _minerRegistry,
        address _feeEscrow
    ) Ownable(msg.sender) {
        modelRegistry = ModelRegistry(_modelRegistry);
        minerRegistry = MinerRegistry(_minerRegistry);
        feeEscrow = FeeEscrow(_feeEscrow);
    }

    /// @notice Submit an inference task with fee
    /// @param modelId The model to use
    /// @param input Serialized inference input
    function submitTask(
        string calldata modelId,
        bytes calldata input
    ) external payable nonReentrant returns (uint256 taskId) {
        if (!modelRegistry.isApproved(modelId)) revert ModelNotApproved(modelId);
        uint256 baseFee = modelRegistry.getBaseFee(modelId);
        if (msg.value < baseFee) revert FeeBelowMinimum(baseFee, msg.value);

        taskId = nextTaskId++;
        _tasks[taskId] = Task({
            id: taskId,
            submitter: msg.sender,
            modelId: modelId,
            input: input,
            maxFee: msg.value,
            status: TaskStatus.Pending,
            miner: address(0),
            result: "",
            createdAt: block.timestamp,
            claimedAt: 0,
            completedAt: 0
        });

        // Lock fee in escrow
        feeEscrow.deposit{value: msg.value}(taskId, msg.sender);

        emit TaskSubmitted(taskId, msg.sender, modelId, msg.value);
    }

    /// @notice Miner claims a pending task
    /// @param taskId The task to claim
    function claimTask(uint256 taskId) external {
        Task storage t = _tasks[taskId];
        if (t.createdAt == 0) revert TaskNotFound(taskId);
        if (t.status != TaskStatus.Pending) revert TaskNotPending(taskId);

        uint8 minTier = modelRegistry.getMinTier(t.modelId);
        if (!minerRegistry.isEligible(msg.sender, minTier)) revert MinerNotEligible(msg.sender);

        t.status = TaskStatus.Claimed;
        t.miner = msg.sender;
        t.claimedAt = block.timestamp;

        emit TaskClaimed(taskId, msg.sender);
    }

    /// @notice Miner submits result for a claimed task
    /// @param taskId The task ID
    /// @param result Serialized inference output
    function completeTask(uint256 taskId, bytes calldata result) external nonReentrant {
        Task storage t = _tasks[taskId];
        if (t.createdAt == 0) revert TaskNotFound(taskId);
        if (t.status != TaskStatus.Claimed) revert TaskNotClaimed(taskId);
        if (t.miner != msg.sender) revert NotTaskMiner(taskId);
        if (block.timestamp > t.claimedAt + claimTimeout) revert ClaimExpired(taskId);

        t.status = TaskStatus.Completed;
        t.result = result;
        t.completedAt = block.timestamp;

        // Release payment to miner
        feeEscrow.release(taskId, msg.sender);
        minerRegistry.recordTaskCompleted(msg.sender);

        emit TaskCompleted(taskId, msg.sender, result);
    }

    /// @notice Mark a claimed task as failed (expired or miner error)
    /// @param taskId The task ID
    function failTask(uint256 taskId, string calldata reason) external onlyOwner {
        Task storage t = _tasks[taskId];
        if (t.createdAt == 0) revert TaskNotFound(taskId);
        if (t.status != TaskStatus.Claimed) revert TaskNotClaimed(taskId);

        t.status = TaskStatus.Failed;
        address miner = t.miner;

        // Refund submitter
        feeEscrow.refund(taskId);
        minerRegistry.recordTaskFailed(miner);

        emit TaskFailed(taskId, miner, reason);
    }

    /// @notice Submitter cancels a pending task
    /// @param taskId The task ID
    function cancelTask(uint256 taskId) external nonReentrant {
        Task storage t = _tasks[taskId];
        if (t.createdAt == 0) revert TaskNotFound(taskId);
        if (t.submitter != msg.sender) revert OnlySubmitter(taskId);
        if (t.status != TaskStatus.Pending) revert TaskNotPending(taskId);

        t.status = TaskStatus.Cancelled;
        feeEscrow.refund(taskId);

        emit TaskCancelled(taskId);
    }

    /// @notice Get task details
    function getTask(uint256 taskId) external view returns (Task memory) {
        if (_tasks[taskId].createdAt == 0) revert TaskNotFound(taskId);
        return _tasks[taskId];
    }

    /// @notice Update claim timeout
    function setClaimTimeout(uint256 newTimeout) external onlyOwner {
        claimTimeout = newTimeout;
        emit ClaimTimeoutUpdated(newTimeout);
    }
}
