// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Vault
 * @dev ERC4626-like vault for yield generation
 *
 * Features:
 * - Deposit tokens to receive vault shares
 * - Withdraw shares to get tokens + yield
 * - Configurable management fee
 * - Strategy integration ready
 */
contract Vault is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;

    uint256 public totalAssets;
    uint256 public managementFee; // In basis points (100 = 1%)
    uint256 public lastHarvestTime;

    address public strategy;

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event StrategyUpdated(address oldStrategy, address newStrategy);
    event Harvested(uint256 profit, uint256 fee);

    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        uint256 _managementFee
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        asset = IERC20(_asset);
        managementFee = _managementFee;
        lastHarvestTime = block.timestamp;
    }

    /**
     * @dev Deposit assets and receive shares
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        require(assets > 0, "Invalid deposit amount");

        shares = previewDeposit(assets);
        require(shares > 0, "Zero shares");

        asset.safeTransferFrom(msg.sender, address(this), assets);
        totalAssets += assets;

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @dev Withdraw assets by burning shares
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
        totalAssets -= assets;

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

        assets = previewRedeem(shares);

        _burn(owner, shares);
        totalAssets -= assets;

        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @dev Preview deposit amount for given assets
     */
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    /**
     * @dev Preview shares needed for withdrawal
     */
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        return (assets * supply + totalAssets - 1) / totalAssets;
    }

    /**
     * @dev Preview assets for redeeming shares
     */
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /**
     * @dev Convert assets to shares
     */
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        return (assets * supply) / totalAssets;
    }

    /**
     * @dev Convert shares to assets
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return (shares * totalAssets) / supply;
    }

    /**
     * @dev Get share price in terms of assets (scaled by 1e18)
     */
    function sharePrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return (totalAssets * 1e18) / supply;
    }

    /**
     * @dev Report profit from strategy
     * @param profit Amount of profit generated
     */
    function harvest(uint256 profit) external {
        require(msg.sender == strategy || msg.sender == owner(), "Unauthorized");

        if (profit > 0) {
            // Take management fee
            uint256 fee = (profit * managementFee) / 10000;
            uint256 netProfit = profit - fee;

            totalAssets += netProfit;

            if (fee > 0) {
                asset.safeTransfer(owner(), fee);
            }

            emit Harvested(profit, fee);
        }

        lastHarvestTime = block.timestamp;
    }

    /**
     * @dev Set strategy address
     * @param _strategy New strategy address
     */
    function setStrategy(address _strategy) external onlyOwner {
        emit StrategyUpdated(strategy, _strategy);
        strategy = _strategy;
    }

    /**
     * @dev Set management fee
     * @param _fee New fee in basis points
     */
    function setManagementFee(uint256 _fee) external onlyOwner {
        require(_fee <= 1000, "Fee too high"); // Max 10%
        managementFee = _fee;
    }

    /**
     * @dev Deploy assets to strategy
     * @param amount Amount to deploy
     */
    function deployToStrategy(uint256 amount) external onlyOwner {
        require(strategy != address(0), "No strategy set");
        asset.safeTransfer(strategy, amount);
    }

    /**
     * @dev Max deposit amount
     */
    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @dev Max withdraw amount
     */
    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /**
     * @dev Max redeem amount
     */
    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }
}
