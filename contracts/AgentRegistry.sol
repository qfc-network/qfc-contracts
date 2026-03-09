// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AgentRegistry
 * @notice Native AI Agent wallet support for QFC blockchain.
 *         Agents can hold funds, submit transactions, and operate
 *         within permission scopes set by their human owners.
 */
contract AgentRegistry {
    enum Permission {
        InferenceSubmit,   // can submit inference tasks
        Transfer,          // can send QFC, capped per tx
        StakeDelegate,     // can delegate stake
        QueryOnly          // read-only (no tx)
    }

    struct AgentAccount {
        string agentId;
        address owner;
        address agentAddress;
        Permission[] permissions;
        uint256 dailyLimit;       // max QFC spend per day (wei)
        uint256 maxPerTx;         // max QFC per transfer tx (wei)
        uint256 deposit;          // owner-funded balance
        uint256 spentToday;
        uint256 lastSpendDay;     // day number (block.timestamp / 86400)
        uint256 registeredAt;
        bool active;
    }

    struct SessionKey {
        address key;
        string agentId;
        uint256 expiresAt;
        bool revoked;
    }

    // agentId => AgentAccount
    mapping(string => AgentAccount) public agents;
    // sessionKeyAddress => SessionKey
    mapping(address => SessionKey) public sessionKeys;
    // owner => agentIds
    mapping(address => string[]) private ownerAgents;

    event AgentRegistered(string indexed agentId, address indexed owner, address agentAddress);
    event AgentFunded(string indexed agentId, uint256 amount);
    event AgentRevoked(string indexed agentId);
    event SessionKeyIssued(string indexed agentId, address key, uint256 expiresAt);
    event SessionKeyRevoked(address indexed key);
    event AgentSpent(string indexed agentId, uint256 amount, string action);

    modifier onlyOwner(string memory agentId) {
        require(agents[agentId].owner == msg.sender, "Not agent owner");
        _;
    }

    modifier agentActive(string memory agentId) {
        require(agents[agentId].active, "Agent not active");
        _;
    }

    // ─── Registration ──────────────────────────────────────────────────────────

    function registerAgent(
        string memory agentId,
        address agentAddress,
        Permission[] memory permissions,
        uint256 dailyLimit,
        uint256 maxPerTx
    ) external payable returns (string memory) {
        require(bytes(agentId).length > 0, "Agent ID required");
        require(agentAddress != address(0), "Invalid agent address");
        require(agents[agentId].registeredAt == 0, "Agent ID already taken");

        agents[agentId] = AgentAccount({
            agentId: agentId,
            owner: msg.sender,
            agentAddress: agentAddress,
            permissions: permissions,
            dailyLimit: dailyLimit,
            maxPerTx: maxPerTx,
            deposit: msg.value,
            spentToday: 0,
            lastSpendDay: block.timestamp / 86400,
            registeredAt: block.timestamp,
            active: true
        });

        ownerAgents[msg.sender].push(agentId);
        emit AgentRegistered(agentId, msg.sender, agentAddress);
        return agentId;
    }

    function fundAgent(string memory agentId) external payable agentActive(agentId) {
        require(msg.value > 0, "Must send QFC");
        agents[agentId].deposit += msg.value;
        emit AgentFunded(agentId, msg.value);
    }

    function revokeAgent(string memory agentId) external onlyOwner(agentId) {
        AgentAccount storage agent = agents[agentId];
        agent.active = false;
        uint256 refund = agent.deposit;
        agent.deposit = 0;
        if (refund > 0) {
            payable(msg.sender).transfer(refund);
        }
        emit AgentRevoked(agentId);
    }

    // ─── Session Keys ──────────────────────────────────────────────────────────

    function issueSessionKey(
        string memory agentId,
        address sessionKeyAddress,
        uint256 durationSeconds
    ) external onlyOwner(agentId) agentActive(agentId) {
        require(sessionKeyAddress != address(0), "Invalid key address");
        require(durationSeconds <= 7 days, "Max 7 days");

        sessionKeys[sessionKeyAddress] = SessionKey({
            key: sessionKeyAddress,
            agentId: agentId,
            expiresAt: block.timestamp + durationSeconds,
            revoked: false
        });

        emit SessionKeyIssued(agentId, sessionKeyAddress, block.timestamp + durationSeconds);
    }

    function revokeSessionKey(address keyAddress) external {
        SessionKey storage sk = sessionKeys[keyAddress];
        require(
            agents[sk.agentId].owner == msg.sender || sk.key == msg.sender,
            "Not authorized"
        );
        sk.revoked = true;
        emit SessionKeyRevoked(keyAddress);
    }

    // ─── Spending / Actions ────────────────────────────────────────────────────

    function _refreshDailySpend(AgentAccount storage agent) internal {
        uint256 today = block.timestamp / 86400;
        if (agent.lastSpendDay < today) {
            agent.spentToday = 0;
            agent.lastSpendDay = today;
        }
    }

    function _hasPermission(AgentAccount storage agent, Permission perm) internal view returns (bool) {
        for (uint i = 0; i < agent.permissions.length; i++) {
            if (agent.permissions[i] == perm) return true;
        }
        return false;
    }

    function _isValidCaller(string memory agentId) internal view returns (bool) {
        AgentAccount storage agent = agents[agentId];
        if (msg.sender == agent.agentAddress) return true;
        SessionKey storage sk = sessionKeys[msg.sender];
        if (keccak256(bytes(sk.agentId)) == keccak256(bytes(agentId))) {
            if (!sk.revoked && sk.expiresAt > block.timestamp) return true;
        }
        return false;
    }

    /**
     * @notice Agent transfers QFC to a recipient (subject to permissions + limits)
     */
    function agentTransfer(
        string memory agentId,
        address payable recipient,
        uint256 amount
    ) external agentActive(agentId) {
        require(_isValidCaller(agentId), "Not authorized agent/session key");
        AgentAccount storage agent = agents[agentId];
        require(_hasPermission(agent, Permission.Transfer), "No transfer permission");
        require(amount <= agent.maxPerTx, "Exceeds per-tx limit");
        require(agent.deposit >= amount, "Insufficient deposit");

        _refreshDailySpend(agent);
        require(agent.spentToday + amount <= agent.dailyLimit, "Daily limit exceeded");

        agent.deposit -= amount;
        agent.spentToday += amount;
        recipient.transfer(amount);

        emit AgentSpent(agentId, amount, "transfer");
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    function getAgent(string memory agentId) external view returns (AgentAccount memory) {
        return agents[agentId];
    }

    function getAgentsByOwner(address owner) external view returns (string[] memory) {
        return ownerAgents[owner];
    }

    function isSessionKeyValid(address keyAddress) external view returns (bool) {
        SessionKey storage sk = sessionKeys[keyAddress];
        return !sk.revoked && sk.expiresAt > block.timestamp && sk.key != address(0);
    }

    function getAgentForSessionKey(address keyAddress) external view returns (string memory) {
        return sessionKeys[keyAddress].agentId;
    }
}
