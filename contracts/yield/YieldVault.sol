// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./BaseStrategy.sol";

/**
 * @title YieldVault
 * @dev ERC-4626 compliant yield aggregator vault (Yearn V2 style)
 *
 * Features:
 * - Deposit assets to receive vault shares
 * - Pluggable strategies with allocation weights
 * - Auto-compounding harvest across all strategies
 * - 10% performance fee on harvested yield
 * - Emergency pause and withdrawAll
 */
contract YieldVault is ERC20, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    address public feeRecipient;

    uint256 public constant PERFORMANCE_FEE = 1000; // 10% in basis points
    uint256 public constant FEE_DENOMINATOR = 10000;

    struct StrategyInfo {
        uint256 allocation; // Basis points (out of 10000)
        bool active;
    }

    address[] public strategies;
    mapping(address => StrategyInfo) public strategyInfo;
    uint256 public totalAllocation;

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event StrategyAdded(address indexed strategy, uint256 allocation);
    event StrategyRemoved(address indexed strategy);
    event Harvested(uint256 totalProfit, uint256 fee);
    event EmergencyWithdrawAll();

    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _feeRecipient
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        asset = IERC20(_asset);
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Deposit assets and receive vault shares
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        require(assets > 0, "Invalid deposit amount");

        shares = convertToShares(assets);
        require(shares > 0, "Zero shares");

        asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @dev Withdraw assets by specifying asset amount
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive assets
     * @param owner Address that owns the shares
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 shares)
    {
        shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "Insufficient allowance");
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        _burn(owner, shares);
        _ensureLiquidity(assets);
        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @dev Redeem shares for assets
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive assets
     * @param owner Address that owns the shares
     * @return assets Amount of assets received
     */
    function redeem(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 assets)
    {
        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "Insufficient allowance");
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        assets = convertToAssets(shares);
        _burn(owner, shares);
        _ensureLiquidity(assets);
        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @dev Harvest yield from all active strategies and reinvest
     */
    function harvest() external nonReentrant {
        uint256 totalProfit;

        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategyInfo[strategies[i]].active) {
                uint256 profit = BaseStrategy(strategies[i]).harvest();
                totalProfit += profit;
            }
        }

        uint256 fee;
        if (totalProfit > 0) {
            fee = (totalProfit * PERFORMANCE_FEE) / FEE_DENOMINATOR;
            if (fee > 0) {
                asset.safeTransfer(feeRecipient, fee);
            }
        }

        // Redeploy idle assets to strategies
        _deployToStrategies();

        emit Harvested(totalProfit, fee);
    }

    /**
     * @dev Add a new strategy
     * @param strategy Strategy contract address
     * @param allocation Allocation weight in basis points
     */
    function addStrategy(address strategy, uint256 allocation) external onlyOwner {
        require(strategy != address(0), "Invalid strategy");
        require(!strategyInfo[strategy].active, "Strategy already active");
        require(totalAllocation + allocation <= FEE_DENOMINATOR, "Allocation exceeds 100%");

        strategies.push(strategy);
        strategyInfo[strategy] = StrategyInfo({
            allocation: allocation,
            active: true
        });
        totalAllocation += allocation;

        emit StrategyAdded(strategy, allocation);
    }

    /**
     * @dev Remove a strategy and withdraw all its funds
     * @param strategy Strategy contract address
     */
    function removeStrategy(address strategy) external onlyOwner {
        require(strategyInfo[strategy].active, "Strategy not active");

        // Withdraw all funds from strategy
        uint256 strategyBalance = BaseStrategy(strategy).estimatedTotalAssets();
        if (strategyBalance > 0) {
            BaseStrategy(strategy).withdraw(strategyBalance);
        }

        totalAllocation -= strategyInfo[strategy].allocation;
        strategyInfo[strategy].active = false;
        strategyInfo[strategy].allocation = 0;

        // Remove from array
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i] == strategy) {
                strategies[i] = strategies[strategies.length - 1];
                strategies.pop();
                break;
            }
        }

        emit StrategyRemoved(strategy);
    }

    /**
     * @dev Total assets under management (vault balance + all strategy balances)
     * @return total Sum of vault idle balance and strategy balances
     */
    function totalAssets() public view returns (uint256 total) {
        total = asset.balanceOf(address(this));
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategyInfo[strategies[i]].active) {
                total += BaseStrategy(strategies[i]).estimatedTotalAssets();
            }
        }
    }

    /**
     * @dev Convert assets to shares
     */
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        return (assets * supply) / totalAssets();
    }

    /**
     * @dev Convert shares to assets
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return (shares * totalAssets()) / supply;
    }

    /**
     * @dev Preview shares needed for withdrawal
     */
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 _totalAssets = totalAssets();
        if (supply == 0) return assets;
        return (assets * supply + _totalAssets - 1) / _totalAssets;
    }

    /**
     * @dev Share price in terms of assets (scaled by 1e18)
     */
    function sharePrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return (totalAssets() * 1e18) / supply;
    }

    /**
     * @dev Pause vault deposits
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause vault deposits
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Emergency: withdraw all funds from all strategies back to vault
     */
    function withdrawAll() external onlyOwner {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategyInfo[strategies[i]].active) {
                uint256 bal = BaseStrategy(strategies[i]).estimatedTotalAssets();
                if (bal > 0) {
                    BaseStrategy(strategies[i]).withdraw(bal);
                }
            }
        }
        emit EmergencyWithdrawAll();
    }

    /**
     * @dev Set fee recipient address
     * @param _feeRecipient New fee recipient
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid address");
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Get number of active strategies
     */
    function strategyCount() external view returns (uint256) {
        return strategies.length;
    }

    /**
     * @dev Ensure vault has enough liquid assets, pulling from strategies if needed
     */
    function _ensureLiquidity(uint256 amount) internal {
        uint256 idle = asset.balanceOf(address(this));
        if (idle >= amount) return;

        uint256 deficit = amount - idle;
        for (uint256 i = 0; i < strategies.length && deficit > 0; i++) {
            if (!strategyInfo[strategies[i]].active) continue;
            uint256 available = BaseStrategy(strategies[i]).estimatedTotalAssets();
            uint256 pull = deficit > available ? available : deficit;
            if (pull > 0) {
                BaseStrategy(strategies[i]).withdraw(pull);
                deficit -= pull;
            }
        }
    }

    /**
     * @dev Deploy idle vault assets to strategies based on allocation
     */
    function _deployToStrategies() internal {
        uint256 idle = asset.balanceOf(address(this));
        if (idle == 0 || totalAllocation == 0) return;

        for (uint256 i = 0; i < strategies.length; i++) {
            address strat = strategies[i];
            if (!strategyInfo[strat].active) continue;

            uint256 amount = (idle * strategyInfo[strat].allocation) / totalAllocation;
            if (amount > 0) {
                asset.safeTransfer(strat, amount);
                BaseStrategy(strat).deposit();
            }
        }
    }
}
