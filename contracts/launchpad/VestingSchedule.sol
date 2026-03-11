// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title VestingSchedule
 * @notice Linear token vesting with cliff period. Owner can revoke unvested tokens.
 */
contract VestingSchedule is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Schedule {
        address beneficiary;
        IERC20 token;
        uint256 totalAmount;
        uint256 startTime;
        uint256 cliffDuration;
        uint256 totalDuration;
        uint256 claimed;
        bool revoked;
    }

    uint256 public nextScheduleId;

    mapping(uint256 => Schedule) private _schedules;

    // --- Events ---

    event VestingCreated(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed token,
        uint256 totalAmount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 totalDuration
    );

    event TokensClaimed(uint256 indexed scheduleId, address indexed beneficiary, uint256 amount);
    event VestingRevoked(uint256 indexed scheduleId, uint256 unvestedAmount);

    // --- Errors ---

    error InvalidBeneficiary();
    error InvalidAmount();
    error InvalidDurations();
    error ScheduleNotFound(uint256 scheduleId);
    error NotBeneficiary(uint256 scheduleId);
    error ScheduleRevoked(uint256 scheduleId);
    error NothingToClaim(uint256 scheduleId);
    error AlreadyRevoked(uint256 scheduleId);

    constructor() Ownable(msg.sender) {}

    // --- External Functions ---

    /**
     * @notice Create a vesting schedule for a beneficiary.
     * @param beneficiary Address that will receive vested tokens
     * @param token ERC-20 token to vest
     * @param amount Total number of tokens to vest
     * @param cliffDuration Duration in seconds before any tokens vest
     * @param totalDuration Total vesting duration in seconds (from now)
     * @return scheduleId The ID of the created schedule
     */
    function createVesting(
        address beneficiary,
        address token,
        uint256 amount,
        uint256 cliffDuration,
        uint256 totalDuration
    ) external returns (uint256 scheduleId) {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (amount == 0) revert InvalidAmount();
        if (totalDuration == 0 || cliffDuration > totalDuration) revert InvalidDurations();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        scheduleId = nextScheduleId++;
        _schedules[scheduleId] = Schedule({
            beneficiary: beneficiary,
            token: IERC20(token),
            totalAmount: amount,
            startTime: block.timestamp,
            cliffDuration: cliffDuration,
            totalDuration: totalDuration,
            claimed: 0,
            revoked: false
        });

        emit VestingCreated(
            scheduleId, beneficiary, token,
            amount, block.timestamp, cliffDuration, totalDuration
        );
    }

    /**
     * @notice Claim vested tokens.
     * @param scheduleId The vesting schedule to claim from
     */
    function claim(uint256 scheduleId) external nonReentrant {
        Schedule storage schedule = _getSchedule(scheduleId);
        if (msg.sender != schedule.beneficiary) revert NotBeneficiary(scheduleId);
        if (schedule.revoked) revert ScheduleRevoked(scheduleId);

        uint256 vested = _vestedAmount(schedule);
        uint256 claimable = vested - schedule.claimed;
        if (claimable == 0) revert NothingToClaim(scheduleId);

        schedule.claimed += claimable;
        schedule.token.safeTransfer(schedule.beneficiary, claimable);

        emit TokensClaimed(scheduleId, schedule.beneficiary, claimable);
    }

    /**
     * @notice Revoke a vesting schedule. Unvested tokens are returned to the owner.
     * @param scheduleId The vesting schedule to revoke
     */
    function revoke(uint256 scheduleId) external onlyOwner nonReentrant {
        Schedule storage schedule = _getSchedule(scheduleId);
        if (schedule.revoked) revert AlreadyRevoked(scheduleId);

        schedule.revoked = true;

        uint256 vested = _vestedAmount(schedule);
        uint256 unvested = schedule.totalAmount - vested;

        // Allow beneficiary to claim already vested but unclaimed tokens
        uint256 claimable = vested - schedule.claimed;
        if (claimable > 0) {
            schedule.claimed += claimable;
            schedule.token.safeTransfer(schedule.beneficiary, claimable);
            emit TokensClaimed(scheduleId, schedule.beneficiary, claimable);
        }

        // Return unvested to owner
        if (unvested > 0) {
            schedule.token.safeTransfer(owner(), unvested);
        }

        emit VestingRevoked(scheduleId, unvested);
    }

    // --- View Functions ---

    function getSchedule(uint256 scheduleId) external view returns (Schedule memory) {
        return _getSchedule(scheduleId);
    }

    /**
     * @notice Get the claimable (vested but unclaimed) amount for a schedule.
     * @param scheduleId The schedule to query
     * @return The claimable amount
     */
    function getClaimable(uint256 scheduleId) external view returns (uint256) {
        Schedule storage schedule = _getSchedule(scheduleId);
        if (schedule.revoked) return 0;
        return _vestedAmount(schedule) - schedule.claimed;
    }

    /**
     * @notice Get the total vested amount for a schedule.
     * @param scheduleId The schedule to query
     * @return The vested amount
     */
    function getVestedAmount(uint256 scheduleId) external view returns (uint256) {
        return _vestedAmount(_getSchedule(scheduleId));
    }

    // --- Internal Functions ---

    function _getSchedule(uint256 scheduleId) internal view returns (Schedule storage) {
        if (scheduleId >= nextScheduleId) revert ScheduleNotFound(scheduleId);
        return _schedules[scheduleId];
    }

    function _vestedAmount(Schedule storage schedule) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - schedule.startTime;

        // Nothing vested before cliff
        if (elapsed < schedule.cliffDuration) return 0;

        // Fully vested after total duration
        if (elapsed >= schedule.totalDuration) return schedule.totalAmount;

        // Linear vesting
        return (schedule.totalAmount * elapsed) / schedule.totalDuration;
    }
}
