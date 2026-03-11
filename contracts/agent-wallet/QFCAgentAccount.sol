// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccount, IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PolicyManager} from "./PolicyManager.sol";

/**
 * @title QFCAgentAccount
 * @notice ERC-4337 compliant smart account with session keys and spending policies.
 * @dev UUPS upgradeable. Validated by an ERC-4337 EntryPoint.
 */
contract QFCAgentAccount is Initializable, UUPSUpgradeable, IAccount {
    using PolicyManager for PolicyManager.Policies;

    // ── Permission constants ────────────────────────────────────────────
    uint64 public constant PERM_INFERENCE = 0x01;
    uint64 public constant PERM_TRANSFER = 0x02;
    uint64 public constant PERM_STAKE = 0x04;
    uint64 public constant PERM_REGISTER = 0x08;
    uint64 public constant PERM_ALL = 0xFF;

    // ── ERC-4337 validation return values ───────────────────────────────
    uint256 internal constant SIG_VALIDATION_SUCCESS = 0;
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    // ── Structs ─────────────────────────────────────────────────────────
    struct SessionKey {
        uint64 permissions;
        uint256 spendingLimit;
        uint256 spentThisPeriod;
        uint64 periodStart;
        uint64 periodDuration;
        uint64 expiresAt;
        uint64 nonce;
        bool active;
    }

    // ── State ───────────────────────────────────────────────────────────
    address public owner;
    IEntryPoint public entryPoint;
    PolicyManager.Policies internal _policies;
    mapping(address => SessionKey) public sessionKeys;

    // ── Errors ──────────────────────────────────────────────────────────
    error NotOwner();
    error NotEntryPoint();
    error NotOwnerOrEntryPoint();
    error SessionKeyExpired(address key);
    error SessionKeyInactive(address key);
    error SessionKeySpendingExceeded(address key, uint256 newTotal, uint256 limit);
    error InsufficientPermissions(address key, uint64 required);
    error ExecutionFailed(address target, bytes returnData);
    error ArrayLengthMismatch();
    error InvalidSignatureLength();
    error ZeroAddress();

    // ── Events ──────────────────────────────────────────────────────────
    event Initialized(address indexed owner, address indexed entryPoint);
    event SessionKeyAdded(address indexed key, uint64 permissions, uint256 spendingLimit, uint64 expiresAt);
    event SessionKeyRemoved(address indexed key);
    event Executed(address indexed target, uint256 value, bytes data);
    event BatchExecuted(uint256 count);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PerTxLimitSet(uint256 limit);
    event PerPeriodLimitSet(uint256 limit, uint64 duration);
    event TimeLockThresholdSet(uint256 threshold, uint64 delay);

    // ── Modifiers ───────────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();
        _;
    }

    modifier onlyOwnerOrEntryPoint() {
        if (msg.sender != owner && msg.sender != address(entryPoint)) revert NotOwnerOrEntryPoint();
        _;
    }

    // ── Constructor (disable initializers on implementation) ─────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ── Initializer ─────────────────────────────────────────────────────
    /// @notice Initialize the account with an owner and entry point.
    /// @param owner_ The account owner.
    /// @param entryPoint_ The ERC-4337 EntryPoint contract.
    function initialize(address owner_, IEntryPoint entryPoint_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        entryPoint = entryPoint_;
        _policies.initialize(type(uint256).max, type(uint256).max, 1 days);
        emit Initialized(owner_, address(entryPoint_));
    }

    // ── ERC-4337 IAccount ───────────────────────────────────────────────
    /// @notice Validate a user operation signature.
    /// @param userOp The packed user operation.
    /// @param userOpHash The hash of the user operation.
    /// @param missingAccountFunds Funds the account must deposit to the EntryPoint.
    /// @return validationData 0 for valid owner sig, 1 for failure. Packed expiry for session keys.
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external onlyEntryPoint returns (uint256 validationData) {
        // Pay prefund
        if (missingAccountFunds > 0) {
            (bool success, ) = payable(msg.sender).call{value: missingAccountFunds}("");
            (success); // suppress unused warning
        }

        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);

        if (userOp.signature.length < 65) {
            return SIG_VALIDATION_FAILED;
        }

        address recovered = ECDSA.recover(ethHash, userOp.signature);

        // Owner signature
        if (recovered == owner) {
            return SIG_VALIDATION_SUCCESS;
        }

        // Session key signature
        SessionKey storage sk = sessionKeys[recovered];
        if (!sk.active) {
            return SIG_VALIDATION_FAILED;
        }
        if (block.timestamp >= sk.expiresAt) {
            return SIG_VALIDATION_FAILED;
        }

        // Pack validAfter=0, validUntil=expiresAt, authorizer=0
        // validationData = authorizer(20) | validUntil(6) | validAfter(6)
        return uint256(uint48(sk.expiresAt)) << 160;
    }

    // ── Execution ───────────────────────────────────────────────────────
    /// @notice Execute a transaction from this account.
    /// @param target The target address.
    /// @param value The ETH value to send.
    /// @param data The calldata.
    function execute(address target, uint256 value, bytes calldata data) external onlyOwnerOrEntryPoint {
        _executeWithPolicies(target, value, data);
    }

    /// @notice Execute a batch of transactions.
    /// @param targets Array of target addresses.
    /// @param values Array of ETH values.
    /// @param datas Array of calldata.
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external onlyOwnerOrEntryPoint {
        if (targets.length != values.length || values.length != datas.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < targets.length; i++) {
            _executeWithPolicies(targets[i], values[i], datas[i]);
        }
        emit BatchExecuted(targets.length);
    }

    // ── Session key management ──────────────────────────────────────────
    /// @notice Add a session key with specified permissions and limits.
    /// @param key The session key address.
    /// @param permissions Bitmask of allowed permissions.
    /// @param spendingLimit Maximum spend per period.
    /// @param periodDuration Spending period duration in seconds.
    /// @param ttl Time-to-live in seconds from now.
    function addSessionKey(
        address key,
        uint64 permissions,
        uint256 spendingLimit,
        uint64 periodDuration,
        uint64 ttl
    ) external onlyOwner {
        if (key == address(0)) revert ZeroAddress();
        uint64 expiresAt = uint64(block.timestamp) + ttl;
        sessionKeys[key] = SessionKey({
            permissions: permissions,
            spendingLimit: spendingLimit,
            spentThisPeriod: 0,
            periodStart: uint64(block.timestamp),
            periodDuration: periodDuration,
            expiresAt: expiresAt,
            nonce: 0,
            active: true
        });
        emit SessionKeyAdded(key, permissions, spendingLimit, expiresAt);
    }

    /// @notice Remove a session key.
    /// @param key The session key address to remove.
    function removeSessionKey(address key) external onlyOwner {
        sessionKeys[key].active = false;
        emit SessionKeyRemoved(key);
    }

    // ── Policy management ───────────────────────────────────────────────
    /// @notice Set the per-transaction spending limit.
    /// @param limit The new per-tx limit.
    function setPerTxLimit(uint256 limit) external onlyOwner {
        _policies.perTxLimit = limit;
        emit PerTxLimitSet(limit);
    }

    /// @notice Set the per-period spending limit.
    /// @param limit The new cumulative limit.
    /// @param duration The period duration in seconds.
    function setPerPeriodLimit(uint256 limit, uint64 duration) external onlyOwner {
        _policies.perPeriodLimit = limit;
        _policies.periodDuration = duration;
        _policies.spentThisPeriod = 0;
        _policies.periodStart = uint64(block.timestamp);
        emit PerPeriodLimitSet(limit, duration);
    }

    /// @notice Add a contract to the allowlist.
    /// @param target The contract address to allow.
    function addAllowedContract(address target) external onlyOwner {
        _policies.addAllowedContract(target);
    }

    /// @notice Remove a contract from the allowlist.
    /// @param target The contract address to disallow.
    function removeAllowedContract(address target) external onlyOwner {
        _policies.removeAllowedContract(target);
    }

    /// @notice Set the time-lock threshold and delay.
    /// @param threshold Value above which time-lock is required.
    /// @param delay Time delay in seconds before execution.
    function setTimeLockThreshold(uint256 threshold, uint64 delay) external onlyOwner {
        _policies.timeLockThreshold = threshold;
        _policies.timeLockDelay = delay;
        emit TimeLockThresholdSet(threshold, delay);
    }

    // ── Ownership ───────────────────────────────────────────────────────
    /// @notice Transfer ownership of this account.
    /// @param newOwner The new owner address.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    // ── View helpers ────────────────────────────────────────────────────
    /// @notice Get the per-transaction limit.
    function perTxLimit() external view returns (uint256) {
        return _policies.perTxLimit;
    }

    /// @notice Get the per-period limit.
    function perPeriodLimit() external view returns (uint256) {
        return _policies.perPeriodLimit;
    }

    /// @notice Check if a contract is allowed.
    function isContractAllowed(address target) external view returns (bool) {
        return _policies.isContractAllowed(target);
    }

    // ── Receive ETH ─────────────────────────────────────────────────────
    /// @notice Allow the account to receive ETH.
    receive() external payable {}

    // ── Internal ────────────────────────────────────────────────────────
    function _executeWithPolicies(address target, uint256 value, bytes calldata data) internal {
        _policies.checkPerTxLimit(value);
        _policies.checkPerPeriodLimit(value);

        if (data.length > 0 && target.code.length > 0) {
            if (!_policies.isContractAllowed(target)) {
                revert PolicyManager.ContractNotAllowed(target);
            }
        }

        (bool success, bytes memory returnData) = target.call{value: value}(data);
        if (!success) revert ExecutionFailed(target, returnData);
        emit Executed(target, value, data);
    }

    /// @dev UUPS authorization — only owner can upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
