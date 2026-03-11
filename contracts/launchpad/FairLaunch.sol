// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title FairLaunch
 * @notice Fixed-price token launch with soft/hard caps and per-wallet limits.
 * @dev Contributors send native QFC. On success tokens are distributed and a
 *      1% protocol fee is taken. On failure contributors can claim refunds.
 */
contract FairLaunch is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum LaunchStatus { Active, Finalized, Cancelled }

    struct Launch {
        IERC20 token;
        uint256 softCap;
        uint256 hardCap;
        uint256 price; // tokens per 1 QFC (wei-denominated)
        uint256 startTime;
        uint256 endTime;
        uint256 maxPerWallet;
        uint256 totalRaised;
        address creator;
        LaunchStatus status;
    }

    uint256 public nextLaunchId;
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1%

    mapping(uint256 => Launch) private _launches;
    mapping(uint256 => mapping(address => uint256)) private _contributions;

    // --- Events ---

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed token,
        address indexed creator,
        uint256 softCap,
        uint256 hardCap,
        uint256 price,
        uint256 startTime,
        uint256 endTime,
        uint256 maxPerWallet
    );

    event Contributed(uint256 indexed launchId, address indexed contributor, uint256 amount);
    event LaunchFinalized(uint256 indexed launchId, uint256 totalRaised, uint256 protocolFee);
    event LaunchCancelled(uint256 indexed launchId);
    event Refunded(uint256 indexed launchId, address indexed contributor, uint256 amount);
    event TokensClaimed(uint256 indexed launchId, address indexed contributor, uint256 tokenAmount);

    // --- Errors ---

    error InvalidCaps();
    error InvalidPrice();
    error InvalidTimes();
    error InvalidMaxPerWallet();
    error LaunchNotFound(uint256 launchId);
    error LaunchNotActive(uint256 launchId);
    error LaunchNotStarted(uint256 launchId);
    error LaunchEnded(uint256 launchId);
    error LaunchNotEnded(uint256 launchId);
    error HardCapReached(uint256 launchId);
    error ExceedsMaxPerWallet(uint256 launchId);
    error ZeroContribution();
    error SoftCapNotMet(uint256 launchId);
    error SoftCapMet(uint256 launchId);
    error NothingToRefund(uint256 launchId);
    error NothingToClaim(uint256 launchId);
    error TransferFailed();
    error InsufficientTokenBalance();

    constructor() Ownable(msg.sender) {}

    // --- External Functions ---

    /**
     * @notice Create a new fair launch.
     * @param token ERC-20 token to sell
     * @param softCap Minimum raise to succeed (in wei)
     * @param hardCap Maximum raise (in wei)
     * @param price Tokens per 1 wei of QFC contributed
     * @param startTime Unix timestamp when contributions open
     * @param endTime Unix timestamp when contributions close
     * @param maxPerWallet Maximum contribution per wallet (in wei)
     * @return launchId The ID of the created launch
     */
    function createLaunch(
        address token,
        uint256 softCap,
        uint256 hardCap,
        uint256 price,
        uint256 startTime,
        uint256 endTime,
        uint256 maxPerWallet
    ) external returns (uint256 launchId) {
        if (softCap == 0 || hardCap == 0 || softCap > hardCap) revert InvalidCaps();
        if (price == 0) revert InvalidPrice();
        if (startTime >= endTime || startTime < block.timestamp) revert InvalidTimes();
        if (maxPerWallet == 0) revert InvalidMaxPerWallet();

        // Ensure creator deposits enough tokens for hardCap
        uint256 tokensRequired = hardCap * price;
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensRequired);

        launchId = nextLaunchId++;
        _launches[launchId] = Launch({
            token: IERC20(token),
            softCap: softCap,
            hardCap: hardCap,
            price: price,
            startTime: startTime,
            endTime: endTime,
            maxPerWallet: maxPerWallet,
            totalRaised: 0,
            creator: msg.sender,
            status: LaunchStatus.Active
        });

        emit LaunchCreated(
            launchId, token, msg.sender,
            softCap, hardCap, price, startTime, endTime, maxPerWallet
        );
    }

    /**
     * @notice Contribute native QFC to a launch.
     * @param launchId The launch to contribute to
     */
    function contribute(uint256 launchId) external payable nonReentrant {
        Launch storage launch = _getLaunch(launchId);
        if (launch.status != LaunchStatus.Active) revert LaunchNotActive(launchId);
        if (block.timestamp < launch.startTime) revert LaunchNotStarted(launchId);
        if (block.timestamp > launch.endTime) revert LaunchEnded(launchId);
        if (msg.value == 0) revert ZeroContribution();
        if (launch.totalRaised + msg.value > launch.hardCap) revert HardCapReached(launchId);
        if (_contributions[launchId][msg.sender] + msg.value > launch.maxPerWallet)
            revert ExceedsMaxPerWallet(launchId);

        _contributions[launchId][msg.sender] += msg.value;
        launch.totalRaised += msg.value;

        emit Contributed(launchId, msg.sender, msg.value);
    }

    /**
     * @notice Finalize a successful launch. Distributes protocol fee and
     *         returns unsold tokens to the creator.
     * @param launchId The launch to finalize
     */
    function finalize(uint256 launchId) external nonReentrant {
        Launch storage launch = _getLaunch(launchId);
        if (launch.status != LaunchStatus.Active) revert LaunchNotActive(launchId);

        bool hardCapHit = launch.totalRaised >= launch.hardCap;
        bool ended = block.timestamp > launch.endTime;
        if (!hardCapHit && !ended) revert LaunchNotEnded(launchId);
        if (launch.totalRaised < launch.softCap) revert SoftCapNotMet(launchId);

        launch.status = LaunchStatus.Finalized;

        // Protocol fee: 1% of raised
        uint256 protocolFee = (launch.totalRaised * PROTOCOL_FEE_BPS) / 10_000;
        uint256 creatorProceeds = launch.totalRaised - protocolFee;

        // Send proceeds to creator
        (bool ok, ) = launch.creator.call{value: creatorProceeds}("");
        if (!ok) revert TransferFailed();

        // Send protocol fee to owner
        (ok, ) = owner().call{value: protocolFee}("");
        if (!ok) revert TransferFailed();

        // Return unsold tokens to creator
        uint256 tokensSold = launch.totalRaised * launch.price;
        uint256 tokensDeposited = launch.hardCap * launch.price;
        uint256 unsold = tokensDeposited - tokensSold;
        if (unsold > 0) {
            launch.token.safeTransfer(launch.creator, unsold);
        }

        emit LaunchFinalized(launchId, launch.totalRaised, protocolFee);
    }

    /**
     * @notice Claim tokens after a successful launch.
     * @param launchId The launch to claim from
     */
    function claimTokens(uint256 launchId) external nonReentrant {
        Launch storage launch = _getLaunch(launchId);
        if (launch.status != LaunchStatus.Finalized) revert LaunchNotActive(launchId);

        uint256 contributed = _contributions[launchId][msg.sender];
        if (contributed == 0) revert NothingToClaim(launchId);

        _contributions[launchId][msg.sender] = 0;
        uint256 tokenAmount = contributed * launch.price;
        launch.token.safeTransfer(msg.sender, tokenAmount);

        emit TokensClaimed(launchId, msg.sender, tokenAmount);
    }

    /**
     * @notice Claim a refund if softCap was not met after endTime.
     * @param launchId The launch to get a refund from
     */
    function refund(uint256 launchId) external nonReentrant {
        Launch storage launch = _getLaunch(launchId);
        if (launch.status == LaunchStatus.Finalized) revert SoftCapMet(launchId);
        if (block.timestamp <= launch.endTime) revert LaunchNotEnded(launchId);
        if (launch.totalRaised >= launch.softCap) revert SoftCapMet(launchId);

        // Mark as cancelled on first refund
        if (launch.status == LaunchStatus.Active) {
            launch.status = LaunchStatus.Cancelled;
            // Return all tokens to creator
            uint256 tokensDeposited = launch.hardCap * launch.price;
            launch.token.safeTransfer(launch.creator, tokensDeposited);
            emit LaunchCancelled(launchId);
        }

        uint256 contributed = _contributions[launchId][msg.sender];
        if (contributed == 0) revert NothingToRefund(launchId);

        _contributions[launchId][msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: contributed}("");
        if (!ok) revert TransferFailed();

        emit Refunded(launchId, msg.sender, contributed);
    }

    // --- View Functions ---

    function getLaunch(uint256 launchId) external view returns (Launch memory) {
        return _getLaunch(launchId);
    }

    function getContribution(uint256 launchId, address contributor) external view returns (uint256) {
        return _contributions[launchId][contributor];
    }

    // --- Internal Functions ---

    function _getLaunch(uint256 launchId) internal view returns (Launch storage) {
        if (launchId >= nextLaunchId) revert LaunchNotFound(launchId);
        return _launches[launchId];
    }
}
