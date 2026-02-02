// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SimpleSwap
 * @dev Simple AMM DEX with constant product formula (x * y = k)
 *
 * Features:
 * - Add/remove liquidity
 * - Token swaps with fee
 * - LP token minting
 */
contract SimpleSwap is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    uint256 public totalLiquidity;
    mapping(address => uint256) public liquidity;

    uint256 public constant FEE_NUMERATOR = 3;
    uint256 public constant FEE_DENOMINATOR = 1000; // 0.3% fee

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Swap(address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    constructor(address _token0, address _token1) Ownable(msg.sender) {
        require(_token0 != _token1, "Identical tokens");
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    /**
     * @dev Add liquidity to the pool
     * @param amount0 Amount of token0 to add
     * @param amount1 Amount of token1 to add
     * @return liquidityMinted Amount of LP tokens minted
     */
    function addLiquidity(uint256 amount0, uint256 amount1)
        external
        nonReentrant
        returns (uint256 liquidityMinted)
    {
        require(amount0 > 0 && amount1 > 0, "Invalid amounts");

        if (totalLiquidity == 0) {
            // Initial liquidity
            liquidityMinted = sqrt(amount0 * amount1);
        } else {
            // Proportional liquidity
            uint256 liquidity0 = (amount0 * totalLiquidity) / reserve0;
            uint256 liquidity1 = (amount1 * totalLiquidity) / reserve1;
            liquidityMinted = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }

        require(liquidityMinted > 0, "Insufficient liquidity minted");

        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        reserve0 += amount0;
        reserve1 += amount1;
        totalLiquidity += liquidityMinted;
        liquidity[msg.sender] += liquidityMinted;

        emit LiquidityAdded(msg.sender, amount0, amount1, liquidityMinted);
    }

    /**
     * @dev Remove liquidity from the pool
     * @param liquidityAmount Amount of LP tokens to burn
     * @return amount0 Amount of token0 returned
     * @return amount1 Amount of token1 returned
     */
    function removeLiquidity(uint256 liquidityAmount)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        require(liquidityAmount > 0, "Invalid amount");
        require(liquidity[msg.sender] >= liquidityAmount, "Insufficient liquidity");

        amount0 = (liquidityAmount * reserve0) / totalLiquidity;
        amount1 = (liquidityAmount * reserve1) / totalLiquidity;

        require(amount0 > 0 && amount1 > 0, "Insufficient output amounts");

        liquidity[msg.sender] -= liquidityAmount;
        totalLiquidity -= liquidityAmount;
        reserve0 -= amount0;
        reserve1 -= amount1;

        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);

        emit LiquidityRemoved(msg.sender, amount0, amount1, liquidityAmount);
    }

    /**
     * @dev Swap token0 for token1
     * @param amountIn Amount of token0 to swap
     * @param minAmountOut Minimum token1 to receive
     * @return amountOut Amount of token1 received
     */
    function swap0For1(uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        amountOut = getAmountOut(amountIn, reserve0, reserve1);
        require(amountOut >= minAmountOut, "Slippage too high");

        token0.safeTransferFrom(msg.sender, address(this), amountIn);
        token1.safeTransfer(msg.sender, amountOut);

        reserve0 += amountIn;
        reserve1 -= amountOut;

        emit Swap(msg.sender, address(token0), amountIn, amountOut);
    }

    /**
     * @dev Swap token1 for token0
     * @param amountIn Amount of token1 to swap
     * @param minAmountOut Minimum token0 to receive
     * @return amountOut Amount of token0 received
     */
    function swap1For0(uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        amountOut = getAmountOut(amountIn, reserve1, reserve0);
        require(amountOut >= minAmountOut, "Slippage too high");

        token1.safeTransferFrom(msg.sender, address(this), amountIn);
        token0.safeTransfer(msg.sender, amountOut);

        reserve1 += amountIn;
        reserve0 -= amountOut;

        emit Swap(msg.sender, address(token1), amountIn, amountOut);
    }

    /**
     * @dev Calculate output amount for a swap
     * @param amountIn Input amount
     * @param reserveIn Input token reserve
     * @param reserveOut Output token reserve
     * @return amountOut Output amount
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountOut) {
        require(amountIn > 0, "Invalid input amount");
        require(reserveIn > 0 && reserveOut > 0, "Invalid reserves");

        uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - FEE_NUMERATOR);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * FEE_DENOMINATOR) + amountInWithFee;

        amountOut = numerator / denominator;
    }

    /**
     * @dev Calculate input amount for a desired output
     * @param amountOut Desired output amount
     * @param reserveIn Input token reserve
     * @param reserveOut Output token reserve
     * @return amountIn Required input amount
     */
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountIn) {
        require(amountOut > 0, "Invalid output amount");
        require(reserveIn > 0 && reserveOut > 0, "Invalid reserves");
        require(amountOut < reserveOut, "Insufficient liquidity");

        uint256 numerator = reserveIn * amountOut * FEE_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * (FEE_DENOMINATOR - FEE_NUMERATOR);

        amountIn = (numerator / denominator) + 1;
    }

    /**
     * @dev Get current price of token0 in terms of token1
     */
    function getPrice0() external view returns (uint256) {
        if (reserve0 == 0) return 0;
        return (reserve1 * 1e18) / reserve0;
    }

    /**
     * @dev Get current price of token1 in terms of token0
     */
    function getPrice1() external view returns (uint256) {
        if (reserve1 == 0) return 0;
        return (reserve0 * 1e18) / reserve1;
    }

    /**
     * @dev Get pool info
     */
    function getPoolInfo() external view returns (
        address _token0,
        address _token1,
        uint256 _reserve0,
        uint256 _reserve1,
        uint256 _totalLiquidity
    ) {
        return (address(token0), address(token1), reserve0, reserve1, totalLiquidity);
    }

    // Babylonian method for square root
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
