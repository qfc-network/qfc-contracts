// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./AgentToken.sol";
import "./BondingCurve.sol";
import "./RevenueDistributor.sol";

/**
 * @title AgentTokenFactory
 * @notice Deploys AgentToken contracts via CREATE2 and manages agent metadata.
 *         Each agent requires a launch fee and gets a bonding curve.
 */
contract AgentTokenFactory is Ownable {
    /// @notice Launch fee required to create an agent (100 QFC)
    uint256 public constant LAUNCH_FEE = 100 ether;

    /// @notice Maximum token supply (1 billion with 18 decimals)
    uint256 public constant MAX_SUPPLY = 1_000_000_000e18;

    struct AgentInfo {
        address tokenAddress;
        address creator;
        bytes32 qvmAgentId;
        string metadataURI;
        bool graduated;
        uint256 createdAt;
    }

    /// @notice Next agent ID to be assigned
    uint256 public nextAgentId;

    /// @notice agentId => AgentInfo
    mapping(uint256 => AgentInfo) public agents;

    /// @notice qvmAgentId => agentId (for reverse lookup)
    mapping(bytes32 => uint256) public qvmToAgentId;

    /// @notice Track which qvmAgentIds have been used
    mapping(bytes32 => bool) private _qvmIdUsed;

    /// @notice Bonding curve contract
    BondingCurve public bondingCurve;

    /// @notice Revenue distributor contract
    RevenueDistributor public revenueDistributor;

    event AgentCreated(
        uint256 indexed agentId,
        address indexed tokenAddress,
        address indexed creator,
        bytes32 qvmAgentId,
        string name,
        string symbol
    );
    event Graduated(uint256 indexed agentId);

    error InsufficientFee();
    error DuplicateQvmAgentId();
    error AgentNotFound();
    error OnlyBondingCurve();
    error ZeroAddress();

    /**
     * @notice Constructs the AgentTokenFactory.
     */
    constructor() Ownable(msg.sender) {}

    /**
     * @notice Set the bonding curve contract. Owner only.
     * @param _bondingCurve Address of the bonding curve
     */
    function setBondingCurve(address _bondingCurve) external onlyOwner {
        if (_bondingCurve == address(0)) revert ZeroAddress();
        bondingCurve = BondingCurve(_bondingCurve);
    }

    /**
     * @notice Set the revenue distributor contract. Owner only.
     * @param _revenueDistributor Address of the revenue distributor
     */
    function setRevenueDistributor(address _revenueDistributor) external onlyOwner {
        if (_revenueDistributor == address(0)) revert ZeroAddress();
        revenueDistributor = RevenueDistributor(_revenueDistributor);
    }

    /**
     * @notice Create a new AI agent with its own ERC-20 token.
     * @param name Token name
     * @param symbol Token symbol
     * @param qvmAgentId QVM agent identifier (unique)
     * @param metadataURI IPFS metadata URI
     * @return agentId The newly assigned agent ID
     */
    function createAgent(
        string calldata name,
        string calldata symbol,
        bytes32 qvmAgentId,
        string calldata metadataURI
    ) external payable returns (uint256 agentId) {
        if (msg.value < LAUNCH_FEE) revert InsufficientFee();
        if (_qvmIdUsed[qvmAgentId]) revert DuplicateQvmAgentId();

        agentId = nextAgentId++;
        _qvmIdUsed[qvmAgentId] = true;

        // Deploy token via CREATE2 for deterministic addressing
        bytes32 salt = keccak256(abi.encodePacked(agentId, qvmAgentId));
        AgentToken token = new AgentToken{salt: salt}(
            name,
            symbol,
            address(this),
            address(bondingCurve),
            address(revenueDistributor),
            metadataURI
        );

        address tokenAddr = address(token);

        agents[agentId] = AgentInfo({
            tokenAddress: tokenAddr,
            creator: msg.sender,
            qvmAgentId: qvmAgentId,
            metadataURI: metadataURI,
            graduated: false,
            createdAt: block.timestamp
        });

        qvmToAgentId[qvmAgentId] = agentId;

        // Initialize bonding curve
        bondingCurve.initializeCurve(agentId, tokenAddr);

        emit AgentCreated(agentId, tokenAddr, msg.sender, qvmAgentId, name, symbol);
    }

    /**
     * @notice Mark an agent as graduated. Only callable by bonding curve.
     * @param agentId The agent ID
     */
    function setGraduated(uint256 agentId) external {
        if (msg.sender != address(bondingCurve)) revert OnlyBondingCurve();
        agents[agentId].graduated = true;
        emit Graduated(agentId);
    }

    /**
     * @notice Get full agent info.
     * @param agentId The agent ID
     * @return info The AgentInfo struct
     */
    function getAgent(uint256 agentId) external view returns (AgentInfo memory info) {
        info = agents[agentId];
        if (info.tokenAddress == address(0)) revert AgentNotFound();
    }

    /**
     * @notice Get agent info by QVM agent ID.
     * @param qvmAgentId The QVM agent identifier
     * @return info The AgentInfo struct
     */
    function getAgentByQvmId(bytes32 qvmAgentId) external view returns (AgentInfo memory info) {
        uint256 agentId = qvmToAgentId[qvmAgentId];
        info = agents[agentId];
        if (info.tokenAddress == address(0)) revert AgentNotFound();
    }

    /**
     * @notice Get total number of agents created.
     * @return count Number of agents
     */
    function agentCount() external view returns (uint256) {
        return nextAgentId;
    }

    /**
     * @notice Withdraw collected launch fees. Owner only.
     */
    function withdrawFees() external onlyOwner {
        (bool success,) = msg.sender.call{value: address(this).balance}("");
        require(success, "Transfer failed");
    }
}
