// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title WithdrawalQueue
 * @dev Manages unstake requests with a 7-day cooldown period
 *
 * Features:
 * - FIFO queue per user with unique request IDs
 * - 7-day cooldown before claims are eligible
 * - Finalization when cooldown has passed
 */
contract WithdrawalQueue {
    uint256 public constant COOLDOWN_PERIOD = 7 days;

    struct WithdrawalRequest {
        address owner;
        uint256 qfcAmount;
        uint256 requestTime;
        bool claimed;
    }

    uint256 public nextRequestId = 1;
    mapping(uint256 => WithdrawalRequest) public requests;
    mapping(address => uint256[]) internal _userRequests;

    event WithdrawalRequested(uint256 indexed requestId, address indexed owner, uint256 qfcAmount);
    event WithdrawalClaimed(uint256 indexed requestId, address indexed owner, uint256 qfcAmount);

    /**
     * @dev Queue a new withdrawal request (internal, called by LiquidStaking)
     * @param owner Request owner
     * @param qfcAmount Amount of QFC to withdraw
     * @return requestId The ID of the new request
     */
    function _enqueue(address owner, uint256 qfcAmount) internal returns (uint256 requestId) {
        requestId = nextRequestId++;
        requests[requestId] = WithdrawalRequest({
            owner: owner,
            qfcAmount: qfcAmount,
            requestTime: block.timestamp,
            claimed: false
        });
        _userRequests[owner].push(requestId);

        emit WithdrawalRequested(requestId, owner, qfcAmount);
    }

    /**
     * @dev Mark a request as claimed (internal, called by LiquidStaking)
     * @param requestId The request to finalize
     * @return owner The request owner
     * @return qfcAmount The QFC amount to return
     */
    function _finalize(uint256 requestId) internal returns (address owner, uint256 qfcAmount) {
        WithdrawalRequest storage req = requests[requestId];
        require(req.owner != address(0), "Request does not exist");
        require(!req.claimed, "Already claimed");
        require(
            block.timestamp >= req.requestTime + COOLDOWN_PERIOD,
            "Cooldown not passed"
        );

        req.claimed = true;
        owner = req.owner;
        qfcAmount = req.qfcAmount;

        emit WithdrawalClaimed(requestId, owner, qfcAmount);
    }

    /**
     * @dev Get all request IDs for a user
     * @param user User address
     */
    function getUserRequests(address user) external view returns (uint256[] memory) {
        return _userRequests[user];
    }

    /**
     * @dev Check if a request is claimable
     * @param requestId The request to check
     */
    function isClaimable(uint256 requestId) external view returns (bool) {
        WithdrawalRequest memory req = requests[requestId];
        return req.owner != address(0)
            && !req.claimed
            && block.timestamp >= req.requestTime + COOLDOWN_PERIOD;
    }
}
