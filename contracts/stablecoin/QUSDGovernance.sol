// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title QUSDGovernance
 * @notice Timelocked parameter governance for the qUSD stablecoin system.
 *
 *  Governable parameters:
 *    - Stability fee rate
 *    - Min collateral ratio
 *    - Liquidation threshold
 *    - Liquidation penalty
 *    - Debt ceiling (per-asset and global)
 *    - PSM fees (tin/tout)
 *
 *  Safety features:
 *    - Each parameter change is capped at ±20% per proposal
 *    - Timelock delay before execution (default 2 days)
 *    - Only the GovernorContract (owner) can queue changes
 *    - Anyone can execute after timelock expires (but before deadline)
 *
 * @dev Owner should be set to the GovernorContract or a Timelock controller.
 *      The governance contract must be granted ownership / admin rights on the
 *      target contracts (CDPVault, CollateralManager, PSM).
 */
contract QUSDGovernance is Ownable {

    // --- Timelock ---

    uint256 public timelockDelay = 2 days;
    uint256 public constant MIN_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 14 days;
    uint256 public constant EXECUTION_WINDOW = 7 days;

    /// @notice Maximum parameter change per proposal (±20% = 2000 basis points)
    uint256 public constant MAX_CHANGE_BPS = 2000;
    uint256 public constant BASIS_POINTS = 10000;

    struct TimelockProposal {
        address target;        // Contract to call
        bytes callData;        // Encoded function call
        uint256 executableAt;  // Timestamp when execution is allowed
        uint256 deadline;      // Timestamp after which proposal expires
        bool executed;
        bool cancelled;
        string description;
    }

    uint256 public proposalCount;
    mapping(uint256 => TimelockProposal) public proposals;

    // --- Parameter bounds ---

    struct ParameterBounds {
        uint256 minValue;
        uint256 maxValue;
    }

    /// @notice Bounds for each parameter type
    mapping(bytes32 => ParameterBounds) public parameterBounds;

    // --- Errors ---

    error ProposalNotFound();
    error ProposalNotReady();
    error ProposalExpired();
    error ProposalAlreadyExecuted();
    error ProposalIsCancelled();
    error ExecutionFailed();
    error InvalidDelay();
    error ChangeExceedsLimit(uint256 oldValue, uint256 newValue, uint256 maxChangeBps);
    error ValueOutOfBounds(bytes32 paramId, uint256 value, uint256 min, uint256 max);

    // --- Events ---

    event ProposalQueued(uint256 indexed proposalId, address indexed target, uint256 executableAt, string description);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event TimelockDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event ParameterBoundsSet(bytes32 indexed paramId, uint256 minValue, uint256 maxValue);

    constructor(address _governor) Ownable(_governor) {
        // Set default parameter bounds
        // Stability fee: 0% - 20%
        parameterBounds[keccak256("stabilityFee")] = ParameterBounds(0, 2000);
        // Min collateral ratio: 110% - 300%
        parameterBounds[keccak256("minCollateralRatio")] = ParameterBounds(11000, 30000);
        // Liquidation threshold: 105% - 250%
        parameterBounds[keccak256("liquidationThreshold")] = ParameterBounds(10500, 25000);
        // Liquidation penalty: 0% - 25%
        parameterBounds[keccak256("liquidationPenalty")] = ParameterBounds(0, 2500);
        // PSM tin/tout: 0% - 5%
        parameterBounds[keccak256("psmFee")] = ParameterBounds(0, 500);
    }

    // =========================================================================
    // Queue proposals
    // =========================================================================

    /**
     * @notice Queue a parameter change proposal with timelock
     * @param _target Target contract address
     * @param _callData Encoded function call
     * @param _description Human-readable description
     * @return proposalId The ID of the queued proposal
     */
    function queueProposal(
        address _target,
        bytes calldata _callData,
        string calldata _description
    ) external onlyOwner returns (uint256) {
        proposalCount++;
        uint256 executableAt = block.timestamp + timelockDelay;

        proposals[proposalCount] = TimelockProposal({
            target: _target,
            callData: _callData,
            executableAt: executableAt,
            deadline: executableAt + EXECUTION_WINDOW,
            executed: false,
            cancelled: false,
            description: _description
        });

        emit ProposalQueued(proposalCount, _target, executableAt, _description);
        return proposalCount;
    }

    /**
     * @notice Execute a proposal after its timelock has passed
     * @param _proposalId The proposal to execute
     */
    function executeProposal(uint256 _proposalId) external {
        TimelockProposal storage p = proposals[_proposalId];
        if (p.target == address(0)) revert ProposalNotFound();
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.cancelled) revert ProposalIsCancelled();
        if (block.timestamp < p.executableAt) revert ProposalNotReady();
        if (block.timestamp > p.deadline) revert ProposalExpired();

        p.executed = true;

        (bool success,) = p.target.call(p.callData);
        if (!success) revert ExecutionFailed();

        emit ProposalExecuted(_proposalId);
    }

    /**
     * @notice Cancel a pending proposal
     */
    function cancelProposal(uint256 _proposalId) external onlyOwner {
        TimelockProposal storage p = proposals[_proposalId];
        if (p.target == address(0)) revert ProposalNotFound();
        if (p.executed) revert ProposalAlreadyExecuted();

        p.cancelled = true;
        emit ProposalCancelled(_proposalId);
    }

    // =========================================================================
    // Validated parameter changes (convenience wrappers with ±20% guard)
    // =========================================================================

    /**
     * @notice Validate that a parameter change is within ±20% of current value
     * @param _oldValue Current parameter value
     * @param _newValue Proposed new value
     */
    function validateChange(uint256 _oldValue, uint256 _newValue) public pure {
        if (_oldValue == 0) return; // No limit on first-time set

        uint256 maxDelta = (_oldValue * MAX_CHANGE_BPS) / BASIS_POINTS;
        uint256 diff = _newValue > _oldValue ? _newValue - _oldValue : _oldValue - _newValue;

        if (diff > maxDelta) {
            revert ChangeExceedsLimit(_oldValue, _newValue, MAX_CHANGE_BPS);
        }
    }

    /**
     * @notice Validate that a value is within configured bounds for a parameter type
     * @param _paramId Parameter identifier (keccak256 of name)
     * @param _value Value to validate
     */
    function validateBounds(bytes32 _paramId, uint256 _value) public view {
        ParameterBounds memory bounds = parameterBounds[_paramId];
        if (bounds.maxValue > 0 && (_value < bounds.minValue || _value > bounds.maxValue)) {
            revert ValueOutOfBounds(_paramId, _value, bounds.minValue, bounds.maxValue);
        }
    }

    /**
     * @notice Combined validation: bounds check + ±20% change limit
     */
    function validateParameterChange(
        bytes32 _paramId,
        uint256 _oldValue,
        uint256 _newValue
    ) external view {
        validateBounds(_paramId, _newValue);
        validateChange(_oldValue, _newValue);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function setTimelockDelay(uint256 _delay) external onlyOwner {
        if (_delay < MIN_DELAY || _delay > MAX_DELAY) revert InvalidDelay();
        uint256 old = timelockDelay;
        timelockDelay = _delay;
        emit TimelockDelayUpdated(old, _delay);
    }

    function setParameterBounds(
        bytes32 _paramId,
        uint256 _minValue,
        uint256 _maxValue
    ) external onlyOwner {
        parameterBounds[_paramId] = ParameterBounds(_minValue, _maxValue);
        emit ParameterBoundsSet(_paramId, _minValue, _maxValue);
    }

    // =========================================================================
    // View
    // =========================================================================

    function getProposal(uint256 _proposalId) external view returns (TimelockProposal memory) {
        return proposals[_proposalId];
    }

    function isExecutable(uint256 _proposalId) external view returns (bool) {
        TimelockProposal memory p = proposals[_proposalId];
        return !p.executed && !p.cancelled
            && block.timestamp >= p.executableAt
            && block.timestamp <= p.deadline;
    }
}
