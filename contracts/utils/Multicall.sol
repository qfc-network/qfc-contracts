// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Multicall
 * @dev Aggregate multiple contract calls into a single transaction
 *
 * Features:
 * - Batch multiple read calls
 * - Batch multiple write calls
 * - Optional failure handling
 */
contract Multicall {
    struct Call {
        address target;
        bytes callData;
    }

    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Call3Value {
        address target;
        bool allowFailure;
        uint256 value;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    /**
     * @dev Aggregate calls (reverts if any call fails)
     * @param calls Array of Call structs
     * @return blockNumber Current block number
     * @return returnData Array of return data
     */
    function aggregate(Call[] calldata calls)
        external
        payable
        returns (uint256 blockNumber, bytes[] memory returnData)
    {
        blockNumber = block.number;
        returnData = new bytes[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
            require(success, "Multicall: call failed");
            returnData[i] = ret;
        }
    }

    /**
     * @dev Aggregate calls with failure handling
     * @param calls Array of Call3 structs
     * @return returnData Array of Result structs
     */
    function aggregate3(Call3[] calldata calls)
        external
        payable
        returns (Result[] memory returnData)
    {
        returnData = new Result[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);

            if (!success && !calls[i].allowFailure) {
                // Bubble up the revert reason
                if (ret.length > 0) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
                revert("Multicall3: call failed");
            }

            returnData[i] = Result(success, ret);
        }
    }

    /**
     * @dev Aggregate calls with value and failure handling
     * @param calls Array of Call3Value structs
     * @return returnData Array of Result structs
     */
    function aggregate3Value(Call3Value[] calldata calls)
        external
        payable
        returns (Result[] memory returnData)
    {
        returnData = new Result[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory ret) = calls[i].target.call{value: calls[i].value}(
                calls[i].callData
            );

            if (!success && !calls[i].allowFailure) {
                if (ret.length > 0) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
                revert("Multicall3: call failed");
            }

            returnData[i] = Result(success, ret);
        }
    }

    /**
     * @dev Try aggregate calls (never reverts)
     * @param calls Array of Call structs
     * @return blockNumber Current block number
     * @return returnData Array of Result structs
     */
    function tryAggregate(bool requireSuccess, Call[] calldata calls)
        external
        payable
        returns (uint256 blockNumber, Result[] memory returnData)
    {
        blockNumber = block.number;
        returnData = new Result[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);

            if (requireSuccess && !success) {
                if (ret.length > 0) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
                revert("Multicall: call failed");
            }

            returnData[i] = Result(success, ret);
        }
    }

    /**
     * @dev Get ETH balance of an address
     * @param addr Address to check
     * @return balance ETH balance
     */
    function getEthBalance(address addr) external view returns (uint256 balance) {
        balance = addr.balance;
    }

    /**
     * @dev Get current block number
     */
    function getBlockNumber() external view returns (uint256 blockNumber) {
        blockNumber = block.number;
    }

    /**
     * @dev Get current block hash
     * @param blockNumber Block number to get hash for
     */
    function getBlockHash(uint256 blockNumber) external view returns (bytes32 blockHash) {
        blockHash = blockhash(blockNumber);
    }

    /**
     * @dev Get current block timestamp
     */
    function getCurrentBlockTimestamp() external view returns (uint256 timestamp) {
        timestamp = block.timestamp;
    }

    /**
     * @dev Get current block gas limit
     */
    function getCurrentBlockGasLimit() external view returns (uint256 gaslimit) {
        gaslimit = block.gaslimit;
    }

    /**
     * @dev Get current block coinbase
     */
    function getCurrentBlockCoinbase() external view returns (address coinbase) {
        coinbase = block.coinbase;
    }

    /**
     * @dev Get chain ID
     */
    function getChainId() external view returns (uint256 chainid) {
        chainid = block.chainid;
    }

    /**
     * @dev Get base fee
     */
    function getBasefee() external view returns (uint256 basefee) {
        basefee = block.basefee;
    }
}
