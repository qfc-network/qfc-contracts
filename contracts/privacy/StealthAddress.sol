// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title StealthAddress
 * @notice EIP-5564 inspired stealth address registry and transfer system for qUSD.
 *
 *  How it works:
 *    1. Recipient registers a stealth meta-address (spending pubkey + viewing pubkey)
 *    2. Sender calls `sendStealth()`:
 *       - Generates ephemeral keypair off-chain
 *       - Computes stealth address = hash(ephemeralPriv * viewingPub) + spendingPub
 *       - Transfers qUSD to stealth address
 *       - Publishes ephemeral pubkey on-chain (announcement)
 *    3. Recipient scans announcements using viewing key
 *       - For each announcement, tries to derive stealth address
 *       - If it matches, they can spend from it using spending key
 *
 *  Privacy guarantee:
 *    - An observer cannot link a stealth address to the recipient's main address
 *    - Only the viewing key holder can identify which announcements are theirs
 *    - The spending key is needed to actually move funds
 *
 * @dev This is a simplified implementation. Production should use secp256k1
 *      ECDH for key derivation. The current version uses hash-based derivation.
 */
contract StealthAddress {
    using SafeERC20 for IERC20;

    // --- Meta-address registry ---

    struct StealthMetaAddress {
        bytes spendingPubKey;  // Public key for spending (compressed, 33 bytes)
        bytes viewingPubKey;   // Public key for scanning (compressed, 33 bytes)
        bool registered;
    }

    /// @notice Registry: main address → stealth meta-address
    mapping(address => StealthMetaAddress) public registry;

    // --- Announcements ---

    struct Announcement {
        address token;              // ERC-20 token transferred
        uint256 amount;             // Amount transferred
        address stealthAddress;     // One-time stealth address
        bytes ephemeralPubKey;      // Sender's ephemeral pubkey (for recipient to derive)
        bytes32 viewTag;            // First 32 bytes of shared secret (for fast scanning)
        uint256 timestamp;
    }

    Announcement[] public announcements;

    // --- Events ---

    event StealthMetaAddressRegistered(
        address indexed registrant,
        bytes spendingPubKey,
        bytes viewingPubKey
    );

    event StealthTransfer(
        address indexed token,
        address indexed stealthAddress,
        bytes ephemeralPubKey,
        bytes32 viewTag,
        uint256 amount
    );

    // --- Errors ---

    error AlreadyRegistered();
    error NotRegistered();
    error InvalidPubKey();
    error ZeroAmount();

    // =========================================================================
    // Registry
    // =========================================================================

    /**
     * @notice Register a stealth meta-address
     * @param _spendingPubKey Public key for spending (33 bytes compressed)
     * @param _viewingPubKey Public key for scanning announcements (33 bytes compressed)
     */
    function registerMetaAddress(
        bytes calldata _spendingPubKey,
        bytes calldata _viewingPubKey
    ) external {
        if (registry[msg.sender].registered) revert AlreadyRegistered();
        if (_spendingPubKey.length == 0 || _viewingPubKey.length == 0) revert InvalidPubKey();

        registry[msg.sender] = StealthMetaAddress({
            spendingPubKey: _spendingPubKey,
            viewingPubKey: _viewingPubKey,
            registered: true
        });

        emit StealthMetaAddressRegistered(msg.sender, _spendingPubKey, _viewingPubKey);
    }

    /**
     * @notice Update stealth meta-address
     */
    function updateMetaAddress(
        bytes calldata _spendingPubKey,
        bytes calldata _viewingPubKey
    ) external {
        if (!registry[msg.sender].registered) revert NotRegistered();
        if (_spendingPubKey.length == 0 || _viewingPubKey.length == 0) revert InvalidPubKey();

        registry[msg.sender].spendingPubKey = _spendingPubKey;
        registry[msg.sender].viewingPubKey = _viewingPubKey;

        emit StealthMetaAddressRegistered(msg.sender, _spendingPubKey, _viewingPubKey);
    }

    // =========================================================================
    // Stealth transfer
    // =========================================================================

    /**
     * @notice Send ERC-20 tokens to a stealth address
     * @param _token ERC-20 token to send
     * @param _stealthAddress The computed one-time stealth address
     * @param _amount Amount to send
     * @param _ephemeralPubKey Sender's ephemeral pubkey (for recipient to derive shared secret)
     * @param _viewTag First 32 bytes of shared secret (for fast announcement scanning)
     *
     * @dev The sender computes the stealth address off-chain:
     *      1. Generate ephemeral keypair (r, R = r*G)
     *      2. Compute shared secret S = r * viewingPubKey
     *      3. viewTag = keccak256(S)
     *      4. stealthAddress = spendingPubKey + hash(S)*G → derive address
     *      5. Call this function with (stealthAddress, R, viewTag)
     */
    function sendStealth(
        address _token,
        address _stealthAddress,
        uint256 _amount,
        bytes calldata _ephemeralPubKey,
        bytes32 _viewTag
    ) external {
        if (_amount == 0) revert ZeroAmount();

        // Transfer tokens to stealth address
        IERC20(_token).safeTransferFrom(msg.sender, _stealthAddress, _amount);

        // Store announcement for recipient scanning
        announcements.push(Announcement({
            token: _token,
            amount: _amount,
            stealthAddress: _stealthAddress,
            ephemeralPubKey: _ephemeralPubKey,
            viewTag: _viewTag,
            timestamp: block.timestamp
        }));

        emit StealthTransfer(_token, _stealthAddress, _ephemeralPubKey, _viewTag, _amount);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /**
     * @notice Get the stealth meta-address of a user
     */
    function getMetaAddress(address _user)
        external
        view
        returns (bytes memory spendingPubKey, bytes memory viewingPubKey)
    {
        StealthMetaAddress memory meta = registry[_user];
        if (!meta.registered) revert NotRegistered();
        return (meta.spendingPubKey, meta.viewingPubKey);
    }

    /**
     * @notice Get announcements in a range (for scanning)
     * @param _fromIndex Start index (inclusive)
     * @param _count Max number to return
     */
    function getAnnouncements(uint256 _fromIndex, uint256 _count)
        external
        view
        returns (Announcement[] memory result)
    {
        uint256 total = announcements.length;
        if (_fromIndex >= total) return new Announcement[](0);

        uint256 end = _fromIndex + _count;
        if (end > total) end = total;
        uint256 len = end - _fromIndex;

        result = new Announcement[](len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = announcements[_fromIndex + i];
        }
    }

    /**
     * @notice Get announcements filtered by viewTag (fast scanning)
     * @param _viewTag The viewTag to filter by
     * @param _fromIndex Start index
     * @param _maxResults Max results to return
     */
    function scanByViewTag(bytes32 _viewTag, uint256 _fromIndex, uint256 _maxResults)
        external
        view
        returns (Announcement[] memory result)
    {
        // First pass: count matches
        uint256 total = announcements.length;
        uint256 matchCount = 0;
        uint256[] memory matchIndices = new uint256[](_maxResults);

        for (uint256 i = _fromIndex; i < total && matchCount < _maxResults; i++) {
            if (announcements[i].viewTag == _viewTag) {
                matchIndices[matchCount] = i;
                matchCount++;
            }
        }

        result = new Announcement[](matchCount);
        for (uint256 i = 0; i < matchCount; i++) {
            result[i] = announcements[matchIndices[i]];
        }
    }

    /**
     * @notice Total number of announcements
     */
    function announcementCount() external view returns (uint256) {
        return announcements.length;
    }
}
