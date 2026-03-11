// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/**
 * @title RoyaltyRegistry
 * @dev On-chain royalty management with EIP-2981 compliance
 *
 * Features:
 * - EIP-2981 compliant royalty lookups
 * - Max 10% royalty cap
 * - Override support for non-compliant collections
 * - Collection owners can set their own royalties
 */
contract RoyaltyRegistry is ERC165, Ownable {
    uint256 public constant MAX_ROYALTY_BPS = 1000; // 10%

    struct RoyaltyInfo {
        address receiver;
        uint96 royaltyBps;
    }

    /// @dev Collection-level royalty overrides
    mapping(address => RoyaltyInfo) public collectionRoyalties;

    /// @dev Token-level royalty overrides (collection => tokenId => info)
    mapping(address => mapping(uint256 => RoyaltyInfo)) public tokenRoyalties;

    /// @dev Collection admin mapping (collection => admin)
    mapping(address => address) public collectionAdmins;

    event CollectionRoyaltySet(address indexed collection, address receiver, uint96 royaltyBps);
    event TokenRoyaltySet(address indexed collection, uint256 indexed tokenId, address receiver, uint96 royaltyBps);
    event CollectionAdminSet(address indexed collection, address admin);

    constructor() Ownable(msg.sender) {}

    /**
     * @dev Set collection-level royalty override
     * @param collection NFT contract address
     * @param receiver Royalty recipient
     * @param royaltyBps Royalty in basis points (max 1000 = 10%)
     */
    function setCollectionRoyalty(
        address collection,
        address receiver,
        uint96 royaltyBps
    ) external {
        require(
            msg.sender == owner() || msg.sender == collectionAdmins[collection],
            "Not authorized"
        );
        require(royaltyBps <= MAX_ROYALTY_BPS, "Royalty exceeds 10% cap");
        require(receiver != address(0), "Invalid receiver");

        collectionRoyalties[collection] = RoyaltyInfo(receiver, royaltyBps);
        emit CollectionRoyaltySet(collection, receiver, royaltyBps);
    }

    /**
     * @dev Set token-level royalty override
     * @param collection NFT contract address
     * @param tokenId Token ID
     * @param receiver Royalty recipient
     * @param royaltyBps Royalty in basis points (max 1000 = 10%)
     */
    function setTokenRoyalty(
        address collection,
        uint256 tokenId,
        address receiver,
        uint96 royaltyBps
    ) external {
        require(
            msg.sender == owner() || msg.sender == collectionAdmins[collection],
            "Not authorized"
        );
        require(royaltyBps <= MAX_ROYALTY_BPS, "Royalty exceeds 10% cap");
        require(receiver != address(0), "Invalid receiver");

        tokenRoyalties[collection][tokenId] = RoyaltyInfo(receiver, royaltyBps);
        emit TokenRoyaltySet(collection, tokenId, receiver, royaltyBps);
    }

    /**
     * @dev Set collection admin who can manage royalties
     * @param collection NFT contract address
     * @param admin Admin address
     */
    function setCollectionAdmin(address collection, address admin) external onlyOwner {
        collectionAdmins[collection] = admin;
        emit CollectionAdminSet(collection, admin);
    }

    /**
     * @dev Get royalty info for a token sale
     * @param collection NFT contract address
     * @param tokenId Token ID
     * @param salePrice Sale price
     * @return receiver Royalty recipient
     * @return royaltyAmount Royalty amount
     */
    function getRoyaltyInfo(
        address collection,
        uint256 tokenId,
        uint256 salePrice
    ) external view returns (address receiver, uint256 royaltyAmount) {
        // 1. Check token-level override
        RoyaltyInfo memory tokenInfo = tokenRoyalties[collection][tokenId];
        if (tokenInfo.receiver != address(0)) {
            return (tokenInfo.receiver, (salePrice * tokenInfo.royaltyBps) / 10000);
        }

        // 2. Check collection-level override
        RoyaltyInfo memory collInfo = collectionRoyalties[collection];
        if (collInfo.receiver != address(0)) {
            return (collInfo.receiver, (salePrice * collInfo.royaltyBps) / 10000);
        }

        // 3. Try EIP-2981 on the collection itself
        try IERC2981(collection).royaltyInfo(tokenId, salePrice) returns (
            address _receiver,
            uint256 _amount
        ) {
            // Cap at 10%
            uint256 maxAmount = (salePrice * MAX_ROYALTY_BPS) / 10000;
            if (_amount > maxAmount) {
                _amount = maxAmount;
            }
            return (_receiver, _amount);
        } catch {
            return (address(0), 0);
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
