// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FeeEscrow
 * @notice Escrow contract for inference task fees on the QFC Marketplace.
 * @dev Holds fees in escrow until a task is completed or cancelled.
 *      Charges a 5% protocol fee on successful completions.
 */
contract FeeEscrow is Ownable, ReentrancyGuard {
    struct Escrow {
        address submitter;
        uint256 amount;
        bool settled;
    }

    /// @notice Task ID => Escrow info
    mapping(bytes32 => Escrow) public escrows;

    /// @notice Accumulated protocol fees available for withdrawal
    uint256 public protocolFees;

    /// @notice Protocol fee in basis points (500 = 5%)
    uint256 public constant PROTOCOL_FEE_BPS = 500;

    /// @notice TaskRegistry address, authorized to lock/release/refund
    address public taskRegistry;

    event FeeLocked(bytes32 indexed taskId, address indexed submitter, uint256 amount);
    event FeeReleased(bytes32 indexed taskId, address indexed miner, uint256 minerAmount, uint256 protocolAmount);
    event FeeRefunded(bytes32 indexed taskId, address indexed submitter, uint256 amount);
    event ProtocolFeesClaimed(address indexed to, uint256 amount);
    event TaskRegistrySet(address indexed taskRegistry);

    error OnlyTaskRegistry();
    error EscrowAlreadyExists(bytes32 taskId);
    error EscrowNotFound(bytes32 taskId);
    error EscrowAlreadySettled(bytes32 taskId);
    error NoProtocolFees();
    error TransferFailed();

    modifier onlyTaskRegistry() {
        if (msg.sender != taskRegistry) revert OnlyTaskRegistry();
        _;
    }

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Set the TaskRegistry address. Only owner.
     * @param _taskRegistry Address of the TaskRegistry contract.
     */
    function setTaskRegistry(address _taskRegistry) external onlyOwner {
        require(_taskRegistry != address(0), "Zero address");
        taskRegistry = _taskRegistry;
        emit TaskRegistrySet(_taskRegistry);
    }

    /**
     * @notice Lock fee in escrow for a task. Called by TaskRegistry.
     * @param taskId Unique task identifier.
     * @param submitter The task submitter address.
     */
    function lockFee(bytes32 taskId, address submitter) external payable onlyTaskRegistry {
        if (escrows[taskId].amount != 0) revert EscrowAlreadyExists(taskId);
        require(msg.value > 0, "No fee sent");

        escrows[taskId] = Escrow({
            submitter: submitter,
            amount: msg.value,
            settled: false
        });

        emit FeeLocked(taskId, submitter, msg.value);
    }

    /**
     * @notice Release escrowed fee to miner on task completion. 5% protocol fee deducted.
     * @param taskId The completed task ID.
     * @param miner Address of the miner to pay.
     */
    function releaseFee(bytes32 taskId, address miner) external onlyTaskRegistry nonReentrant {
        Escrow storage e = escrows[taskId];
        if (e.amount == 0) revert EscrowNotFound(taskId);
        if (e.settled) revert EscrowAlreadySettled(taskId);

        e.settled = true;

        uint256 protocolAmount = (e.amount * PROTOCOL_FEE_BPS) / 10000;
        uint256 minerAmount = e.amount - protocolAmount;
        protocolFees += protocolAmount;

        (bool success, ) = miner.call{value: minerAmount}("");
        if (!success) revert TransferFailed();

        emit FeeReleased(taskId, miner, minerAmount, protocolAmount);
    }

    /**
     * @notice Refund escrowed fee to submitter on task cancel/failure.
     * @param taskId The cancelled/failed task ID.
     */
    function refundFee(bytes32 taskId) external onlyTaskRegistry nonReentrant {
        Escrow storage e = escrows[taskId];
        if (e.amount == 0) revert EscrowNotFound(taskId);
        if (e.settled) revert EscrowAlreadySettled(taskId);

        e.settled = true;

        (bool success, ) = e.submitter.call{value: e.amount}("");
        if (!success) revert TransferFailed();

        emit FeeRefunded(taskId, e.submitter, e.amount);
    }

    /**
     * @notice Withdraw accumulated protocol fees. Only owner.
     */
    function claimProtocolFees() external onlyOwner nonReentrant {
        if (protocolFees == 0) revert NoProtocolFees();

        uint256 amount = protocolFees;
        protocolFees = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit ProtocolFeesClaimed(msg.sender, amount);
    }
}
