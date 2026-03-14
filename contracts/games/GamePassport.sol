// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title GamePassport
 * @dev Cross-game identity and reputation — one soulbound NFT per player
 *
 * Features:
 * - One passport per wallet (soulbound, non-transferable)
 * - Tracks stats across all games (total score, games played, wins)
 * - Reputation level based on accumulated XP
 * - Authorized game contracts can update stats
 */
contract GamePassport is ERC721, AccessControl {
    bytes32 public constant GAME_ROLE = keccak256("GAME_ROLE");

    struct Passport {
        uint256 totalXP;
        uint256 level;
        uint256 gamesPlayed;
        uint256 totalWins;
        uint256 createdAt;
        uint256 lastActiveAt;
    }

    /// @dev XP thresholds for levels (index = level, value = cumulative XP required)
    uint256[] public levelThresholds;

    uint256 private _nextTokenId;

    /// @dev player => tokenId
    mapping(address => uint256) public passportOf;

    /// @dev tokenId => passport data
    mapping(uint256 => Passport) public passports;

    /// @dev tokenId => gameId => game-specific score
    mapping(uint256 => mapping(bytes32 => uint256)) public gameScores;

    /// @dev tokenId => gameId => games played in that game
    mapping(uint256 => mapping(bytes32 => uint256)) public gamePlayCount;

    event PassportMinted(uint256 indexed tokenId, address indexed player);
    event XPEarned(uint256 indexed tokenId, bytes32 indexed gameId, uint256 xp);
    event LevelUp(uint256 indexed tokenId, uint256 newLevel);
    event GamePlayed(uint256 indexed tokenId, bytes32 indexed gameId, bool won, uint256 score);

    constructor() ERC721("QFC Game Passport", "QPASS") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // Default level thresholds (10 levels)
        levelThresholds.push(0);       // Level 0
        levelThresholds.push(100);     // Level 1
        levelThresholds.push(300);     // Level 2
        levelThresholds.push(600);     // Level 3
        levelThresholds.push(1000);    // Level 4
        levelThresholds.push(1500);    // Level 5
        levelThresholds.push(2500);    // Level 6
        levelThresholds.push(4000);    // Level 7
        levelThresholds.push(6000);    // Level 8
        levelThresholds.push(10000);   // Level 9
        levelThresholds.push(15000);   // Level 10
    }

    /**
     * @dev Mint a passport for the caller (one per wallet)
     */
    function mint() external returns (uint256 tokenId) {
        require(passportOf[msg.sender] == 0 && balanceOf(msg.sender) == 0, "Already has passport");

        tokenId = ++_nextTokenId; // Start from 1 so 0 means "no passport"
        _safeMint(msg.sender, tokenId);

        passportOf[msg.sender] = tokenId;
        passports[tokenId] = Passport({
            totalXP: 0,
            level: 0,
            gamesPlayed: 0,
            totalWins: 0,
            createdAt: block.timestamp,
            lastActiveAt: block.timestamp
        });

        emit PassportMinted(tokenId, msg.sender);
    }

    /**
     * @dev Record a game result and award XP (called by game contracts)
     * @param player Player address
     * @param gameId Game identifier
     * @param won Whether the player won
     * @param score Score achieved
     * @param xp XP to award
     */
    function recordGame(
        address player,
        bytes32 gameId,
        bool won,
        uint256 score,
        uint256 xp
    ) external onlyRole(GAME_ROLE) {
        uint256 tokenId = passportOf[player];
        require(tokenId != 0, "No passport");

        Passport storage passport = passports[tokenId];
        passport.gamesPlayed++;
        passport.lastActiveAt = block.timestamp;

        if (won) {
            passport.totalWins++;
        }

        // Update game-specific stats
        if (score > gameScores[tokenId][gameId]) {
            gameScores[tokenId][gameId] = score;
        }
        gamePlayCount[tokenId][gameId]++;

        emit GamePlayed(tokenId, gameId, won, score);

        // Award XP
        if (xp > 0) {
            passport.totalXP += xp;
            emit XPEarned(tokenId, gameId, xp);

            // Check level up
            uint256 newLevel = _calculateLevel(passport.totalXP);
            if (newLevel > passport.level) {
                passport.level = newLevel;
                emit LevelUp(tokenId, newLevel);
            }
        }
    }

    /**
     * @dev Award XP without recording a game (for achievements, events, etc.)
     * @param player Player address
     * @param gameId Source game
     * @param xp XP to award
     */
    function awardXP(address player, bytes32 gameId, uint256 xp) external onlyRole(GAME_ROLE) {
        uint256 tokenId = passportOf[player];
        require(tokenId != 0, "No passport");
        require(xp > 0, "XP must be > 0");

        Passport storage passport = passports[tokenId];
        passport.totalXP += xp;
        passport.lastActiveAt = block.timestamp;

        emit XPEarned(tokenId, gameId, xp);

        uint256 newLevel = _calculateLevel(passport.totalXP);
        if (newLevel > passport.level) {
            passport.level = newLevel;
            emit LevelUp(tokenId, newLevel);
        }
    }

    /**
     * @dev Get full passport data for a player
     * @param player Player address
     */
    function getPassport(address player) external view returns (Passport memory) {
        uint256 tokenId = passportOf[player];
        require(tokenId != 0, "No passport");
        return passports[tokenId];
    }

    /**
     * @dev Get player's score for a specific game
     */
    function getGameScore(address player, bytes32 gameId) external view returns (uint256) {
        uint256 tokenId = passportOf[player];
        require(tokenId != 0, "No passport");
        return gameScores[tokenId][gameId];
    }

    /**
     * @dev Update level thresholds (owner only)
     * @param thresholds New XP thresholds array
     */
    function setLevelThresholds(uint256[] calldata thresholds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(thresholds.length > 0, "Empty thresholds");
        delete levelThresholds;
        for (uint256 i = 0; i < thresholds.length; i++) {
            levelThresholds.push(thresholds[i]);
        }
    }

    /**
     * @dev Calculate level from XP
     */
    function _calculateLevel(uint256 xp) internal view returns (uint256) {
        for (uint256 i = levelThresholds.length; i > 0; i--) {
            if (xp >= levelThresholds[i - 1]) {
                return i - 1;
            }
        }
        return 0;
    }

    // --- Soulbound: prevent transfers ---

    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        // Only allow mint (from == 0) and burn (to == 0)
        if (from != address(0) && to != address(0)) {
            revert("Soulbound: non-transferable");
        }
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
