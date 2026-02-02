// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title QFCNFT
 * @dev Example ERC721 NFT collection with enumerable and URI storage
 *
 * Features:
 * - Mintable with custom URI per token
 * - Enumerable (queryable by owner)
 * - Burnable
 * - Configurable max supply
 * - Configurable mint price
 */
contract QFCNFT is ERC721, ERC721Enumerable, ERC721URIStorage, ERC721Burnable, Ownable {
    uint256 private _nextTokenId;
    uint256 public maxSupply;
    uint256 public mintPrice;
    string public baseTokenURI;
    bool public mintingEnabled;

    event MintPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event BaseURIUpdated(string oldURI, string newURI);
    event MintingToggled(bool enabled);

    /**
     * @dev Constructor
     * @param name Collection name
     * @param symbol Collection symbol
     * @param _maxSupply Maximum number of tokens (0 for unlimited)
     * @param _mintPrice Price to mint in wei (0 for free)
     * @param _baseTokenURI Base URI for token metadata
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 _maxSupply,
        uint256 _mintPrice,
        string memory _baseTokenURI
    ) ERC721(name, symbol) Ownable(msg.sender) {
        maxSupply = _maxSupply;
        mintPrice = _mintPrice;
        baseTokenURI = _baseTokenURI;
        mintingEnabled = true;
    }

    /**
     * @dev Public mint function
     * @param to Recipient address
     * @param uri Token URI (can be empty to use base URI)
     */
    function mint(address to, string memory uri) external payable {
        require(mintingEnabled, "Minting disabled");
        require(msg.value >= mintPrice, "Insufficient payment");
        require(maxSupply == 0 || _nextTokenId < maxSupply, "Max supply reached");

        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);

        if (bytes(uri).length > 0) {
            _setTokenURI(tokenId, uri);
        }

        // Refund excess payment
        if (msg.value > mintPrice) {
            payable(msg.sender).transfer(msg.value - mintPrice);
        }
    }

    /**
     * @dev Owner mint (free, no limits)
     * @param to Recipient address
     * @param uri Token URI
     */
    function ownerMint(address to, string memory uri) external onlyOwner {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);

        if (bytes(uri).length > 0) {
            _setTokenURI(tokenId, uri);
        }
    }

    /**
     * @dev Batch mint to multiple addresses
     * @param recipients Array of recipient addresses
     */
    function batchMint(address[] calldata recipients) external onlyOwner {
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 tokenId = _nextTokenId++;
            _safeMint(recipients[i], tokenId);
        }
    }

    /**
     * @dev Set mint price
     * @param _mintPrice New mint price in wei
     */
    function setMintPrice(uint256 _mintPrice) external onlyOwner {
        emit MintPriceUpdated(mintPrice, _mintPrice);
        mintPrice = _mintPrice;
    }

    /**
     * @dev Set base URI
     * @param _baseTokenURI New base URI
     */
    function setBaseURI(string memory _baseTokenURI) external onlyOwner {
        emit BaseURIUpdated(baseTokenURI, _baseTokenURI);
        baseTokenURI = _baseTokenURI;
    }

    /**
     * @dev Toggle minting
     */
    function toggleMinting() external onlyOwner {
        mintingEnabled = !mintingEnabled;
        emit MintingToggled(mintingEnabled);
    }

    /**
     * @dev Withdraw contract balance
     */
    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    /**
     * @dev Get tokens owned by an address
     * @param owner Owner address
     * @return Array of token IDs
     */
    function tokensOfOwner(address owner) external view returns (uint256[] memory) {
        uint256 balance = balanceOf(owner);
        uint256[] memory tokens = new uint256[](balance);

        for (uint256 i = 0; i < balance; i++) {
            tokens[i] = tokenOfOwnerByIndex(owner, i);
        }

        return tokens;
    }

    // Required overrides
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
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

    function _baseURI() internal view override returns (string memory) {
        return baseTokenURI;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
