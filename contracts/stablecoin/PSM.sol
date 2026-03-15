// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./QUSDToken.sol";

/**
 * @title PSM (Peg Stability Module)
 * @notice Allows 1:1 swaps between external stablecoins (USDC, USDT, DAI)
 *         and qUSD to maintain the peg.
 *
 *  - swapIn:  user sends stablecoin → receives qUSD (minus tin fee)
 *  - swapOut: user sends qUSD → receives stablecoin (minus tout fee)
 *
 * @dev Each supported gem (stablecoin) has its own debt ceiling to limit
 *      the share of any single backing asset. The PSM must be authorized
 *      as a vault on QUSDToken to mint/burn.
 */
contract PSM is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    QUSDToken public immutable qusd;

    // --- Gem (stablecoin) configuration ---

    struct GemInfo {
        bool active;           // Whether this gem is accepted
        uint8 decimals;        // Gem decimals (e.g. 6 for USDC, 18 for DAI)
        uint256 debtCeiling;   // Max qUSD mintable against this gem
        uint256 totalDebt;     // Current qUSD minted against this gem
        uint256 tin;           // Fee on swapIn (basis points, e.g. 10 = 0.1%)
        uint256 tout;          // Fee on swapOut (basis points)
    }

    mapping(address => GemInfo) public gems;
    address[] public gemList;

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Max fee cap (5%)
    uint256 public constant MAX_FEE = 500;

    /// @notice Accumulated protocol fees in qUSD
    uint256 public accumulatedFees;

    // --- Errors ---

    error GemNotActive();
    error GemAlreadyAdded();
    error DebtCeilingExceeded(uint256 requested, uint256 available);
    error ZeroAmount();
    error FeeTooHigh();
    error InvalidDecimals();
    error InsufficientReserves(uint256 requested, uint256 available);

    // --- Events ---

    event GemAdded(address indexed gem, uint8 decimals, uint256 debtCeiling, uint256 tin, uint256 tout);
    event GemRemoved(address indexed gem);
    event GemUpdated(address indexed gem, uint256 debtCeiling, uint256 tin, uint256 tout);
    event SwapIn(address indexed user, address indexed gem, uint256 gemAmount, uint256 qusdAmount, uint256 fee);
    event SwapOut(address indexed user, address indexed gem, uint256 qusdAmount, uint256 gemAmount, uint256 fee);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor(address _qusd) Ownable(msg.sender) {
        qusd = QUSDToken(_qusd);
    }

    // =========================================================================
    // Gem management
    // =========================================================================

    /**
     * @notice Add a new stablecoin to the PSM
     * @param _gem ERC-20 token address
     * @param _decimals Token decimals
     * @param _debtCeiling Max qUSD mintable against this gem (18 decimals)
     * @param _tin Swap-in fee in basis points
     * @param _tout Swap-out fee in basis points
     */
    function addGem(
        address _gem,
        uint8 _decimals,
        uint256 _debtCeiling,
        uint256 _tin,
        uint256 _tout
    ) external onlyOwner {
        if (gems[_gem].active) revert GemAlreadyAdded();
        if (_decimals == 0 || _decimals > 18) revert InvalidDecimals();
        if (_tin > MAX_FEE || _tout > MAX_FEE) revert FeeTooHigh();

        gems[_gem] = GemInfo({
            active: true,
            decimals: _decimals,
            debtCeiling: _debtCeiling,
            totalDebt: 0,
            tin: _tin,
            tout: _tout
        });
        gemList.push(_gem);

        emit GemAdded(_gem, _decimals, _debtCeiling, _tin, _tout);
    }

    /**
     * @notice Deactivate a gem (no new swaps, existing reserves remain withdrawable)
     */
    function removeGem(address _gem) external onlyOwner {
        if (!gems[_gem].active) revert GemNotActive();
        gems[_gem].active = false;
        emit GemRemoved(_gem);
    }

    /**
     * @notice Update gem parameters
     */
    function updateGem(
        address _gem,
        uint256 _debtCeiling,
        uint256 _tin,
        uint256 _tout
    ) external onlyOwner {
        if (!gems[_gem].active) revert GemNotActive();
        if (_tin > MAX_FEE || _tout > MAX_FEE) revert FeeTooHigh();

        gems[_gem].debtCeiling = _debtCeiling;
        gems[_gem].tin = _tin;
        gems[_gem].tout = _tout;

        emit GemUpdated(_gem, _debtCeiling, _tin, _tout);
    }

    // =========================================================================
    // Swap operations
    // =========================================================================

    /**
     * @notice Swap stablecoin → qUSD (deposit stablecoin, receive qUSD)
     * @param _gem Stablecoin address
     * @param _gemAmount Amount of stablecoin (in gem's decimals)
     */
    function swapIn(address _gem, uint256 _gemAmount) external nonReentrant whenNotPaused {
        if (_gemAmount == 0) revert ZeroAmount();
        GemInfo storage info = gems[_gem];
        if (!info.active) revert GemNotActive();

        // Normalize to 18 decimals
        uint256 qusdAmount = _normalize(_gemAmount, info.decimals);

        // Calculate fee
        uint256 fee = (qusdAmount * info.tin) / BASIS_POINTS;
        uint256 qusdOut = qusdAmount - fee;

        // Check debt ceiling
        if (info.totalDebt + qusdOut > info.debtCeiling) {
            revert DebtCeilingExceeded(qusdOut, info.debtCeiling - info.totalDebt);
        }

        // Update state
        info.totalDebt += qusdOut;
        accumulatedFees += fee;

        // Transfer stablecoin from user
        IERC20(_gem).safeTransferFrom(msg.sender, address(this), _gemAmount);

        // Mint qUSD to user
        qusd.mint(msg.sender, qusdOut);

        // Mint fee qUSD to this contract (protocol revenue)
        if (fee > 0) {
            qusd.mint(address(this), fee);
        }

        emit SwapIn(msg.sender, _gem, _gemAmount, qusdOut, fee);
    }

    /**
     * @notice Swap qUSD → stablecoin (burn qUSD, receive stablecoin)
     * @param _gem Stablecoin address
     * @param _qusdAmount Amount of qUSD to swap (18 decimals)
     */
    function swapOut(address _gem, uint256 _qusdAmount) external nonReentrant whenNotPaused {
        if (_qusdAmount == 0) revert ZeroAmount();
        GemInfo storage info = gems[_gem];
        if (!info.active) revert GemNotActive();

        // Calculate fee
        uint256 fee = (_qusdAmount * info.tout) / BASIS_POINTS;
        uint256 qusdNet = _qusdAmount - fee;

        // Convert to gem decimals
        uint256 gemOut = _denormalize(qusdNet, info.decimals);

        // Check reserves
        uint256 reserves = IERC20(_gem).balanceOf(address(this));
        if (gemOut > reserves) {
            revert InsufficientReserves(gemOut, reserves);
        }

        // Update state
        if (info.totalDebt >= qusdNet) {
            info.totalDebt -= qusdNet;
        } else {
            info.totalDebt = 0;
        }
        accumulatedFees += fee;

        // Burn the net qUSD
        qusd.burnFrom(msg.sender, qusdNet);

        // Transfer fee qUSD to this contract
        if (fee > 0) {
            IERC20(address(qusd)).safeTransferFrom(msg.sender, address(this), fee);
        }

        // Send stablecoin to user
        IERC20(_gem).safeTransfer(msg.sender, gemOut);

        emit SwapOut(msg.sender, _gem, _qusdAmount, gemOut, fee);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /**
     * @notice Get the PSM reserves for a specific gem
     */
    function getReserves(address _gem) external view returns (uint256) {
        return IERC20(_gem).balanceOf(address(this));
    }

    /**
     * @notice Get the available debt capacity for a gem
     */
    function getAvailableDebt(address _gem) external view returns (uint256) {
        GemInfo memory info = gems[_gem];
        if (info.totalDebt >= info.debtCeiling) return 0;
        return info.debtCeiling - info.totalDebt;
    }

    /**
     * @notice Get all registered gems
     */
    function getGemList() external view returns (address[] memory) {
        return gemList;
    }

    /**
     * @notice Get the number of registered gems
     */
    function gemCount() external view returns (uint256) {
        return gemList.length;
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /**
     * @notice Withdraw accumulated protocol fees (in qUSD)
     */
    function withdrawFees(address _to) external onlyOwner {
        uint256 fees = accumulatedFees;
        if (fees == 0) revert ZeroAmount();
        accumulatedFees = 0;

        IERC20(address(qusd)).safeTransfer(_to, fees);
        emit FeesWithdrawn(_to, fees);
    }

    /// @notice Pause all swap operations
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume swap operations
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Internal
    // =========================================================================

    /// @dev Convert gem amount to 18-decimal qUSD amount
    function _normalize(uint256 _amount, uint8 _decimals) internal pure returns (uint256) {
        if (_decimals == 18) return _amount;
        return _amount * (10 ** (18 - _decimals));
    }

    /// @dev Convert 18-decimal qUSD amount to gem decimals
    function _denormalize(uint256 _amount, uint8 _decimals) internal pure returns (uint256) {
        if (_decimals == 18) return _amount;
        return _amount / (10 ** (18 - _decimals));
    }
}
