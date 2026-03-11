// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../BaseStrategy.sol";

/**
 * @title MockStrategy
 * @dev Mock strategy for testing the YieldVault
 */
contract MockStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    uint256 public deposited;
    uint256 private _profit;

    constructor(address _want, address _vault) BaseStrategy(_want, _vault) {}

    function estimatedTotalAssets() public view override returns (uint256) {
        return deposited + want.balanceOf(address(this));
    }

    function deposit() external override onlyVault {
        uint256 balance = want.balanceOf(address(this));
        deposited += balance;
    }

    function withdraw(uint256 amount) external override onlyVault {
        uint256 idle = want.balanceOf(address(this));
        // In a real strategy we'd pull from the protocol.
        // For the mock, just track accounting and transfer idle tokens.
        if (amount <= deposited) {
            deposited -= amount;
        } else {
            deposited = 0;
        }
        // Transfer what we can from idle balance
        uint256 toSend = amount > idle ? idle : amount;
        if (toSend > 0) {
            want.safeTransfer(vault, toSend);
        }
    }

    function harvest() external override onlyVault returns (uint256 profit) {
        profit = _profit;
        _profit = 0;

        if (profit > 0) {
            want.safeTransfer(vault, profit);
        }

        emit Harvested(profit);
    }

    /**
     * @dev Set the profit that will be returned on next harvest (test helper)
     */
    function setProfit(uint256 amount) external {
        _profit = amount;
    }
}
