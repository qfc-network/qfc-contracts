// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LiquidityPool
 * @dev GLP-style liquidity pool for perpetual futures. LPs deposit QUSD and
 *      receive LP shares. The pool acts as counterparty to all trades and
 *      earns 60% of trading fees.
 */
contract LiquidityPool is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable qusd;

    /// @dev Address of the PositionManager (set after deployment)
    address public positionManager;
    /// @dev Address of the PerpRouter (set after deployment)
    address public router;

    /// @dev Accumulated fees available to LPs (tracked separately)
    uint256 public accumulatedFees;
    /// @dev Net PnL impact on pool (positive = pool lost money, negative = pool gained)
    int256 public netPnLImpact;

    event LiquidityAdded(address indexed provider, uint256 amount, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 shares, uint256 amount);
    event FeesAccrued(uint256 amount);
    event PnLSettled(int256 amount);

    error ZeroAmount();
    error InsufficientPoolBalance();
    error Unauthorized();

    modifier onlyAuthorized() {
        if (msg.sender != positionManager && msg.sender != router && msg.sender != owner())
            revert Unauthorized();
        _;
    }

    constructor(address _qusd) ERC20("QFC Perps LP", "qfcPLP") Ownable(msg.sender) {
        qusd = IERC20(_qusd);
    }

    /**
     * @dev Set the PositionManager address. Only callable by owner.
     * @param _positionManager Address of PositionManager contract
     */
    function setPositionManager(address _positionManager) external onlyOwner {
        positionManager = _positionManager;
    }

    /**
     * @dev Set the PerpRouter address. Only callable by owner.
     * @param _router Address of PerpRouter contract
     */
    function setRouter(address _router) external onlyOwner {
        router = _router;
    }

    /**
     * @dev Add liquidity to the pool by depositing QUSD.
     * @param amount Amount of QUSD to deposit
     * @return shares Number of LP shares minted
     */
    function addLiquidity(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();

        uint256 totalPool = totalAssets();
        uint256 supply = totalSupply();

        if (supply == 0 || totalPool == 0) {
            shares = amount;
        } else {
            shares = (amount * supply) / totalPool;
        }

        qusd.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, shares);

        emit LiquidityAdded(msg.sender, amount, shares);
    }

    /**
     * @dev Remove liquidity by burning LP shares.
     * @param shares Number of LP shares to burn
     * @return amount Amount of QUSD returned
     */
    function removeLiquidity(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();

        uint256 supply = totalSupply();
        amount = (shares * totalAssets()) / supply;

        if (amount > qusd.balanceOf(address(this))) revert InsufficientPoolBalance();

        _burn(msg.sender, shares);
        qusd.safeTransfer(msg.sender, amount);

        emit LiquidityRemoved(msg.sender, shares, amount);
    }

    /**
     * @dev Total assets managed by the pool: QUSD balance adjusted for net PnL.
     * @return Total value in QUSD
     */
    function totalAssets() public view returns (uint256) {
        uint256 balance = qusd.balanceOf(address(this));
        if (netPnLImpact >= 0) {
            // Pool has lost money to traders — effective value is lower
            uint256 loss = uint256(netPnLImpact);
            return balance > loss ? balance - loss : 0;
        } else {
            // Pool has gained from traders
            return balance + uint256(-netPnLImpact);
        }
    }

    /**
     * @dev Accrue trading fees to the pool (called by Router).
     * @param amount Fee amount in QUSD
     */
    function accrueFees(uint256 amount) external onlyAuthorized {
        accumulatedFees += amount;
        emit FeesAccrued(amount);
    }

    /**
     * @dev Settle PnL when a position is closed. Called by PositionManager.
     *      Positive pnl = trader profit (pool pays out).
     *      Negative pnl = trader loss (pool receives).
     * @param pnl Signed PnL amount
     */
    function settlePnL(int256 pnl) external onlyAuthorized {
        netPnLImpact += pnl;
        emit PnLSettled(pnl);
    }

    /**
     * @dev Transfer QUSD out of the pool (for paying trader profits).
     * @param to Recipient
     * @param amount Amount of QUSD
     */
    function transferOut(address to, uint256 amount) external onlyAuthorized {
        if (amount > qusd.balanceOf(address(this))) revert InsufficientPoolBalance();
        qusd.safeTransfer(to, amount);
    }

    /**
     * @dev Reset net PnL tracking (called when positions are fully settled).
     */
    function resetPnL() external onlyAuthorized {
        netPnLImpact = 0;
    }
}
