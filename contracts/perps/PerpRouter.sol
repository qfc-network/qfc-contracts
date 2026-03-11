// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./PositionManager.sol";
import "./LiquidityPool.sol";
import "./FundingRate.sol";

/**
 * @title PerpRouter
 * @dev User-facing entry point for the perpetual futures protocol.
 *      Handles fee collection (0.1% open + 0.1% close) and delegates
 *      position management to PositionManager.
 */
contract PerpRouter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable qusd;
    PositionManager public immutable positionManager;
    LiquidityPool public immutable pool;
    FundingRate public fundingRate;

    /// @dev Fee rate: 0.1% = 10 basis points
    uint256 public constant OPEN_FEE_BPS = 10;
    uint256 public constant CLOSE_FEE_BPS = 10;
    uint256 public constant BASIS_POINTS = 10000;

    /// @dev Fee split: 60% to LP, 40% to protocol
    uint256 public constant LP_FEE_SHARE = 6000;

    /// @dev Protocol fee recipient
    address public protocolFeeRecipient;
    uint256 public protocolFeesCollected;

    event LongOpened(uint256 indexed positionId, address indexed trader, string asset, uint256 size);
    event ShortOpened(uint256 indexed positionId, address indexed trader, string asset, uint256 size);
    event PositionClosed(uint256 indexed positionId, int256 pnl);
    event FeesCollected(uint256 lpFee, uint256 protocolFee);

    error DeadlineExpired();
    error MinPnLNotMet();
    error ZeroAddress();

    constructor(
        address _qusd,
        address _positionManager,
        address _pool,
        address _protocolFeeRecipient
    ) Ownable(msg.sender) {
        qusd = IERC20(_qusd);
        positionManager = PositionManager(_positionManager);
        pool = LiquidityPool(_pool);
        protocolFeeRecipient = _protocolFeeRecipient;
    }

    /**
     * @dev Set the FundingRate contract.
     * @param _fundingRate Address of the FundingRate contract
     */
    function setFundingRate(address _fundingRate) external onlyOwner {
        fundingRate = FundingRate(_fundingRate);
    }

    /**
     * @dev Set the protocol fee recipient.
     * @param _recipient New fee recipient address
     */
    function setProtocolFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = _recipient;
    }

    /**
     * @dev Open a long position.
     * @param asset Asset symbol
     * @param sizeUSD Position size in USD (18 decimals)
     * @param maxCollateral Maximum collateral willing to deposit
     * @param deadline Transaction deadline
     * @return positionId The new position ID
     */
    function openLong(
        string calldata asset,
        uint256 sizeUSD,
        uint256 maxCollateral,
        uint256 deadline
    ) external nonReentrant returns (uint256 positionId) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        positionId = _openPosition(asset, true, sizeUSD, maxCollateral);
        emit LongOpened(positionId, msg.sender, asset, sizeUSD);
    }

    /**
     * @dev Open a short position.
     * @param asset Asset symbol
     * @param sizeUSD Position size in USD (18 decimals)
     * @param maxCollateral Maximum collateral willing to deposit
     * @param deadline Transaction deadline
     * @return positionId The new position ID
     */
    function openShort(
        string calldata asset,
        uint256 sizeUSD,
        uint256 maxCollateral,
        uint256 deadline
    ) external nonReentrant returns (uint256 positionId) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        positionId = _openPosition(asset, false, sizeUSD, maxCollateral);
        emit ShortOpened(positionId, msg.sender, asset, sizeUSD);
    }

    /**
     * @dev Close a position.
     * @param positionId Position to close
     * @param minPnL Minimum acceptable PnL (for slippage protection)
     * @return pnl Realized PnL
     */
    function close(uint256 positionId, int256 minPnL) external nonReentrant returns (int256 pnl) {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);

        // Close position — payout comes to router first
        pnl = positionManager.closePosition(positionId, msg.sender, address(this));
        if (pnl < minPnL) revert MinPnLNotMet();

        // Deduct closing fee from payout: 0.1% of size
        uint256 closeFee = (pos.size * CLOSE_FEE_BPS) / BASIS_POINTS;
        uint256 payout = qusd.balanceOf(address(this));
        if (closeFee > payout) closeFee = payout;
        _distributeFee(closeFee);

        // Forward remaining payout to trader
        uint256 remaining = qusd.balanceOf(address(this));
        if (remaining > 0) {
            qusd.safeTransfer(msg.sender, remaining);
        }

        emit PositionClosed(positionId, pnl);
    }

    // --- Internal ---

    function _openPosition(
        string calldata asset,
        bool isLong,
        uint256 sizeUSD,
        uint256 maxCollateral
    ) internal returns (uint256 positionId) {
        // Calculate collateral = maxCollateral (user decides leverage within limits)
        uint256 collateral = maxCollateral;

        // Calculate opening fee: 0.1% of size
        uint256 openFee = (sizeUSD * OPEN_FEE_BPS) / BASIS_POINTS;
        uint256 totalRequired = collateral + openFee;

        // Transfer QUSD from trader
        qusd.safeTransferFrom(msg.sender, address(this), totalRequired);

        // Distribute fee
        _distributeFee(openFee);

        // Transfer collateral to pool
        qusd.safeTransfer(address(pool), collateral);

        // Open position
        positionId = positionManager.openPosition(msg.sender, asset, isLong, sizeUSD, collateral);

        // Record funding snapshot
        if (address(fundingRate) != address(0)) {
            fundingRate.recordPositionFunding(positionId, asset);
        }
    }

    function _distributeFee(uint256 fee) internal {
        if (fee == 0) return;

        uint256 lpShare = (fee * LP_FEE_SHARE) / BASIS_POINTS;
        uint256 protocolShare = fee - lpShare;

        if (lpShare > 0) {
            qusd.safeTransfer(address(pool), lpShare);
            pool.accrueFees(lpShare);
        }

        if (protocolShare > 0) {
            qusd.safeTransfer(protocolFeeRecipient, protocolShare);
            protocolFeesCollected += protocolShare;
        }

        emit FeesCollected(lpShare, protocolShare);
    }
}
