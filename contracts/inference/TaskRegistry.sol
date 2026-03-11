// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ModelRegistry.sol";
import "./MinerRegistry.sol";
import "./FeeEscrow.sol";

/**
 * @title TaskRegistry
 * @notice Core contract for the QFC AI Inference Marketplace.
 * @dev Manages the lifecycle of inference tasks: submit → assign → complete/fail/cancel.
 *      Coordinates with ModelRegistry, MinerRegistry, and FeeEscrow.
 */
contract TaskRegistry is Ownable, ReentrancyGuard {
    enum TaskStatus { Pending, Assigned, Completed, Failed, Cancelled }

    struct Task {
        bytes32 modelId;
        bytes32 inputHash;
        bytes32 resultHash;
        bytes32 proof;
        address submitter;
        address miner;
        uint256 maxFee;
        TaskStatus status;
        uint256 createdAt;
    }

    /// @notice Task ID => Task info
    mapping(bytes32 => Task) public tasks;

    /// @notice List of open (Pending) task IDs
    bytes32[] private _openTasks;

    /// @notice Index tracking for open tasks removal
    mapping(bytes32 => uint256) private _openTaskIndex;

    /// @notice Total tasks created (used for ID generation)
    uint256 public taskCount;

    /// @notice Router address authorized to assign tasks
    address public router;

    ModelRegistry public modelRegistry;
    MinerRegistry public minerRegistry;
    FeeEscrow public feeEscrow;

    event TaskSubmitted(bytes32 indexed taskId, bytes32 indexed modelId, address indexed submitter, uint256 fee);
    event TaskAssigned(bytes32 indexed taskId, address indexed miner);
    event TaskCompleted(bytes32 indexed taskId, bytes32 resultHash, bytes32 proof);
    event TaskFailed(bytes32 indexed taskId);
    event TaskCancelled(bytes32 indexed taskId);
    event RouterSet(address indexed router);

    error TaskNotFound(bytes32 taskId);
    error InvalidStatus(bytes32 taskId, TaskStatus expected, TaskStatus actual);
    error OnlyRouter();
    error OnlySubmitter();
    error OnlyAssignedMiner();
    error InsufficientFee(uint256 required, uint256 provided);
    error ModelNotActive(bytes32 modelId);
    error MinerNotEligible(address miner);

    modifier onlyRouter() {
        if (msg.sender != router) revert OnlyRouter();
        _;
    }

    constructor(
        address _modelRegistry,
        address _minerRegistry,
        address _feeEscrow
    ) Ownable(msg.sender) {
        modelRegistry = ModelRegistry(_modelRegistry);
        minerRegistry = MinerRegistry(_minerRegistry);
        feeEscrow = FeeEscrow(_feeEscrow);
    }

    /**
     * @notice Set the router address authorized to assign tasks.
     * @param _router Address of the router.
     */
    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Zero address");
        router = _router;
        emit RouterSet(_router);
    }

    /**
     * @notice Submit a new inference task.
     * @param modelId The model to run inference on.
     * @param inputHash Hash of the off-chain input data.
     * @param maxFee Maximum fee the submitter is willing to pay.
     * @return taskId The generated task ID.
     */
    function submitTask(
        bytes32 modelId,
        bytes32 inputHash,
        uint256 maxFee
    ) external payable nonReentrant returns (bytes32 taskId) {
        // Validate model exists and is active
        ModelRegistry.Model memory model = modelRegistry.getModel(modelId);
        if (!model.active) revert ModelNotActive(modelId);

        // Validate fee
        if (msg.value < model.baseFee) revert InsufficientFee(model.baseFee, msg.value);

        // Generate task ID
        taskId = keccak256(abi.encodePacked(block.chainid, address(this), taskCount));
        taskCount++;

        // Store task
        tasks[taskId] = Task({
            modelId: modelId,
            inputHash: inputHash,
            resultHash: bytes32(0),
            proof: bytes32(0),
            submitter: msg.sender,
            miner: address(0),
            maxFee: maxFee,
            status: TaskStatus.Pending,
            createdAt: block.timestamp
        });

        // Add to open tasks
        _openTaskIndex[taskId] = _openTasks.length;
        _openTasks.push(taskId);

        // Lock fee in escrow
        feeEscrow.lockFee{value: msg.value}(taskId, msg.sender);

        emit TaskSubmitted(taskId, modelId, msg.sender, msg.value);
    }

    /**
     * @notice Assign a pending task to a miner. Router only.
     * @param taskId The task to assign.
     * @param miner The miner to assign the task to.
     */
    function assignTask(bytes32 taskId, address miner) external onlyRouter {
        Task storage task = tasks[taskId];
        if (task.submitter == address(0)) revert TaskNotFound(taskId);
        if (task.status != TaskStatus.Pending) {
            revert InvalidStatus(taskId, TaskStatus.Pending, task.status);
        }

        // Verify miner is registered and eligible
        MinerRegistry.Miner memory m = minerRegistry.getMiner(miner);
        ModelRegistry.Model memory model = modelRegistry.getModel(task.modelId);
        if (m.tier < model.minTier) revert MinerNotEligible(miner);

        task.status = TaskStatus.Assigned;
        task.miner = miner;

        _removeFromOpenTasks(taskId);

        emit TaskAssigned(taskId, miner);
    }

    /**
     * @notice Submit inference result. Only the assigned miner.
     * @param taskId The task to complete.
     * @param resultHash Hash of the off-chain result data.
     * @param proof Proof of computation.
     */
    function submitResult(
        bytes32 taskId,
        bytes32 resultHash,
        bytes32 proof
    ) external nonReentrant {
        Task storage task = tasks[taskId];
        if (task.submitter == address(0)) revert TaskNotFound(taskId);
        if (task.status != TaskStatus.Assigned) {
            revert InvalidStatus(taskId, TaskStatus.Assigned, task.status);
        }
        if (task.miner != msg.sender) revert OnlyAssignedMiner();

        task.status = TaskStatus.Completed;
        task.resultHash = resultHash;
        task.proof = proof;

        // Release fee to miner
        feeEscrow.releaseFee(taskId, msg.sender);

        // Record completion in miner stats
        minerRegistry.recordCompletion(msg.sender);

        emit TaskCompleted(taskId, resultHash, proof);
    }

    /**
     * @notice Cancel a pending task. Only the submitter.
     * @param taskId The task to cancel.
     */
    function cancelTask(bytes32 taskId) external nonReentrant {
        Task storage task = tasks[taskId];
        if (task.submitter == address(0)) revert TaskNotFound(taskId);
        if (task.submitter != msg.sender) revert OnlySubmitter();
        if (task.status != TaskStatus.Pending) {
            revert InvalidStatus(taskId, TaskStatus.Pending, task.status);
        }

        task.status = TaskStatus.Cancelled;

        _removeFromOpenTasks(taskId);

        // Refund fee
        feeEscrow.refundFee(taskId);

        emit TaskCancelled(taskId);
    }

    /**
     * @notice Get all open (Pending) task IDs.
     * @return taskIds Array of pending task IDs.
     */
    function getOpenTasks() external view returns (bytes32[] memory taskIds) {
        return _openTasks;
    }

    /**
     * @dev Remove a task from the open tasks array using swap-and-pop.
     */
    function _removeFromOpenTasks(bytes32 taskId) internal {
        uint256 index = _openTaskIndex[taskId];
        uint256 lastIndex = _openTasks.length - 1;

        if (index != lastIndex) {
            bytes32 lastTaskId = _openTasks[lastIndex];
            _openTasks[index] = lastTaskId;
            _openTaskIndex[lastTaskId] = index;
        }

        _openTasks.pop();
        delete _openTaskIndex[taskId];
    }
}
