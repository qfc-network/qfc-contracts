// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./IncrementalMerkleTree.sol";

/**
 * @title ShieldedPool
 * @notice Privacy pool for qUSD — deposit stablecoins to break on-chain linkability.
 *
 *  Flow:
 *    1. User generates secret + nullifier off-chain
 *    2. commitment = hash(secret, nullifier)
 *    3. User deposits fixed amount of qUSD + commitment → added to Merkle tree
 *    4. Later, user (or relayer) submits ZK proof + nullifier from a new address
 *    5. Contract verifies proof and sends qUSD to the new address
 *
 *  The ZK proof demonstrates:
 *    - "I know a (secret, nullifier) such that hash(secret, nullifier) is in the Merkle tree"
 *    - "The nullifier I'm revealing hasn't been used before"
 *    - Without revealing which commitment is mine
 *
 *  Supported denominations: 100, 1000, 10000, 100000 qUSD
 *
 * @dev In production, the simplified proof verification should be replaced with
 *      a real Groth16/PLONK verifier generated from a ZK circuit (e.g., circom/snarkjs).
 *      The current implementation uses a hash-based proof for testing and demonstration.
 */
contract ShieldedPool is IncrementalMerkleTree, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    // --- Denominations ---

    mapping(uint256 => bool) public supportedDenominations;
    uint256[] public denominations;

    // --- Nullifiers ---

    mapping(bytes32 => bool) public nullifierUsed;

    // --- Deposits ---

    struct Deposit {
        bytes32 commitment;
        uint256 denomination;
        uint256 timestamp;
        uint32 leafIndex;
    }

    mapping(bytes32 => Deposit) public deposits;
    uint256 public depositCount;

    // --- Relayer ---

    /// @notice Fee paid to relayer (basis points of denomination)
    uint256 public relayerFeeBps = 50; // 0.5% default
    uint256 public constant MAX_RELAYER_FEE = 500; // 5% max
    uint256 public constant BASIS_POINTS = 10000;

    // --- Errors ---

    error InvalidDenomination(uint256 denomination);
    error DuplicateCommitment();
    error InvalidProof();
    error NullifierAlreadyUsed();
    error InvalidRoot();
    error InvalidRecipient();
    error FeeTooHigh();
    error DenominationAlreadyExists();

    // --- Events ---

    event DepositMade(
        bytes32 indexed commitment,
        uint256 denomination,
        uint32 leafIndex,
        uint256 timestamp
    );
    event WithdrawalMade(
        address indexed recipient,
        bytes32 indexed nullifierHash,
        address indexed relayer,
        uint256 denomination,
        uint256 fee
    );
    event DenominationAdded(uint256 denomination);

    constructor(address _token) Ownable(msg.sender) {
        token = IERC20(_token);

        // Default denominations (18 decimals)
        uint256[4] memory defaultDenoms = [
            uint256(100 * 1e18),
            uint256(1000 * 1e18),
            uint256(10000 * 1e18),
            uint256(100000 * 1e18)
        ];

        for (uint256 i = 0; i < 4; i++) {
            supportedDenominations[defaultDenoms[i]] = true;
            denominations.push(defaultDenoms[i]);
        }
    }

    // =========================================================================
    // Deposit
    // =========================================================================

    /**
     * @notice Deposit qUSD into the shielded pool
     * @param _commitment Hash of (secret, nullifier) — generated off-chain
     * @param _denomination Amount of qUSD to deposit (must be a supported denomination)
     */
    function deposit(bytes32 _commitment, uint256 _denomination) external nonReentrant whenNotPaused {
        if (!supportedDenominations[_denomination]) revert InvalidDenomination(_denomination);
        if (deposits[_commitment].commitment != bytes32(0)) revert DuplicateCommitment();

        // Insert commitment into Merkle tree
        uint32 leafIndex = uint32(_insertLeaf(_commitment));

        // Record deposit
        deposits[_commitment] = Deposit({
            commitment: _commitment,
            denomination: _denomination,
            timestamp: block.timestamp,
            leafIndex: leafIndex
        });
        depositCount++;

        // Transfer qUSD from depositor
        token.safeTransferFrom(msg.sender, address(this), _denomination);

        emit DepositMade(_commitment, _denomination, leafIndex, block.timestamp);
    }

    // =========================================================================
    // Withdraw
    // =========================================================================

    /**
     * @notice Withdraw qUSD from the shielded pool using a ZK proof
     * @param _proof The ZK proof data (format depends on proving system)
     * @param _root Merkle root at time of proof generation
     * @param _nullifierHash Hash of the nullifier (prevents double-spend)
     * @param _recipient Address to receive the qUSD
     * @param _relayer Address of the relayer (address(0) if self-relaying)
     * @param _denomination Denomination of the original deposit
     *
     * @dev In production, replace _verifyProof with a real Groth16/PLONK verifier.
     *      The proof must demonstrate knowledge of (secret, nullifier) such that:
     *        1. hash(secret, nullifier) is a leaf in the Merkle tree with root _root
     *        2. hash(nullifier) == _nullifierHash
     *      Without revealing which leaf.
     */
    function withdraw(
        bytes calldata _proof,
        bytes32 _root,
        bytes32 _nullifierHash,
        address _recipient,
        address _relayer,
        uint256 _denomination
    ) external nonReentrant whenNotPaused {
        if (_recipient == address(0)) revert InvalidRecipient();
        if (!supportedDenominations[_denomination]) revert InvalidDenomination(_denomination);
        if (nullifierUsed[_nullifierHash]) revert NullifierAlreadyUsed();
        if (!isKnownRoot(_root)) revert InvalidRoot();

        // Verify the ZK proof
        if (!_verifyProof(_proof, _root, _nullifierHash, _recipient, _denomination)) {
            revert InvalidProof();
        }

        // Mark nullifier as used
        nullifierUsed[_nullifierHash] = true;

        // Calculate relayer fee
        uint256 fee = 0;
        if (_relayer != address(0)) {
            fee = (_denomination * relayerFeeBps) / BASIS_POINTS;
        }

        uint256 amountToRecipient = _denomination - fee;

        // Transfer qUSD
        token.safeTransfer(_recipient, amountToRecipient);
        if (fee > 0) {
            token.safeTransfer(_relayer, fee);
        }

        emit WithdrawalMade(_recipient, _nullifierHash, _relayer, _denomination, fee);
    }

    // =========================================================================
    // Proof verification
    // =========================================================================

    /**
     * @notice Verify the withdrawal proof
     * @dev PLACEHOLDER — in production, replace with a real Groth16/PLONK verifier
     *      generated from a circom circuit. The current implementation uses a
     *      simplified hash-based check for testing purposes.
     *
     *      Production circuit proves:
     *        - ∃ (secret, nullifier, pathElements, pathIndices) such that:
     *          - commitment = hash(secret, nullifier)
     *          - commitment is in Merkle tree with root _root (using pathElements/pathIndices)
     *          - hash(nullifier) == _nullifierHash
     *        - Public inputs: _root, _nullifierHash, _recipient, _denomination
     *        - Private inputs: secret, nullifier, pathElements[20], pathIndices[20]
     */
    function _verifyProof(
        bytes calldata _proof,
        bytes32 _root,
        bytes32 _nullifierHash,
        address _recipient,
        uint256 _denomination
    ) internal view returns (bool) {
        // Simplified verification for testing:
        // proof = abi.encode(secret, nullifier, commitment)
        // Verify: hash(secret, nullifier) == commitment AND commitment exists in tree
        if (_proof.length < 96) return false;

        (bytes32 secret, bytes32 nullifier, bytes32 commitment) = abi.decode(_proof, (bytes32, bytes32, bytes32));

        // Check: hash(secret, nullifier) == commitment
        bytes32 computedCommitment = keccak256(abi.encodePacked(secret, nullifier));
        if (computedCommitment != commitment) return false;

        // Check: hash(nullifier) == nullifierHash
        bytes32 computedNullifierHash = keccak256(abi.encodePacked(nullifier));
        if (computedNullifierHash != _nullifierHash) return false;

        // Check: commitment was deposited
        if (deposits[commitment].commitment == bytes32(0)) return false;

        // Check: denomination matches
        if (deposits[commitment].denomination != _denomination) return false;

        return true;
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function addDenomination(uint256 _denomination) external onlyOwner {
        if (supportedDenominations[_denomination]) revert DenominationAlreadyExists();
        supportedDenominations[_denomination] = true;
        denominations.push(_denomination);
        emit DenominationAdded(_denomination);
    }

    function setRelayerFee(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_RELAYER_FEE) revert FeeTooHigh();
        relayerFeeBps = _feeBps;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // =========================================================================
    // View
    // =========================================================================

    function getDenominations() external view returns (uint256[] memory) {
        return denominations;
    }

    function getPoolBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
