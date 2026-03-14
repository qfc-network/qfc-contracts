// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title GameLeaderboard
 * @dev On-chain high scores verified by game server signatures
 *
 * Features:
 * - Multiple game support (dungeon, cards, pets, office)
 * - Scores signed by authorized game servers
 * - Top-N leaderboard per game per season
 * - Season rotation with history
 */
contract GameLeaderboard is Ownable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    struct ScoreEntry {
        address player;
        uint256 score;
        uint256 timestamp;
    }

    struct Season {
        uint256 startTime;
        uint256 endTime;
        bool finalized;
    }

    uint256 public constant MAX_LEADERBOARD_SIZE = 100;

    /// @dev gameId => authorized server signer
    mapping(bytes32 => address) public gameSigner;

    /// @dev gameId => seasonId => leaderboard entries
    mapping(bytes32 => mapping(uint256 => ScoreEntry[])) public leaderboards;

    /// @dev gameId => seasonId => player => best score
    mapping(bytes32 => mapping(uint256 => mapping(address => uint256))) public playerBestScore;

    /// @dev gameId => current season ID
    mapping(bytes32 => uint256) public currentSeason;

    /// @dev gameId => seasonId => season info
    mapping(bytes32 => mapping(uint256 => Season)) public seasons;

    /// @dev Replay protection: used nonces
    mapping(bytes32 => bool) public usedNonces;

    event GameRegistered(bytes32 indexed gameId, address signer);
    event ScoreSubmitted(bytes32 indexed gameId, uint256 indexed seasonId, address indexed player, uint256 score);
    event SeasonStarted(bytes32 indexed gameId, uint256 indexed seasonId, uint256 startTime, uint256 endTime);
    event SeasonFinalized(bytes32 indexed gameId, uint256 indexed seasonId);

    constructor() Ownable(msg.sender) {}

    /**
     * @dev Register a new game with its server signer
     * @param gameId Unique game identifier (e.g., keccak256("dungeon"))
     * @param signer Authorized server address that signs scores
     */
    function registerGame(bytes32 gameId, address signer) external onlyOwner {
        require(signer != address(0), "Invalid signer");
        gameSigner[gameId] = signer;
        emit GameRegistered(gameId, signer);
    }

    /**
     * @dev Start a new season for a game
     * @param gameId Game identifier
     * @param duration Season duration in seconds
     */
    function startSeason(bytes32 gameId, uint256 duration) external onlyOwner {
        require(gameSigner[gameId] != address(0), "Game not registered");
        require(duration > 0, "Duration must be > 0");

        uint256 seasonId = currentSeason[gameId];

        // Finalize previous season if exists and not finalized
        if (seasonId > 0) {
            Season storage prev = seasons[gameId][seasonId];
            if (!prev.finalized) {
                prev.finalized = true;
                emit SeasonFinalized(gameId, seasonId);
            }
        }

        seasonId = seasonId + 1;
        currentSeason[gameId] = seasonId;

        seasons[gameId][seasonId] = Season({
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            finalized: false
        });

        emit SeasonStarted(gameId, seasonId, block.timestamp, block.timestamp + duration);
    }

    /**
     * @dev Submit a score signed by the game server
     * @param gameId Game identifier
     * @param score Player's score
     * @param nonce Unique nonce for replay protection
     * @param signature Server signature over (gameId, player, score, nonce, chainId)
     */
    function submitScore(
        bytes32 gameId,
        uint256 score,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(gameSigner[gameId] != address(0), "Game not registered");
        require(!usedNonces[nonce], "Nonce already used");

        uint256 seasonId = currentSeason[gameId];
        require(seasonId > 0, "No active season");

        Season memory season = seasons[gameId][seasonId];
        require(block.timestamp >= season.startTime, "Season not started");
        require(block.timestamp <= season.endTime, "Season ended");

        // Verify server signature
        bytes32 messageHash = keccak256(
            abi.encodePacked(gameId, msg.sender, score, nonce, block.chainid)
        );
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address recovered = ethSignedHash.recover(signature);
        require(recovered == gameSigner[gameId], "Invalid signature");

        usedNonces[nonce] = true;

        // Update best score
        uint256 currentBest = playerBestScore[gameId][seasonId][msg.sender];
        if (score > currentBest) {
            playerBestScore[gameId][seasonId][msg.sender] = score;
            _updateLeaderboard(gameId, seasonId, msg.sender, score);
        }

        emit ScoreSubmitted(gameId, seasonId, msg.sender, score);
    }

    /**
     * @dev Get top N entries for a game season
     * @param gameId Game identifier
     * @param seasonId Season ID
     * @return entries Leaderboard entries sorted by score (descending)
     */
    function getLeaderboard(
        bytes32 gameId,
        uint256 seasonId
    ) external view returns (ScoreEntry[] memory) {
        return leaderboards[gameId][seasonId];
    }

    /**
     * @dev Get leaderboard size
     */
    function getLeaderboardSize(bytes32 gameId, uint256 seasonId) external view returns (uint256) {
        return leaderboards[gameId][seasonId].length;
    }

    /**
     * @dev Internal: update leaderboard with new best score
     */
    function _updateLeaderboard(
        bytes32 gameId,
        uint256 seasonId,
        address player,
        uint256 score
    ) internal {
        ScoreEntry[] storage board = leaderboards[gameId][seasonId];

        // Check if player already on board — update in place
        for (uint256 i = 0; i < board.length; i++) {
            if (board[i].player == player) {
                board[i].score = score;
                board[i].timestamp = block.timestamp;
                _sortDown(board, i);
                return;
            }
        }

        // New entry
        if (board.length < MAX_LEADERBOARD_SIZE) {
            board.push(ScoreEntry(player, score, block.timestamp));
            _sortDown(board, board.length - 1);
        } else if (score > board[board.length - 1].score) {
            // Replace last entry
            board[board.length - 1] = ScoreEntry(player, score, block.timestamp);
            _sortDown(board, board.length - 1);
        }
    }

    /**
     * @dev Bubble-sort an entry into its correct position (descending order)
     */
    function _sortDown(ScoreEntry[] storage board, uint256 idx) internal {
        // Bubble up
        while (idx > 0 && board[idx].score > board[idx - 1].score) {
            ScoreEntry memory temp = board[idx];
            board[idx] = board[idx - 1];
            board[idx - 1] = temp;
            idx--;
        }
        // Bubble down
        while (idx < board.length - 1 && board[idx].score < board[idx + 1].score) {
            ScoreEntry memory temp = board[idx];
            board[idx] = board[idx + 1];
            board[idx + 1] = temp;
            idx++;
        }
    }
}
