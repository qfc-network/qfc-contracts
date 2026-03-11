// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DutchAuction
 * @notice Token sale where price decreases linearly from startPrice to endPrice
 *         over the auction duration.
 * @dev Clears when hardCap is hit or endTime is reached.
 */
contract DutchAuction is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum AuctionStatus { Active, Finalized, Cancelled }

    struct Auction {
        IERC20 token;
        uint256 hardCap;         // max raise in wei
        uint256 startPrice;      // tokens per wei at start (highest price = fewest tokens)
        uint256 endPrice;        // tokens per wei at end (lowest price = most tokens)
        uint256 startTime;
        uint256 endTime;
        uint256 maxPerWallet;
        uint256 totalRaised;
        uint256 totalTokensSold;
        address creator;
        AuctionStatus status;
    }

    uint256 public nextAuctionId;
    uint256 public constant PROTOCOL_FEE_BPS = 100;

    mapping(uint256 => Auction) private _auctions;
    mapping(uint256 => mapping(address => uint256)) private _contributions;
    mapping(uint256 => mapping(address => uint256)) private _tokenAllocations;

    // --- Events ---

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed token,
        address indexed creator,
        uint256 hardCap,
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 endTime,
        uint256 maxPerWallet
    );

    event Contributed(uint256 indexed auctionId, address indexed contributor, uint256 amount, uint256 tokensAllocated, uint256 price);
    event AuctionFinalized(uint256 indexed auctionId, uint256 totalRaised, uint256 protocolFee);
    event AuctionCancelled(uint256 indexed auctionId);
    event Refunded(uint256 indexed auctionId, address indexed contributor, uint256 amount);
    event TokensClaimed(uint256 indexed auctionId, address indexed contributor, uint256 tokenAmount);

    // --- Errors ---

    error InvalidHardCap();
    error InvalidPrices();
    error InvalidTimes();
    error InvalidMaxPerWallet();
    error AuctionNotFound(uint256 auctionId);
    error AuctionNotActive(uint256 auctionId);
    error AuctionNotStarted(uint256 auctionId);
    error AuctionEnded(uint256 auctionId);
    error AuctionNotEnded(uint256 auctionId);
    error HardCapReached(uint256 auctionId);
    error ExceedsMaxPerWallet(uint256 auctionId);
    error ZeroContribution();
    error NothingToRefund(uint256 auctionId);
    error NothingToClaim(uint256 auctionId);
    error TransferFailed();
    error NoRaise(uint256 auctionId);

    constructor() Ownable(msg.sender) {}

    // --- External Functions ---

    /**
     * @notice Create a new dutch auction.
     * @param token ERC-20 token to sell
     * @param hardCap Maximum raise in wei
     * @param startPrice Tokens per wei at auction start (lower = more expensive)
     * @param endPrice Tokens per wei at auction end (higher = cheaper)
     * @param startTime Unix timestamp when auction starts
     * @param endTime Unix timestamp when auction ends
     * @param maxPerWallet Maximum contribution per wallet in wei
     * @param totalTokens Total tokens to deposit for sale
     * @return auctionId The ID of the created auction
     */
    function createAuction(
        address token,
        uint256 hardCap,
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 endTime,
        uint256 maxPerWallet,
        uint256 totalTokens
    ) external returns (uint256 auctionId) {
        if (hardCap == 0) revert InvalidHardCap();
        if (startPrice == 0 || endPrice == 0 || endPrice <= startPrice) revert InvalidPrices();
        if (startTime >= endTime || startTime < block.timestamp) revert InvalidTimes();
        if (maxPerWallet == 0) revert InvalidMaxPerWallet();

        IERC20(token).safeTransferFrom(msg.sender, address(this), totalTokens);

        auctionId = nextAuctionId++;
        _auctions[auctionId] = Auction({
            token: IERC20(token),
            hardCap: hardCap,
            startPrice: startPrice,
            endPrice: endPrice,
            startTime: startTime,
            endTime: endTime,
            maxPerWallet: maxPerWallet,
            totalRaised: 0,
            totalTokensSold: 0,
            creator: msg.sender,
            status: AuctionStatus.Active
        });

        emit AuctionCreated(
            auctionId, token, msg.sender,
            hardCap, startPrice, endPrice,
            startTime, endTime, maxPerWallet
        );
    }

    /**
     * @notice Contribute to a dutch auction at the current price.
     * @param auctionId The auction to contribute to
     */
    function contribute(uint256 auctionId) external payable nonReentrant {
        Auction storage auction = _getAuction(auctionId);
        if (auction.status != AuctionStatus.Active) revert AuctionNotActive(auctionId);
        if (block.timestamp < auction.startTime) revert AuctionNotStarted(auctionId);
        if (block.timestamp > auction.endTime) revert AuctionEnded(auctionId);
        if (msg.value == 0) revert ZeroContribution();
        if (auction.totalRaised + msg.value > auction.hardCap) revert HardCapReached(auctionId);
        if (_contributions[auctionId][msg.sender] + msg.value > auction.maxPerWallet)
            revert ExceedsMaxPerWallet(auctionId);

        uint256 currentPrice = getCurrentPrice(auctionId);
        uint256 tokens = msg.value * currentPrice;

        _contributions[auctionId][msg.sender] += msg.value;
        _tokenAllocations[auctionId][msg.sender] += tokens;
        auction.totalRaised += msg.value;
        auction.totalTokensSold += tokens;

        emit Contributed(auctionId, msg.sender, msg.value, tokens, currentPrice);
    }

    /**
     * @notice Finalize a completed auction.
     * @param auctionId The auction to finalize
     */
    function finalize(uint256 auctionId) external nonReentrant {
        Auction storage auction = _getAuction(auctionId);
        if (auction.status != AuctionStatus.Active) revert AuctionNotActive(auctionId);

        bool hardCapHit = auction.totalRaised >= auction.hardCap;
        bool ended = block.timestamp > auction.endTime;
        if (!hardCapHit && !ended) revert AuctionNotEnded(auctionId);

        if (auction.totalRaised == 0) {
            auction.status = AuctionStatus.Cancelled;
            // Return all tokens
            uint256 tokenBalance = auction.token.balanceOf(address(this));
            if (tokenBalance > 0) {
                auction.token.safeTransfer(auction.creator, tokenBalance);
            }
            emit AuctionCancelled(auctionId);
            return;
        }

        auction.status = AuctionStatus.Finalized;

        uint256 protocolFee = (auction.totalRaised * PROTOCOL_FEE_BPS) / 10_000;
        uint256 creatorProceeds = auction.totalRaised - protocolFee;

        (bool ok, ) = auction.creator.call{value: creatorProceeds}("");
        if (!ok) revert TransferFailed();

        (ok, ) = owner().call{value: protocolFee}("");
        if (!ok) revert TransferFailed();

        // Return unsold tokens to creator
        uint256 remainingTokens = auction.token.balanceOf(address(this));
        uint256 unsold = remainingTokens - auction.totalTokensSold;
        if (unsold > 0) {
            auction.token.safeTransfer(auction.creator, unsold);
        }

        emit AuctionFinalized(auctionId, auction.totalRaised, protocolFee);
    }

    /**
     * @notice Claim tokens after a finalized auction.
     * @param auctionId The auction to claim from
     */
    function claimTokens(uint256 auctionId) external nonReentrant {
        Auction storage auction = _getAuction(auctionId);
        if (auction.status != AuctionStatus.Finalized) revert AuctionNotActive(auctionId);

        uint256 tokens = _tokenAllocations[auctionId][msg.sender];
        if (tokens == 0) revert NothingToClaim(auctionId);

        _tokenAllocations[auctionId][msg.sender] = 0;
        auction.token.safeTransfer(msg.sender, tokens);

        emit TokensClaimed(auctionId, msg.sender, tokens);
    }

    // --- View Functions ---

    /**
     * @notice Get the current price (tokens per wei) based on elapsed time.
     * @param auctionId The auction to query
     * @return Current tokens-per-wei price
     */
    function getCurrentPrice(uint256 auctionId) public view returns (uint256) {
        Auction storage auction = _getAuction(auctionId);

        if (block.timestamp <= auction.startTime) return auction.startPrice;
        if (block.timestamp >= auction.endTime) return auction.endPrice;

        uint256 elapsed = block.timestamp - auction.startTime;
        uint256 duration = auction.endTime - auction.startTime;
        uint256 priceRange = auction.endPrice - auction.startPrice;

        return auction.startPrice + (priceRange * elapsed) / duration;
    }

    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return _getAuction(auctionId);
    }

    function getContribution(uint256 auctionId, address contributor) external view returns (uint256) {
        return _contributions[auctionId][contributor];
    }

    function getTokenAllocation(uint256 auctionId, address contributor) external view returns (uint256) {
        return _tokenAllocations[auctionId][contributor];
    }

    // --- Internal Functions ---

    function _getAuction(uint256 auctionId) internal view returns (Auction storage) {
        if (auctionId >= nextAuctionId) revert AuctionNotFound(auctionId);
        return _auctions[auctionId];
    }
}
