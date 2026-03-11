// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../BaseStrategy.sol";

/**
 * @title IStakingRewards
 * @dev Interface for staking rewards integration
 */
interface IStakingRewards {
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function claimRewards() external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title ISwapRouter
 * @dev Interface for swapping reward tokens to want tokens
 */
interface ISwapRouter {
    function swap(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut);
}

/**
 * @title StakingStrategy
 * @dev Strategy that stakes want token and claims QFC rewards
 *
 * Features:
 * - Stakes want token in StakingPool
 * - Claims QFC reward tokens
 * - Swaps rewards back to want token via router
 * - Compounds profits back into staking
 */
contract StakingStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IStakingRewards public immutable stakingRewards;
    IERC20 public immutable rewardToken;
    ISwapRouter public immutable swapRouter;

    constructor(
        address _want,
        address _vault,
        address _stakingRewards,
        address _rewardToken,
        address _swapRouter
    ) BaseStrategy(_want, _vault) {
        stakingRewards = IStakingRewards(_stakingRewards);
        rewardToken = IERC20(_rewardToken);
        swapRouter = ISwapRouter(_swapRouter);
    }

    /**
     * @dev Total assets held in the staking pool plus idle balance
     */
    function estimatedTotalAssets() public view override returns (uint256) {
        return stakingRewards.balanceOf(address(this)) + want.balanceOf(address(this));
    }

    /**
     * @dev Deploy idle want tokens into the staking pool
     */
    function deposit() external override onlyVault {
        uint256 balance = want.balanceOf(address(this));
        if (balance > 0) {
            want.safeIncreaseAllowance(address(stakingRewards), balance);
            stakingRewards.stake(balance);
        }
    }

    /**
     * @dev Withdraw want tokens from the staking pool back to vault
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external override onlyVault {
        uint256 idle = want.balanceOf(address(this));
        if (idle >= amount) {
            want.safeTransfer(vault, amount);
            return;
        }

        uint256 toWithdraw = amount - idle;
        stakingRewards.withdraw(toWithdraw);
        want.safeTransfer(vault, amount);
    }

    /**
     * @dev Harvest staking rewards, swap to want, and return profit
     * @return profit Amount of want tokens gained
     */
    function harvest() external override onlyVault returns (uint256 profit) {
        // Claim reward tokens
        uint256 rewardAmount = stakingRewards.claimRewards();

        if (rewardAmount > 0) {
            // Swap reward tokens to want tokens
            rewardToken.safeIncreaseAllowance(address(swapRouter), rewardAmount);
            profit = swapRouter.swap(address(rewardToken), address(want), rewardAmount);

            // Transfer profit to vault
            if (profit > 0) {
                want.safeTransfer(vault, profit);
            }
        }

        emit Harvested(profit);
    }
}
