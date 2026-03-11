// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./PositionManager.sol";

/**
 * @title FundingRate
 * @dev Calculates and applies funding rates for perpetual positions.
 *      Longs pay shorts when long OI > short OI, and vice versa.
 *      Funding rate = (longOI - shortOI) / totalOI * 0.01% per hour.
 */
contract FundingRate is Ownable {
    PositionManager public positionManager;

    /// @dev Accumulated funding rate per asset (scaled by PRECISION)
    mapping(bytes32 => int256) public cumulativeFundingRate;
    /// @dev Cumulative funding rate snapshot when a position was opened/last applied
    mapping(uint256 => int256) public positionFundingSnapshot;
    /// @dev Last funding update timestamp per asset
    mapping(bytes32 => uint256) public lastFundingUpdate;

    uint256 public constant FUNDING_RATE_BASE = 1e14; // 0.01% = 0.0001 = 1e14 / 1e18
    uint256 public constant FUNDING_INTERVAL = 1 hours;
    uint256 public constant PRECISION = 1e18;

    event FundingRateUpdated(string asset, int256 fundingRate, uint256 timestamp);
    event FundingApplied(uint256 indexed positionId, int256 fundingAmount);

    error TooEarlyForUpdate();
    error Unauthorized();

    constructor() Ownable(msg.sender) {}

    /**
     * @dev Set the PositionManager address.
     * @param _positionManager Address of the PositionManager
     */
    function setPositionManager(address _positionManager) external onlyOwner {
        positionManager = PositionManager(_positionManager);
    }

    /**
     * @dev Update the cumulative funding rate for an asset. Called by keeper hourly.
     * @param asset Asset symbol (e.g. "QFC")
     */
    function updateFundingRate(string calldata asset) external {
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        uint256 lastUpdate = lastFundingUpdate[assetKey];

        if (lastUpdate != 0 && block.timestamp < lastUpdate + FUNDING_INTERVAL) {
            revert TooEarlyForUpdate();
        }

        (uint256 longOI, uint256 shortOI) = positionManager.getOpenInterest(asset);
        uint256 totalOI = longOI + shortOI;

        int256 rate = 0;
        if (totalOI > 0) {
            // rate = (longOI - shortOI) / totalOI * 0.01%
            rate = (int256(longOI) - int256(shortOI)) * int256(FUNDING_RATE_BASE) / int256(totalOI);
        }

        // Account for elapsed periods
        uint256 periods = 1;
        if (lastUpdate > 0 && block.timestamp > lastUpdate) {
            periods = (block.timestamp - lastUpdate) / FUNDING_INTERVAL;
            if (periods == 0) periods = 1;
        }

        cumulativeFundingRate[assetKey] += rate * int256(periods);
        lastFundingUpdate[assetKey] = block.timestamp;

        emit FundingRateUpdated(asset, rate, block.timestamp);
    }

    /**
     * @dev Record the funding rate snapshot for a newly opened position.
     * @param positionId The position ID
     * @param asset The asset symbol
     */
    function recordPositionFunding(uint256 positionId, string calldata asset) external {
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        positionFundingSnapshot[positionId] = cumulativeFundingRate[assetKey];
    }

    /**
     * @dev Calculate pending funding for a position.
     * @param positionId The position ID
     * @return funding Signed funding amount (positive = position receives, negative = position pays)
     */
    function calculateFunding(uint256 positionId) external view returns (int256 funding) {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        if (!pos.isOpen) return 0;

        bytes32 assetKey = keccak256(abi.encodePacked(pos.asset));
        int256 rateDelta = cumulativeFundingRate[assetKey] - positionFundingSnapshot[positionId];

        // Funding amount = rateDelta * size / PRECISION
        // Longs pay when rate > 0, shorts pay when rate < 0
        funding = (rateDelta * int256(pos.size)) / int256(PRECISION);
        if (pos.isLong) {
            funding = -funding; // Longs pay positive funding
        }
    }

    /**
     * @dev Get the current funding rate for an asset.
     * @param asset Asset symbol
     * @return rate Current hourly funding rate (signed, scaled by PRECISION)
     */
    function getCurrentFundingRate(string calldata asset) external view returns (int256 rate) {
        (uint256 longOI, uint256 shortOI) = positionManager.getOpenInterest(asset);
        uint256 totalOI = longOI + shortOI;
        if (totalOI == 0) return 0;
        rate = (int256(longOI) - int256(shortOI)) * int256(FUNDING_RATE_BASE) / int256(totalOI);
    }
}
