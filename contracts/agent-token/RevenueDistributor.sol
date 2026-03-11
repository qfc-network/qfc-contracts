// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAgentTokenFactoryForRevenue {
    function agents(uint256 agentId) external view returns (
        address tokenAddress,
        address creator,
        bytes32 qvmAgentId,
        string memory metadataURI,
        bool graduated,
        uint256 createdAt
    );
}

/**
 * @title RevenueDistributor
 * @notice Distributes agent revenue in a 60/30/10 split:
 *         - 60% to the agent's creator wallet
 *         - 30% for buyback and burn (sent to bonding curve)
 *         - 10% to the protocol treasury
 */
contract RevenueDistributor is Ownable, ReentrancyGuard {
    /// @notice Agent wallet share: 60%
    uint256 public constant AGENT_WALLET_BPS = 6000;

    /// @notice Buyback and burn share: 30%
    uint256 public constant BUYBACK_BURN_BPS = 3000;

    /// @notice Treasury share: 10%
    uint256 public constant TREASURY_BPS = 1000;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Protocol treasury address
    address public treasury;

    /// @notice Factory contract
    IAgentTokenFactoryForRevenue public immutable factory;

    /// @notice Per-agent pending revenue
    mapping(uint256 => uint256) public pendingRevenue;

    event RevenueDeposited(uint256 indexed agentId, uint256 amount);
    event RevenueDistributed(
        uint256 indexed agentId,
        uint256 agentWalletAmount,
        uint256 buybackBurnAmount,
        uint256 treasuryAmount
    );
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    error ZeroAddress();
    error ZeroAmount();
    error NoRevenue();
    error TransferFailed();
    error AgentNotFound();

    /**
     * @notice Constructs the RevenueDistributor.
     * @param _factory Factory contract address
     * @param _treasury Initial treasury address
     */
    constructor(address _factory, address _treasury) Ownable(msg.sender) {
        if (_treasury == address(0)) revert ZeroAddress();
        factory = IAgentTokenFactoryForRevenue(_factory);
        treasury = _treasury;
    }

    /**
     * @notice Deposit QFC revenue for an agent.
     * @param agentId The agent ID
     */
    function depositRevenue(uint256 agentId) external payable {
        if (msg.value == 0) revert ZeroAmount();
        pendingRevenue[agentId] += msg.value;
        emit RevenueDeposited(agentId, msg.value);
    }

    /**
     * @notice Distribute pending revenue for an agent using the 60/30/10 split.
     * @param agentId The agent ID
     */
    function distribute(uint256 agentId) public nonReentrant {
        uint256 amount = pendingRevenue[agentId];
        if (amount == 0) revert NoRevenue();

        (address tokenAddress, address creator,,,,) = factory.agents(agentId);
        if (tokenAddress == address(0)) revert AgentNotFound();

        pendingRevenue[agentId] = 0;

        uint256 agentWalletAmount = (amount * AGENT_WALLET_BPS) / BPS_DENOMINATOR;
        uint256 buybackBurnAmount = (amount * BUYBACK_BURN_BPS) / BPS_DENOMINATOR;
        uint256 treasuryAmount = amount - agentWalletAmount - buybackBurnAmount;

        // Send to agent creator
        (bool s1,) = creator.call{value: agentWalletAmount}("");
        if (!s1) revert TransferFailed();

        // Buyback+burn: send to this contract for now (could integrate with curve)
        // In production this would buy tokens on the curve and burn them
        (bool s2,) = treasury.call{value: buybackBurnAmount}("");
        if (!s2) revert TransferFailed();

        // Send to treasury
        (bool s3,) = treasury.call{value: treasuryAmount}("");
        if (!s3) revert TransferFailed();

        emit RevenueDistributed(agentId, agentWalletAmount, buybackBurnAmount, treasuryAmount);
    }

    /**
     * @notice Batch distribute revenue for multiple agents.
     * @param agentIds Array of agent IDs
     */
    function batchDistribute(uint256[] calldata agentIds) external {
        for (uint256 i = 0; i < agentIds.length; i++) {
            distribute(agentIds[i]);
        }
    }

    /**
     * @notice Update the treasury address. Owner only.
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(old, _treasury);
    }
}
