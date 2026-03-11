// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title WrappedToken
 * @dev Wrapped representation of a cross-chain asset on the QFC chain.
 *      Only the BridgeMint contract can mint and burn tokens.
 *
 * Features:
 * - Standard ERC-20 (QRC-20) with mint/burn restricted to bridge
 * - Deploy as wETH, wUSDC, wBTC etc. with different name/symbol/decimals
 */
contract WrappedToken is ERC20, ERC20Burnable {
    /// @dev Address of the BridgeMint contract authorized to mint/burn
    address public immutable bridge;

    /// @dev Token decimals (configurable per deployment)
    uint8 private immutable _decimals;

    // ── Errors ──────────────────────────────────────────────────────────

    error OnlyBridge();
    error ZeroAddress();

    // ── Modifiers ───────────────────────────────────────────────────────

    modifier onlyBridge() {
        if (msg.sender != bridge) revert OnlyBridge();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────

    /**
     * @param _name Token name (e.g. "Wrapped Ether")
     * @param _symbol Token symbol (e.g. "wETH")
     * @param _bridge Address of the BridgeMint contract
     * @param decimals_ Token decimals (e.g. 18 for wETH, 6 for wUSDC)
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _bridge,
        uint8 decimals_
    ) ERC20(_name, _symbol) {
        if (_bridge == address(0)) revert ZeroAddress();
        bridge = _bridge;
        _decimals = decimals_;
    }

    // ── Bridge Functions ────────────────────────────────────────────────

    /**
     * @notice Mint wrapped tokens to a recipient (bridge only)
     * @param _to Recipient address
     * @param _amount Amount to mint
     */
    function mint(address _to, uint256 _amount) external onlyBridge {
        _mint(_to, _amount);
    }

    /**
     * @notice Burn wrapped tokens from an account (bridge only)
     * @param _from Account to burn from
     * @param _amount Amount to burn
     */
    function bridgeBurn(address _from, uint256 _amount) external onlyBridge {
        _burn(_from, _amount);
    }

    // ── View Functions ──────────────────────────────────────────────────

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
