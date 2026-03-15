// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title PriceFeedV2
 * @notice Decentralized multi-source oracle for QFC/USD price with TWAP,
 *         circuit breaker, heartbeat, and price history.
 * @dev Backward-compatible with PriceFeed.getLatestPrice() interface.
 *      Multiple authorized reporters submit prices; the median is used.
 */
contract PriceFeedV2 is AccessControl, Pausable {
    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    uint8 public constant DECIMALS = 8;

    // --- Configuration ---

    /// @notice Maximum allowed deviation between reports (basis points, default 500 = 5%)
    uint256 public maxDeviationBps = 500;

    /// @notice Maximum age of a price before it's considered stale (default 1 hour)
    uint256 public heartbeatInterval = 1 hours;

    /// @notice Minimum number of reporters required for a valid round
    uint256 public minReporters = 1;

    /// @notice TWAP observation window (default 1 hour)
    uint256 public twapWindow = 1 hours;

    // --- Price state ---

    struct Round {
        uint256 price;       // Median price with 8 decimals
        uint256 timestamp;   // Block timestamp of the round
        uint256 reportCount; // Number of reports in this round
    }

    /// @notice Current round ID (incremented on each finalized update)
    uint256 public currentRoundId;

    /// @notice Historical rounds (ring buffer of last HISTORY_SIZE rounds)
    uint256 public constant HISTORY_SIZE = 256;
    mapping(uint256 => Round) public rounds;

    /// @notice Pending reports for the current (unfinalized) round
    address[] internal _currentReporters;
    uint256[] internal _currentPrices;

    // --- TWAP observations ---

    struct Observation {
        uint256 cumulativePrice;
        uint256 timestamp;
    }

    Observation[] public observations;

    // --- Circuit breaker ---

    /// @notice Whether the circuit breaker has been tripped
    bool public circuitBroken;

    // --- Errors ---

    error InvalidPrice();
    error StalePrice();
    error CircuitBreakerActive();
    error AlreadyReported();
    error DeviationTooHigh(uint256 reportedPrice, uint256 medianPrice, uint256 deviationBps);
    error InsufficientReporters(uint256 have, uint256 need);
    error InvalidConfiguration();

    // --- Events ---

    event PriceUpdated(uint256 indexed roundId, uint256 price, uint256 timestamp, uint256 reportCount);
    event PriceReported(address indexed reporter, uint256 price, uint256 roundId);
    event CircuitBreakerTripped(uint256 price, uint256 previousPrice, uint256 deviationBps);
    event CircuitBreakerReset();
    event EmergencyPriceSet(uint256 price, address indexed setter);
    event ConfigUpdated(string param, uint256 value);

    constructor(uint256 _initialPrice, address _admin) {
        if (_initialPrice == 0) revert InvalidPrice();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(REPORTER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);

        // Initialize round 1
        currentRoundId = 1;
        rounds[1] = Round({price: _initialPrice, timestamp: block.timestamp, reportCount: 1});

        // Initialize TWAP
        observations.push(Observation({cumulativePrice: 0, timestamp: block.timestamp}));
    }

    // =========================================================================
    // Reporter interface
    // =========================================================================

    /**
     * @notice Submit a price report for the current round
     * @param _price QFC/USD price with 8 decimals
     */
    function reportPrice(uint256 _price) external onlyRole(REPORTER_ROLE) whenNotPaused {
        if (_price == 0) revert InvalidPrice();
        if (circuitBroken) revert CircuitBreakerActive();

        // Prevent double-reporting in same round
        for (uint256 i = 0; i < _currentReporters.length; i++) {
            if (_currentReporters[i] == msg.sender) revert AlreadyReported();
        }

        _currentReporters.push(msg.sender);
        _currentPrices.push(_price);

        emit PriceReported(msg.sender, _price, currentRoundId + 1);

        // Auto-finalize when enough reporters have submitted
        if (_currentPrices.length >= minReporters) {
            _finalizeRound();
        }
    }

    // =========================================================================
    // Read interface (backward-compatible)
    // =========================================================================

    /**
     * @notice Get the latest QFC/USD price (PriceFeed V1 compatible)
     */
    function getLatestPrice()
        external
        view
        returns (uint256 _price, uint256 _updatedAt, uint8 _decimals)
    {
        Round memory r = rounds[currentRoundId];
        if (r.price == 0) revert InvalidPrice();
        if (block.timestamp - r.timestamp > heartbeatInterval) revert StalePrice();
        if (circuitBroken) revert CircuitBreakerActive();
        return (r.price, r.timestamp, DECIMALS);
    }

    /// @notice Convenience getter matching V1 interface
    function price() external view returns (uint256) {
        return rounds[currentRoundId].price;
    }

    /// @notice Convenience getter matching V1 interface
    function updatedAt() external view returns (uint256) {
        return rounds[currentRoundId].timestamp;
    }

    /**
     * @notice Get price for a specific round
     */
    function getRoundData(uint256 _roundId)
        external
        view
        returns (uint256 _price, uint256 _updatedAt, uint256 _reportCount)
    {
        Round memory r = rounds[_roundId];
        return (r.price, r.timestamp, r.reportCount);
    }

    /**
     * @notice Calculate TWAP over the configured window
     * @return twapPrice Time-weighted average price with 8 decimals
     */
    function getTWAP() external view returns (uint256 twapPrice) {
        uint256 len = observations.length;
        if (len < 2) return rounds[currentRoundId].price;

        Observation memory latest = observations[len - 1];
        uint256 targetTime = block.timestamp > twapWindow ? block.timestamp - twapWindow : 0;

        // Find the oldest observation within the window
        uint256 oldestIdx = len - 1;
        for (uint256 i = len - 1; i > 0; i--) {
            if (observations[i - 1].timestamp < targetTime) {
                oldestIdx = i;
                break;
            }
            oldestIdx = i - 1;
        }

        Observation memory oldest = observations[oldestIdx];
        uint256 timeDelta = latest.timestamp - oldest.timestamp;
        if (timeDelta == 0) return rounds[currentRoundId].price;

        return (latest.cumulativePrice - oldest.cumulativePrice) / timeDelta;
    }

    // =========================================================================
    // Emergency controls
    // =========================================================================

    /**
     * @notice Emergency price override (when all feeds are down)
     * @param _price Emergency price with 8 decimals
     */
    function setEmergencyPrice(uint256 _price) external onlyRole(EMERGENCY_ROLE) {
        if (_price == 0) revert InvalidPrice();

        currentRoundId++;
        rounds[currentRoundId] = Round({
            price: _price,
            timestamp: block.timestamp,
            reportCount: 0 // 0 indicates emergency override
        });

        _updateTWAP(_price);

        if (circuitBroken) {
            circuitBroken = false;
            emit CircuitBreakerReset();
        }

        emit EmergencyPriceSet(_price, msg.sender);
        emit PriceUpdated(currentRoundId, _price, block.timestamp, 0);
    }

    /**
     * @notice Reset the circuit breaker after investigation
     */
    function resetCircuitBreaker() external onlyRole(EMERGENCY_ROLE) {
        circuitBroken = false;
        emit CircuitBreakerReset();
    }

    // =========================================================================
    // Admin configuration
    // =========================================================================

    function setMaxDeviationBps(uint256 _bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_bps == 0 || _bps > 5000) revert InvalidConfiguration();
        maxDeviationBps = _bps;
        emit ConfigUpdated("maxDeviationBps", _bps);
    }

    function setHeartbeatInterval(uint256 _seconds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_seconds < 60 || _seconds > 24 hours) revert InvalidConfiguration();
        heartbeatInterval = _seconds;
        emit ConfigUpdated("heartbeatInterval", _seconds);
    }

    function setMinReporters(uint256 _count) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_count == 0) revert InvalidConfiguration();
        minReporters = _count;
        emit ConfigUpdated("minReporters", _count);
    }

    function setTwapWindow(uint256 _seconds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_seconds < 5 minutes || _seconds > 24 hours) revert InvalidConfiguration();
        twapWindow = _seconds;
        emit ConfigUpdated("twapWindow", _seconds);
    }

    /// @notice Pause all price reporting (emergency)
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /// @notice Resume price reporting
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // =========================================================================
    // V1 compatibility — owner-style setPrice (for migration period)
    // =========================================================================

    /**
     * @notice Direct price set for backward compatibility (admin only)
     * @dev Use reportPrice() for production. This exists for migration from V1.
     */
    function setPrice(uint256 _price) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_price == 0) revert InvalidPrice();

        uint256 previousPrice = rounds[currentRoundId].price;

        // Check circuit breaker
        if (previousPrice > 0) {
            uint256 deviation = _calculateDeviation(_price, previousPrice);
            if (deviation > maxDeviationBps) {
                circuitBroken = true;
                emit CircuitBreakerTripped(_price, previousPrice, deviation);
                revert DeviationTooHigh(_price, previousPrice, deviation);
            }
        }

        currentRoundId++;
        rounds[currentRoundId] = Round({price: _price, timestamp: block.timestamp, reportCount: 1});
        _updateTWAP(_price);
        emit PriceUpdated(currentRoundId, _price, block.timestamp, 1);
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _finalizeRound() internal {
        uint256 median = _calculateMedian(_currentPrices);
        uint256 previousPrice = rounds[currentRoundId].price;

        // Circuit breaker check against previous round
        if (previousPrice > 0) {
            uint256 deviation = _calculateDeviation(median, previousPrice);
            if (deviation > maxDeviationBps) {
                circuitBroken = true;
                emit CircuitBreakerTripped(median, previousPrice, deviation);
                // Clear pending reports
                delete _currentReporters;
                delete _currentPrices;
                return;
            }
        }

        currentRoundId++;
        rounds[currentRoundId] = Round({
            price: median,
            timestamp: block.timestamp,
            reportCount: _currentPrices.length
        });

        _updateTWAP(median);

        emit PriceUpdated(currentRoundId, median, block.timestamp, _currentPrices.length);

        // Clear pending reports for next round
        delete _currentReporters;
        delete _currentPrices;
    }

    function _updateTWAP(uint256 _price) internal {
        uint256 len = observations.length;
        Observation memory last = observations[len - 1];
        uint256 elapsed = block.timestamp - last.timestamp;

        observations.push(Observation({
            cumulativePrice: last.cumulativePrice + (_price * elapsed),
            timestamp: block.timestamp
        }));
    }

    function _calculateMedian(uint256[] memory prices) internal pure returns (uint256) {
        uint256 len = prices.length;
        if (len == 1) return prices[0];

        // Simple insertion sort (small arrays)
        for (uint256 i = 1; i < len; i++) {
            uint256 key = prices[i];
            uint256 j = i;
            while (j > 0 && prices[j - 1] > key) {
                prices[j] = prices[j - 1];
                j--;
            }
            prices[j] = key;
        }

        if (len % 2 == 1) {
            return prices[len / 2];
        } else {
            return (prices[len / 2 - 1] + prices[len / 2]) / 2;
        }
    }

    function _calculateDeviation(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 diff = a > b ? a - b : b - a;
        return (diff * 10000) / b;
    }
}
