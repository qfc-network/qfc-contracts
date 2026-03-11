// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title PriceOracle
 * @dev Simple price oracle for perpetual futures. Owner or authorized relayers
 *      submit off-chain prices for supported assets.
 */
contract PriceOracle is AccessControl {
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    /// @dev asset symbol hash => price (18 decimals)
    mapping(bytes32 => uint256) private _prices;
    /// @dev asset symbol hash => last update timestamp
    mapping(bytes32 => uint256) private _timestamps;

    event PriceUpdated(string indexed asset, uint256 price, uint256 timestamp);

    error StalePrice(string asset);
    error ZeroPrice();
    error UnsupportedAsset(string asset);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RELAYER_ROLE, msg.sender);
    }

    /**
     * @dev Set the price for an asset. Only callable by relayers.
     * @param asset Asset symbol (e.g. "QFC", "TTK", "QDOGE")
     * @param price Price in 18-decimal format
     */
    function setPrice(string calldata asset, uint256 price) external onlyRole(RELAYER_ROLE) {
        if (price == 0) revert ZeroPrice();
        bytes32 key = keccak256(abi.encodePacked(asset));
        _prices[key] = price;
        _timestamps[key] = block.timestamp;
        emit PriceUpdated(asset, price, block.timestamp);
    }

    /**
     * @dev Batch-set prices for multiple assets.
     * @param assets Array of asset symbols
     * @param prices Array of prices (18 decimals)
     */
    function setPrices(string[] calldata assets, uint256[] calldata prices) external onlyRole(RELAYER_ROLE) {
        require(assets.length == prices.length, "Length mismatch");
        for (uint256 i = 0; i < assets.length; i++) {
            if (prices[i] == 0) revert ZeroPrice();
            bytes32 key = keccak256(abi.encodePacked(assets[i]));
            _prices[key] = prices[i];
            _timestamps[key] = block.timestamp;
            emit PriceUpdated(assets[i], prices[i], block.timestamp);
        }
    }

    /**
     * @dev Get the current price for an asset.
     * @param asset Asset symbol
     * @return price Price in 18-decimal format
     */
    function getPrice(string calldata asset) external view returns (uint256 price) {
        bytes32 key = keccak256(abi.encodePacked(asset));
        price = _prices[key];
        if (price == 0) revert UnsupportedAsset(asset);
    }

    /**
     * @dev Get price and last update timestamp.
     * @param asset Asset symbol
     * @return price Price in 18 decimals
     * @return timestamp Last update time
     */
    function getPriceWithTimestamp(string calldata asset) external view returns (uint256 price, uint256 timestamp) {
        bytes32 key = keccak256(abi.encodePacked(asset));
        price = _prices[key];
        if (price == 0) revert UnsupportedAsset(asset);
        timestamp = _timestamps[key];
    }
}
