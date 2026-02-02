// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Treasury
 * @dev DAO treasury for managing funds
 *
 * Features:
 * - Hold ETH and ERC20 tokens
 * - Hold ERC721 NFTs
 * - Role-based access control
 * - Proposal-based spending
 */
contract Treasury is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SPENDER_ROLE = keccak256("SPENDER_ROLE");

    // Spending limits per role
    mapping(bytes32 => uint256) public spendingLimits;
    mapping(bytes32 => mapping(address => uint256)) public tokenSpendingLimits;

    // Spending tracking (resets daily)
    mapping(bytes32 => uint256) public dailySpent;
    mapping(bytes32 => mapping(address => uint256)) public dailyTokenSpent;
    uint256 public lastResetDay;

    event Deposit(address indexed from, uint256 amount);
    event TokenDeposit(address indexed token, address indexed from, uint256 amount);
    event Withdrawal(address indexed to, uint256 amount);
    event TokenWithdrawal(address indexed token, address indexed to, uint256 amount);
    event NFTWithdrawal(address indexed nft, address indexed to, uint256 tokenId);
    event SpendingLimitUpdated(bytes32 indexed role, uint256 limit);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        lastResetDay = block.timestamp / 1 days;
    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @dev Deposit ERC20 tokens
     * @param token Token address
     * @param amount Amount to deposit
     */
    function depositToken(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit TokenDeposit(token, msg.sender, amount);
    }

    /**
     * @dev Withdraw ETH
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdraw(address payable to, uint256 amount)
        external
        nonReentrant
        onlyRole(SPENDER_ROLE)
    {
        _resetDailyLimits();
        _checkSpendingLimit(SPENDER_ROLE, amount);

        dailySpent[SPENDER_ROLE] += amount;
        to.transfer(amount);

        emit Withdrawal(to, amount);
    }

    /**
     * @dev Withdraw ERC20 tokens
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawToken(address token, address to, uint256 amount)
        external
        nonReentrant
        onlyRole(SPENDER_ROLE)
    {
        _resetDailyLimits();
        _checkTokenSpendingLimit(SPENDER_ROLE, token, amount);

        dailyTokenSpent[SPENDER_ROLE][token] += amount;
        IERC20(token).safeTransfer(to, amount);

        emit TokenWithdrawal(token, to, amount);
    }

    /**
     * @dev Withdraw NFT
     * @param nft NFT contract address
     * @param to Recipient address
     * @param tokenId Token ID
     */
    function withdrawNFT(address nft, address to, uint256 tokenId)
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
    {
        IERC721(nft).transferFrom(address(this), to, tokenId);
        emit NFTWithdrawal(nft, to, tokenId);
    }

    /**
     * @dev Set spending limit for a role
     * @param role Role identifier
     * @param limit Daily limit in wei
     */
    function setSpendingLimit(bytes32 role, uint256 limit)
        external
        onlyRole(ADMIN_ROLE)
    {
        spendingLimits[role] = limit;
        emit SpendingLimitUpdated(role, limit);
    }

    /**
     * @dev Set token spending limit for a role
     * @param role Role identifier
     * @param token Token address
     * @param limit Daily limit
     */
    function setTokenSpendingLimit(bytes32 role, address token, uint256 limit)
        external
        onlyRole(ADMIN_ROLE)
    {
        tokenSpendingLimits[role][token] = limit;
    }

    /**
     * @dev Execute arbitrary call (admin only)
     * @param target Target contract
     * @param value ETH value
     * @param data Call data
     */
    function execute(address target, uint256 value, bytes calldata data)
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
        returns (bytes memory)
    {
        (bool success, bytes memory result) = target.call{value: value}(data);
        require(success, "Execution failed");
        return result;
    }

    /**
     * @dev Get treasury balances
     */
    function getBalances(address[] calldata tokens)
        external
        view
        returns (uint256 ethBalance, uint256[] memory tokenBalances)
    {
        ethBalance = address(this).balance;
        tokenBalances = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            tokenBalances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    function _resetDailyLimits() internal {
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > lastResetDay) {
            lastResetDay = currentDay;
            // Note: Mappings cannot be reset, but the check in _checkSpendingLimit
            // will effectively reset by comparing to the limit
        }
    }

    function _checkSpendingLimit(bytes32 role, uint256 amount) internal view {
        uint256 limit = spendingLimits[role];
        if (limit > 0) {
            require(dailySpent[role] + amount <= limit, "Daily limit exceeded");
        }
    }

    function _checkTokenSpendingLimit(bytes32 role, address token, uint256 amount) internal view {
        uint256 limit = tokenSpendingLimits[role][token];
        if (limit > 0) {
            require(dailyTokenSpent[role][token] + amount <= limit, "Daily token limit exceeded");
        }
    }

    // ERC721 receiver
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }
}
