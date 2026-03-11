// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PriceOracle
 * @dev Mock price oracle for the QFC Lending Protocol.
 *
 * Prices are denominated in USD with 18 decimals (1 USD = 1e18).
 * In production this would be replaced by a Chainlink or similar oracle.
 */
contract PriceOracle is Ownable {
    /// @notice Asset address → price in USD (18 decimals)
    mapping(address => uint256) public prices;

    event PriceUpdated(address indexed asset, uint256 price);

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Set the USD price for an asset.
     * @param asset Token address
     * @param price Price in USD with 18 decimals
     */
    function setPrice(address asset, uint256 price) external onlyOwner {
        require(price > 0, "PriceOracle: price must be > 0");
        prices[asset] = price;
        emit PriceUpdated(asset, price);
    }

    /**
     * @notice Batch-set prices for multiple assets.
     * @param assets Array of token addresses
     * @param _prices Array of prices in USD (18 decimals)
     */
    function setPrices(address[] calldata assets, uint256[] calldata _prices) external onlyOwner {
        require(assets.length == _prices.length, "PriceOracle: length mismatch");
        for (uint256 i = 0; i < assets.length; i++) {
            require(_prices[i] > 0, "PriceOracle: price must be > 0");
            prices[assets[i]] = _prices[i];
            emit PriceUpdated(assets[i], _prices[i]);
        }
    }

    /**
     * @notice Get the USD price for an asset.
     * @param asset Token address
     * @return Price in USD with 18 decimals
     */
    function getPrice(address asset) external view returns (uint256) {
        uint256 price = prices[asset];
        require(price > 0, "PriceOracle: price not set");
        return price;
    }
}
