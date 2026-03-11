// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title PolicyManager
 * @notice Library for managing spending policies, contract allowlists, and time-locked operations.
 */
library PolicyManager {
    /// @notice A pending time-locked transaction request.
    struct TimeLockRequest {
        address target;
        uint256 value;
        bytes data;
        uint64 executeAfter;
        bool executed;
    }

    /// @notice Spending and access policies for an agent wallet.
    struct Policies {
        uint256 perTxLimit;
        uint256 perPeriodLimit;
        uint64 periodDuration;
        uint256 spentThisPeriod;
        uint64 periodStart;
        mapping(address => bool) allowedContracts;
        bool allowlistEnabled;
        uint256 timeLockThreshold;
        uint64 timeLockDelay;
        mapping(bytes32 => TimeLockRequest) pendingTimeLocks;
    }

    // ── Errors ──────────────────────────────────────────────────────────
    error PerTxLimitExceeded(uint256 value, uint256 limit);
    error PerPeriodLimitExceeded(uint256 newTotal, uint256 limit);
    error ContractNotAllowed(address target);
    error TimeLockNotReady(bytes32 id, uint64 executeAfter);
    error TimeLockAlreadyExecuted(bytes32 id);
    error TimeLockNotFound(bytes32 id);

    // ── Events ──────────────────────────────────────────────────────────
    event PerTxLimitUpdated(uint256 newLimit);
    event PerPeriodLimitUpdated(uint256 newLimit, uint64 periodDuration);
    event AllowedContractAdded(address indexed target);
    event AllowedContractRemoved(address indexed target);
    event TimeLockThresholdUpdated(uint256 threshold, uint64 delay);
    event TimeLockRequested(bytes32 indexed id, address target, uint256 value, uint64 executeAfter);
    event TimeLockExecuted(bytes32 indexed id);

    // ── Functions ───────────────────────────────────────────────────────

    /// @notice Initialize default policy values.
    /// @param self The Policies storage reference.
    /// @param perTxLimit_ Maximum value per transaction.
    /// @param perPeriodLimit_ Maximum cumulative spend per period.
    /// @param periodDuration_ Duration of the spending period in seconds.
    function initialize(
        Policies storage self,
        uint256 perTxLimit_,
        uint256 perPeriodLimit_,
        uint64 periodDuration_
    ) internal {
        self.perTxLimit = perTxLimit_;
        self.perPeriodLimit = perPeriodLimit_;
        self.periodDuration = periodDuration_;
        self.periodStart = uint64(block.timestamp);
    }

    /// @notice Check whether a target contract is on the allowlist (or if the allowlist is disabled).
    /// @param self The Policies storage reference.
    /// @param target The contract address to check.
    /// @return True if allowed.
    function isContractAllowed(Policies storage self, address target) internal view returns (bool) {
        if (!self.allowlistEnabled) return true;
        return self.allowedContracts[target];
    }

    /// @notice Enforce the per-transaction spending limit.
    /// @param self The Policies storage reference.
    /// @param value The value of the transaction.
    function checkPerTxLimit(Policies storage self, uint256 value) internal view {
        if (self.perTxLimit > 0 && value > self.perTxLimit) {
            revert PerTxLimitExceeded(value, self.perTxLimit);
        }
    }

    /// @notice Enforce the per-period cumulative spending limit and update tracked spend.
    /// @param self The Policies storage reference.
    /// @param value The value being spent.
    function checkPerPeriodLimit(Policies storage self, uint256 value) internal {
        if (self.perPeriodLimit == 0) return;

        // Reset period if expired
        if (self.periodDuration > 0 && uint64(block.timestamp) >= self.periodStart + self.periodDuration) {
            self.spentThisPeriod = 0;
            self.periodStart = uint64(block.timestamp);
        }

        uint256 newTotal = self.spentThisPeriod + value;
        if (newTotal > self.perPeriodLimit) {
            revert PerPeriodLimitExceeded(newTotal, self.perPeriodLimit);
        }
        self.spentThisPeriod = newTotal;
    }

    /// @notice Request a time-locked operation for high-value transactions.
    /// @param self The Policies storage reference.
    /// @param target The target address.
    /// @param value The ETH value to send.
    /// @param data The calldata.
    /// @return id The unique identifier for this time-lock request.
    function requestTimeLock(
        Policies storage self,
        address target,
        uint256 value,
        bytes memory data
    ) internal returns (bytes32 id) {
        id = keccak256(abi.encodePacked(target, value, data, block.timestamp));
        uint64 executeAfter = uint64(block.timestamp) + self.timeLockDelay;
        self.pendingTimeLocks[id] = TimeLockRequest({
            target: target,
            value: value,
            data: data,
            executeAfter: executeAfter,
            executed: false
        });
        emit TimeLockRequested(id, target, value, executeAfter);
    }

    /// @notice Execute a previously requested time-locked operation.
    /// @param self The Policies storage reference.
    /// @param id The time-lock request identifier.
    /// @return target The target address.
    /// @return value The ETH value.
    /// @return data The calldata.
    function executeTimeLock(
        Policies storage self,
        bytes32 id
    ) internal returns (address target, uint256 value, bytes memory data) {
        TimeLockRequest storage req = self.pendingTimeLocks[id];
        if (req.executeAfter == 0) revert TimeLockNotFound(id);
        if (req.executed) revert TimeLockAlreadyExecuted(id);
        if (uint64(block.timestamp) < req.executeAfter) {
            revert TimeLockNotReady(id, req.executeAfter);
        }
        req.executed = true;
        emit TimeLockExecuted(id);
        return (req.target, req.value, req.data);
    }

    /// @notice Add a contract to the allowlist.
    /// @param self The Policies storage reference.
    /// @param target The contract address to allow.
    function addAllowedContract(Policies storage self, address target) internal {
        self.allowedContracts[target] = true;
        self.allowlistEnabled = true;
        emit AllowedContractAdded(target);
    }

    /// @notice Remove a contract from the allowlist.
    /// @param self The Policies storage reference.
    /// @param target The contract address to disallow.
    function removeAllowedContract(Policies storage self, address target) internal {
        self.allowedContracts[target] = false;
        emit AllowedContractRemoved(target);
    }
}
