// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title InterestRateModel
 * @dev Jump rate model for the QFC Lending Protocol.
 *
 * Rate curve:
 *   - Base rate: 2% APY
 *   - Below kink (80% utilization): linear ramp to ~20% APY
 *   - Above kink: steep ramp to 100% APY at full utilization
 *
 * All rates are stored as per-second rates scaled by 1e18 (RAY precision).
 */
contract InterestRateModel is Ownable {
    /// @dev Precision constant (1e18)
    uint256 public constant PRECISION = 1e18;

    /// @dev Seconds per year (365.25 days)
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;

    /// @notice Base borrow rate per year (2% = 0.02e18)
    uint256 public baseRatePerYear;

    /// @notice Borrow rate slope below the kink (per year)
    uint256 public multiplierPerYear;

    /// @notice Borrow rate slope above the kink (per year)
    uint256 public jumpMultiplierPerYear;

    /// @notice Utilization threshold where the jump rate kicks in (80% = 0.8e18)
    uint256 public kink;

    event RateModelUpdated(
        uint256 baseRatePerYear,
        uint256 multiplierPerYear,
        uint256 jumpMultiplierPerYear,
        uint256 kink
    );

    /**
     * @param _baseRatePerYear Base rate per year (e.g. 0.02e18 = 2%)
     * @param _multiplierPerYear Slope below kink per year
     * @param _jumpMultiplierPerYear Slope above kink per year
     * @param _kink Utilization threshold (e.g. 0.8e18 = 80%)
     */
    constructor(
        uint256 _baseRatePerYear,
        uint256 _multiplierPerYear,
        uint256 _jumpMultiplierPerYear,
        uint256 _kink
    ) Ownable(msg.sender) {
        baseRatePerYear = _baseRatePerYear;
        multiplierPerYear = _multiplierPerYear;
        jumpMultiplierPerYear = _jumpMultiplierPerYear;
        kink = _kink;

        emit RateModelUpdated(_baseRatePerYear, _multiplierPerYear, _jumpMultiplierPerYear, _kink);
    }

    /**
     * @notice Calculate utilization rate.
     * @param cash Total idle cash in the market
     * @param borrows Total outstanding borrows
     * @param reserves Total reserves
     * @return Utilization rate scaled by 1e18
     */
    function utilizationRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public pure returns (uint256) {
        if (borrows == 0) return 0;
        uint256 total = cash + borrows - reserves;
        if (total == 0) return 0;
        return (borrows * PRECISION) / total;
    }

    /**
     * @notice Calculate the current borrow rate per second.
     * @param cash Total idle cash
     * @param borrows Total outstanding borrows
     * @param reserves Total reserves
     * @return Borrow rate per second (scaled by 1e18)
     */
    function getBorrowRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public view returns (uint256) {
        uint256 util = utilizationRate(cash, borrows, reserves);
        uint256 annualRate;

        if (util <= kink) {
            // base + util * multiplier
            annualRate = baseRatePerYear + (util * multiplierPerYear) / PRECISION;
        } else {
            // base + kink * multiplier + (util - kink) * jumpMultiplier
            uint256 normalRate = baseRatePerYear + (kink * multiplierPerYear) / PRECISION;
            uint256 excessUtil = util - kink;
            annualRate = normalRate + (excessUtil * jumpMultiplierPerYear) / PRECISION;
        }

        return annualRate / SECONDS_PER_YEAR;
    }

    /**
     * @notice Calculate the current supply rate per second.
     * @param cash Total idle cash
     * @param borrows Total outstanding borrows
     * @param reserves Total reserves
     * @param reserveFactor Fraction of interest that goes to reserves (scaled by 1e18)
     * @return Supply rate per second (scaled by 1e18)
     */
    function getSupplyRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 reserveFactor
    ) external view returns (uint256) {
        uint256 oneMinusReserveFactor = PRECISION - reserveFactor;
        uint256 borrowRate = getBorrowRate(cash, borrows, reserves);
        uint256 rateToPool = (borrowRate * oneMinusReserveFactor) / PRECISION;
        uint256 util = utilizationRate(cash, borrows, reserves);
        return (util * rateToPool) / PRECISION;
    }

    /**
     * @notice Update rate model parameters. Only callable by owner.
     * @param _baseRatePerYear New base rate per year
     * @param _multiplierPerYear New multiplier per year
     * @param _jumpMultiplierPerYear New jump multiplier per year
     * @param _kink New kink utilization
     */
    function updateRateModel(
        uint256 _baseRatePerYear,
        uint256 _multiplierPerYear,
        uint256 _jumpMultiplierPerYear,
        uint256 _kink
    ) external onlyOwner {
        require(_kink <= PRECISION, "InterestRateModel: kink > 100%");

        baseRatePerYear = _baseRatePerYear;
        multiplierPerYear = _multiplierPerYear;
        jumpMultiplierPerYear = _jumpMultiplierPerYear;
        kink = _kink;

        emit RateModelUpdated(_baseRatePerYear, _multiplierPerYear, _jumpMultiplierPerYear, _kink);
    }
}
