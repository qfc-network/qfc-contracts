// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./RoyaltyRegistry.sol";

/**
 * @title AuctionHouse
 * @dev English and Dutch auctions for QRC-721 and QRC-1155 NFTs
 *
 * Features:
 * - English auctions with reserve price and anti-snipe extension
 * - Dutch auctions with linear price decay
 * - 2% marketplace fee, EIP-2981 royalties via RoyaltyRegistry
 * - Anyone can settle expired auctions
 */
contract AuctionHouse is ReentrancyGuard, Ownable {
    uint256 public constant MARKETPLACE_FEE_BPS = 200; // 2%
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant ANTI_SNIPE_DURATION = 5 minutes;
    uint256 public constant MIN_BID_INCREMENT_BPS = 500; // 5%

    enum AuctionType { English, Dutch }
    enum TokenStandard { ERC721, ERC1155 }

    struct Auction {
        address seller;
        address nftContract;
        uint256 tokenId;
        TokenStandard standard;
        uint256 amount; // For ERC-1155
        AuctionType auctionType;
        uint256 startPrice;
        uint256 endPrice; // Dutch auction end price (0 for English)
        uint256 reservePrice; // English auction reserve price
        uint256 startTime;
        uint256 endTime;
        address highestBidder;
        uint256 highestBid;
        bool settled;
    }

    uint256 public nextAuctionId;
    mapping(uint256 => Auction) public auctions;

    RoyaltyRegistry public royaltyRegistry;
    address public feeRecipient;

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address nftContract,
        uint256 tokenId,
        AuctionType auctionType,
        uint256 startPrice,
        uint256 endTime
    );
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event AuctionExtended(uint256 indexed auctionId, uint256 newEndTime);
    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed winner,
        uint256 amount
    );
    event AuctionCancelled(uint256 indexed auctionId);

    constructor(address _royaltyRegistry, address _feeRecipient) Ownable(msg.sender) {
        royaltyRegistry = RoyaltyRegistry(_royaltyRegistry);
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Create an English auction
     * @param nftContract NFT contract address
     * @param tokenId Token ID
     * @param reservePrice Minimum acceptable price
     * @param startPrice Starting bid price
     * @param duration Auction duration in seconds
     */
    function createEnglishAuction(
        address nftContract,
        uint256 tokenId,
        uint256 reservePrice,
        uint256 startPrice,
        uint256 duration
    ) external returns (uint256 auctionId) {
        require(startPrice > 0, "Start price must be > 0");
        require(duration > 0, "Duration must be > 0");
        require(reservePrice >= startPrice, "Reserve < start price");

        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);

        auctionId = nextAuctionId++;
        auctions[auctionId] = Auction({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            standard: TokenStandard.ERC721,
            amount: 1,
            auctionType: AuctionType.English,
            startPrice: startPrice,
            endPrice: 0,
            reservePrice: reservePrice,
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            highestBidder: address(0),
            highestBid: 0,
            settled: false
        });

        emit AuctionCreated(
            auctionId, msg.sender, nftContract, tokenId,
            AuctionType.English, startPrice, block.timestamp + duration
        );
    }

    /**
     * @dev Create a Dutch auction (linear price decay)
     * @param nftContract NFT contract address
     * @param tokenId Token ID
     * @param startPrice Starting (highest) price
     * @param endPrice Ending (lowest) price
     * @param duration Auction duration in seconds
     */
    function createDutchAuction(
        address nftContract,
        uint256 tokenId,
        uint256 startPrice,
        uint256 endPrice,
        uint256 duration
    ) external returns (uint256 auctionId) {
        require(startPrice > endPrice, "Start must exceed end price");
        require(endPrice > 0, "End price must be > 0");
        require(duration > 0, "Duration must be > 0");

        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);

        auctionId = nextAuctionId++;
        auctions[auctionId] = Auction({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            standard: TokenStandard.ERC721,
            amount: 1,
            auctionType: AuctionType.Dutch,
            startPrice: startPrice,
            endPrice: endPrice,
            reservePrice: endPrice,
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            highestBidder: address(0),
            highestBid: 0,
            settled: false
        });

        emit AuctionCreated(
            auctionId, msg.sender, nftContract, tokenId,
            AuctionType.Dutch, startPrice, block.timestamp + duration
        );
    }

    /**
     * @dev Place a bid on an English auction
     * @param auctionId Auction ID
     */
    function placeBid(uint256 auctionId) external payable nonReentrant {
        Auction storage auction = auctions[auctionId];
        require(auction.seller != address(0), "Auction does not exist");
        require(auction.auctionType == AuctionType.English, "Not an English auction");
        require(block.timestamp < auction.endTime, "Auction ended");
        require(!auction.settled, "Already settled");

        if (auction.highestBid == 0) {
            require(msg.value >= auction.startPrice, "Bid below start price");
        } else {
            uint256 minBid = auction.highestBid +
                (auction.highestBid * MIN_BID_INCREMENT_BPS) / BPS_DENOMINATOR;
            require(msg.value >= minBid, "Bid increment too low");
        }

        // Refund previous bidder
        if (auction.highestBidder != address(0)) {
            payable(auction.highestBidder).transfer(auction.highestBid);
        }

        auction.highestBidder = msg.sender;
        auction.highestBid = msg.value;

        emit BidPlaced(auctionId, msg.sender, msg.value);

        // Anti-snipe: extend by 5 minutes if bid in last 5 minutes
        if (auction.endTime - block.timestamp < ANTI_SNIPE_DURATION) {
            auction.endTime = block.timestamp + ANTI_SNIPE_DURATION;
            emit AuctionExtended(auctionId, auction.endTime);
        }
    }

    /**
     * @dev Buy from a Dutch auction at the current price
     * @param auctionId Auction ID
     */
    function buyDutchAuction(uint256 auctionId) external payable nonReentrant {
        Auction storage auction = auctions[auctionId];
        require(auction.seller != address(0), "Auction does not exist");
        require(auction.auctionType == AuctionType.Dutch, "Not a Dutch auction");
        require(block.timestamp <= auction.endTime, "Auction ended");
        require(!auction.settled, "Already settled");

        uint256 currentPrice = getDutchAuctionPrice(auctionId);
        require(msg.value >= currentPrice, "Insufficient payment");

        auction.highestBidder = msg.sender;
        auction.highestBid = currentPrice;
        auction.settled = true;

        // Transfer NFT
        IERC721(auction.nftContract).safeTransferFrom(
            address(this), msg.sender, auction.tokenId
        );

        // Distribute funds
        _distributeFunds(auction.nftContract, auction.tokenId, auction.seller, currentPrice);

        // Refund excess
        if (msg.value > currentPrice) {
            payable(msg.sender).transfer(msg.value - currentPrice);
        }

        emit AuctionSettled(auctionId, msg.sender, currentPrice);
    }

    /**
     * @dev Get the current price of a Dutch auction
     * @param auctionId Auction ID
     * @return Current price
     */
    function getDutchAuctionPrice(uint256 auctionId) public view returns (uint256) {
        Auction memory auction = auctions[auctionId];
        require(auction.auctionType == AuctionType.Dutch, "Not a Dutch auction");

        if (block.timestamp >= auction.endTime) {
            return auction.endPrice;
        }

        uint256 elapsed = block.timestamp - auction.startTime;
        uint256 duration = auction.endTime - auction.startTime;
        uint256 priceDrop = ((auction.startPrice - auction.endPrice) * elapsed) / duration;

        return auction.startPrice - priceDrop;
    }

    /**
     * @dev Settle an English auction after it ends
     * @param auctionId Auction ID
     */
    function settleAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        require(auction.seller != address(0), "Auction does not exist");
        require(auction.auctionType == AuctionType.English, "Not an English auction");
        require(block.timestamp >= auction.endTime, "Auction not ended");
        require(!auction.settled, "Already settled");

        auction.settled = true;

        if (auction.highestBidder != address(0) && auction.highestBid >= auction.reservePrice) {
            // Successful auction — transfer NFT and funds
            IERC721(auction.nftContract).safeTransferFrom(
                address(this), auction.highestBidder, auction.tokenId
            );

            _distributeFunds(
                auction.nftContract, auction.tokenId,
                auction.seller, auction.highestBid
            );

            emit AuctionSettled(auctionId, auction.highestBidder, auction.highestBid);
        } else {
            // No bids or reserve not met — return NFT to seller
            IERC721(auction.nftContract).safeTransferFrom(
                address(this), auction.seller, auction.tokenId
            );

            // Refund highest bidder if reserve not met
            if (auction.highestBidder != address(0)) {
                payable(auction.highestBidder).transfer(auction.highestBid);
            }

            emit AuctionSettled(auctionId, address(0), 0);
        }
    }

    /**
     * @dev Cancel an auction with no bids
     * @param auctionId Auction ID
     */
    function cancelAuction(uint256 auctionId) external {
        Auction storage auction = auctions[auctionId];
        require(auction.seller == msg.sender, "Not the seller");
        require(!auction.settled, "Already settled");
        require(auction.highestBidder == address(0), "Has bids");

        auction.settled = true;

        IERC721(auction.nftContract).safeTransferFrom(
            address(this), msg.sender, auction.tokenId
        );

        emit AuctionCancelled(auctionId);
    }

    /**
     * @dev Update fee recipient
     * @param _feeRecipient New fee recipient
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid address");
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Distribute sale proceeds: fee, royalty, seller
     */
    function _distributeFunds(
        address nftContract,
        uint256 tokenId,
        address seller,
        uint256 price
    ) internal {
        uint256 fee = (price * MARKETPLACE_FEE_BPS) / BPS_DENOMINATOR;

        (address royaltyReceiver, uint256 royaltyAmount) = royaltyRegistry.getRoyaltyInfo(
            nftContract, tokenId, price
        );

        uint256 totalDeductions = fee + royaltyAmount;
        require(totalDeductions <= price, "Fees exceed price");

        uint256 sellerProceeds = price - totalDeductions;

        payable(feeRecipient).transfer(fee);
        if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
            payable(royaltyReceiver).transfer(royaltyAmount);
        }
        payable(seller).transfer(sellerProceeds);
    }

    /// @dev Required to receive ERC721 tokens via safeTransferFrom
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
