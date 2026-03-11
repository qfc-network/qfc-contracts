// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title StQFC
 * @dev Liquid staking receipt token for staked QFC
 *
 * Features:
 * - Non-rebasing ERC-20 (exchange rate model like rETH)
 * - Only the LiquidStaking contract can mint/burn
 * - Standard transfers for DEX and lending composability
 * - EIP-2612 permit for gasless approvals
 */
contract StQFC is ERC20, ERC20Permit {
    address public immutable liquidStaking;

    error OnlyLiquidStaking();

    modifier onlyLiquidStaking() {
        if (msg.sender != liquidStaking) revert OnlyLiquidStaking();
        _;
    }

    constructor(address _liquidStaking)
        ERC20("Staked QFC", "stQFC")
        ERC20Permit("Staked QFC")
    {
        liquidStaking = _liquidStaking;
    }

    /**
     * @dev Mint stQFC tokens. Only callable by LiquidStaking.
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyLiquidStaking {
        _mint(to, amount);
    }

    /**
     * @dev Burn stQFC tokens. Only callable by LiquidStaking.
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount) external onlyLiquidStaking {
        _burn(from, amount);
    }
}
