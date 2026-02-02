// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title QFCToken
 * @dev Example ERC20 token with mint, burn, and permit functionality
 *
 * Features:
 * - Mintable by owner
 * - Burnable by token holders
 * - EIP-2612 permit for gasless approvals
 * - Configurable cap
 */
contract QFCToken is ERC20, ERC20Burnable, ERC20Permit, Ownable {
    uint256 public immutable cap;

    /**
     * @dev Constructor
     * @param name Token name
     * @param symbol Token symbol
     * @param _cap Maximum supply cap (0 for unlimited)
     * @param initialSupply Initial supply to mint to deployer
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 _cap,
        uint256 initialSupply
    ) ERC20(name, symbol) ERC20Permit(name) Ownable(msg.sender) {
        require(_cap == 0 || initialSupply <= _cap, "Initial supply exceeds cap");
        cap = _cap;

        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    /**
     * @dev Mint new tokens (owner only)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        require(cap == 0 || totalSupply() + amount <= cap, "Cap exceeded");
        _mint(to, amount);
    }

    /**
     * @dev Batch transfer to multiple addresses
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts to transfer
     */
    function batchTransfer(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external {
        require(recipients.length == amounts.length, "Length mismatch");

        for (uint256 i = 0; i < recipients.length; i++) {
            transfer(recipients[i], amounts[i]);
        }
    }
}
