// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title QFCCollection
 * @dev ERC-721 collection deployed by CollectionFactory
 *
 * Features:
 * - Configurable max supply, mint price, royalty
 * - Whitelist mint phase via merkle proof
 * - Public mint phase
 * - EIP-2981 royalty built-in
 */
contract QFCCollection is ERC721, ERC721Enumerable, ERC721Royalty, Ownable {
    uint256 private _nextTokenId;
    uint256 public maxSupply;
    uint256 public mintPrice;
    bytes32 public merkleRoot;
    bool public publicMintEnabled;
    bool public whitelistMintEnabled;
    string private _baseTokenURI;

    mapping(address => bool) public whitelistClaimed;

    event PublicMintToggled(bool enabled);
    event WhitelistMintToggled(bool enabled);
    event MerkleRootSet(bytes32 root);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 _maxSupply,
        uint256 _mintPrice,
        uint96 _royaltyBps,
        address royaltyReceiver,
        address owner_
    ) ERC721(name_, symbol_) Ownable(owner_) {
        maxSupply = _maxSupply;
        mintPrice = _mintPrice;
        _setDefaultRoyalty(royaltyReceiver, _royaltyBps);
    }

    /**
     * @dev Whitelist mint with merkle proof
     * @param proof Merkle proof for the caller
     */
    function whitelistMint(bytes32[] calldata proof) external payable {
        require(whitelistMintEnabled, "Whitelist mint not active");
        require(msg.value >= mintPrice, "Insufficient payment");
        require(!whitelistClaimed[msg.sender], "Already claimed");
        require(_nextTokenId < maxSupply, "Max supply reached");

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        require(MerkleProof.verify(proof, merkleRoot, leaf), "Invalid proof");

        whitelistClaimed[msg.sender] = true;
        _safeMint(msg.sender, _nextTokenId++);
    }

    /**
     * @dev Public mint
     * @param quantity Number of tokens to mint
     */
    function publicMint(uint256 quantity) external payable {
        require(publicMintEnabled, "Public mint not active");
        require(msg.value >= mintPrice * quantity, "Insufficient payment");
        require(_nextTokenId + quantity <= maxSupply, "Exceeds max supply");

        for (uint256 i = 0; i < quantity; i++) {
            _safeMint(msg.sender, _nextTokenId++);
        }
    }

    /**
     * @dev Set merkle root for whitelist
     * @param _merkleRoot New merkle root
     */
    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
        emit MerkleRootSet(_merkleRoot);
    }

    /**
     * @dev Toggle public mint phase
     */
    function togglePublicMint() external onlyOwner {
        publicMintEnabled = !publicMintEnabled;
        emit PublicMintToggled(publicMintEnabled);
    }

    /**
     * @dev Toggle whitelist mint phase
     */
    function toggleWhitelistMint() external onlyOwner {
        whitelistMintEnabled = !whitelistMintEnabled;
        emit WhitelistMintToggled(whitelistMintEnabled);
    }

    /**
     * @dev Set base token URI
     * @param baseURI New base URI
     */
    function setBaseURI(string memory baseURI) external onlyOwner {
        _baseTokenURI = baseURI;
    }

    /**
     * @dev Withdraw contract balance
     */
    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
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

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721Royalty)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

/**
 * @title CollectionFactory
 * @dev Factory for deploying new QRC-721 collections
 *
 * Features:
 * - Deploy new collections with configurable parameters
 * - Track all deployed collections
 * - Configurable creation fee
 */
contract CollectionFactory is Ownable {
    address[] public collections;
    mapping(address => address[]) public creatorCollections;

    uint256 public creationFee;

    event CollectionCreated(
        address indexed collection,
        address indexed creator,
        string name,
        string symbol,
        uint256 maxSupply
    );
    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);

    constructor(uint256 _creationFee) Ownable(msg.sender) {
        creationFee = _creationFee;
    }

    /**
     * @dev Deploy a new QRC-721 collection
     * @param name Collection name
     * @param symbol Collection symbol
     * @param maxSupply Maximum number of tokens
     * @param mintPrice Price per mint in wei
     * @param royaltyBps Royalty in basis points (max 1000 = 10%)
     * @return collection Address of the deployed collection
     */
    function createCollection(
        string calldata name,
        string calldata symbol,
        uint256 maxSupply,
        uint256 mintPrice,
        uint96 royaltyBps
    ) external payable returns (address collection) {
        require(msg.value >= creationFee, "Insufficient creation fee");
        require(royaltyBps <= 1000, "Royalty exceeds 10%");
        require(maxSupply > 0, "Max supply must be > 0");

        QFCCollection newCollection = new QFCCollection(
            name,
            symbol,
            maxSupply,
            mintPrice,
            royaltyBps,
            msg.sender,
            msg.sender
        );

        collection = address(newCollection);
        collections.push(collection);
        creatorCollections[msg.sender].push(collection);

        emit CollectionCreated(collection, msg.sender, name, symbol, maxSupply);
    }

    /**
     * @dev Get total number of deployed collections
     */
    function totalCollections() external view returns (uint256) {
        return collections.length;
    }

    /**
     * @dev Get collections created by a specific address
     * @param creator Creator address
     */
    function getCreatorCollections(address creator) external view returns (address[] memory) {
        return creatorCollections[creator];
    }

    /**
     * @dev Update creation fee
     * @param _creationFee New fee in wei
     */
    function setCreationFee(uint256 _creationFee) external onlyOwner {
        emit CreationFeeUpdated(creationFee, _creationFee);
        creationFee = _creationFee;
    }

    /**
     * @dev Withdraw collected fees
     */
    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}
