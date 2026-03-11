// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StakingPool
 * @dev Staking pool with time-weighted rewards
 *
 * Features:
 * - Stake ERC20 tokens
 * - Earn rewards over time
 * - Configurable reward rate
 * - Lock period support
 * - Emergency withdraw
 */
contract StakingPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public rewardRate; // Rewards per second per token staked (scaled by 1e18)
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public lockPeriod; // Lock period in seconds

    uint256 public totalStaked;

    struct StakeInfo {
        uint256 amount;
        uint256 rewardPerTokenPaid;
        uint256 rewards;
        uint256 stakeTime;
    }

    mapping(address => StakeInfo) public stakes;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event LockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    constructor(
        address _stakingToken,
        address _rewardToken,
        uint256 _rewardRate,
        uint256 _lockPeriod
    ) Ownable(msg.sender) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        rewardRate = _rewardRate;
        lockPeriod = _lockPeriod;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;

        if (account != address(0)) {
            stakes[account].rewards = earned(account);
            stakes[account].rewardPerTokenPaid = rewardPerTokenStored;
        }
        _;
    }

    /**
     * @dev Calculate reward per token
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + (
            (block.timestamp - lastUpdateTime) * rewardRate * 1e18 / totalStaked
        );
    }

    /**
     * @dev Calculate earned rewards for an account
     * @param account User address
     */
    function earned(address account) public view returns (uint256) {
        StakeInfo memory stake = stakes[account];
        return (
            stake.amount * (rewardPerToken() - stake.rewardPerTokenPaid) / 1e18
        ) + stake.rewards;
    }

    /**
     * @dev Stake tokens
     * @param amount Amount to stake
     */
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");

        totalStaked += amount;
        stakes[msg.sender].amount += amount;
        stakes[msg.sender].stakeTime = block.timestamp;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /**
     * @dev Withdraw staked tokens
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        require(stakes[msg.sender].amount >= amount, "Insufficient stake");
        require(
            block.timestamp >= stakes[msg.sender].stakeTime + lockPeriod,
            "Still locked"
        );

        totalStaked -= amount;
        stakes[msg.sender].amount -= amount;

        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @dev Claim rewards
     */
    function claimRewards() public nonReentrant updateReward(msg.sender) {
        uint256 reward = stakes[msg.sender].rewards;
        if (reward > 0) {
            stakes[msg.sender].rewards = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     * @dev Withdraw all and claim rewards
     */
    function exit() external nonReentrant updateReward(msg.sender) {
        uint256 amount = stakes[msg.sender].amount;
        require(amount > 0, "Nothing to withdraw");
        require(
            block.timestamp >= stakes[msg.sender].stakeTime + lockPeriod,
            "Still locked"
        );

        totalStaked -= amount;
        stakes[msg.sender].amount = 0;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);

        uint256 reward = stakes[msg.sender].rewards;
        if (reward > 0) {
            stakes[msg.sender].rewards = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     * @dev Emergency withdraw without rewards
     */
    function emergencyWithdraw() external nonReentrant {
        uint256 amount = stakes[msg.sender].amount;
        require(amount > 0, "Nothing to withdraw");

        totalStaked -= amount;
        stakes[msg.sender].amount = 0;
        stakes[msg.sender].rewards = 0;

        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @dev Update reward rate (owner only)
     * @param _rewardRate New reward rate
     */
    function setRewardRate(uint256 _rewardRate) external onlyOwner updateReward(address(0)) {
        emit RewardRateUpdated(rewardRate, _rewardRate);
        rewardRate = _rewardRate;
    }

    /**
     * @dev Update lock period (owner only)
     * @param _lockPeriod New lock period in seconds
     */
    function setLockPeriod(uint256 _lockPeriod) external onlyOwner {
        emit LockPeriodUpdated(lockPeriod, _lockPeriod);
        lockPeriod = _lockPeriod;
    }

    /**
     * @dev Add reward tokens to the pool
     * @param amount Amount of reward tokens
     */
    function addRewards(uint256 amount) external onlyOwner {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev Recover accidentally sent tokens
     * @param token Token address
     * @param amount Amount to recover
     */
    function recoverTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(stakingToken), "Cannot recover staking token");
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @dev Get stake info for an account
     * @param account User address
     */
    function getStakeInfo(address account) external view returns (
        uint256 stakedAmount,
        uint256 pendingRewards,
        uint256 stakeTime,
        uint256 unlockTime
    ) {
        StakeInfo memory stake = stakes[account];
        return (
            stake.amount,
            earned(account),
            stake.stakeTime,
            stake.stakeTime + lockPeriod
        );
    }
}
