// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./QUSDToken.sol";
import "./PriceFeed.sol";

/**
 * @title CDPVault
 * @notice Collateralized Debt Position vault — lock QFC (native) to mint qUSD stablecoin.
 * @dev Minimum collateral ratio: 150%. Liquidation threshold: 130%. Stability fee: 2% annual.
 */
contract CDPVault is ReentrancyGuard, Ownable {
    QUSDToken public immutable qusd;
    PriceFeed public immutable priceFeed;

    /// @notice Minimum collateral ratio to mint (150% = 15000)
    uint256 public constant MIN_COLLATERAL_RATIO = 15000;

    /// @notice Liquidation threshold (130% = 13000)
    uint256 public constant LIQUIDATION_THRESHOLD = 13000;

    /// @notice Liquidation penalty awarded to liquidator (10% = 1000)
    uint256 public constant LIQUIDATION_PENALTY = 1000;

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Annual stability fee in basis points (2% = 200)
    uint256 public constant STABILITY_FEE_RATE = 200;

    /// @notice Seconds per year (365.25 days)
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;

    struct Position {
        uint256 collateral;      // QFC deposited (wei)
        uint256 debt;            // qUSD principal owed
        uint256 lastFeeUpdate;   // timestamp of last fee accrual
        uint256 accruedFees;     // accumulated stability fees
    }

    mapping(address => Position) public positions;

    error ZeroAmount();
    error InsufficientCollateral();
    error BelowMinCollateralRatio();
    error NotLiquidatable();
    error TransferFailed();
    error NoDebt();
    error ExcessRepayment();

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event QUSDMinted(address indexed user, uint256 amount);
    event QUSDBurned(address indexed user, uint256 amount);
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );
    event FeesAccrued(address indexed user, uint256 feeAmount);

    constructor(address _qusd, address _priceFeed) Ownable(msg.sender) {
        qusd = QUSDToken(_qusd);
        priceFeed = PriceFeed(_priceFeed);
    }

    /**
     * @notice Deposit QFC as collateral
     */
    function depositCollateral() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        _accrueStabilityFee(msg.sender);
        positions[msg.sender].collateral += msg.value;
        emit CollateralDeposited(msg.sender, msg.value);
    }

    /**
     * @notice Mint qUSD against deposited collateral
     * @param amount Amount of qUSD to mint
     */
    function mintQUSD(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrueStabilityFee(msg.sender);
        Position storage pos = positions[msg.sender];
        pos.debt += amount;

        if (pos.lastFeeUpdate == 0) {
            pos.lastFeeUpdate = block.timestamp;
        }

        uint256 ratio = _calculateCollateralRatio(pos.collateral, pos.debt + pos.accruedFees);
        if (ratio < MIN_COLLATERAL_RATIO) revert BelowMinCollateralRatio();

        qusd.mint(msg.sender, amount);
        emit QUSDMinted(msg.sender, amount);
    }

    /**
     * @notice Repay qUSD debt
     * @param amount Amount of qUSD to repay
     */
    function burnQUSD(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrueStabilityFee(msg.sender);
        Position storage pos = positions[msg.sender];

        uint256 totalOwed = pos.debt + pos.accruedFees;
        if (totalOwed == 0) revert NoDebt();
        if (amount > totalOwed) revert ExcessRepayment();

        // Pay off accrued fees first, then principal
        if (amount <= pos.accruedFees) {
            pos.accruedFees -= amount;
        } else {
            uint256 remainder = amount - pos.accruedFees;
            pos.accruedFees = 0;
            pos.debt -= remainder;
        }

        qusd.burnFrom(msg.sender, amount);
        emit QUSDBurned(msg.sender, amount);
    }

    /**
     * @notice Withdraw collateral if collateral ratio remains safe
     * @param amount Amount of QFC to withdraw (wei)
     */
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrueStabilityFee(msg.sender);
        Position storage pos = positions[msg.sender];

        if (amount > pos.collateral) revert InsufficientCollateral();

        uint256 newCollateral = pos.collateral - amount;
        uint256 totalDebt = pos.debt + pos.accruedFees;

        // If there's outstanding debt, ensure ratio stays above minimum
        if (totalDebt > 0) {
            uint256 ratio = _calculateCollateralRatio(newCollateral, totalDebt);
            if (ratio < MIN_COLLATERAL_RATIO) revert BelowMinCollateralRatio();
        }

        pos.collateral = newCollateral;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit CollateralWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Liquidate an undercollateralized position
     * @param user Address of the position to liquidate
     */
    function liquidate(address user) external nonReentrant {
        _accrueStabilityFee(user);
        Position storage pos = positions[user];

        uint256 totalDebt = pos.debt + pos.accruedFees;
        if (totalDebt == 0) revert NoDebt();

        uint256 ratio = _calculateCollateralRatio(pos.collateral, totalDebt);
        if (ratio >= LIQUIDATION_THRESHOLD) revert NotLiquidatable();

        uint256 collateralToSeize = pos.collateral;
        uint256 debtToRepay = totalDebt;

        // Clear the position
        pos.collateral = 0;
        pos.debt = 0;
        pos.accruedFees = 0;

        // Liquidator repays the debt
        qusd.burnFrom(msg.sender, debtToRepay);

        // Transfer collateral + penalty to liquidator
        (bool success, ) = msg.sender.call{value: collateralToSeize}("");
        if (!success) revert TransferFailed();

        emit Liquidated(user, msg.sender, debtToRepay, collateralToSeize);
    }

    /**
     * @notice Get the collateral ratio of a position
     * @param user Address to check
     * @return ratio Collateral ratio in basis points (15000 = 150%)
     */
    function getCollateralRatio(address user) external view returns (uint256 ratio) {
        Position memory pos = positions[user];
        uint256 pendingFees = _pendingStabilityFee(pos);
        uint256 totalDebt = pos.debt + pos.accruedFees + pendingFees;
        if (totalDebt == 0) return type(uint256).max;
        return _calculateCollateralRatio(pos.collateral, totalDebt);
    }

    /**
     * @notice Get total debt including accrued fees for a user
     * @param user Address to check
     * @return Total debt (principal + accrued fees + pending fees)
     */
    function getTotalDebt(address user) external view returns (uint256) {
        Position memory pos = positions[user];
        return pos.debt + pos.accruedFees + _pendingStabilityFee(pos);
    }

    // --- Internal ---

    function _accrueStabilityFee(address user) internal {
        Position storage pos = positions[user];
        if (pos.debt > 0 && pos.lastFeeUpdate > 0) {
            uint256 fee = _pendingStabilityFee(pos);
            if (fee > 0) {
                pos.accruedFees += fee;
                emit FeesAccrued(user, fee);
            }
        }
        pos.lastFeeUpdate = block.timestamp;
    }

    function _pendingStabilityFee(Position memory pos) internal view returns (uint256) {
        if (pos.debt == 0 || pos.lastFeeUpdate == 0) return 0;
        uint256 elapsed = block.timestamp - pos.lastFeeUpdate;
        return (pos.debt * STABILITY_FEE_RATE * elapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
    }

    function _calculateCollateralRatio(uint256 collateral, uint256 debt) internal view returns (uint256) {
        if (debt == 0) return type(uint256).max;
        (uint256 qfcPrice, , ) = priceFeed.getLatestPrice();
        // collateral is in wei (18 decimals), price has 8 decimals
        // collateralValue = collateral * qfcPrice / 1e8 (in 18-decimal USD)
        // ratio = collateralValue * BASIS_POINTS / debt
        uint256 collateralValue = (collateral * qfcPrice) / 1e8;
        return (collateralValue * BASIS_POINTS) / debt;
    }

    receive() external payable {
        positions[msg.sender].collateral += msg.value;
        emit CollateralDeposited(msg.sender, msg.value);
    }
}
