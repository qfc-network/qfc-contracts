// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title QUSDToken
 * @notice qUSD — QFC's native stablecoin pegged to USD. Only the CDPVault can mint and burn.
 */
contract QUSDToken is ERC20, ERC20Burnable, ERC20Permit, Ownable {
    /// @notice Address of the CDPVault authorized to mint/burn
    address public vault;

    error OnlyVault();
    error ZeroAddress();

    event VaultUpdated(address indexed oldVault, address indexed newVault);

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor() ERC20("qUSD Stablecoin", "qUSD") ERC20Permit("qUSD Stablecoin") Ownable(msg.sender) {}

    /**
     * @notice Set the CDPVault address authorized to mint/burn
     * @param _vault Address of the CDPVault contract
     */
    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert ZeroAddress();
        address oldVault = vault;
        vault = _vault;
        emit VaultUpdated(oldVault, _vault);
    }

    /**
     * @notice Mint qUSD tokens. Only callable by the vault.
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    /**
     * @notice Burn qUSD tokens from an address. Only callable by the vault.
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) public override onlyVault {
        _burn(from, amount);
    }
}
