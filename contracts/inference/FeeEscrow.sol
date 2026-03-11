// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FeeEscrow
 * @notice Locks QFC fees when inference tasks are submitted.
 *         Releases payment to miners on completion, refunds submitters on failure/cancellation.
 *         Designed to be called by TaskRegistry.
 */
contract FeeEscrow is Ownable, ReentrancyGuard {
    struct Escrow {
        address submitter;
        address miner;
        uint256 amount;
        bool settled;
    }

    /// @dev taskId => Escrow
    mapping(uint256 => Escrow) private _escrows;

    uint256 public totalLocked;
    uint256 public protocolFeeBps; // basis points (e.g. 250 = 2.5%)
    address public protocolFeeRecipient;

    event Deposited(uint256 indexed taskId, address indexed submitter, uint256 amount);
    event Released(uint256 indexed taskId, address indexed miner, uint256 minerAmount, uint256 protocolFee);
    event Refunded(uint256 indexed taskId, address indexed submitter, uint256 amount);
    event ProtocolFeeUpdated(uint256 newFeeBps);
    event FeeRecipientUpdated(address newRecipient);

    error AlreadyDeposited(uint256 taskId);
    error NotDeposited(uint256 taskId);
    error AlreadySettled(uint256 taskId);
    error InvalidAmount();
    error FeeTooHigh();
    error TransferFailed();

    constructor(uint256 _protocolFeeBps, address _feeRecipient) Ownable(msg.sender) {
        if (_protocolFeeBps > 1000) revert FeeTooHigh(); // max 10%
        protocolFeeBps = _protocolFeeBps;
        protocolFeeRecipient = _feeRecipient;
    }

    /// @notice Lock funds for a task
    /// @param taskId The task ID
    /// @param submitter The task submitter address
    function deposit(uint256 taskId, address submitter) external payable onlyOwner {
        if (msg.value == 0) revert InvalidAmount();
        if (_escrows[taskId].amount != 0) revert AlreadyDeposited(taskId);

        _escrows[taskId] = Escrow({
            submitter: submitter,
            miner: address(0),
            amount: msg.value,
            settled: false
        });
        totalLocked += msg.value;

        emit Deposited(taskId, submitter, msg.value);
    }

    /// @notice Release escrowed funds to the miner (minus protocol fee)
    /// @param taskId The task ID
    /// @param miner The miner to pay
    function release(uint256 taskId, address miner) external onlyOwner nonReentrant {
        Escrow storage e = _escrows[taskId];
        if (e.amount == 0) revert NotDeposited(taskId);
        if (e.settled) revert AlreadySettled(taskId);

        e.miner = miner;
        e.settled = true;
        totalLocked -= e.amount;

        uint256 fee = (e.amount * protocolFeeBps) / 10000;
        uint256 minerAmount = e.amount - fee;

        if (fee > 0 && protocolFeeRecipient != address(0)) {
            (bool feeOk, ) = protocolFeeRecipient.call{value: fee}("");
            if (!feeOk) revert TransferFailed();
        } else {
            minerAmount = e.amount; // no fee if recipient not set
        }

        (bool ok, ) = miner.call{value: minerAmount}("");
        if (!ok) revert TransferFailed();

        emit Released(taskId, miner, minerAmount, fee);
    }

    /// @notice Refund escrowed funds to the submitter
    /// @param taskId The task ID
    function refund(uint256 taskId) external onlyOwner nonReentrant {
        Escrow storage e = _escrows[taskId];
        if (e.amount == 0) revert NotDeposited(taskId);
        if (e.settled) revert AlreadySettled(taskId);

        e.settled = true;
        totalLocked -= e.amount;

        (bool ok, ) = e.submitter.call{value: e.amount}("");
        if (!ok) revert TransferFailed();

        emit Refunded(taskId, e.submitter, e.amount);
    }

    /// @notice Get escrow details
    function getEscrow(uint256 taskId) external view returns (Escrow memory) {
        return _escrows[taskId];
    }

    /// @notice Update protocol fee (max 10%)
    function setProtocolFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > 1000) revert FeeTooHigh();
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeUpdated(newFeeBps);
    }

    /// @notice Update fee recipient
    function setFeeRecipient(address newRecipient) external onlyOwner {
        protocolFeeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }
}
