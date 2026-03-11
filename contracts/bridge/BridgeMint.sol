// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./BridgeRelayerManager.sol";
import "./WrappedToken.sol";

/**
 * @title BridgeMint
 * @dev QFC-chain contract for the lock-and-mint bridge.
 *      Relayers call mint() after tokens are locked on source chain.
 *      Users call burn() to bridge back, which triggers unlock on source chain.
 *
 * Features:
 * - Mint wrapped tokens upon relayer-validated lock confirmation
 * - Burn wrapped tokens to initiate bridge-back
 * - 3-of-5 multisig relayer validation via BridgeRelayerManager
 * - Replay protection via processed nonce tracking
 * - Owner-managed wrapped token registry
 */
contract BridgeMint is Ownable, Pausable, ReentrancyGuard {
    /// @dev Relayer manager for signature validation
    BridgeRelayerManager public immutable relayerManager;

    /// @dev Mapping: source token address => wrapped token on QFC
    mapping(address => WrappedToken) public wrappedTokens;

    /// @dev Processed mint nonces: keccak256(srcChain, nonce) => bool
    mapping(bytes32 => bool) public processedNonces;

    /// @dev Auto-incrementing nonce for burn (bridge-back) requests
    uint256 public burnNonce;

    // ── Events ──────────────────────────────────────────────────────────

    event TokenMinted(
        address indexed srcToken,
        address indexed wrappedToken,
        address indexed recipient,
        uint256 amount,
        uint256 srcChain,
        uint256 nonce
    );

    event BurnRequest(
        uint256 indexed nonce,
        address indexed wrappedToken,
        address indexed sender,
        uint256 amount,
        uint256 destChain,
        address recipient
    );

    event WrappedTokenRegistered(address indexed srcToken, address indexed wrappedToken);

    // ── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error AlreadyProcessed();
    error InvalidSignatures();
    error TokenNotRegistered();
    error TokenAlreadyRegistered();

    // ── Constructor ─────────────────────────────────────────────────────

    /**
     * @param _relayerManager Address of the BridgeRelayerManager contract
     */
    constructor(address _relayerManager) Ownable(msg.sender) {
        if (_relayerManager == address(0)) revert ZeroAddress();
        relayerManager = BridgeRelayerManager(_relayerManager);
    }

    // ── Admin Functions ─────────────────────────────────────────────────

    /**
     * @notice Register a wrapped token for a source-chain token
     * @param _srcToken Source token address on origin chain
     * @param _wrappedToken Deployed WrappedToken contract address
     */
    function registerWrappedToken(
        address _srcToken,
        address _wrappedToken
    ) external onlyOwner {
        if (_srcToken == address(0) || _wrappedToken == address(0)) revert ZeroAddress();
        if (address(wrappedTokens[_srcToken]) != address(0)) revert TokenAlreadyRegistered();

        wrappedTokens[_srcToken] = WrappedToken(_wrappedToken);
        emit WrappedTokenRegistered(_srcToken, _wrappedToken);
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

    // ── Mint Function ───────────────────────────────────────────────────

    /**
     * @notice Mint wrapped tokens after source-chain lock is confirmed
     * @param _srcToken Source token address on origin chain
     * @param _recipient Recipient on QFC chain
     * @param _amount Amount to mint
     * @param _srcChain Source chain ID where lock occurred
     * @param _nonce Lock nonce from source chain
     * @param _signatures Relayer signatures (must meet quorum)
     */
    function mint(
        address _srcToken,
        address _recipient,
        uint256 _amount,
        uint256 _srcChain,
        uint256 _nonce,
        bytes[] calldata _signatures
    ) external whenNotPaused nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (_recipient == address(0)) revert ZeroAddress();

        WrappedToken wrapped = wrappedTokens[_srcToken];
        if (address(wrapped) == address(0)) revert TokenNotRegistered();

        // Replay protection
        bytes32 nonceKey = keccak256(abi.encodePacked(_srcChain, _nonce));
        if (processedNonces[nonceKey]) revert AlreadyProcessed();

        // Validate relayer signatures
        bytes32 messageHash = keccak256(
            abi.encodePacked(_srcToken, _recipient, _amount, _srcChain, _nonce)
        );
        if (!relayerManager.isValidSignatureSet(messageHash, _signatures)) {
            revert InvalidSignatures();
        }

        processedNonces[nonceKey] = true;

        wrapped.mint(_recipient, _amount);

        emit TokenMinted(
            _srcToken,
            address(wrapped),
            _recipient,
            _amount,
            _srcChain,
            _nonce
        );
    }

    // ── Burn Function ───────────────────────────────────────────────────

    /**
     * @notice Burn wrapped tokens to bridge back to source chain
     * @param _srcToken Source token address (used to look up wrapped token)
     * @param _amount Amount to burn
     * @param _destChain Destination chain ID
     * @param _recipient Recipient address on destination chain
     */
    function burn(
        address _srcToken,
        uint256 _amount,
        uint256 _destChain,
        address _recipient
    ) external whenNotPaused nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (_recipient == address(0)) revert ZeroAddress();

        WrappedToken wrapped = wrappedTokens[_srcToken];
        if (address(wrapped) == address(0)) revert TokenNotRegistered();

        wrapped.bridgeBurn(msg.sender, _amount);

        uint256 currentNonce = burnNonce++;

        emit BurnRequest(
            currentNonce,
            address(wrapped),
            msg.sender,
            _amount,
            _destChain,
            _recipient
        );
    }
}
