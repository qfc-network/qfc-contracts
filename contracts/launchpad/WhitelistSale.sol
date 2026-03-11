// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title WhitelistSale
 * @notice Token sale with a merkle-proof whitelist phase followed by a public phase.
 * @dev Whitelist phase runs from startTime to whitelistEndTime. Public phase runs
 *      from whitelistEndTime to endTime. Same soft/hard cap and refund mechanics
 *      as FairLaunch.
 */
contract WhitelistSale is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum SaleStatus { Active, Finalized, Cancelled }

    struct Sale {
        IERC20 token;
        uint256 softCap;
        uint256 hardCap;
        uint256 price;
        uint256 startTime;
        uint256 whitelistEndTime;
        uint256 endTime;
        uint256 maxPerWallet;
        uint256 totalRaised;
        address creator;
        SaleStatus status;
        bytes32 merkleRoot;
    }

    uint256 public nextSaleId;
    uint256 public constant PROTOCOL_FEE_BPS = 100;

    mapping(uint256 => Sale) private _sales;
    mapping(uint256 => mapping(address => uint256)) private _contributions;

    // --- Events ---

    event SaleCreated(
        uint256 indexed saleId,
        address indexed token,
        address indexed creator,
        uint256 softCap,
        uint256 hardCap,
        uint256 price,
        uint256 startTime,
        uint256 whitelistEndTime,
        uint256 endTime,
        uint256 maxPerWallet
    );

    event MerkleRootSet(uint256 indexed saleId, bytes32 merkleRoot);
    event Contributed(uint256 indexed saleId, address indexed contributor, uint256 amount, bool whitelisted);
    event SaleFinalized(uint256 indexed saleId, uint256 totalRaised, uint256 protocolFee);
    event SaleCancelled(uint256 indexed saleId);
    event Refunded(uint256 indexed saleId, address indexed contributor, uint256 amount);
    event TokensClaimed(uint256 indexed saleId, address indexed contributor, uint256 tokenAmount);

    // --- Errors ---

    error InvalidCaps();
    error InvalidPrice();
    error InvalidTimes();
    error InvalidMaxPerWallet();
    error SaleNotFound(uint256 saleId);
    error SaleNotActive(uint256 saleId);
    error SaleNotStarted(uint256 saleId);
    error SaleEnded(uint256 saleId);
    error SaleNotEnded(uint256 saleId);
    error HardCapReached(uint256 saleId);
    error ExceedsMaxPerWallet(uint256 saleId);
    error ExceedsWhitelistMax(uint256 saleId);
    error ZeroContribution();
    error SoftCapNotMet(uint256 saleId);
    error SoftCapMet(uint256 saleId);
    error NothingToRefund(uint256 saleId);
    error NothingToClaim(uint256 saleId);
    error TransferFailed();
    error InvalidProof();
    error WhitelistPhaseOnly(uint256 saleId);
    error PublicPhaseOnly(uint256 saleId);
    error NotCreator();

    constructor() Ownable(msg.sender) {}

    // --- External Functions ---

    /**
     * @notice Create a new whitelist sale.
     * @param token ERC-20 token to sell
     * @param softCap Minimum raise to succeed (in wei)
     * @param hardCap Maximum raise (in wei)
     * @param price Tokens per 1 wei of QFC contributed
     * @param startTime Unix timestamp when whitelist phase begins
     * @param whitelistEndTime Unix timestamp when whitelist phase ends and public begins
     * @param endTime Unix timestamp when sale ends
     * @param maxPerWallet Maximum contribution per wallet (in wei)
     * @return saleId The ID of the created sale
     */
    function createSale(
        address token,
        uint256 softCap,
        uint256 hardCap,
        uint256 price,
        uint256 startTime,
        uint256 whitelistEndTime,
        uint256 endTime,
        uint256 maxPerWallet
    ) external returns (uint256 saleId) {
        if (softCap == 0 || hardCap == 0 || softCap > hardCap) revert InvalidCaps();
        if (price == 0) revert InvalidPrice();
        if (startTime >= whitelistEndTime || whitelistEndTime >= endTime || startTime < block.timestamp)
            revert InvalidTimes();
        if (maxPerWallet == 0) revert InvalidMaxPerWallet();

        uint256 tokensRequired = hardCap * price;
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensRequired);

        saleId = nextSaleId++;
        _sales[saleId] = Sale({
            token: IERC20(token),
            softCap: softCap,
            hardCap: hardCap,
            price: price,
            startTime: startTime,
            whitelistEndTime: whitelistEndTime,
            endTime: endTime,
            maxPerWallet: maxPerWallet,
            totalRaised: 0,
            creator: msg.sender,
            status: SaleStatus.Active,
            merkleRoot: bytes32(0)
        });

        emit SaleCreated(
            saleId, token, msg.sender,
            softCap, hardCap, price,
            startTime, whitelistEndTime, endTime, maxPerWallet
        );
    }

    /**
     * @notice Set the merkle root for whitelist verification.
     * @param saleId The sale to configure
     * @param root The merkle root
     */
    function setMerkleRoot(uint256 saleId, bytes32 root) external {
        Sale storage sale = _getSale(saleId);
        if (msg.sender != sale.creator && msg.sender != owner()) revert NotCreator();
        sale.merkleRoot = root;
        emit MerkleRootSet(saleId, root);
    }

    /**
     * @notice Contribute during whitelist phase with a merkle proof.
     * @param saleId The sale to contribute to
     * @param proof Merkle proof for the caller
     * @param maxAmount Max allocation for this whitelisted address (encoded in leaf)
     */
    function contributeWhitelist(
        uint256 saleId,
        bytes32[] calldata proof,
        uint256 maxAmount
    ) external payable nonReentrant {
        Sale storage sale = _getSale(saleId);
        if (sale.status != SaleStatus.Active) revert SaleNotActive(saleId);
        if (block.timestamp < sale.startTime) revert SaleNotStarted(saleId);
        if (block.timestamp >= sale.whitelistEndTime) revert WhitelistPhaseOnly(saleId);
        if (msg.value == 0) revert ZeroContribution();

        // Verify merkle proof: leaf = double-hash to match @openzeppelin/merkle-tree StandardMerkleTree
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, maxAmount))));
        if (!MerkleProof.verify(proof, sale.merkleRoot, leaf)) revert InvalidProof();

        if (_contributions[saleId][msg.sender] + msg.value > maxAmount)
            revert ExceedsWhitelistMax(saleId);
        if (sale.totalRaised + msg.value > sale.hardCap) revert HardCapReached(saleId);

        _contributions[saleId][msg.sender] += msg.value;
        sale.totalRaised += msg.value;

        emit Contributed(saleId, msg.sender, msg.value, true);
    }

    /**
     * @notice Contribute during public phase.
     * @param saleId The sale to contribute to
     */
    function contributePublic(uint256 saleId) external payable nonReentrant {
        Sale storage sale = _getSale(saleId);
        if (sale.status != SaleStatus.Active) revert SaleNotActive(saleId);
        if (block.timestamp < sale.whitelistEndTime) revert PublicPhaseOnly(saleId);
        if (block.timestamp > sale.endTime) revert SaleEnded(saleId);
        if (msg.value == 0) revert ZeroContribution();
        if (sale.totalRaised + msg.value > sale.hardCap) revert HardCapReached(saleId);
        if (_contributions[saleId][msg.sender] + msg.value > sale.maxPerWallet)
            revert ExceedsMaxPerWallet(saleId);

        _contributions[saleId][msg.sender] += msg.value;
        sale.totalRaised += msg.value;

        emit Contributed(saleId, msg.sender, msg.value, false);
    }

    /**
     * @notice Finalize a successful sale.
     * @param saleId The sale to finalize
     */
    function finalize(uint256 saleId) external nonReentrant {
        Sale storage sale = _getSale(saleId);
        if (sale.status != SaleStatus.Active) revert SaleNotActive(saleId);

        bool hardCapHit = sale.totalRaised >= sale.hardCap;
        bool ended = block.timestamp > sale.endTime;
        if (!hardCapHit && !ended) revert SaleNotEnded(saleId);
        if (sale.totalRaised < sale.softCap) revert SoftCapNotMet(saleId);

        sale.status = SaleStatus.Finalized;

        uint256 protocolFee = (sale.totalRaised * PROTOCOL_FEE_BPS) / 10_000;
        uint256 creatorProceeds = sale.totalRaised - protocolFee;

        (bool ok, ) = sale.creator.call{value: creatorProceeds}("");
        if (!ok) revert TransferFailed();

        (ok, ) = owner().call{value: protocolFee}("");
        if (!ok) revert TransferFailed();

        uint256 tokensSold = sale.totalRaised * sale.price;
        uint256 tokensDeposited = sale.hardCap * sale.price;
        uint256 unsold = tokensDeposited - tokensSold;
        if (unsold > 0) {
            sale.token.safeTransfer(sale.creator, unsold);
        }

        emit SaleFinalized(saleId, sale.totalRaised, protocolFee);
    }

    /**
     * @notice Claim tokens after a successful sale.
     * @param saleId The sale to claim from
     */
    function claimTokens(uint256 saleId) external nonReentrant {
        Sale storage sale = _getSale(saleId);
        if (sale.status != SaleStatus.Finalized) revert SaleNotActive(saleId);

        uint256 contributed = _contributions[saleId][msg.sender];
        if (contributed == 0) revert NothingToClaim(saleId);

        _contributions[saleId][msg.sender] = 0;
        uint256 tokenAmount = contributed * sale.price;
        sale.token.safeTransfer(msg.sender, tokenAmount);

        emit TokensClaimed(saleId, msg.sender, tokenAmount);
    }

    /**
     * @notice Claim a refund if softCap was not met after endTime.
     * @param saleId The sale to get a refund from
     */
    function refund(uint256 saleId) external nonReentrant {
        Sale storage sale = _getSale(saleId);
        if (sale.status == SaleStatus.Finalized) revert SoftCapMet(saleId);
        if (block.timestamp <= sale.endTime) revert SaleNotEnded(saleId);
        if (sale.totalRaised >= sale.softCap) revert SoftCapMet(saleId);

        if (sale.status == SaleStatus.Active) {
            sale.status = SaleStatus.Cancelled;
            uint256 tokensDeposited = sale.hardCap * sale.price;
            sale.token.safeTransfer(sale.creator, tokensDeposited);
            emit SaleCancelled(saleId);
        }

        uint256 contributed = _contributions[saleId][msg.sender];
        if (contributed == 0) revert NothingToRefund(saleId);

        _contributions[saleId][msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: contributed}("");
        if (!ok) revert TransferFailed();

        emit Refunded(saleId, msg.sender, contributed);
    }

    // --- View Functions ---

    function getSale(uint256 saleId) external view returns (Sale memory) {
        return _getSale(saleId);
    }

    function getContribution(uint256 saleId, address contributor) external view returns (uint256) {
        return _contributions[saleId][contributor];
    }

    // --- Internal Functions ---

    function _getSale(uint256 saleId) internal view returns (Sale storage) {
        if (saleId >= nextSaleId) revert SaleNotFound(saleId);
        return _sales[saleId];
    }
}
