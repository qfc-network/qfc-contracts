// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title AgentToken
 * @notice ERC-20 token representing an AI agent on the QFC network.
 *         Minting is restricted to the factory contract.
 */
contract AgentToken is ERC20, ERC20Burnable {
    /// @notice The factory contract that deployed this token
    address public immutable factory;

    /// @notice The bonding curve contract authorized to mint
    address public immutable bondingCurve;

    /// @notice The revenue distributor contract for this token
    address public immutable revenueDistributor;

    /// @notice IPFS metadata URI for the agent
    string public metadataURI;

    error OnlyFactory();

    /**
     * @notice Constructs the AgentToken.
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _factory Factory contract address
     * @param _bondingCurve Bonding curve contract address (authorized minter)
     * @param _revenueDistributor Revenue distributor contract address
     * @param _metadataURI IPFS metadata URI
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _factory,
        address _bondingCurve,
        address _revenueDistributor,
        string memory _metadataURI
    ) ERC20(_name, _symbol) {
        factory = _factory;
        bondingCurve = _bondingCurve;
        revenueDistributor = _revenueDistributor;
        metadataURI = _metadataURI;
    }

    /**
     * @notice Mint tokens. Can only be called by the factory or bonding curve.
     * @param to Recipient address
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        if (msg.sender != factory && msg.sender != bondingCurve) revert OnlyFactory();
        _mint(to, amount);
    }
}
