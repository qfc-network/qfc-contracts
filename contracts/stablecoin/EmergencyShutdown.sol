// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./QUSDToken.sol";

/**
 * @title EmergencyShutdown
 * @notice Tiered pause and global settlement for the qUSD stablecoin system.
 *
 *  Pause levels:
 *    Level 0 — Normal operation
 *    Level 1 — Pause new minting (existing positions can still repay/withdraw)
 *    Level 2 — Pause all CDP operations except repayment
 *    Level 3 — Global settlement (irreversible)
 *
 *  Global settlement flow:
 *    1. Trigger shutdown → snapshot all CDP state
 *    2. qUSD holders redeem collateral at the settlement price
 *    3. CDP holders withdraw excess collateral after all QUSD is redeemed
 *
 * @dev This contract must be granted EMERGENCY_ROLE on CDPVaultV2 and
 *      authorized as a vault on QUSDToken to burn during settlement.
 */
contract EmergencyShutdown is AccessControl {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // --- Pause levels ---

    enum PauseLevel {
        Normal,    // 0
        PauseMint, // 1
        PauseAll,  // 2
        Settlement // 3
    }

    PauseLevel public pauseLevel;

    // --- Settlement state ---

    /// @notice Whether global settlement has been triggered (irreversible)
    bool public settled;

    /// @notice QFC/USD price at settlement time (8 decimals)
    uint256 public settlementPrice;

    /// @notice Total QFC collateral locked at settlement
    uint256 public totalCollateralAtSettlement;

    /// @notice Total qUSD debt outstanding at settlement
    uint256 public totalDebtAtSettlement;

    /// @notice Amount of QFC per qUSD (18 decimals), calculated at settlement
    uint256 public redemptionRate;

    /// @notice Total QFC claimed by qUSD holders so far
    uint256 public totalRedeemed;

    /// @notice Track which addresses have redeemed their QUSD
    mapping(address => uint256) public redeemed;

    /// @notice Track which CDP owners have withdrawn excess collateral
    mapping(address => bool) public excessWithdrawn;

    /// @notice CDP collateral snapshot at settlement time
    mapping(address => uint256) public collateralSnapshot;

    /// @notice CDP debt snapshot at settlement time
    mapping(address => uint256) public debtSnapshot;

    /// @notice List of CDP owners for iteration during settlement
    address[] public cdpOwners;
    mapping(address => bool) public isCdpOwner;

    /// @notice Reference to the qUSD token for burning during redemption
    QUSDToken public immutable qusd;

    // --- Multi-sig shutdown ---

    /// @notice Number of guardian signatures required to trigger settlement
    uint256 public requiredSignatures = 3;

    /// @notice Pending shutdown proposal
    uint256 public shutdownProposalTime;
    address[] public shutdownSigners;
    mapping(address => bool) public hasSignedShutdown;

    // --- Errors ---

    error AlreadySettled();
    error NotSettled();
    error NotEnoughSignatures(uint256 have, uint256 need);
    error AlreadySigned();
    error NothingToRedeem();
    error NothingToWithdraw();
    error AlreadyWithdrawn();
    error InvalidPauseLevel();
    error CannotRecoverFromSettlement();
    error TransferFailed();
    error InvalidConfiguration();
    error ProposalExpired();
    error NoActiveProposal();
    error ZeroAmount();

    // --- Events ---

    event PauseLevelChanged(PauseLevel oldLevel, PauseLevel newLevel, address indexed changer);
    event ShutdownProposed(address indexed proposer, uint256 timestamp);
    event ShutdownSigned(address indexed signer, uint256 totalSignatures);
    event GlobalSettlement(
        uint256 settlementPrice,
        uint256 totalCollateral,
        uint256 totalDebt,
        uint256 redemptionRate
    );
    event QUSDRedeemed(address indexed holder, uint256 qusdAmount, uint256 qfcReceived);
    event ExcessCollateralWithdrawn(address indexed cdpOwner, uint256 amount);

    constructor(address _qusd, address _admin) {
        qusd = QUSDToken(_qusd);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GUARDIAN_ROLE, _admin);
    }

    // =========================================================================
    // Pause controls (Level 1-2, reversible via DAO)
    // =========================================================================

    /**
     * @notice Set the pause level (guardian can escalate, admin can de-escalate)
     * @dev Level 3 (Settlement) can only be triggered via proposeShutdown/signShutdown
     */
    function setPauseLevel(PauseLevel _level) external {
        if (settled) revert AlreadySettled();
        if (_level == PauseLevel.Settlement) revert InvalidPauseLevel();

        PauseLevel current = pauseLevel;

        if (_level > current) {
            // Escalation — guardians can do this
            _checkRole(GUARDIAN_ROLE);
        } else {
            // De-escalation — only admin (DAO)
            _checkRole(DEFAULT_ADMIN_ROLE);
        }

        PauseLevel old = pauseLevel;
        pauseLevel = _level;
        emit PauseLevelChanged(old, _level, msg.sender);
    }

    /**
     * @notice Check if minting is allowed at the current pause level
     */
    function isMintAllowed() external view returns (bool) {
        return pauseLevel == PauseLevel.Normal && !settled;
    }

    /**
     * @notice Check if CDP operations (except repay) are allowed
     */
    function isOperationAllowed() external view returns (bool) {
        return pauseLevel <= PauseLevel.PauseMint && !settled;
    }

    /**
     * @notice Check if repayment is allowed (always allowed except during settlement)
     */
    function isRepayAllowed() external view returns (bool) {
        return !settled;
    }

    // =========================================================================
    // Multi-sig shutdown (Level 3, irreversible)
    // =========================================================================

    /**
     * @notice Propose a global settlement. Starts the multi-sig collection.
     *         Proposal expires after 24 hours.
     */
    function proposeShutdown() external onlyRole(GUARDIAN_ROLE) {
        if (settled) revert AlreadySettled();

        // Reset any existing proposal
        delete shutdownSigners;
        for (uint256 i = 0; i < shutdownSigners.length; i++) {
            hasSignedShutdown[shutdownSigners[i]] = false;
        }

        shutdownProposalTime = block.timestamp;
        shutdownSigners.push(msg.sender);
        hasSignedShutdown[msg.sender] = true;

        emit ShutdownProposed(msg.sender, block.timestamp);
        emit ShutdownSigned(msg.sender, 1);
    }

    /**
     * @notice Sign the pending shutdown proposal
     */
    function signShutdown() external onlyRole(GUARDIAN_ROLE) {
        if (settled) revert AlreadySettled();
        if (shutdownProposalTime == 0) revert NoActiveProposal();
        if (block.timestamp - shutdownProposalTime > 24 hours) revert ProposalExpired();
        if (hasSignedShutdown[msg.sender]) revert AlreadySigned();

        shutdownSigners.push(msg.sender);
        hasSignedShutdown[msg.sender] = true;

        emit ShutdownSigned(msg.sender, shutdownSigners.length);
    }

    /**
     * @notice Execute the global settlement after enough signatures
     * @param _settlementPrice QFC/USD price at settlement (8 decimals)
     * @param _totalCollateral Total QFC locked in all CDPs (wei)
     * @param _totalDebt Total qUSD debt outstanding (18 decimals)
     * @param _owners List of all CDP owner addresses
     * @param _collaterals Collateral amounts for each owner (wei)
     * @param _debts Debt amounts for each owner (18 decimals)
     */
    function executeSettlement(
        uint256 _settlementPrice,
        uint256 _totalCollateral,
        uint256 _totalDebt,
        address[] calldata _owners,
        uint256[] calldata _collaterals,
        uint256[] calldata _debts
    ) external onlyRole(GUARDIAN_ROLE) {
        if (settled) revert AlreadySettled();
        if (shutdownSigners.length < requiredSignatures) {
            revert NotEnoughSignatures(shutdownSigners.length, requiredSignatures);
        }
        if (_settlementPrice == 0) revert ZeroAmount();

        // Mark as settled
        settled = true;
        pauseLevel = PauseLevel.Settlement;
        settlementPrice = _settlementPrice;
        totalCollateralAtSettlement = _totalCollateral;
        totalDebtAtSettlement = _totalDebt;

        // Snapshot CDP positions
        for (uint256 i = 0; i < _owners.length; i++) {
            collateralSnapshot[_owners[i]] = _collaterals[i];
            debtSnapshot[_owners[i]] = _debts[i];
            if (!isCdpOwner[_owners[i]]) {
                cdpOwners.push(_owners[i]);
                isCdpOwner[_owners[i]] = true;
            }
        }

        // Calculate redemption rate: how much QFC per 1 qUSD
        // redemptionRate = totalCollateral * 1e18 / max(totalDebt, totalCollateralValue)
        // where totalCollateralValue = totalCollateral * settlementPrice / 1e8
        if (_totalDebt > 0) {
            uint256 collateralValueInQusd = (_totalCollateral * _settlementPrice) / 1e8;
            if (collateralValueInQusd >= _totalDebt) {
                // Fully backed: 1 qUSD = 1 USD worth of QFC
                // qfcPerQusd = 1e8 / settlementPrice (in 18-decimal QFC)
                redemptionRate = (1e18 * 1e8) / _settlementPrice;
            } else {
                // Undercollateralized: pro-rata
                redemptionRate = (_totalCollateral * 1e18) / _totalDebt;
            }
        }

        emit GlobalSettlement(_settlementPrice, _totalCollateral, _totalDebt, redemptionRate);
        emit PauseLevelChanged(PauseLevel.PauseAll, PauseLevel.Settlement, msg.sender);
    }

    // =========================================================================
    // Settlement redemption
    // =========================================================================

    /**
     * @notice qUSD holders redeem their tokens for QFC at the settlement rate
     * @param _qusdAmount Amount of qUSD to redeem
     */
    function redeemQUSD(uint256 _qusdAmount) external {
        if (!settled) revert NotSettled();
        if (_qusdAmount == 0) revert NothingToRedeem();

        uint256 qfcAmount = (_qusdAmount * redemptionRate) / 1e18;
        if (qfcAmount == 0) revert NothingToRedeem();

        redeemed[msg.sender] += _qusdAmount;
        totalRedeemed += qfcAmount;

        // Burn the qUSD
        qusd.burnFrom(msg.sender, _qusdAmount);

        // Transfer QFC to the holder
        (bool success, ) = msg.sender.call{value: qfcAmount}("");
        if (!success) revert TransferFailed();

        emit QUSDRedeemed(msg.sender, _qusdAmount, qfcAmount);
    }

    /**
     * @notice CDP owners withdraw excess collateral after settlement
     * @dev Only available after settlement. Excess = collateral - (debt * redemptionRate / 1e18)
     */
    function withdrawExcessCollateral() external {
        if (!settled) revert NotSettled();
        if (excessWithdrawn[msg.sender]) revert AlreadyWithdrawn();

        uint256 collateral = collateralSnapshot[msg.sender];
        uint256 debt = debtSnapshot[msg.sender];

        uint256 collateralUsedForDebt = (debt * redemptionRate) / 1e18;
        if (collateral <= collateralUsedForDebt) revert NothingToWithdraw();

        uint256 excess = collateral - collateralUsedForDebt;
        excessWithdrawn[msg.sender] = true;

        (bool success, ) = msg.sender.call{value: excess}("");
        if (!success) revert TransferFailed();

        emit ExcessCollateralWithdrawn(msg.sender, excess);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function setRequiredSignatures(uint256 _count) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_count == 0 || _count > 10) revert InvalidConfiguration();
        requiredSignatures = _count;
    }

    /// @notice Accept QFC transfers (needed to hold collateral during settlement)
    receive() external payable {}
}
