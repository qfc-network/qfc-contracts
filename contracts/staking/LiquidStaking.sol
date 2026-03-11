// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./StQFC.sol";
import "./WithdrawalQueue.sol";

/**
 * @title LiquidStaking
 * @dev Lido-style liquid staking for QFC
 *
 * Features:
 * - Stake native QFC and receive stQFC receipt tokens
 * - Exchange rate model (non-rebasing): stQFC appreciates as rewards accrue
 * - 7-day withdrawal queue for unstaking
 * - Validator/owner distributes rewards to increase exchange rate
 */
contract LiquidStaking is WithdrawalQueue, ReentrancyGuard, Ownable {
    StQFC public immutable stQFC;

    uint256 public totalPooledQFC;
    uint256 public totalPendingWithdrawals;

    event Staked(address indexed user, uint256 qfcAmount, uint256 stQFCAmount);
    event UnstakeRequested(address indexed user, uint256 stQFCAmount, uint256 qfcAmount, uint256 requestId);
    event RewardsDistributed(uint256 amount, uint256 newExchangeRate);

    error ZeroAmount();
    error InsufficientBalance();
    error NotRequestOwner();
    error InsufficientContractBalance();

    constructor() Ownable(msg.sender) {
        stQFC = new StQFC(address(this));
    }

    /**
     * @dev Stake QFC and receive stQFC at current exchange rate
     */
    function stake() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        uint256 stQFCAmount = _qfcToStQFC(msg.value);

        totalPooledQFC += msg.value;
        stQFC.mint(msg.sender, stQFCAmount);

        emit Staked(msg.sender, msg.value, stQFCAmount);
    }

    /**
     * @dev Request unstake — burns stQFC and queues a withdrawal
     * @param stQFCAmount Amount of stQFC to unstake
     * @return requestId The withdrawal request ID
     */
    function requestUnstake(uint256 stQFCAmount) external nonReentrant returns (uint256 requestId) {
        if (stQFCAmount == 0) revert ZeroAmount();
        if (stQFC.balanceOf(msg.sender) < stQFCAmount) revert InsufficientBalance();

        uint256 qfcAmount = _stQFCToQFC(stQFCAmount);

        stQFC.burn(msg.sender, stQFCAmount);
        totalPooledQFC -= qfcAmount;
        totalPendingWithdrawals += qfcAmount;

        requestId = _enqueue(msg.sender, qfcAmount);

        emit UnstakeRequested(msg.sender, stQFCAmount, qfcAmount, requestId);
    }

    /**
     * @dev Claim QFC after cooldown period has passed
     * @param requestId The withdrawal request ID
     */
    function claimUnstake(uint256 requestId) external nonReentrant {
        (address owner, uint256 qfcAmount) = _finalize(requestId);
        if (owner != msg.sender) revert NotRequestOwner();
        if (address(this).balance < qfcAmount) revert InsufficientContractBalance();

        totalPendingWithdrawals -= qfcAmount;

        (bool success, ) = msg.sender.call{value: qfcAmount}("");
        require(success, "QFC transfer failed");
    }

    /**
     * @dev Distribute validator rewards — increases exchange rate for all stQFC holders
     */
    function distributeRewards() external payable onlyOwner {
        if (msg.value == 0) revert ZeroAmount();

        totalPooledQFC += msg.value;

        emit RewardsDistributed(msg.value, getExchangeRate());
    }

    /**
     * @dev Get current exchange rate (QFC per stQFC), scaled by 1e18
     * @return Exchange rate: how much QFC 1 stQFC is worth
     */
    function getExchangeRate() public view returns (uint256) {
        uint256 totalShares = stQFC.totalSupply();
        if (totalShares == 0) {
            return 1e18; // 1:1 initially
        }
        return (totalPooledQFC * 1e18) / totalShares;
    }

    /**
     * @dev Convert QFC amount to stQFC amount at current rate
     * @param qfcAmount Amount of QFC
     */
    function _qfcToStQFC(uint256 qfcAmount) internal view returns (uint256) {
        uint256 totalShares = stQFC.totalSupply();
        if (totalShares == 0) {
            return qfcAmount; // 1:1 initially
        }
        return (qfcAmount * totalShares) / totalPooledQFC;
    }

    /**
     * @dev Convert stQFC amount to QFC amount at current rate
     * @param stQFCAmount Amount of stQFC
     */
    function _stQFCToQFC(uint256 stQFCAmount) internal view returns (uint256) {
        uint256 totalShares = stQFC.totalSupply();
        if (totalShares == 0) {
            return stQFCAmount; // 1:1 initially
        }
        return (stQFCAmount * totalPooledQFC) / totalShares;
    }

    /**
     * @dev Receive QFC (e.g., from validator rewards or direct transfers)
     */
    receive() external payable {}
}
