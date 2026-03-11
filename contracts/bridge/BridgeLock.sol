// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./BridgeRelayerManager.sol";

/**
 * @title BridgeLock
 * @dev Source-chain contract for the QFC lock-and-mint bridge.
 *      Users lock tokens (ETH native or ERC-20) here, and relayers mint
 *      wrapped versions on the QFC chain.
 *
 * Features:
 * - Lock native ETH and ERC-20 tokens with destination chain routing
 * - 0.1% bridge fee collected for the protocol
 * - Relayer-validated unlock after destination burn is confirmed
 * - Emergency pause by owner
 * - Replay protection via nonce tracking
 */
contract BridgeLock is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Sentinel address representing native ETH
    address public constant NATIVE_TOKEN = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /// @dev Bridge fee in basis points (10 = 0.1%)
    uint256 public bridgeFeeBps = 10;

    /// @dev Maximum fee: 1%
    uint256 public constant MAX_FEE_BPS = 100;

    /// @dev Fee denominator
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @dev Relayer manager for signature validation
    BridgeRelayerManager public immutable relayerManager;

    /// @dev Auto-incrementing nonce for bridge requests
    uint256 public nonce;

    /// @dev Accumulated protocol fees per token
    mapping(address => uint256) public collectedFees;

    /// @dev Processed unlock nonces (replay protection)
    mapping(bytes32 => bool) public processedUnlocks;

    // ── Events ──────────────────────────────────────────────────────────

    event BridgeRequest(
        uint256 indexed nonce,
        address indexed token,
        address indexed sender,
        uint256 amount,
        uint256 fee,
        uint256 destChain,
        address recipient
    );

    event Unlocked(
        address indexed token,
        address indexed recipient,
        uint256 amount,
        uint256 srcChain,
        bytes32 indexed unlockId
    );

    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event BridgeFeeUpdated(uint256 oldFee, uint256 newFee);

    // ── Errors ──────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error InvalidFee();
    error InsufficientETH();
    error AlreadyProcessed();
    error InvalidSignatures();
    error TransferFailed();
    error NoFeesToWithdraw();

    // ── Constructor ─────────────────────────────────────────────────────

    /**
     * @param _relayerManager Address of the BridgeRelayerManager contract
     */
    constructor(address _relayerManager) Ownable(msg.sender) {
        if (_relayerManager == address(0)) revert ZeroAddress();
        relayerManager = BridgeRelayerManager(_relayerManager);
    }

    // ── Lock Functions ──────────────────────────────────────────────────

    /**
     * @notice Lock ERC-20 tokens to bridge to destination chain
     * @param _token ERC-20 token address
     * @param _amount Amount to lock (before fee)
     * @param _destChain Destination chain ID
     * @param _recipient Recipient address on destination chain
     */
    function lock(
        address _token,
        uint256 _amount,
        uint256 _destChain,
        address _recipient
    ) external whenNotPaused nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (_recipient == address(0)) revert ZeroAddress();
        if (_token == NATIVE_TOKEN) revert ZeroAddress(); // Use lockETH for native

        uint256 fee = (_amount * bridgeFeeBps) / BPS_DENOMINATOR;
        uint256 netAmount = _amount - fee;

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        collectedFees[_token] += fee;

        uint256 currentNonce = nonce++;

        emit BridgeRequest(
            currentNonce,
            _token,
            msg.sender,
            netAmount,
            fee,
            _destChain,
            _recipient
        );
    }

    /**
     * @notice Lock native ETH to bridge to destination chain
     * @param _destChain Destination chain ID
     * @param _recipient Recipient address on destination chain
     */
    function lockETH(
        uint256 _destChain,
        address _recipient
    ) external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        if (_recipient == address(0)) revert ZeroAddress();

        uint256 fee = (msg.value * bridgeFeeBps) / BPS_DENOMINATOR;
        uint256 netAmount = msg.value - fee;

        collectedFees[NATIVE_TOKEN] += fee;

        uint256 currentNonce = nonce++;

        emit BridgeRequest(
            currentNonce,
            NATIVE_TOKEN,
            msg.sender,
            netAmount,
            fee,
            _destChain,
            _recipient
        );
    }

    // ── Unlock Functions ────────────────────────────────────────────────

    /**
     * @notice Unlock tokens after destination burn confirmed by relayers
     * @param _token Token address (or NATIVE_TOKEN for ETH)
     * @param _recipient Recipient address
     * @param _amount Amount to unlock
     * @param _srcChain Source chain where burn occurred
     * @param _nonce Bridge nonce from source chain
     * @param _signatures Relayer signatures (must meet quorum)
     */
    function unlock(
        address _token,
        address _recipient,
        uint256 _amount,
        uint256 _srcChain,
        uint256 _nonce,
        bytes[] calldata _signatures
    ) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (_recipient == address(0)) revert ZeroAddress();

        bytes32 unlockId = keccak256(
            abi.encodePacked(_token, _recipient, _amount, _srcChain, _nonce)
        );

        if (processedUnlocks[unlockId]) revert AlreadyProcessed();

        if (!relayerManager.isValidSignatureSet(unlockId, _signatures)) {
            revert InvalidSignatures();
        }

        processedUnlocks[unlockId] = true;

        if (_token == NATIVE_TOKEN) {
            (bool success, ) = _recipient.call{value: _amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(_token).safeTransfer(_recipient, _amount);
        }

        emit Unlocked(_token, _recipient, _amount, _srcChain, unlockId);
    }

    // ── Admin Functions ─────────────────────────────────────────────────

    /**
     * @notice Update the bridge fee
     * @param _newFeeBps New fee in basis points
     */
    function setBridgeFee(uint256 _newFeeBps) external onlyOwner {
        if (_newFeeBps > MAX_FEE_BPS) revert InvalidFee();
        uint256 oldFee = bridgeFeeBps;
        bridgeFeeBps = _newFeeBps;
        emit BridgeFeeUpdated(oldFee, _newFeeBps);
    }

    /**
     * @notice Withdraw collected protocol fees
     * @param _token Token address (or NATIVE_TOKEN for ETH)
     * @param _to Recipient address
     */
    function withdrawFees(address _token, address _to) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        uint256 amount = collectedFees[_token];
        if (amount == 0) revert NoFeesToWithdraw();

        collectedFees[_token] = 0;

        if (_token == NATIVE_TOKEN) {
            (bool success, ) = _to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(_token).safeTransfer(_to, amount);
        }

        emit FeesWithdrawn(_token, _to, amount);
    }

    /**
     * @notice Pause the bridge (emergency)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the bridge
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Allow contract to receive ETH
    receive() external payable {}
}
