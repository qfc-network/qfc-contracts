// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./RoyaltyRegistry.sol";

/**
 * @title QRCMarketplace
 * @dev Fixed-price listings and offers for QRC-721 and QRC-1155 NFTs
 *
 * Features:
 * - List NFTs at a fixed price
 * - Buy listed NFTs
 * - Make and accept offers
 * - 2% marketplace fee
 * - EIP-2981 royalty support via RoyaltyRegistry
 */
contract QRCMarketplace is ReentrancyGuard, Ownable {
    uint256 public constant MARKETPLACE_FEE_BPS = 200; // 2%
    uint256 public constant BPS_DENOMINATOR = 10000;

    enum TokenStandard { ERC721, ERC1155 }

    struct Listing {
        address seller;
        uint256 price;
        TokenStandard standard;
        uint256 amount; // For ERC-1155
    }

    struct Offer {
        address offerer;
        uint256 amount;
        uint256 expiry;
    }

    /// @dev (nftContract, tokenId) => Listing
    mapping(address => mapping(uint256 => Listing)) public listings;

    /// @dev (nftContract, tokenId, offerer) => Offer
    mapping(address => mapping(uint256 => mapping(address => Offer))) public offers;

    RoyaltyRegistry public royaltyRegistry;
    address public feeRecipient;

    event NFTListed(
        address indexed nftContract,
        uint256 indexed tokenId,
        address indexed seller,
        uint256 price,
        TokenStandard standard
    );
    event NFTSold(
        address indexed nftContract,
        uint256 indexed tokenId,
        address seller,
        address indexed buyer,
        uint256 price
    );
    event ListingCancelled(address indexed nftContract, uint256 indexed tokenId, address indexed seller);
    event OfferMade(
        address indexed nftContract,
        uint256 indexed tokenId,
        address indexed offerer,
        uint256 amount,
        uint256 expiry
    );
    event OfferAccepted(
        address indexed nftContract,
        uint256 indexed tokenId,
        address seller,
        address indexed offerer,
        uint256 amount
    );
    event OfferCancelled(address indexed nftContract, uint256 indexed tokenId, address indexed offerer);

    constructor(address _royaltyRegistry, address _feeRecipient) Ownable(msg.sender) {
        royaltyRegistry = RoyaltyRegistry(_royaltyRegistry);
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev List an ERC-721 NFT for sale
     * @param nftContract NFT contract address
     * @param tokenId Token ID
     * @param price Listing price in wei
     */
    function listNFT(address nftContract, uint256 tokenId, uint256 price) external {
        require(price > 0, "Price must be > 0");
        require(
            IERC721(nftContract).ownerOf(tokenId) == msg.sender,
            "Not token owner"
        );
        require(
            IERC721(nftContract).isApprovedForAll(msg.sender, address(this)) ||
            IERC721(nftContract).getApproved(tokenId) == address(this),
            "Marketplace not approved"
        );

        listings[nftContract][tokenId] = Listing({
            seller: msg.sender,
            price: price,
            standard: TokenStandard.ERC721,
            amount: 1
        });

        emit NFTListed(nftContract, tokenId, msg.sender, price, TokenStandard.ERC721);
    }

    /**
     * @dev List an ERC-1155 NFT for sale
     * @param nftContract NFT contract address
     * @param tokenId Token ID
     * @param price Listing price in wei (total price for all tokens)
     * @param amount Number of tokens to list
     */
    function listNFT1155(
        address nftContract,
        uint256 tokenId,
        uint256 price,
        uint256 amount
    ) external {
        require(price > 0, "Price must be > 0");
        require(amount > 0, "Amount must be > 0");
        require(
            IERC1155(nftContract).balanceOf(msg.sender, tokenId) >= amount,
            "Insufficient balance"
        );
        require(
            IERC1155(nftContract).isApprovedForAll(msg.sender, address(this)),
            "Marketplace not approved"
        );

        listings[nftContract][tokenId] = Listing({
            seller: msg.sender,
            price: price,
            standard: TokenStandard.ERC1155,
            amount: amount
        });

        emit NFTListed(nftContract, tokenId, msg.sender, price, TokenStandard.ERC1155);
    }

    /**
     * @dev Buy a listed NFT
     * @param nftContract NFT contract address
     * @param tokenId Token ID
     */
    function buyNFT(address nftContract, uint256 tokenId) external payable nonReentrant {
        Listing memory listing = listings[nftContract][tokenId];
        require(listing.seller != address(0), "Not listed");
        require(msg.value >= listing.price, "Insufficient payment");

        delete listings[nftContract][tokenId];

        _executeSale(
            nftContract,
            tokenId,
            listing.seller,
            msg.sender,
            listing.price,
            listing.standard,
            listing.amount
        );

        // Refund excess
        if (msg.value > listing.price) {
            payable(msg.sender).transfer(msg.value - listing.price);
        }

        emit NFTSold(nftContract, tokenId, listing.seller, msg.sender, listing.price);
    }

    /**
     * @dev Cancel a listing
     * @param nftContract NFT contract address
     * @param tokenId Token ID
     */
    function cancelListing(address nftContract, uint256 tokenId) external {
        Listing memory listing = listings[nftContract][tokenId];
        require(listing.seller == msg.sender, "Not the seller");

        delete listings[nftContract][tokenId];
        emit ListingCancelled(nftContract, tokenId, msg.sender);
    }

    /**
     * @dev Make an offer on an NFT
     * @param nftContract NFT contract address
     * @param tokenId Token ID
     * @param expiry Offer expiry timestamp
     */
    function makeOffer(
        address nftContract,
        uint256 tokenId,
        uint256 expiry
    ) external payable {
        require(msg.value > 0, "Offer must be > 0");
        require(expiry > block.timestamp, "Expiry must be in future");

        // Refund any existing offer
        Offer memory existing = offers[nftContract][tokenId][msg.sender];
        if (existing.amount > 0) {
            payable(msg.sender).transfer(existing.amount);
        }

        offers[nftContract][tokenId][msg.sender] = Offer({
            offerer: msg.sender,
            amount: msg.value,
            expiry: expiry
        });

        emit OfferMade(nftContract, tokenId, msg.sender, msg.value, expiry);
    }

    /**
     * @dev Accept an offer on your NFT
     * @param nftContract NFT contract address
     * @param tokenId Token ID
     * @param offerer Address of the offerer
     */
    function acceptOffer(
        address nftContract,
        uint256 tokenId,
        address offerer
    ) external nonReentrant {
        Offer memory offer = offers[nftContract][tokenId][offerer];
        require(offer.amount > 0, "No offer found");
        require(offer.expiry >= block.timestamp, "Offer expired");

        // Determine token standard from listing or default to ERC721
        TokenStandard standard = TokenStandard.ERC721;
        uint256 amount = 1;
        Listing memory listing = listings[nftContract][tokenId];
        if (listing.seller != address(0)) {
            standard = listing.standard;
            amount = listing.amount;
            delete listings[nftContract][tokenId];
        }

        delete offers[nftContract][tokenId][offerer];

        _executeSale(nftContract, tokenId, msg.sender, offerer, offer.amount, standard, amount);

        emit OfferAccepted(nftContract, tokenId, msg.sender, offerer, offer.amount);
    }

    /**
     * @dev Cancel your offer and reclaim funds
     * @param nftContract NFT contract address
     * @param tokenId Token ID
     */
    function cancelOffer(address nftContract, uint256 tokenId) external nonReentrant {
        Offer memory offer = offers[nftContract][tokenId][msg.sender];
        require(offer.amount > 0, "No offer found");

        delete offers[nftContract][tokenId][msg.sender];
        payable(msg.sender).transfer(offer.amount);

        emit OfferCancelled(nftContract, tokenId, msg.sender);
    }

    /**
     * @dev Update fee recipient
     * @param _feeRecipient New fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid address");
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Update royalty registry
     * @param _royaltyRegistry New registry address
     */
    function setRoyaltyRegistry(address _royaltyRegistry) external onlyOwner {
        royaltyRegistry = RoyaltyRegistry(_royaltyRegistry);
    }

    /**
     * @dev Execute an NFT sale with fee and royalty distribution
     */
    function _executeSale(
        address nftContract,
        uint256 tokenId,
        address seller,
        address buyer,
        uint256 price,
        TokenStandard standard,
        uint256 amount
    ) internal {
        // Calculate marketplace fee
        uint256 fee = (price * MARKETPLACE_FEE_BPS) / BPS_DENOMINATOR;

        // Calculate royalty
        (address royaltyReceiver, uint256 royaltyAmount) = royaltyRegistry.getRoyaltyInfo(
            nftContract,
            tokenId,
            price
        );

        // Ensure fees don't exceed price
        uint256 totalDeductions = fee + royaltyAmount;
        require(totalDeductions <= price, "Fees exceed price");

        uint256 sellerProceeds = price - totalDeductions;

        // Transfer NFT
        if (standard == TokenStandard.ERC721) {
            IERC721(nftContract).safeTransferFrom(seller, buyer, tokenId);
        } else {
            IERC1155(nftContract).safeTransferFrom(seller, buyer, tokenId, amount, "");
        }

        // Distribute funds
        payable(feeRecipient).transfer(fee);
        if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
            payable(royaltyReceiver).transfer(royaltyAmount);
        }
        payable(seller).transfer(sellerProceeds);
    }
}
