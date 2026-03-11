// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BaseStrategy
 * @dev Abstract base for yield vault strategies
 *
 * Features:
 * - Standard interface for vault integration
 * - Deposit idle funds into yield source
 * - Withdraw funds back to vault on demand
 * - Harvest yield and report profit
 */
abstract contract BaseStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable want;
    address public vault;

    event Harvested(uint256 profit);

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    constructor(address _want, address _vault) {
        want = IERC20(_want);
        vault = _vault;
    }

    /**
     * @dev Estimated total assets held by this strategy
     * @return Total value denominated in want token
     */
    function estimatedTotalAssets() public view virtual returns (uint256);

    /**
     * @dev Deploy idle want tokens into the yield source
     */
    function deposit() external virtual;

    /**
     * @dev Withdraw want tokens back to the vault
     * @param amount Amount of want tokens to withdraw
     */
    function withdraw(uint256 amount) external virtual;

    /**
     * @dev Harvest yield, convert to want, and return profit amount
     * @return profit Amount of want tokens gained
     */
    function harvest() external virtual returns (uint256 profit);
}
