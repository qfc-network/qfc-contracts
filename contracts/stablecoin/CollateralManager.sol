// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./QUSDToken.sol";

/**
 * @title CollateralManager
 * @notice Multi-collateral CDP vault for qUSD. Supports ERC-20 collateral
 *         (wBTC, wETH, wstETH, etc.) with per-asset risk parameters.
 *
 *  Each collateral type has:
 *    - Independent min collateral ratio & liquidation threshold
 *    - Per-asset and global debt ceilings
 *    - Configurable stability fee
 *    - Independent price feed
 *
 * @dev The original CDPVault handles native QFC. This contract handles
 *      ERC-20 collateral types. Both share the same QUSDToken.
 */
contract CollateralManager is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    QUSDToken public immutable qusd;

    // --- Collateral type configuration ---

    struct CollateralType {
        bool active;
        IERC20 token;
        address priceFeed;         // Must implement getLatestPrice() → (uint256, uint256, uint8)
        uint8 tokenDecimals;
        uint256 minCollateralRatio; // basis points (e.g. 15000 = 150%)
        uint256 liquidationThreshold; // basis points (e.g. 13000 = 130%)
        uint256 liquidationPenalty;   // basis points (e.g. 1000 = 10%)
        uint256 stabilityFeeRate;    // annual, basis points (e.g. 200 = 2%)
        uint256 debtCeiling;         // max qUSD for this collateral type
        uint256 totalDebt;           // current total qUSD minted
    }

    /// @notice Registered collateral types by token address
    mapping(address => CollateralType) public collateralTypes;
    address[] public collateralList;

    /// @notice Global debt ceiling across all collateral types
    uint256 public globalDebtCeiling;

    /// @notice Global total debt
    uint256 public globalTotalDebt;

    // --- Positions ---

    struct Position {
        uint256 collateral;      // Token amount deposited
        uint256 debt;            // qUSD principal owed
        uint256 lastFeeUpdate;
        uint256 accruedFees;
    }

    /// @notice user → collateral token → position
    mapping(address => mapping(address => Position)) public positions;

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;

    // --- Errors ---

    error CollateralNotActive();
    error CollateralAlreadyAdded();
    error ZeroAmount();
    error InsufficientCollateral();
    error BelowMinCollateralRatio();
    error NotLiquidatable();
    error NoDebt();
    error ExcessRepayment();
    error DebtCeilingExceeded();
    error GlobalDebtCeilingExceeded();
    error InvalidParameters();

    // --- Events ---

    event CollateralAdded(address indexed token, uint256 minRatio, uint256 liqThreshold, uint256 debtCeiling);
    event CollateralUpdated(address indexed token);
    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event Minted(address indexed user, address indexed token, uint256 amount);
    event Burned(address indexed user, address indexed token, uint256 amount);
    event Liquidated(
        address indexed user,
        address indexed token,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );
    event FeesAccrued(address indexed user, address indexed token, uint256 amount);

    constructor(address _qusd, uint256 _globalDebtCeiling) Ownable(msg.sender) {
        qusd = QUSDToken(_qusd);
        globalDebtCeiling = _globalDebtCeiling;
    }

    // =========================================================================
    // Collateral type management
    // =========================================================================

    function addCollateral(
        address _token,
        address _priceFeed,
        uint8 _tokenDecimals,
        uint256 _minCollateralRatio,
        uint256 _liquidationThreshold,
        uint256 _liquidationPenalty,
        uint256 _stabilityFeeRate,
        uint256 _debtCeiling
    ) external onlyOwner {
        if (collateralTypes[_token].active) revert CollateralAlreadyAdded();
        if (_minCollateralRatio <= BASIS_POINTS) revert InvalidParameters();
        if (_liquidationThreshold >= _minCollateralRatio) revert InvalidParameters();
        if (_liquidationThreshold <= BASIS_POINTS) revert InvalidParameters();

        collateralTypes[_token] = CollateralType({
            active: true,
            token: IERC20(_token),
            priceFeed: _priceFeed,
            tokenDecimals: _tokenDecimals,
            minCollateralRatio: _minCollateralRatio,
            liquidationThreshold: _liquidationThreshold,
            liquidationPenalty: _liquidationPenalty,
            stabilityFeeRate: _stabilityFeeRate,
            debtCeiling: _debtCeiling,
            totalDebt: 0
        });
        collateralList.push(_token);

        emit CollateralAdded(_token, _minCollateralRatio, _liquidationThreshold, _debtCeiling);
    }

    function updateCollateral(
        address _token,
        uint256 _minCollateralRatio,
        uint256 _liquidationThreshold,
        uint256 _liquidationPenalty,
        uint256 _stabilityFeeRate,
        uint256 _debtCeiling
    ) external onlyOwner {
        CollateralType storage ct = collateralTypes[_token];
        if (!ct.active) revert CollateralNotActive();

        ct.minCollateralRatio = _minCollateralRatio;
        ct.liquidationThreshold = _liquidationThreshold;
        ct.liquidationPenalty = _liquidationPenalty;
        ct.stabilityFeeRate = _stabilityFeeRate;
        ct.debtCeiling = _debtCeiling;

        emit CollateralUpdated(_token);
    }

    function setGlobalDebtCeiling(uint256 _ceiling) external onlyOwner {
        globalDebtCeiling = _ceiling;
    }

    // =========================================================================
    // CDP operations
    // =========================================================================

    function deposit(address _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        CollateralType storage ct = collateralTypes[_token];
        if (!ct.active) revert CollateralNotActive();

        _accrueStabilityFee(_token, msg.sender);

        ct.token.safeTransferFrom(msg.sender, address(this), _amount);
        positions[msg.sender][_token].collateral += _amount;

        emit Deposited(msg.sender, _token, _amount);
    }

    function mint(address _token, uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        CollateralType storage ct = collateralTypes[_token];
        if (!ct.active) revert CollateralNotActive();

        _accrueStabilityFee(_token, msg.sender);

        Position storage pos = positions[msg.sender][_token];
        pos.debt += _amount;

        if (pos.lastFeeUpdate == 0) {
            pos.lastFeeUpdate = block.timestamp;
        }

        // Check collateral ratio
        uint256 ratio = _calculateCollateralRatio(_token, pos.collateral, pos.debt + pos.accruedFees);
        if (ratio < ct.minCollateralRatio) revert BelowMinCollateralRatio();

        // Check debt ceilings
        if (ct.totalDebt + _amount > ct.debtCeiling) revert DebtCeilingExceeded();
        if (globalTotalDebt + _amount > globalDebtCeiling) revert GlobalDebtCeilingExceeded();

        ct.totalDebt += _amount;
        globalTotalDebt += _amount;

        qusd.mint(msg.sender, _amount);
        emit Minted(msg.sender, _token, _amount);
    }

    function burn(address _token, uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        CollateralType storage ct = collateralTypes[_token];
        _accrueStabilityFee(_token, msg.sender);

        Position storage pos = positions[msg.sender][_token];
        uint256 totalOwed = pos.debt + pos.accruedFees;
        if (totalOwed == 0) revert NoDebt();
        if (_amount > totalOwed) revert ExcessRepayment();

        // Pay fees first, then principal
        uint256 principalRepaid;
        if (_amount <= pos.accruedFees) {
            pos.accruedFees -= _amount;
        } else {
            principalRepaid = _amount - pos.accruedFees;
            pos.accruedFees = 0;
            pos.debt -= principalRepaid;
        }

        // Update debt tracking
        if (principalRepaid > 0) {
            ct.totalDebt = ct.totalDebt > principalRepaid ? ct.totalDebt - principalRepaid : 0;
            globalTotalDebt = globalTotalDebt > principalRepaid ? globalTotalDebt - principalRepaid : 0;
        }

        qusd.burnFrom(msg.sender, _amount);
        emit Burned(msg.sender, _token, _amount);
    }

    function withdraw(address _token, uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        _accrueStabilityFee(_token, msg.sender);

        Position storage pos = positions[msg.sender][_token];
        if (_amount > pos.collateral) revert InsufficientCollateral();

        uint256 newCollateral = pos.collateral - _amount;
        uint256 totalDebt = pos.debt + pos.accruedFees;

        if (totalDebt > 0) {
            uint256 ratio = _calculateCollateralRatio(_token, newCollateral, totalDebt);
            if (ratio < collateralTypes[_token].minCollateralRatio) revert BelowMinCollateralRatio();
        }

        pos.collateral = newCollateral;
        collateralTypes[_token].token.safeTransfer(msg.sender, _amount);

        emit Withdrawn(msg.sender, _token, _amount);
    }

    function liquidate(address _user, address _token) external nonReentrant {
        CollateralType storage ct = collateralTypes[_token];
        _accrueStabilityFee(_token, _user);

        Position storage pos = positions[_user][_token];
        uint256 totalDebt = pos.debt + pos.accruedFees;
        if (totalDebt == 0) revert NoDebt();

        uint256 ratio = _calculateCollateralRatio(_token, pos.collateral, totalDebt);
        if (ratio >= ct.liquidationThreshold) revert NotLiquidatable();

        uint256 collateralToSeize = pos.collateral;
        uint256 debtToRepay = totalDebt;

        // Update debt tracking
        if (pos.debt > 0) {
            ct.totalDebt = ct.totalDebt > pos.debt ? ct.totalDebt - pos.debt : 0;
            globalTotalDebt = globalTotalDebt > pos.debt ? globalTotalDebt - pos.debt : 0;
        }

        // Clear position
        pos.collateral = 0;
        pos.debt = 0;
        pos.accruedFees = 0;

        // Liquidator repays debt
        qusd.burnFrom(msg.sender, debtToRepay);

        // Transfer collateral to liquidator
        ct.token.safeTransfer(msg.sender, collateralToSeize);

        emit Liquidated(_user, _token, msg.sender, debtToRepay, collateralToSeize);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    function getCollateralRatio(address _user, address _token) external view returns (uint256) {
        Position memory pos = positions[_user][_token];
        uint256 pendingFees = _pendingStabilityFee(_token, pos);
        uint256 totalDebt = pos.debt + pos.accruedFees + pendingFees;
        if (totalDebt == 0) return type(uint256).max;
        return _calculateCollateralRatio(_token, pos.collateral, totalDebt);
    }

    function getTotalDebt(address _user, address _token) external view returns (uint256) {
        Position memory pos = positions[_user][_token];
        return pos.debt + pos.accruedFees + _pendingStabilityFee(_token, pos);
    }

    function getCollateralList() external view returns (address[] memory) {
        return collateralList;
    }

    function collateralCount() external view returns (uint256) {
        return collateralList.length;
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // =========================================================================
    // Internal
    // =========================================================================

    function _accrueStabilityFee(address _token, address _user) internal {
        Position storage pos = positions[_user][_token];
        if (pos.debt > 0 && pos.lastFeeUpdate > 0) {
            uint256 fee = _pendingStabilityFee(_token, pos);
            if (fee > 0) {
                pos.accruedFees += fee;
                emit FeesAccrued(_user, _token, fee);
            }
        }
        pos.lastFeeUpdate = block.timestamp;
    }

    function _pendingStabilityFee(address _token, Position memory pos) internal view returns (uint256) {
        if (pos.debt == 0 || pos.lastFeeUpdate == 0) return 0;
        uint256 rate = collateralTypes[_token].stabilityFeeRate;
        uint256 elapsed = block.timestamp - pos.lastFeeUpdate;
        return (pos.debt * rate * elapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
    }

    function _calculateCollateralRatio(
        address _token,
        uint256 _collateral,
        uint256 _debt
    ) internal view returns (uint256) {
        if (_debt == 0) return type(uint256).max;

        CollateralType memory ct = collateralTypes[_token];

        // Get price from feed (8 decimals)
        (uint256 tokenPrice,,) = IPriceFeed(ct.priceFeed).getLatestPrice();

        // Normalize collateral to 18 decimals, then to USD value
        uint256 collateral18 = _collateral;
        if (ct.tokenDecimals < 18) {
            collateral18 = _collateral * (10 ** (18 - ct.tokenDecimals));
        } else if (ct.tokenDecimals > 18) {
            collateral18 = _collateral / (10 ** (ct.tokenDecimals - 18));
        }

        uint256 collateralValue = (collateral18 * tokenPrice) / 1e8;
        return (collateralValue * BASIS_POINTS) / _debt;
    }
}

interface IPriceFeed {
    function getLatestPrice() external view returns (uint256 price, uint256 updatedAt, uint8 decimals);
}
