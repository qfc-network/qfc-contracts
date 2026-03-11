// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {IAccount} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

/**
 * @title MockEntryPoint
 * @notice Simplified EntryPoint mock for testing ERC-4337 accounts.
 */
contract MockEntryPoint {
    mapping(address => uint256) public balanceOf;

    event UserOpHandled(address indexed sender, bool success);

    error ExecutionFailed(address sender, bytes returnData);

    /// @notice Deposit ETH for an account.
    /// @param account The account to deposit for.
    function depositTo(address account) external payable {
        balanceOf[account] += msg.value;
    }

    /// @notice Withdraw ETH from the deposit.
    /// @param withdrawAddress The address to send funds to.
    /// @param withdrawAmount The amount to withdraw.
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external {
        require(balanceOf[msg.sender] >= withdrawAmount, "insufficient balance");
        balanceOf[msg.sender] -= withdrawAmount;
        (bool success, ) = withdrawAddress.call{value: withdrawAmount}("");
        require(success, "withdraw failed");
    }

    /// @notice Handle a batch of user operations (simplified).
    /// @param ops Array of packed user operations.
    /// @param beneficiary Address to receive gas refunds (unused in mock).
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external {
        (beneficiary); // suppress unused warning
        for (uint256 i = 0; i < ops.length; i++) {
            PackedUserOperation calldata op = ops[i];
            address sender = op.sender;

            // Validate
            bytes32 userOpHash = keccak256(abi.encode(op.sender, op.nonce, op.callData));
            uint256 validationData = IAccount(sender).validateUserOp(op, userOpHash, 0);
            require(validationData == 0 || (validationData >> 160) > 0, "validation failed");

            // Execute
            if (op.callData.length > 0) {
                (bool success, bytes memory returnData) = sender.call(op.callData);
                if (!success) revert ExecutionFailed(sender, returnData);
            }

            emit UserOpHandled(sender, true);
        }
    }

    /// @notice Get the nonce (simplified — always 0).
    function getNonce(address, uint192) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}
