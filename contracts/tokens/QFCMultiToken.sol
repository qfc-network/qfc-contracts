// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title QFCMultiToken
 * @dev Example ERC1155 multi-token contract
 *
 * Features:
 * - Multiple token types in one contract
 * - Mintable by owner
 * - Burnable
 * - Supply tracking
 * - Custom URI per token type
 */
contract QFCMultiToken is ERC1155, ERC1155Burnable, ERC1155Supply, Ownable {
    string public name;
    string public symbol;

    // Token type metadata
    mapping(uint256 => string) private _tokenURIs;
    mapping(uint256 => uint256) public maxSupply;
    mapping(uint256 => uint256) public mintPrice;

    event TokenTypeCreated(uint256 indexed tokenId, uint256 maxSupply, uint256 mintPrice);
    event TokenURIUpdated(uint256 indexed tokenId, string uri);

    /**
     * @dev Constructor
     * @param _name Collection name
     * @param _symbol Collection symbol
     * @param _uri Default URI
     */
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _uri
    ) ERC1155(_uri) Ownable(msg.sender) {
        name = _name;
        symbol = _symbol;
    }

    /**
     * @dev Create a new token type
     * @param tokenId Token type ID
     * @param _maxSupply Maximum supply (0 for unlimited)
     * @param _mintPrice Mint price in wei
     * @param _uri Token URI
     */
    function createTokenType(
        uint256 tokenId,
        uint256 _maxSupply,
        uint256 _mintPrice,
        string memory _uri
    ) external onlyOwner {
        require(maxSupply[tokenId] == 0 && totalSupply(tokenId) == 0, "Token type exists");

        maxSupply[tokenId] = _maxSupply;
        mintPrice[tokenId] = _mintPrice;

        if (bytes(_uri).length > 0) {
            _tokenURIs[tokenId] = _uri;
        }

        emit TokenTypeCreated(tokenId, _maxSupply, _mintPrice);
    }

    /**
     * @dev Public mint
     * @param to Recipient address
     * @param tokenId Token type ID
     * @param amount Amount to mint
     */
    function mint(address to, uint256 tokenId, uint256 amount) external payable {
        require(msg.value >= mintPrice[tokenId] * amount, "Insufficient payment");
        require(
            maxSupply[tokenId] == 0 || totalSupply(tokenId) + amount <= maxSupply[tokenId],
            "Max supply exceeded"
        );

        _mint(to, tokenId, amount, "");

        // Refund excess
        uint256 totalPrice = mintPrice[tokenId] * amount;
        if (msg.value > totalPrice) {
            payable(msg.sender).transfer(msg.value - totalPrice);
        }
    }

    /**
     * @dev Owner mint (free)
     * @param to Recipient address
     * @param tokenId Token type ID
     * @param amount Amount to mint
     */
    function ownerMint(address to, uint256 tokenId, uint256 amount) external onlyOwner {
        _mint(to, tokenId, amount, "");
    }

    /**
     * @dev Batch mint multiple token types
     * @param to Recipient address
     * @param tokenIds Array of token IDs
     * @param amounts Array of amounts
     */
    function ownerMintBatch(
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts
    ) external onlyOwner {
        _mintBatch(to, tokenIds, amounts, "");
    }

    /**
     * @dev Set URI for a token type
     * @param tokenId Token type ID
     * @param _uri New URI
     */
    function setTokenURI(uint256 tokenId, string memory _uri) external onlyOwner {
        _tokenURIs[tokenId] = _uri;
        emit TokenURIUpdated(tokenId, _uri);
    }

    /**
     * @dev Set default URI
     * @param _uri New default URI
     */
    function setURI(string memory _uri) external onlyOwner {
        _setURI(_uri);
    }

    /**
     * @dev Withdraw contract balance
     */
    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    /**
     * @dev Get URI for a token type
     * @param tokenId Token type ID
     * @return Token URI
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        string memory tokenUri = _tokenURIs[tokenId];
        if (bytes(tokenUri).length > 0) {
            return tokenUri;
        }
        return super.uri(tokenId);
    }

    // Required override
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) {
        super._update(from, to, ids, values);
    }
}
