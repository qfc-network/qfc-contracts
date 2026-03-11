// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MinerRegistry
 * @notice GPU miner registration and tier system for QFC inference network.
 *         Miners register with hardware specs and are assigned tiers (1-3)
 *         based on GPU capability class.
 */
contract MinerRegistry is Ownable {
    enum MinerStatus { Inactive, Active, Suspended }

    struct Miner {
        address minerAddress;
        string gpuModel;       // e.g. "RTX 4090", "A100"
        uint8 tier;            // 1 = consumer, 2 = prosumer, 3 = datacenter
        uint256 stake;         // staked QFC for slashing
        MinerStatus status;
        uint256 tasksCompleted;
        uint256 tasksFailed;
        uint256 registeredAt;
        uint256 lastActiveAt;
    }

    uint256 public minStake;

    /// @dev miner address => Miner
    mapping(address => Miner) private _miners;
    address[] private _minerList;
    /// @dev authorized callers (TaskRegistry, ResultVerifier)
    mapping(address => bool) public authorizedCallers;

    event MinerRegistered(address indexed miner, string gpuModel, uint8 tier);
    event MinerActivated(address indexed miner);
    event MinerDeactivated(address indexed miner);
    event MinerSuspended(address indexed miner, string reason);
    event MinerStakeUpdated(address indexed miner, uint256 newStake);
    event MinerSlashed(address indexed miner, uint256 amount);
    event MinStakeUpdated(uint256 newMinStake);
    event CallerAuthorized(address indexed caller);
    event CallerRevoked(address indexed caller);

    error AlreadyRegistered();
    error NotRegistered();
    error InsufficientStake(uint256 required, uint256 provided);
    error InvalidTier(uint8 tier);
    error MinerNotActive();
    error NothingToWithdraw();
    error NotAuthorized();

    modifier onlyAuthorized() {
        if (!authorizedCallers[msg.sender] && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    constructor(uint256 _minStake) Ownable(msg.sender) {
        minStake = _minStake;
    }

    /// @notice Authorize a caller (TaskRegistry, ResultVerifier)
    function authorizeCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = true;
        emit CallerAuthorized(caller);
    }

    /// @notice Revoke a caller's authorization
    function revokeCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = false;
        emit CallerRevoked(caller);
    }

    /// @notice Register as a miner with GPU specs and stake
    /// @param gpuModel GPU model string
    /// @param tier Miner tier (1-3)
    function register(string calldata gpuModel, uint8 tier) external payable {
        if (_miners[msg.sender].registeredAt != 0) revert AlreadyRegistered();
        if (tier == 0 || tier > 3) revert InvalidTier(tier);
        if (msg.value < minStake) revert InsufficientStake(minStake, msg.value);

        _miners[msg.sender] = Miner({
            minerAddress: msg.sender,
            gpuModel: gpuModel,
            tier: tier,
            stake: msg.value,
            status: MinerStatus.Active,
            tasksCompleted: 0,
            tasksFailed: 0,
            registeredAt: block.timestamp,
            lastActiveAt: block.timestamp
        });
        _minerList.push(msg.sender);

        emit MinerRegistered(msg.sender, gpuModel, tier);
        emit MinerActivated(msg.sender);
    }

    /// @notice Add more stake
    function addStake() external payable {
        if (_miners[msg.sender].registeredAt == 0) revert NotRegistered();
        _miners[msg.sender].stake += msg.value;
        emit MinerStakeUpdated(msg.sender, _miners[msg.sender].stake);
    }

    /// @notice Deactivate self (must withdraw stake separately)
    function deactivate() external {
        Miner storage m = _miners[msg.sender];
        if (m.registeredAt == 0) revert NotRegistered();
        m.status = MinerStatus.Inactive;
        emit MinerDeactivated(msg.sender);
    }

    /// @notice Reactivate after deactivation
    function activate() external {
        Miner storage m = _miners[msg.sender];
        if (m.registeredAt == 0) revert NotRegistered();
        if (m.stake < minStake) revert InsufficientStake(minStake, m.stake);
        m.status = MinerStatus.Active;
        m.lastActiveAt = block.timestamp;
        emit MinerActivated(msg.sender);
    }

    /// @notice Withdraw stake (only when inactive)
    function withdrawStake(uint256 amount) external {
        Miner storage m = _miners[msg.sender];
        if (m.registeredAt == 0) revert NotRegistered();
        if (m.status == MinerStatus.Active) revert MinerNotActive();
        if (amount == 0 || amount > m.stake) revert NothingToWithdraw();
        m.stake -= amount;
        payable(msg.sender).transfer(amount);
        emit MinerStakeUpdated(msg.sender, m.stake);
    }

    /// @notice Suspend a miner (admin only)
    function suspendMiner(address miner, string calldata reason) external onlyOwner {
        if (_miners[miner].registeredAt == 0) revert NotRegistered();
        _miners[miner].status = MinerStatus.Suspended;
        emit MinerSuspended(miner, reason);
    }

    /// @notice Slash a miner's stake (called by ResultVerifier)
    function slash(address miner, uint256 amount) external onlyAuthorized {
        Miner storage m = _miners[miner];
        if (m.registeredAt == 0) revert NotRegistered();
        uint256 slashAmount = amount > m.stake ? m.stake : amount;
        m.stake -= slashAmount;
        emit MinerSlashed(miner, slashAmount);
    }

    /// @notice Record task completion (called by TaskRegistry)
    function recordTaskCompleted(address miner) external onlyAuthorized {
        _miners[miner].tasksCompleted++;
        _miners[miner].lastActiveAt = block.timestamp;
    }

    /// @notice Record task failure (called by ResultVerifier)
    function recordTaskFailed(address miner) external onlyAuthorized {
        _miners[miner].tasksFailed++;
    }

    /// @notice Update minimum stake requirement
    function setMinStake(uint256 _minStake) external onlyOwner {
        minStake = _minStake;
        emit MinStakeUpdated(_minStake);
    }

    /// @notice Check if miner is active and meets tier requirement
    function isEligible(address miner, uint8 requiredTier) external view returns (bool) {
        Miner storage m = _miners[miner];
        return m.status == MinerStatus.Active && m.tier >= requiredTier;
    }

    /// @notice Get miner details
    function getMiner(address miner) external view returns (Miner memory) {
        if (_miners[miner].registeredAt == 0) revert NotRegistered();
        return _miners[miner];
    }

    /// @notice Total registered miners
    function minerCount() external view returns (uint256) {
        return _minerList.length;
    }

    /// @notice Get miner address by index
    function minerAtIndex(uint256 index) external view returns (address) {
        return _minerList[index];
    }
}
