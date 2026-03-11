// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {QFCAgentAccount} from "./QFCAgentAccount.sol";

/**
 * @title QFCAccountFactory
 * @notice Factory contract for deploying QFCAgentAccount proxies via CREATE2.
 */
contract QFCAccountFactory {
    /// @notice The singleton implementation contract.
    QFCAgentAccount public immutable accountImplementation;

    /// @notice The ERC-4337 EntryPoint used by all created accounts.
    IEntryPoint public immutable entryPoint;

    /// @notice Deployed accounts by (owner, salt) hash.
    mapping(bytes32 => address) public deployedAccounts;

    // ── Events ──────────────────────────────────────────────────────────
    event AccountCreated(address indexed account, address indexed owner, uint256 salt);

    // ── Errors ──────────────────────────────────────────────────────────
    error AccountAlreadyDeployed(address account);

    /// @notice Deploy the factory with a new implementation instance.
    /// @param entryPoint_ The ERC-4337 EntryPoint contract.
    constructor(IEntryPoint entryPoint_) {
        entryPoint = entryPoint_;
        accountImplementation = new QFCAgentAccount();
    }

    /// @notice Deploy a new account proxy via CREATE2.
    /// @param owner_ The owner of the new account.
    /// @param salt A salt for deterministic deployment.
    /// @return account The address of the deployed proxy.
    function createAccount(address owner_, uint256 salt) external returns (address account) {
        bytes32 key = keccak256(abi.encodePacked(owner_, salt));
        if (deployedAccounts[key] != address(0)) {
            revert AccountAlreadyDeployed(deployedAccounts[key]);
        }

        bytes memory initData = abi.encodeCall(QFCAgentAccount.initialize, (owner_, entryPoint));
        ERC1967Proxy proxy = new ERC1967Proxy{salt: bytes32(salt)}(
            address(accountImplementation),
            initData
        );
        account = address(proxy);
        deployedAccounts[key] = account;
        emit AccountCreated(account, owner_, salt);
    }

    /// @notice Get the deployed address for an account, or address(0) if not yet deployed.
    /// @param owner_ The owner of the account.
    /// @param salt A salt for deterministic deployment.
    /// @return The deployed account address, or address(0).
    function getAccountAddress(address owner_, uint256 salt) public view returns (address) {
        return deployedAccounts[keccak256(abi.encodePacked(owner_, salt))];
    }
}
