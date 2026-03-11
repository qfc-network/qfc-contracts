// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPaymaster, IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

/**
 * @title QFCPaymaster
 * @notice A paymaster that sponsors gas for agent wallets, with per-operation and daily caps.
 */
contract QFCPaymaster is IPaymaster {
    /// @notice Sponsorship configuration for an agent account.
    struct AgentSponsorConfig {
        address sponsor;
        uint256 maxPerOp;
        uint256 maxPerDay;
        uint256 spentToday;
        uint64 dayStart;
        bool active;
    }

    /// @notice The ERC-4337 EntryPoint.
    IEntryPoint public immutable entryPoint;

    /// @notice The contract owner.
    address public owner;

    /// @notice Paymaster deposits per depositor.
    mapping(address => uint256) public deposits;

    /// @notice Sponsorship configs per agent account.
    mapping(address => AgentSponsorConfig) public sponsorConfigs;

    // ── Errors ──────────────────────────────────────────────────────────
    error NotOwner();
    error NotEntryPoint();
    error InsufficientDeposit(uint256 available, uint256 required);
    error SponsorshipNotActive(address agent);
    error ExceedsMaxPerOp(uint256 cost, uint256 max);
    error ExceedsDailyLimit(uint256 newTotal, uint256 max);
    error ZeroAmount();
    error WithdrawFailed();

    // ── Events ──────────────────────────────────────────────────────────
    event Deposited(address indexed depositor, uint256 amount);
    event Withdrawn(address indexed depositor, uint256 amount);
    event AgentSponsored(address indexed agent, address indexed sponsor, uint256 maxPerOp, uint256 maxPerDay);
    event SponsorshipRevoked(address indexed agent);
    event GasSponsored(address indexed agent, uint256 actualCost);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();
        _;
    }

    /// @notice Deploy the paymaster.
    /// @param entryPoint_ The ERC-4337 EntryPoint.
    constructor(IEntryPoint entryPoint_) {
        entryPoint = entryPoint_;
        owner = msg.sender;
    }

    /// @notice Deposit funds to sponsor gas.
    function deposit() external payable {
        if (msg.value == 0) revert ZeroAmount();
        deposits[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Withdraw deposited funds.
    /// @param amount The amount to withdraw.
    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (deposits[msg.sender] < amount) revert InsufficientDeposit(deposits[msg.sender], amount);
        deposits[msg.sender] -= amount;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert WithdrawFailed();
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Configure sponsorship for an agent account.
    /// @param agent The agent account to sponsor.
    /// @param maxPerOp Maximum gas cost per operation.
    /// @param maxPerDay Maximum gas cost per day.
    function sponsorAgent(address agent, uint256 maxPerOp, uint256 maxPerDay) external {
        sponsorConfigs[agent] = AgentSponsorConfig({
            sponsor: msg.sender,
            maxPerOp: maxPerOp,
            maxPerDay: maxPerDay,
            spentToday: 0,
            dayStart: uint64(block.timestamp),
            active: true
        });
        emit AgentSponsored(agent, msg.sender, maxPerOp, maxPerDay);
    }

    /// @notice Revoke sponsorship for an agent account.
    /// @param agent The agent account.
    function revokeSponsorship(address agent) external {
        AgentSponsorConfig storage cfg = sponsorConfigs[agent];
        // Only the sponsor or the owner can revoke
        if (msg.sender != cfg.sponsor && msg.sender != owner) revert NotOwner();
        cfg.active = false;
        emit SponsorshipRevoked(agent);
    }

    /// @notice Validate whether the paymaster will sponsor a user operation.
    /// @param userOp The user operation.
    /// @param /* userOpHash */ Unused.
    /// @param maxCost The maximum gas cost.
    /// @return context Encoded agent address for postOp.
    /// @return validationData 0 for valid.
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 /* userOpHash */,
        uint256 maxCost
    ) external onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        address agent = userOp.sender;
        AgentSponsorConfig storage cfg = sponsorConfigs[agent];

        if (!cfg.active) revert SponsorshipNotActive(agent);
        if (maxCost > cfg.maxPerOp) revert ExceedsMaxPerOp(maxCost, cfg.maxPerOp);

        // Reset daily counter if a new day
        if (uint64(block.timestamp) >= cfg.dayStart + 1 days) {
            cfg.spentToday = 0;
            cfg.dayStart = uint64(block.timestamp);
        }

        uint256 newTotal = cfg.spentToday + maxCost;
        if (newTotal > cfg.maxPerDay) revert ExceedsDailyLimit(newTotal, cfg.maxPerDay);

        // Check sponsor has sufficient deposit
        if (deposits[cfg.sponsor] < maxCost) {
            revert InsufficientDeposit(deposits[cfg.sponsor], maxCost);
        }

        // Reserve the funds
        cfg.spentToday = newTotal;
        deposits[cfg.sponsor] -= maxCost;

        context = abi.encode(agent, cfg.sponsor, maxCost);
        validationData = 0;
    }

    /// @notice Post-operation hook to refund unused gas.
    /// @param /* mode */ Unused.
    /// @param context Encoded context from validatePaymasterUserOp.
    /// @param actualGasCost The actual gas cost.
    /// @param /* actualUserOpFeePerGas */ Unused.
    function postOp(
        PostOpMode /* mode */,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 /* actualUserOpFeePerGas */
    ) external onlyEntryPoint {
        (address agent, address sponsor, uint256 maxCost) = abi.decode(context, (address, address, uint256));

        // Refund unused gas to sponsor
        uint256 refund = maxCost - actualGasCost;
        if (refund > 0) {
            deposits[sponsor] += refund;
            // Also adjust daily spend
            AgentSponsorConfig storage cfg = sponsorConfigs[agent];
            if (cfg.spentToday >= refund) {
                cfg.spentToday -= refund;
            }
        }

        emit GasSponsored(agent, actualGasCost);
    }

    /// @notice Allow receiving ETH.
    receive() external payable {
        deposits[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }
}
