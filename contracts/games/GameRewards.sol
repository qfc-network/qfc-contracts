// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./GameLeaderboard.sol";

/**
 * @title GameRewards
 * @dev Distribute QFC rewards for achievements and top leaderboard scores
 *
 * Features:
 * - Season-end rewards for top players
 * - Achievement-based one-time rewards
 * - Configurable reward tiers per game
 * - Pull-based claim pattern
 */
contract GameRewards is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable rewardToken;
    GameLeaderboard public immutable leaderboard;

    /// @dev gameId => tier index => reward amount
    mapping(bytes32 => uint256[]) public seasonRewardTiers;

    /// @dev player => claimable balance
    mapping(address => uint256) public claimable;

    /// @dev gameId => seasonId => finalized (rewards distributed)
    mapping(bytes32 => mapping(uint256 => bool)) public rewardsDistributed;

    /// @dev achievementId => reward amount
    mapping(bytes32 => uint256) public achievementRewards;

    /// @dev player => achievementId => claimed
    mapping(address => mapping(bytes32 => bool)) public achievementClaimed;

    /// @dev Authorized distributors (game servers)
    mapping(address => bool) public distributors;

    event RewardTiersSet(bytes32 indexed gameId, uint256[] amounts);
    event SeasonRewardsDistributed(bytes32 indexed gameId, uint256 indexed seasonId, uint256 totalAmount);
    event AchievementRewardSet(bytes32 indexed achievementId, uint256 amount);
    event AchievementClaimed(address indexed player, bytes32 indexed achievementId, uint256 amount);
    event RewardClaimed(address indexed player, uint256 amount);
    event DistributorSet(address indexed distributor, bool authorized);
    event BonusAwarded(address indexed player, uint256 amount, string reason);

    constructor(address _rewardToken, address _leaderboard) Ownable(msg.sender) {
        rewardToken = IERC20(_rewardToken);
        leaderboard = GameLeaderboard(_leaderboard);
    }

    modifier onlyDistributor() {
        require(distributors[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }

    /**
     * @dev Set reward tiers for a game's season-end distribution
     * @param gameId Game identifier
     * @param amounts Reward amounts for each rank (index 0 = 1st place)
     */
    function setRewardTiers(bytes32 gameId, uint256[] calldata amounts) external onlyOwner {
        seasonRewardTiers[gameId] = amounts;
        emit RewardTiersSet(gameId, amounts);
    }

    /**
     * @dev Set an achievement reward
     * @param achievementId Unique achievement identifier
     * @param amount Reward amount
     */
    function setAchievementReward(bytes32 achievementId, uint256 amount) external onlyOwner {
        achievementRewards[achievementId] = amount;
        emit AchievementRewardSet(achievementId, amount);
    }

    /**
     * @dev Set distributor authorization
     * @param distributor Address to authorize
     * @param authorized Whether to authorize or revoke
     */
    function setDistributor(address distributor, bool authorized) external onlyOwner {
        distributors[distributor] = authorized;
        emit DistributorSet(distributor, authorized);
    }

    /**
     * @dev Distribute season-end rewards based on leaderboard rankings
     * @param gameId Game identifier
     * @param seasonId Season to distribute rewards for
     */
    function distributeSeasonRewards(bytes32 gameId, uint256 seasonId) external onlyOwner {
        require(!rewardsDistributed[gameId][seasonId], "Already distributed");

        uint256[] memory tiers = seasonRewardTiers[gameId];
        require(tiers.length > 0, "No reward tiers set");

        GameLeaderboard.ScoreEntry[] memory board = leaderboard.getLeaderboard(gameId, seasonId);

        uint256 totalRewards;
        uint256 count = board.length < tiers.length ? board.length : tiers.length;

        for (uint256 i = 0; i < count; i++) {
            if (board[i].player != address(0) && tiers[i] > 0) {
                claimable[board[i].player] += tiers[i];
                totalRewards += tiers[i];
            }
        }

        rewardsDistributed[gameId][seasonId] = true;
        emit SeasonRewardsDistributed(gameId, seasonId, totalRewards);
    }

    /**
     * @dev Grant an achievement reward to a player (called by game server)
     * @param player Player address
     * @param achievementId Achievement identifier
     */
    function grantAchievement(address player, bytes32 achievementId) external onlyDistributor {
        require(!achievementClaimed[player][achievementId], "Already claimed");
        uint256 amount = achievementRewards[achievementId];
        require(amount > 0, "Achievement not registered");

        achievementClaimed[player][achievementId] = true;
        claimable[player] += amount;

        emit AchievementClaimed(player, achievementId, amount);
    }

    /**
     * @dev Award bonus rewards to a player
     * @param player Player address
     * @param amount Reward amount
     * @param reason Description of the bonus
     */
    function awardBonus(address player, uint256 amount, string calldata reason) external onlyDistributor {
        require(amount > 0, "Amount must be > 0");
        claimable[player] += amount;
        emit BonusAwarded(player, amount, reason);
    }

    /**
     * @dev Claim all pending rewards
     */
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        require(amount > 0, "Nothing to claim");

        claimable[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, amount);

        emit RewardClaimed(msg.sender, amount);
    }

    /**
     * @dev Fund the contract with reward tokens
     * @param amount Amount to deposit
     */
    function fundRewards(uint256 amount) external {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev Emergency withdraw (owner only)
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        rewardToken.safeTransfer(owner(), amount);
    }
}
