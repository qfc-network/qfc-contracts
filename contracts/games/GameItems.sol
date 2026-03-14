// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title GameItems
 * @dev QRC-721 NFT for in-game items across all QFC games
 *
 * Features:
 * - Authorized game contracts can mint items
 * - Item rarity tiers with metadata
 * - Per-game item categories (dungeon drops, card packs, bred pets)
 * - EIP-2981 royalty support
 * - Soulbound option for non-transferable items
 */
contract GameItems is ERC721, ERC721Enumerable, ERC721URIStorage, ERC721Royalty, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    enum Rarity { Common, Uncommon, Rare, Epic, Legendary }

    struct Item {
        bytes32 gameId;
        Rarity rarity;
        uint256 mintedAt;
        bool soulbound;
    }

    uint256 private _nextTokenId;

    /// @dev tokenId => item metadata
    mapping(uint256 => Item) public items;

    /// @dev gameId => total items minted
    mapping(bytes32 => uint256) public gameItemCount;

    /// @dev gameId => rarity => total minted
    mapping(bytes32 => mapping(Rarity => uint256)) public rarityCount;

    event ItemMinted(
        uint256 indexed tokenId,
        address indexed player,
        bytes32 indexed gameId,
        Rarity rarity,
        bool soulbound
    );
    event ItemBurned(uint256 indexed tokenId);

    constructor(
        uint96 defaultRoyaltyBps,
        address royaltyReceiver
    ) ERC721("QFC Game Items", "QITEM") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _setDefaultRoyalty(royaltyReceiver, defaultRoyaltyBps);
    }

    /**
     * @dev Mint a game item to a player
     * @param player Recipient address
     * @param gameId Game that generated the item
     * @param rarity Item rarity tier
     * @param soulbound Whether the item is non-transferable
     * @param uri Token metadata URI
     * @return tokenId The minted token ID
     */
    function mintItem(
        address player,
        bytes32 gameId,
        Rarity rarity,
        bool soulbound,
        string calldata uri
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        tokenId = _nextTokenId++;

        _safeMint(player, tokenId);
        _setTokenURI(tokenId, uri);

        items[tokenId] = Item({
            gameId: gameId,
            rarity: rarity,
            mintedAt: block.timestamp,
            soulbound: soulbound
        });

        gameItemCount[gameId]++;
        rarityCount[gameId][rarity]++;

        emit ItemMinted(tokenId, player, gameId, rarity, soulbound);
    }

    /**
     * @dev Batch mint items (for loot boxes, card packs, etc.)
     * @param player Recipient address
     * @param gameId Game identifier
     * @param rarities Array of rarities
     * @param soulbound Whether items are non-transferable
     * @param uris Token metadata URIs
     * @return tokenIds The minted token IDs
     */
    function batchMint(
        address player,
        bytes32 gameId,
        Rarity[] calldata rarities,
        bool soulbound,
        string[] calldata uris
    ) external onlyRole(MINTER_ROLE) returns (uint256[] memory tokenIds) {
        require(rarities.length == uris.length, "Length mismatch");

        tokenIds = new uint256[](rarities.length);
        for (uint256 i = 0; i < rarities.length; i++) {
            uint256 tokenId = _nextTokenId++;
            _safeMint(player, tokenId);
            _setTokenURI(tokenId, uris[i]);

            items[tokenId] = Item({
                gameId: gameId,
                rarity: rarities[i],
                mintedAt: block.timestamp,
                soulbound: soulbound
            });

            gameItemCount[gameId]++;
            rarityCount[gameId][rarities[i]]++;
            tokenIds[i] = tokenId;

            emit ItemMinted(tokenId, player, gameId, rarities[i], soulbound);
        }
    }

    /**
     * @dev Burn an item (owner only)
     * @param tokenId Token ID to burn
     */
    function burn(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Not the owner");
        _burn(tokenId);
        emit ItemBurned(tokenId);
    }

    /**
     * @dev Get item details
     * @param tokenId Token ID
     */
    function getItem(uint256 tokenId) external view returns (Item memory) {
        require(ownerOf(tokenId) != address(0), "Token does not exist");
        return items[tokenId];
    }

    // --- Soulbound transfer restriction ---

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        address from = _ownerOf(tokenId);
        // Allow minting (from == 0) and burning (to == 0), block transfers of soulbound
        if (from != address(0) && to != address(0) && items[tokenId].soulbound) {
            revert("Soulbound: non-transferable");
        }
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721URIStorage, ERC721Royalty, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
