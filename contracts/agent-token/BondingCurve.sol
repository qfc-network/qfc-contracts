// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./AgentToken.sol";
import "./SigmoidLib.sol";

// Forward declaration
interface IAgentTokenFactory {
    struct AgentInfo {
        address tokenAddress;
        address creator;
        bytes32 qvmAgentId;
        string metadataURI;
        bool graduated;
        uint256 createdAt;
    }

    function agents(uint256 agentId) external view returns (
        address tokenAddress,
        address creator,
        bytes32 qvmAgentId,
        string memory metadataURI,
        bool graduated,
        uint256 createdAt
    );
    function setGraduated(uint256 agentId) external;
}

/**
 * @title BondingCurve
 * @notice Manages sigmoid bonding curves for agent tokens.
 *         Users buy tokens with QFC (native token) and sell back to the curve.
 *         When enough QFC is collected, the agent "graduates" to a DEX.
 */
contract BondingCurve is ReentrancyGuard {
    using SigmoidLib for uint256;

    /// @notice The factory contract
    IAgentTokenFactory public immutable factory;

    /// @notice QFC threshold to trigger graduation
    uint256 public constant GRADUATION_THRESHOLD = 42_000 ether;

    /// @notice Maximum allowed slippage in basis points (5%)
    uint256 public constant MAX_SLIPPAGE_BPS = 500;

    struct CurveState {
        address token;
        uint256 tokensSold;
        uint256 qfcCollected;
        bool graduated;
    }

    /// @notice agentId => curve state
    mapping(uint256 => CurveState) public curves;

    event TokensBought(uint256 indexed agentId, address indexed buyer, uint256 qfcSpent, uint256 tokensReceived);
    event TokensSold(uint256 indexed agentId, address indexed seller, uint256 tokensSold, uint256 qfcReceived);
    event Graduated(uint256 indexed agentId, uint256 totalQfcCollected);

    error AgentNotFound();
    error AlreadyGraduated();
    error SlippageExceeded();
    error InsufficientPayment();
    error InsufficientTokens();
    error TransferFailed();
    error ZeroAmount();

    /**
     * @notice Constructs the BondingCurve.
     * @param _factory Address of the AgentTokenFactory
     */
    constructor(address _factory) {
        factory = IAgentTokenFactory(_factory);
    }

    /**
     * @notice Initialize a curve for an agent. Called by factory during agent creation.
     * @param agentId The agent ID
     * @param token The agent token address
     */
    function initializeCurve(uint256 agentId, address token) external {
        require(msg.sender == address(factory), "Only factory");
        curves[agentId] = CurveState({
            token: token,
            tokensSold: 0,
            qfcCollected: 0,
            graduated: false
        });
    }

    /**
     * @notice Buy agent tokens with QFC.
     * @param agentId The agent ID to buy tokens for
     * @param minTokensOut Minimum tokens expected (slippage protection)
     */
    function buy(uint256 agentId, uint256 minTokensOut) external payable nonReentrant {
        CurveState storage curve = curves[agentId];
        if (curve.token == address(0)) revert AgentNotFound();
        if (curve.graduated) revert AlreadyGraduated();
        if (msg.value == 0) revert InsufficientPayment();

        uint256 tokensOut = SigmoidLib.getTokensForQfc(curve.tokensSold, msg.value);
        if (tokensOut == 0) revert ZeroAmount();
        if (tokensOut < minTokensOut) revert SlippageExceeded();

        curve.tokensSold += tokensOut;
        curve.qfcCollected += msg.value;

        // Mint tokens to buyer
        AgentToken(curve.token).mint(msg.sender, tokensOut);

        emit TokensBought(agentId, msg.sender, msg.value, tokensOut);

        // Check graduation
        if (curve.qfcCollected >= GRADUATION_THRESHOLD) {
            _graduate(agentId);
        }
    }

    /**
     * @notice Sell agent tokens back to the curve for QFC.
     * @param agentId The agent ID
     * @param tokenAmount Amount of tokens to sell
     * @param minQfcOut Minimum QFC expected (slippage protection)
     */
    function sell(uint256 agentId, uint256 tokenAmount, uint256 minQfcOut) external nonReentrant {
        CurveState storage curve = curves[agentId];
        if (curve.token == address(0)) revert AgentNotFound();
        if (curve.graduated) revert AlreadyGraduated();
        if (tokenAmount == 0) revert ZeroAmount();

        AgentToken token = AgentToken(curve.token);
        if (token.balanceOf(msg.sender) < tokenAmount) revert InsufficientTokens();

        // Calculate QFC to return based on the curve
        uint256 newSupply = curve.tokensSold - tokenAmount;
        uint256 qfcOut = SigmoidLib.getCostForTokens(newSupply, tokenAmount);

        if (qfcOut < minQfcOut) revert SlippageExceeded();
        if (qfcOut > curve.qfcCollected) {
            qfcOut = curve.qfcCollected;
        }

        curve.tokensSold -= tokenAmount;
        curve.qfcCollected -= qfcOut;

        // Burn the tokens
        token.burnFrom(msg.sender, tokenAmount);

        // Send QFC back
        (bool success,) = msg.sender.call{value: qfcOut}("");
        if (!success) revert TransferFailed();

        emit TokensSold(agentId, msg.sender, tokenAmount, qfcOut);
    }

    /**
     * @notice Get the current price per token for an agent.
     * @param agentId The agent ID
     * @return price Current price in wei
     */
    function getPrice(uint256 agentId) external view returns (uint256) {
        CurveState storage curve = curves[agentId];
        if (curve.token == address(0)) revert AgentNotFound();
        return SigmoidLib.getPrice(curve.tokensSold);
    }

    /**
     * @notice Get a quote for buying tokens with a given amount of QFC.
     * @param agentId The agent ID
     * @param qfcAmount Amount of QFC
     * @return tokens Number of tokens that would be received
     */
    function getBuyQuote(uint256 agentId, uint256 qfcAmount) external view returns (uint256) {
        CurveState storage curve = curves[agentId];
        if (curve.token == address(0)) revert AgentNotFound();
        return SigmoidLib.getTokensForQfc(curve.tokensSold, qfcAmount);
    }

    /**
     * @notice Get a quote for selling tokens for QFC.
     * @param agentId The agent ID
     * @param tokenAmount Amount of tokens to sell
     * @return qfcOut Amount of QFC that would be received
     */
    function getSellQuote(uint256 agentId, uint256 tokenAmount) external view returns (uint256) {
        CurveState storage curve = curves[agentId];
        if (curve.token == address(0)) revert AgentNotFound();
        if (tokenAmount > curve.tokensSold) revert InsufficientTokens();
        uint256 newSupply = curve.tokensSold - tokenAmount;
        return SigmoidLib.getCostForTokens(newSupply, tokenAmount);
    }

    /**
     * @dev Graduate the agent — triggered when graduation threshold is reached.
     */
    function _graduate(uint256 agentId) internal {
        CurveState storage curve = curves[agentId];
        curve.graduated = true;
        factory.setGraduated(agentId);
        emit Graduated(agentId, curve.qfcCollected);
    }
}
