// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./QToken.sol";
import "./PriceOracle.sol";

/**
 * @title LendingPool
 * @dev Core controller for the QFC Lending Protocol (Compound V2 style).
 *
 * Users supply assets and receive qTokens. They can then borrow against their
 * collateral up to each asset's collateral factor. Under-collateralized positions
 * can be liquidated with a 5% bonus to the liquidator.
 */
contract LendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e18;

    /// @notice Liquidation incentive bonus (5% = 1.05e18)
    uint256 public constant LIQUIDATION_BONUS = 1.05e18;

    /// @notice Maximum fraction of a borrow that can be repaid in one liquidation (50%)
    uint256 public constant CLOSE_FACTOR = 0.5e18;

    /// @notice The price oracle
    PriceOracle public oracle;

    /// @notice Supported asset list
    address[] public allMarkets;

    /// @notice Underlying asset → QToken market
    mapping(address => QToken) public markets;

    /// @notice Underlying asset → collateral factor (scaled by 1e18, e.g. 0.75e18 = 75%)
    mapping(address => uint256) public collateralFactors;

    /// @notice Underlying asset → whether it is listed
    mapping(address => bool) public isListed;

    /// @notice Account → list of assets used as collateral
    mapping(address => address[]) public accountCollaterals;

    /// @notice Account → asset → whether asset is entered as collateral
    mapping(address => mapping(address => bool)) public isInMarket;

    event MarketListed(address indexed underlying, address indexed qToken, uint256 collateralFactor);
    event CollateralFactorUpdated(address indexed underlying, uint256 oldFactor, uint256 newFactor);
    event MarketEntered(address indexed account, address indexed underlying);
    event MarketExited(address indexed account, address indexed underlying);
    event Supply(address indexed account, address indexed underlying, uint256 amount);
    event Withdraw(address indexed account, address indexed underlying, uint256 amount);
    event BorrowEvent(address indexed account, address indexed underlying, uint256 amount);
    event Repay(address indexed account, address indexed underlying, uint256 amount);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        address indexed repayAsset,
        address seizeAsset,
        uint256 repayAmount,
        uint256 seizeAmount
    );
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    /**
     * @param oracle_ The price oracle address
     */
    constructor(PriceOracle oracle_) Ownable(msg.sender) {
        require(address(oracle_) != address(0), "LendingPool: zero oracle");
        oracle = oracle_;
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    /**
     * @notice List a new market. Only callable by owner.
     * @param underlying The underlying ERC-20 asset
     * @param qToken The corresponding QToken
     * @param collateralFactor Collateral factor (scaled by 1e18)
     */
    function listMarket(
        address underlying,
        QToken qToken,
        uint256 collateralFactor
    ) external onlyOwner {
        require(!isListed[underlying], "LendingPool: already listed");
        require(address(qToken) != address(0), "LendingPool: zero qToken");
        require(collateralFactor <= 0.9e18, "LendingPool: CF too high");
        require(address(qToken.underlying()) == underlying, "LendingPool: underlying mismatch");

        markets[underlying] = qToken;
        collateralFactors[underlying] = collateralFactor;
        isListed[underlying] = true;
        allMarkets.push(underlying);

        emit MarketListed(underlying, address(qToken), collateralFactor);
    }

    /**
     * @notice Update collateral factor for a market. Only callable by owner.
     * @param underlying The asset address
     * @param newFactor New collateral factor
     */
    function setCollateralFactor(address underlying, uint256 newFactor) external onlyOwner {
        require(isListed[underlying], "LendingPool: not listed");
        require(newFactor <= 0.9e18, "LendingPool: CF too high");

        uint256 oldFactor = collateralFactors[underlying];
        collateralFactors[underlying] = newFactor;

        emit CollateralFactorUpdated(underlying, oldFactor, newFactor);
    }

    /**
     * @notice Update the price oracle. Only callable by owner.
     * @param newOracle The new oracle address
     */
    function setOracle(PriceOracle newOracle) external onlyOwner {
        require(address(newOracle) != address(0), "LendingPool: zero oracle");
        address old = address(oracle);
        oracle = newOracle;
        emit OracleUpdated(old, address(newOracle));
    }

    // ─── Collateral Management ──────────────────────────────────────────

    /**
     * @notice Enter a market to use supplied assets as collateral.
     * @param underlying The asset to enable as collateral
     */
    function enterMarket(address underlying) external {
        require(isListed[underlying], "LendingPool: not listed");
        require(!isInMarket[msg.sender][underlying], "LendingPool: already entered");

        isInMarket[msg.sender][underlying] = true;
        accountCollaterals[msg.sender].push(underlying);

        emit MarketEntered(msg.sender, underlying);
    }

    /**
     * @notice Exit a market — stop using an asset as collateral.
     * @param underlying The asset to disable as collateral
     */
    function exitMarket(address underlying) external {
        require(isInMarket[msg.sender][underlying], "LendingPool: not in market");

        // Ensure exiting doesn't make account under-collateralized
        isInMarket[msg.sender][underlying] = false;
        (uint256 collateralValue, uint256 borrowValue) = _accountLiquidity(msg.sender);
        require(collateralValue >= borrowValue, "LendingPool: insufficient collateral after exit");

        // Remove from array
        _removeFromArray(accountCollaterals[msg.sender], underlying);

        emit MarketExited(msg.sender, underlying);
    }

    // ─── Core Operations ────────────────────────────────────────────────

    /**
     * @notice Supply assets to earn interest.
     * @param underlying The asset to supply
     * @param amount Amount to supply
     */
    function supply(address underlying, uint256 amount) external nonReentrant {
        require(isListed[underlying], "LendingPool: not listed");
        require(amount > 0, "LendingPool: zero amount");

        QToken qToken = markets[underlying];
        IERC20(underlying).safeTransferFrom(msg.sender, address(qToken), amount);
        qToken.mintForAccount(msg.sender, amount);

        emit Supply(msg.sender, underlying, amount);
    }

    /**
     * @notice Withdraw supplied assets by redeeming qTokens.
     * @param underlying The asset to withdraw
     * @param qTokenAmount Amount of qTokens to redeem
     */
    function withdraw(address underlying, uint256 qTokenAmount) external nonReentrant {
        require(isListed[underlying], "LendingPool: not listed");
        require(qTokenAmount > 0, "LendingPool: zero amount");

        QToken qToken = markets[underlying];
        qToken.redeemForAccount(msg.sender, qTokenAmount);

        // Check collateral after withdrawal
        if (isInMarket[msg.sender][underlying]) {
            (uint256 collateralValue, uint256 borrowValue) = _accountLiquidity(msg.sender);
            require(collateralValue >= borrowValue, "LendingPool: insufficient collateral after withdraw");
        }

        emit Withdraw(msg.sender, underlying, qTokenAmount);
    }

    /**
     * @notice Borrow assets against supplied collateral.
     * @param underlying The asset to borrow
     * @param amount Amount to borrow
     */
    function borrow(address underlying, uint256 amount) external nonReentrant {
        require(isListed[underlying], "LendingPool: not listed");
        require(amount > 0, "LendingPool: zero amount");

        QToken qToken = markets[underlying];
        qToken.borrowForAccount(msg.sender, amount);

        // Check collateral requirement
        (uint256 collateralValue, uint256 borrowValue) = _accountLiquidity(msg.sender);
        require(collateralValue >= borrowValue, "LendingPool: insufficient collateral");

        emit BorrowEvent(msg.sender, underlying, amount);
    }

    /**
     * @notice Repay borrowed assets.
     * @param underlying The asset to repay
     * @param amount Amount to repay (use type(uint256).max for full repayment)
     */
    function repay(address underlying, uint256 amount) external nonReentrant {
        require(isListed[underlying], "LendingPool: not listed");
        require(amount > 0, "LendingPool: zero amount");

        QToken qToken = markets[underlying];

        // Transfer tokens to qToken contract first
        uint256 actualAmount = amount;
        if (amount == type(uint256).max) {
            // For full repay, calculate current borrow balance
            qToken.accrueInterest();
            actualAmount = qToken.borrowBalanceCurrent(msg.sender);
        }
        IERC20(underlying).safeTransferFrom(msg.sender, address(qToken), actualAmount);
        qToken.repayForAccount(msg.sender, msg.sender, actualAmount);

        emit Repay(msg.sender, underlying, actualAmount);
    }

    /**
     * @notice Liquidate an under-collateralized borrower.
     * @param borrower The account to liquidate
     * @param repayAsset The borrowed asset to repay
     * @param seizeAsset The collateral asset to seize
     * @param repayAmount Amount of borrow to repay
     */
    function liquidate(
        address borrower,
        address repayAsset,
        address seizeAsset,
        uint256 repayAmount
    ) external nonReentrant {
        require(borrower != msg.sender, "LendingPool: cannot self-liquidate");
        require(isListed[repayAsset] && isListed[seizeAsset], "LendingPool: not listed");
        require(repayAmount > 0, "LendingPool: zero amount");

        // Check borrower is liquidatable
        uint256 healthFactor = getHealthFactor(borrower);
        require(healthFactor < PRECISION, "LendingPool: health factor >= 1");

        // Enforce close factor
        QToken repayQToken = markets[repayAsset];
        repayQToken.accrueInterest();
        uint256 borrowBalance = repayQToken.borrowBalanceCurrent(borrower);
        uint256 maxRepay = (borrowBalance * CLOSE_FACTOR) / PRECISION;
        require(repayAmount <= maxRepay, "LendingPool: exceeds close factor");

        // Repay debt
        IERC20(repayAsset).safeTransferFrom(msg.sender, address(repayQToken), repayAmount);
        repayQToken.repayForAccount(msg.sender, borrower, repayAmount);

        // Calculate seize amount: (repayAmount * repayPrice * liquidationBonus) / (seizePrice * seizeExchangeRate)
        QToken seizeQToken = markets[seizeAsset];
        seizeQToken.accrueInterest();

        uint256 repayPrice = oracle.getPrice(repayAsset);
        uint256 seizePrice = oracle.getPrice(seizeAsset);
        uint256 seizeExchangeRate = seizeQToken.exchangeRate();

        // repayValue in USD
        uint256 repayValueUSD = (repayAmount * repayPrice) / PRECISION;
        // seizeValue with bonus
        uint256 seizeValueUSD = (repayValueUSD * LIQUIDATION_BONUS) / PRECISION;
        // Convert USD value to underlying amount, then to qTokens
        uint256 seizeUnderlyingAmount = (seizeValueUSD * PRECISION) / seizePrice;
        uint256 seizeQTokenAmount = (seizeUnderlyingAmount * PRECISION) / seizeExchangeRate;

        // Transfer qTokens from borrower to liquidator
        require(seizeQToken.balanceOf(borrower) >= seizeQTokenAmount, "LendingPool: insufficient collateral to seize");
        // We use a direct transfer of qTokens
        _seizeQTokens(seizeQToken, borrower, msg.sender, seizeQTokenAmount);

        emit Liquidate(msg.sender, borrower, repayAsset, seizeAsset, repayAmount, seizeQTokenAmount);
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /**
     * @notice Get the health factor for an account.
     * @dev healthFactor = collateralValue / borrowValue. Returns type(uint256).max if no borrows.
     * @param account The account to check
     * @return Health factor scaled by 1e18 (1e18 = healthy threshold)
     */
    function getHealthFactor(address account) public view returns (uint256) {
        (uint256 collateralValue, uint256 borrowValue) = _accountLiquidity(account);
        if (borrowValue == 0) return type(uint256).max;
        return (collateralValue * PRECISION) / borrowValue;
    }

    /**
     * @notice Get the total collateral and borrow value for an account in USD.
     * @param account The account to query
     * @return collateralValue Total weighted collateral in USD
     * @return borrowValue Total borrow value in USD
     */
    function getAccountLiquidity(
        address account
    ) external view returns (uint256 collateralValue, uint256 borrowValue) {
        return _accountLiquidity(account);
    }

    /**
     * @notice Get the number of listed markets.
     */
    function marketCount() external view returns (uint256) {
        return allMarkets.length;
    }

    /**
     * @notice Get assets entered as collateral by an account.
     * @param account The account to query
     */
    function getAccountCollaterals(address account) external view returns (address[] memory) {
        return accountCollaterals[account];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _accountLiquidity(
        address account
    ) internal view returns (uint256 collateralValue, uint256 borrowValue) {
        for (uint256 i = 0; i < allMarkets.length; i++) {
            address asset = allMarkets[i];
            QToken qToken = markets[asset];
            uint256 price = oracle.getPrice(asset);

            // Borrow value
            uint256 borrowBal = qToken.borrowBalanceCurrent(account);
            if (borrowBal > 0) {
                borrowValue += (borrowBal * price) / PRECISION;
            }

            // Collateral value (only if entered)
            if (isInMarket[account][asset]) {
                uint256 qTokenBal = qToken.balanceOf(account);
                if (qTokenBal > 0) {
                    uint256 underlyingBal = (qTokenBal * qToken.exchangeRate()) / PRECISION;
                    uint256 assetValue = (underlyingBal * price) / PRECISION;
                    collateralValue += (assetValue * collateralFactors[asset]) / PRECISION;
                }
            }
        }
    }

    function _seizeQTokens(QToken qToken, address from, address to, uint256 amount) internal {
        // Direct balance manipulation via ERC20 transferFrom requires approval.
        // Instead, we use a low-level approach: since LendingPool is trusted,
        // we simply do an internal transfer by burning from borrower and minting to liquidator.
        // However QToken only allows LendingPool to call mint/burn via specific functions.
        // The cleanest approach: require the borrower's qTokens to be seized via transfer.
        // Since we can't force a transfer without approval, QToken needs a seize function.
        // For simplicity in this MVP, we'll call _transfer via a delegated seize.
        _executeSeize(qToken, from, to, amount);
    }

    function _executeSeize(QToken qToken, address from, address to, uint256 amount) internal {
        // QToken inherits ERC20, we need a seize mechanism.
        // Since QToken is controlled by LendingPool, we add a seize function there.
        // For now we call the seize function on QToken.
        qToken.seize(from, to, amount);
    }

    function _removeFromArray(address[] storage arr, address value) internal {
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; i++) {
            if (arr[i] == value) {
                arr[i] = arr[len - 1];
                arr.pop();
                return;
            }
        }
    }
}
