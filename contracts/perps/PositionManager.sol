// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./PriceOracle.sol";
import "./LiquidityPool.sol";
import "./FundingRate.sol";

/**
 * @title PositionManager
 * @dev Manages perpetual futures positions: open, close, liquidate.
 *      Supports long and short positions with up to 10x leverage.
 */
contract PositionManager is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    struct Position {
        address trader;
        string asset;
        bool isLong;
        uint256 size;       // position size in USD (18 decimals)
        uint256 collateral; // collateral in USD (18 decimals)
        uint256 entryPrice; // entry price (18 decimals)
        uint256 openTime;
        bool isOpen;
    }

    IERC20 public immutable qusd;
    PriceOracle public immutable oracle;
    LiquidityPool public pool;
    FundingRate public fundingRate;
    address public router;

    uint256 public nextPositionId;
    mapping(uint256 => Position) public positions;

    /// @dev Open interest tracking per asset
    mapping(bytes32 => uint256) public longOpenInterest;
    mapping(bytes32 => uint256) public shortOpenInterest;

    uint256 public constant MAX_LEVERAGE = 10;
    uint256 public constant LIQUIDATION_THRESHOLD = 500; // 5% in basis points
    uint256 public constant LIQUIDATION_BONUS = 50;      // 0.5% in basis points
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PRECISION = 1e18;

    event PositionOpened(
        uint256 indexed positionId,
        address indexed trader,
        string asset,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 entryPrice
    );
    event PositionClosed(uint256 indexed positionId, int256 pnl, uint256 exitPrice);
    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 bonus);

    error PositionNotOpen();
    error ExceedsMaxLeverage();
    error NotLiquidatable();
    error ZeroSize();
    error ZeroCollateral();
    error Unauthorized();
    error NotPositionOwner();

    modifier onlyRouter() {
        if (msg.sender != router && msg.sender != owner()) revert Unauthorized();
        _;
    }

    constructor(address _qusd, address _oracle) Ownable(msg.sender) {
        qusd = IERC20(_qusd);
        oracle = PriceOracle(_oracle);
    }

    /**
     * @dev Set the LiquidityPool address.
     * @param _pool Address of the LiquidityPool
     */
    function setPool(address _pool) external onlyOwner {
        pool = LiquidityPool(_pool);
    }

    /**
     * @dev Set the FundingRate contract address.
     * @param _fundingRate Address of the FundingRate contract
     */
    function setFundingRate(address _fundingRate) external onlyOwner {
        fundingRate = FundingRate(_fundingRate);
    }

    /**
     * @dev Set the PerpRouter address.
     * @param _router Address of the PerpRouter
     */
    function setRouter(address _router) external onlyOwner {
        router = _router;
    }

    /**
     * @dev Open a new perpetual position.
     * @param trader Address of the trader
     * @param asset Asset symbol (e.g. "QFC")
     * @param isLong True for long, false for short
     * @param sizeUSD Position size in USD (18 decimals)
     * @param collateralUSD Collateral amount in USD (18 decimals)
     * @return positionId The ID of the newly opened position
     */
    function openPosition(
        address trader,
        string calldata asset,
        bool isLong,
        uint256 sizeUSD,
        uint256 collateralUSD
    ) external onlyRouter nonReentrant returns (uint256 positionId) {
        if (sizeUSD == 0) revert ZeroSize();
        if (collateralUSD == 0) revert ZeroCollateral();

        // Check leverage: size / collateral <= MAX_LEVERAGE
        if (sizeUSD > collateralUSD * MAX_LEVERAGE) revert ExceedsMaxLeverage();

        uint256 entryPrice = oracle.getPrice(asset);

        positionId = nextPositionId++;
        positions[positionId] = Position({
            trader: trader,
            asset: asset,
            isLong: isLong,
            size: sizeUSD,
            collateral: collateralUSD,
            entryPrice: entryPrice,
            openTime: block.timestamp,
            isOpen: true
        });

        // Update open interest
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        if (isLong) {
            longOpenInterest[assetKey] += sizeUSD;
        } else {
            shortOpenInterest[assetKey] += sizeUSD;
        }

        emit PositionOpened(positionId, trader, asset, isLong, sizeUSD, collateralUSD, entryPrice);
    }

    /**
     * @dev Close an open position and settle PnL.
     * @param positionId The position to close
     * @param caller The address requesting the close
     * @return pnl The realized PnL (positive = profit)
     */
    function closePosition(uint256 positionId, address caller, address payoutRecipient) external onlyRouter nonReentrant returns (int256 pnl) {
        Position storage pos = positions[positionId];
        if (!pos.isOpen) revert PositionNotOpen();
        if (pos.trader != caller) revert NotPositionOwner();

        // Apply any pending funding
        if (address(fundingRate) != address(0)) {
            int256 funding = fundingRate.calculateFunding(positionId);
            pos.collateral = _applyFundingToCollateral(pos.collateral, funding);
        }

        uint256 exitPrice = oracle.getPrice(pos.asset);
        pnl = _calculatePnL(pos, exitPrice);

        _settlePosition(positionId, pos, pnl, exitPrice, payoutRecipient);
    }

    /**
     * @dev Liquidate an unhealthy position.
     * @param positionId The position to liquidate
     */
    function liquidatePosition(uint256 positionId) external nonReentrant {
        Position storage pos = positions[positionId];
        if (!pos.isOpen) revert PositionNotOpen();

        // Apply any pending funding
        if (address(fundingRate) != address(0)) {
            int256 funding = fundingRate.calculateFunding(positionId);
            pos.collateral = _applyFundingToCollateral(pos.collateral, funding);
        }

        uint256 currentPrice = oracle.getPrice(pos.asset);
        int256 pnl = _calculatePnL(pos, currentPrice);

        // Health = (collateral + unrealizedPnL) / size
        int256 effectiveCollateral = int256(pos.collateral) + pnl;
        if (effectiveCollateral * int256(BASIS_POINTS) >= int256(pos.size) * int256(LIQUIDATION_THRESHOLD)) {
            revert NotLiquidatable();
        }

        // Liquidator bonus: 0.5% of position size
        uint256 bonus = (pos.size * LIQUIDATION_BONUS) / BASIS_POINTS;

        // Update open interest
        _reduceOpenInterest(pos);

        pos.isOpen = false;

        // Settle: pool absorbs remaining collateral, liquidator gets bonus
        pool.settlePnL(-int256(pos.collateral)); // Pool gains the original collateral impact

        if (bonus > 0 && bonus <= qusd.balanceOf(address(pool))) {
            pool.transferOut(msg.sender, bonus);
        }

        emit PositionLiquidated(positionId, msg.sender, bonus);
        emit PositionClosed(positionId, pnl, currentPrice);
    }

    /**
     * @dev Get a position by ID.
     * @param positionId The position ID
     * @return Position struct
     */
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    /**
     * @dev Calculate unrealized PnL for a position.
     * @param positionId The position ID
     * @return pnl Unrealized PnL (signed)
     */
    function getUnrealizedPnL(uint256 positionId) external view returns (int256 pnl) {
        Position storage pos = positions[positionId];
        if (!pos.isOpen) return 0;
        uint256 currentPrice = oracle.getPrice(pos.asset);
        pnl = _calculatePnL(pos, currentPrice);
    }

    /**
     * @dev Get open interest for an asset.
     * @param asset Asset symbol
     * @return longOI Long open interest
     * @return shortOI Short open interest
     */
    function getOpenInterest(string calldata asset) external view returns (uint256 longOI, uint256 shortOI) {
        bytes32 key = keccak256(abi.encodePacked(asset));
        longOI = longOpenInterest[key];
        shortOI = shortOpenInterest[key];
    }

    // --- Internal ---

    function _calculatePnL(Position storage pos, uint256 currentPrice) internal view returns (int256) {
        // PnL = (currentPrice - entryPrice) / entryPrice * size * (isLong ? 1 : -1)
        int256 priceDelta = int256(currentPrice) - int256(pos.entryPrice);
        int256 pnl = (priceDelta * int256(pos.size)) / int256(pos.entryPrice);
        return pos.isLong ? pnl : -pnl;
    }

    function _settlePosition(
        uint256 positionId,
        Position storage pos,
        int256 pnl,
        uint256 exitPrice,
        address recipient
    ) internal {
        _reduceOpenInterest(pos);
        pos.isOpen = false;

        // Settle with pool
        pool.settlePnL(pnl);

        if (pnl >= 0) {
            // Trader profit: return collateral + profit from pool
            uint256 payout = pos.collateral + uint256(pnl);
            pool.transferOut(recipient, payout);
        } else {
            // Trader loss: return collateral - loss
            uint256 loss = uint256(-pnl);
            if (loss < pos.collateral) {
                pool.transferOut(recipient, pos.collateral - loss);
            }
            // If loss >= collateral, trader gets nothing (pool keeps it)
        }

        emit PositionClosed(positionId, pnl, exitPrice);
    }

    function _reduceOpenInterest(Position storage pos) internal {
        bytes32 assetKey = keccak256(abi.encodePacked(pos.asset));
        if (pos.isLong) {
            longOpenInterest[assetKey] -= pos.size;
        } else {
            shortOpenInterest[assetKey] -= pos.size;
        }
    }

    function _applyFundingToCollateral(uint256 collateral, int256 funding) internal pure returns (uint256) {
        if (funding >= 0) {
            return collateral + uint256(funding);
        } else {
            uint256 deduction = uint256(-funding);
            return collateral > deduction ? collateral - deduction : 0;
        }
    }
}
