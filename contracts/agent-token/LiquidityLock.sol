// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LiquidityLock
 * @notice Permanently locks LP tokens to prevent rug pulls.
 *         There is intentionally no unlock or withdraw function.
 */
contract LiquidityLock {
    using SafeERC20 for IERC20;

    /// @notice lpToken address => locked amount
    mapping(address => uint256) public locked;

    event LiquidityLocked(address indexed lpToken, address indexed depositor, uint256 amount);

    error ZeroAmount();
    error ZeroAddress();

    /**
     * @notice Lock LP tokens permanently.
     * @param lpToken Address of the LP token to lock
     * @param amount Amount of LP tokens to lock
     */
    function lock(address lpToken, uint256 amount) external {
        if (lpToken == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(lpToken).safeTransferFrom(msg.sender, address(this), amount);
        locked[lpToken] += amount;

        emit LiquidityLocked(lpToken, msg.sender, amount);
    }

    /**
     * @notice Get the locked amount for an LP token.
     * @param lpToken Address of the LP token
     * @return amount The total locked amount
     */
    function getLocked(address lpToken) external view returns (uint256) {
        return locked[lpToken];
    }
}
