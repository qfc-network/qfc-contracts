// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../BaseStrategy.sol";

/**
 * @title ILendingPool
 * @dev Interface for lending pool integration
 */
interface ILendingPool {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title LendingStrategy
 * @dev Strategy that supplies want token to a lending pool for interest
 *
 * Features:
 * - Deposits want token into LendingPool
 * - Earns interest via qTokens
 * - Harvest claims accrued interest and returns profit to vault
 */
contract LendingStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    ILendingPool public immutable lendingPool;

    constructor(
        address _want,
        address _vault,
        address _lendingPool
    ) BaseStrategy(_want, _vault) {
        lendingPool = ILendingPool(_lendingPool);
    }

    /**
     * @dev Total assets held in the lending pool
     */
    function estimatedTotalAssets() public view override returns (uint256) {
        return lendingPool.balanceOf(address(this)) + want.balanceOf(address(this));
    }

    /**
     * @dev Deploy idle want tokens into the lending pool
     */
    function deposit() external override onlyVault {
        uint256 balance = want.balanceOf(address(this));
        if (balance > 0) {
            want.safeIncreaseAllowance(address(lendingPool), balance);
            lendingPool.supply(address(want), balance);
        }
    }

    /**
     * @dev Withdraw want tokens from the lending pool back to vault
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external override onlyVault {
        uint256 idle = want.balanceOf(address(this));
        if (idle >= amount) {
            want.safeTransfer(vault, amount);
            return;
        }

        uint256 toWithdraw = amount - idle;
        lendingPool.withdraw(address(want), toWithdraw);
        want.safeTransfer(vault, amount);
    }

    /**
     * @dev Harvest accrued interest from the lending pool
     * @return profit Amount of want tokens gained as interest
     */
    function harvest() external override onlyVault returns (uint256 profit) {
        uint256 before = want.balanceOf(address(this));

        // Withdraw all from lending pool
        uint256 poolBalance = lendingPool.balanceOf(address(this));
        if (poolBalance > 0) {
            lendingPool.withdraw(address(want), poolBalance);
        }

        uint256 total = want.balanceOf(address(this));
        // Re-deposit everything
        if (total > 0) {
            want.safeIncreaseAllowance(address(lendingPool), total);
            lendingPool.supply(address(want), total);
        }

        // Profit is the interest earned (total withdrawn - what we had idle before)
        profit = total > before ? total - before : 0;

        // Transfer profit to vault
        if (profit > 0) {
            lendingPool.withdraw(address(want), profit);
            want.safeTransfer(vault, profit);
        }

        emit Harvested(profit);
    }
}
