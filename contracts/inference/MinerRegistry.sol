// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MinerRegistry
 * @notice Registry for GPU miners participating in the QFC Inference Marketplace.
 * @dev Miners self-register with a tier and endpoint. The TaskRegistry updates
 *      stats when tasks are completed or failed.
 *      Tiers: 1 = small (<7B), 2 = medium (7B-30B), 3 = large (30B+).
 */
contract MinerRegistry is Ownable {
    enum Status { Offline, Online, Busy }

    struct Miner {
        uint8 tier;
        string endpoint;
        Status status;
        uint256 completed;
        uint256 failed;
        uint256 reputation; // 0-10000 basis points
        bool registered;
    }

    /// @notice Address => Miner info
    mapping(address => Miner) private _miners;

    /// @notice All registered miner addresses
    address[] public minerAddresses;

    /// @notice TaskRegistry address, authorized to update miner stats
    address public taskRegistry;

    /// @notice ResultVerifier address, authorized to slash miners
    address public resultVerifier;

    event MinerRegistered(address indexed miner, uint8 tier, string endpoint);
    event MinerStatusUpdated(address indexed miner, Status status);
    event MinerStatsUpdated(address indexed miner, uint256 completed, uint256 failed, uint256 reputation);
    event MinerSlashed(address indexed miner, uint256 amount);
    event TaskRegistrySet(address indexed taskRegistry);
    event ResultVerifierSet(address indexed resultVerifier);

    error AlreadyRegistered();
    error NotRegistered();
    error InvalidTier(uint8 tier);
    error OnlyTaskRegistry();
    error OnlyResultVerifier();

    modifier onlyTaskRegistry() {
        if (msg.sender != taskRegistry) revert OnlyTaskRegistry();
        _;
    }

    modifier onlyResultVerifier() {
        if (msg.sender != resultVerifier) revert OnlyResultVerifier();
        _;
    }

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Set the TaskRegistry address. Can only be called once by owner.
     * @param _taskRegistry Address of the TaskRegistry contract.
     */
    function setTaskRegistry(address _taskRegistry) external onlyOwner {
        require(_taskRegistry != address(0), "Zero address");
        taskRegistry = _taskRegistry;
        emit TaskRegistrySet(_taskRegistry);
    }

    /**
     * @notice Set the ResultVerifier address. Only owner.
     * @param _resultVerifier Address of the ResultVerifier contract.
     */
    function setResultVerifier(address _resultVerifier) external onlyOwner {
        require(_resultVerifier != address(0), "Zero address");
        resultVerifier = _resultVerifier;
        emit ResultVerifierSet(_resultVerifier);
    }

    /**
     * @notice Register as a miner with GPU tier and endpoint.
     * @param tier GPU capability tier (1-3).
     * @param endpoint Off-chain inference endpoint URL.
     */
    function registerMiner(uint8 tier, string calldata endpoint) external {
        if (_miners[msg.sender].registered) revert AlreadyRegistered();
        if (tier == 0 || tier > 3) revert InvalidTier(tier);

        _miners[msg.sender] = Miner({
            tier: tier,
            endpoint: endpoint,
            status: Status.Online,
            completed: 0,
            failed: 0,
            reputation: 10000, // start at 100%
            registered: true
        });
        minerAddresses.push(msg.sender);

        emit MinerRegistered(msg.sender, tier, endpoint);
    }

    /**
     * @notice Update miner availability status.
     * @param status New status (Online, Busy, Offline).
     */
    function updateStatus(Status status) external {
        if (!_miners[msg.sender].registered) revert NotRegistered();
        _miners[msg.sender].status = status;
        emit MinerStatusUpdated(msg.sender, status);
    }

    /**
     * @notice Record a completed task for a miner. Called by TaskRegistry.
     * @param miner The miner address.
     */
    function recordCompletion(address miner) external onlyTaskRegistry {
        Miner storage m = _miners[miner];
        m.completed++;
        _updateReputation(m);
        emit MinerStatsUpdated(miner, m.completed, m.failed, m.reputation);
    }

    /**
     * @notice Record a failed task for a miner. Called by TaskRegistry.
     * @param miner The miner address.
     */
    function recordFailure(address miner) external onlyTaskRegistry {
        Miner storage m = _miners[miner];
        m.failed++;
        _updateReputation(m);
        emit MinerStatsUpdated(miner, m.completed, m.failed, m.reputation);
    }

    /**
     * @notice Slash a miner's reputation. Called by ResultVerifier.
     * @param miner The miner address to slash.
     * @param amount The reputation points to deduct.
     */
    function slash(address miner, uint256 amount) external onlyResultVerifier {
        Miner storage m = _miners[miner];
        if (!m.registered) revert NotRegistered();
        if (m.reputation > amount) {
            m.reputation -= amount;
        } else {
            m.reputation = 0;
        }
        emit MinerSlashed(miner, amount);
    }

    /**
     * @notice Get miner stats.
     * @param miner The miner address.
     * @return completed Number of completed tasks.
     * @return failed Number of failed tasks.
     * @return reputation Reputation score (0-10000).
     */
    function getMinerStats(address miner)
        external
        view
        returns (uint256 completed, uint256 failed, uint256 reputation)
    {
        if (!_miners[miner].registered) revert NotRegistered();
        Miner storage m = _miners[miner];
        return (m.completed, m.failed, m.reputation);
    }

    /**
     * @notice Get full miner info.
     * @param miner The miner address.
     * @return info The Miner struct.
     */
    function getMiner(address miner) external view returns (Miner memory info) {
        if (!_miners[miner].registered) revert NotRegistered();
        return _miners[miner];
    }

    /**
     * @notice Get total number of registered miners.
     * @return count Miner count.
     */
    function getMinerCount() external view returns (uint256 count) {
        return minerAddresses.length;
    }

    /**
     * @dev Recalculate reputation as completed / total * 10000.
     */
    function _updateReputation(Miner storage m) internal {
        uint256 total = m.completed + m.failed;
        if (total == 0) {
            m.reputation = 10000;
        } else {
            m.reputation = (m.completed * 10000) / total;
        }
    }
}
