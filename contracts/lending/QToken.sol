// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./InterestRateModel.sol";

/**
 * @title QToken
 * @dev Interest-bearing receipt token for the QFC Lending Protocol.
 *
 * When users supply assets to the LendingPool they receive QTokens whose
 * exchange rate against the underlying grows over time as borrowers pay interest.
 *
 * Only the LendingPool contract may call mint/burn/borrow/repay functions.
 */
contract QToken is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The underlying ERC-20 asset
    IERC20 public immutable underlying;

    /// @notice The interest rate model
    InterestRateModel public immutable interestRateModel;

    /// @notice The LendingPool that controls this market
    address public immutable lendingPool;

    /// @notice Fraction of interest that accrues to reserves (10% = 0.1e18)
    uint256 public constant RESERVE_FACTOR = 0.1e18;

    uint256 private constant PRECISION = 1e18;

    /// @notice Initial exchange rate (1 qToken = 1 underlying scaled by this)
    uint256 private constant INITIAL_EXCHANGE_RATE = 0.02e18;

    /// @notice Accumulated borrow index (starts at 1e18)
    uint256 public borrowIndex;

    /// @notice Total outstanding borrows (principal + accrued interest)
    uint256 public totalBorrows;

    /// @notice Total protocol reserves
    uint256 public totalReserves;

    /// @notice Block timestamp of last interest accrual
    uint256 public lastAccrualTimestamp;

    /// @notice Per-account borrow snapshot: principal, interestIndex
    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
    }

    /// @notice Borrow state per account
    mapping(address => BorrowSnapshot) public accountBorrows;

    event AccrueInterest(uint256 interestAccumulated, uint256 borrowIndex, uint256 totalBorrows);
    event Mint(address indexed supplier, uint256 underlyingAmount, uint256 qTokenAmount);
    event Redeem(address indexed redeemer, uint256 underlyingAmount, uint256 qTokenAmount);
    event Borrow(address indexed borrower, uint256 amount);
    event Repay(address indexed payer, address indexed borrower, uint256 amount);
    event ReservesCollected(address indexed to, uint256 amount);

    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "QToken: caller is not LendingPool");
        _;
    }

    /**
     * @param name_ QToken name (e.g. "QFC Lending QFC")
     * @param symbol_ QToken symbol (e.g. "qQFC")
     * @param underlying_ The underlying ERC-20 token
     * @param interestRateModel_ The interest rate model contract
     * @param lendingPool_ The LendingPool contract address
     */
    constructor(
        string memory name_,
        string memory symbol_,
        IERC20 underlying_,
        InterestRateModel interestRateModel_,
        address lendingPool_
    ) ERC20(name_, symbol_) {
        require(address(underlying_) != address(0), "QToken: zero underlying");
        require(address(interestRateModel_) != address(0), "QToken: zero rate model");
        require(lendingPool_ != address(0), "QToken: zero lending pool");

        underlying = underlying_;
        interestRateModel = interestRateModel_;
        lendingPool = lendingPool_;
        borrowIndex = PRECISION;
        lastAccrualTimestamp = block.timestamp;
    }

    // ─── Interest Accrual ───────────────────────────────────────────────

    /**
     * @notice Accrue interest since last accrual. Called before any state-changing operation.
     */
    function accrueInterest() public {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return;

        lastAccrualTimestamp = block.timestamp;

        if (totalBorrows == 0) return;

        uint256 cash = getCash();
        uint256 borrowRatePerSec = interestRateModel.getBorrowRate(cash, totalBorrows, totalReserves);

        // Simple interest for the elapsed period
        uint256 interestAccumulated = (totalBorrows * borrowRatePerSec * elapsed) / PRECISION;
        uint256 reserveAccumulated = (interestAccumulated * RESERVE_FACTOR) / PRECISION;

        totalBorrows += interestAccumulated;
        totalReserves += reserveAccumulated;
        borrowIndex += (borrowIndex * borrowRatePerSec * elapsed) / PRECISION;

        emit AccrueInterest(interestAccumulated, borrowIndex, totalBorrows);
    }

    // ─── Exchange Rate ──────────────────────────────────────────────────

    /**
     * @notice Current exchange rate: underlying per qToken (scaled by 1e18).
     * @return Exchange rate
     */
    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return INITIAL_EXCHANGE_RATE;
        }
        // (cash + totalBorrows - totalReserves) / totalSupply
        uint256 totalAssets = getCash() + totalBorrows - totalReserves;
        return (totalAssets * PRECISION) / supply;
    }

    /**
     * @notice Underlying balance held by this contract.
     */
    function getCash() public view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    // ─── Supply / Redeem (called by LendingPool) ────────────────────────

    /**
     * @notice Mint qTokens for a supplier. Underlying must already be transferred in.
     * @param supplier Address receiving qTokens
     * @param underlyingAmount Amount of underlying supplied
     * @return qTokensMinted Number of qTokens minted
     */
    function mintForAccount(
        address supplier,
        uint256 underlyingAmount
    ) external onlyLendingPool nonReentrant returns (uint256 qTokensMinted) {
        accrueInterest();

        uint256 rate = exchangeRate();
        qTokensMinted = (underlyingAmount * PRECISION) / rate;
        require(qTokensMinted > 0, "QToken: mint amount is zero");

        _mint(supplier, qTokensMinted);
        emit Mint(supplier, underlyingAmount, qTokensMinted);
    }

    /**
     * @notice Redeem qTokens for underlying. Burns qTokens and sends underlying to redeemer.
     * @param redeemer Address redeeming
     * @param qTokenAmount Amount of qTokens to redeem
     * @return underlyingAmount Amount of underlying returned
     */
    function redeemForAccount(
        address redeemer,
        uint256 qTokenAmount
    ) external onlyLendingPool nonReentrant returns (uint256 underlyingAmount) {
        accrueInterest();

        uint256 rate = exchangeRate();
        underlyingAmount = (qTokenAmount * rate) / PRECISION;
        require(underlyingAmount > 0, "QToken: redeem amount is zero");
        require(getCash() >= underlyingAmount, "QToken: insufficient cash");

        _burn(redeemer, qTokenAmount);
        underlying.safeTransfer(redeemer, underlyingAmount);

        emit Redeem(redeemer, underlyingAmount, qTokenAmount);
    }

    // ─── Borrow / Repay (called by LendingPool) ────────────────────────

    /**
     * @notice Record a borrow and transfer underlying to borrower.
     * @param borrower Address borrowing
     * @param amount Amount to borrow
     */
    function borrowForAccount(
        address borrower,
        uint256 amount
    ) external onlyLendingPool nonReentrant {
        accrueInterest();
        require(getCash() >= amount, "QToken: insufficient cash for borrow");

        // Update borrow snapshot
        BorrowSnapshot storage snapshot = accountBorrows[borrower];
        uint256 principalBefore = _borrowBalanceStored(snapshot);

        snapshot.principal = principalBefore + amount;
        snapshot.interestIndex = borrowIndex;
        totalBorrows += amount;

        underlying.safeTransfer(borrower, amount);
        emit Borrow(borrower, amount);
    }

    /**
     * @notice Repay a borrow. Underlying must already be transferred in.
     * @param payer Address paying (could be liquidator)
     * @param borrower Address whose debt is being repaid
     * @param amount Amount being repaid
     * @return actualRepay Actual amount repaid (capped at outstanding debt)
     */
    function repayForAccount(
        address payer,
        address borrower,
        uint256 amount
    ) external onlyLendingPool nonReentrant returns (uint256 actualRepay) {
        accrueInterest();

        BorrowSnapshot storage snapshot = accountBorrows[borrower];
        uint256 outstanding = _borrowBalanceStored(snapshot);

        actualRepay = amount > outstanding ? outstanding : amount;

        snapshot.principal = outstanding - actualRepay;
        snapshot.interestIndex = borrowIndex;
        totalBorrows = totalBorrows > actualRepay ? totalBorrows - actualRepay : 0;

        // If overpaid, refund excess to payer
        if (amount > actualRepay) {
            underlying.safeTransfer(payer, amount - actualRepay);
        }

        emit Repay(payer, borrower, actualRepay);
    }

    // ─── View Helpers ───────────────────────────────────────────────────

    /**
     * @notice Get the current borrow balance for an account (with accrued interest).
     * @param account Borrower address
     * @return Current borrow balance
     */
    function borrowBalanceCurrent(address account) external view returns (uint256) {
        BorrowSnapshot storage snapshot = accountBorrows[account];
        return _borrowBalanceStored(snapshot);
    }

    /**
     * @notice Get the underlying balance for an account (qToken balance × exchange rate).
     * @param account Supplier address
     * @return Underlying balance
     */
    function balanceOfUnderlying(address account) external view returns (uint256) {
        return (balanceOf(account) * exchangeRate()) / PRECISION;
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    /**
     * @notice Collect accumulated reserves. Only callable by LendingPool.
     * @param to Recipient address
     * @param amount Amount to collect
     */
    function collectReserves(address to, uint256 amount) external onlyLendingPool {
        require(amount <= totalReserves, "QToken: insufficient reserves");
        require(getCash() >= amount, "QToken: insufficient cash");

        totalReserves -= amount;
        underlying.safeTransfer(to, amount);
        emit ReservesCollected(to, amount);
    }

    // ─── Seize (Liquidation) ────────────────────────────────────────────

    /**
     * @notice Transfer qTokens from borrower to liquidator during liquidation.
     * @param from Borrower address
     * @param to Liquidator address
     * @param amount qToken amount to seize
     */
    function seize(address from, address to, uint256 amount) external onlyLendingPool {
        _transfer(from, to, amount);
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _borrowBalanceStored(BorrowSnapshot storage snapshot) internal view returns (uint256) {
        if (snapshot.principal == 0) return 0;
        // principal * currentIndex / snapshotIndex
        return (snapshot.principal * borrowIndex) / snapshot.interestIndex;
    }
}
