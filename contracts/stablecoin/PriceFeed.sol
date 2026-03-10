// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PriceFeed
 * @notice Simple oracle for the QFC/USD price. Owner can update the price.
 * @dev Returns price with 8 decimals (e.g., 1.00 USD = 100_000_000).
 */
contract PriceFeed is Ownable {
    /// @notice QFC/USD price with 8 decimals
    uint256 public price;

    /// @notice Timestamp of the last price update
    uint256 public updatedAt;

    /// @notice Number of decimals in the price
    uint8 public constant DECIMALS = 8;

    error PriceNotSet();
    error InvalidPrice();
    error StalePrice();

    event PriceUpdated(uint256 oldPrice, uint256 newPrice, uint256 timestamp);

    constructor(uint256 _initialPrice) Ownable(msg.sender) {
        if (_initialPrice == 0) revert InvalidPrice();
        price = _initialPrice;
        updatedAt = block.timestamp;
        emit PriceUpdated(0, _initialPrice, block.timestamp);
    }

    /**
     * @notice Update the QFC/USD price
     * @param _price New price with 8 decimals
     */
    function setPrice(uint256 _price) external onlyOwner {
        if (_price == 0) revert InvalidPrice();
        uint256 oldPrice = price;
        price = _price;
        updatedAt = block.timestamp;
        emit PriceUpdated(oldPrice, _price, block.timestamp);
    }

    /**
     * @notice Get the latest QFC/USD price
     * @return _price The current price with 8 decimals
     * @return _updatedAt Timestamp of the last update
     * @return _decimals Number of decimals
     */
    function getLatestPrice() external view returns (uint256 _price, uint256 _updatedAt, uint8 _decimals) {
        if (price == 0) revert PriceNotSet();
        return (price, updatedAt, DECIMALS);
    }
}
