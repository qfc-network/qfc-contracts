// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Create2Factory
 * @dev Factory for deploying contracts with deterministic addresses using CREATE2
 *
 * Features:
 * - Deploy contracts to predictable addresses
 * - Support for constructor arguments
 * - Batch deployments
 */
contract Create2Factory {
    event ContractDeployed(address indexed deployer, address indexed deployed, bytes32 salt);

    /**
     * @dev Deploy a contract using CREATE2
     * @param salt Unique salt for address generation
     * @param bytecode Contract bytecode (including constructor args)
     * @return deployed Address of the deployed contract
     */
    function deploy(bytes32 salt, bytes calldata bytecode)
        external
        payable
        returns (address deployed)
    {
        require(bytecode.length > 0, "Empty bytecode");

        bytes memory code = bytecode;
        assembly {
            deployed := create2(callvalue(), add(code, 0x20), mload(code), salt)
        }

        require(deployed != address(0), "Deployment failed");

        emit ContractDeployed(msg.sender, deployed, salt);
    }

    /**
     * @dev Deploy a contract with encoded constructor arguments
     * @param salt Unique salt
     * @param bytecode Contract creation bytecode
     * @param constructorArgs ABI encoded constructor arguments
     * @return deployed Address of the deployed contract
     */
    function deployWithArgs(
        bytes32 salt,
        bytes calldata bytecode,
        bytes calldata constructorArgs
    ) external payable returns (address deployed) {
        bytes memory code = abi.encodePacked(bytecode, constructorArgs);

        assembly {
            deployed := create2(callvalue(), add(code, 0x20), mload(code), salt)
        }

        require(deployed != address(0), "Deployment failed");

        emit ContractDeployed(msg.sender, deployed, salt);
    }

    /**
     * @dev Compute the address of a contract deployed with CREATE2
     * @param salt Salt used for deployment
     * @param bytecodeHash Keccak256 hash of the bytecode
     * @return predicted The predicted address
     */
    function computeAddress(bytes32 salt, bytes32 bytecodeHash)
        external
        view
        returns (address predicted)
    {
        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)
                    )
                )
            )
        );
    }

    /**
     * @dev Compute address from bytecode
     * @param salt Salt used for deployment
     * @param bytecode Contract bytecode
     * @return predicted The predicted address
     */
    function computeAddressFromBytecode(bytes32 salt, bytes calldata bytecode)
        external
        view
        returns (address predicted)
    {
        bytes32 bytecodeHash = keccak256(bytecode);
        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)
                    )
                )
            )
        );
    }

    /**
     * @dev Check if an address has code
     * @param addr Address to check
     * @return hasCode True if address has code
     */
    function isContract(address addr) external view returns (bool hasCode) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        hasCode = size > 0;
    }

    /**
     * @dev Batch deploy multiple contracts
     * @param salts Array of salts
     * @param bytecodes Array of bytecodes
     * @return deployed Array of deployed addresses
     */
    function batchDeploy(bytes32[] calldata salts, bytes[] calldata bytecodes)
        external
        payable
        returns (address[] memory deployed)
    {
        require(salts.length == bytecodes.length, "Length mismatch");

        deployed = new address[](salts.length);

        for (uint256 i = 0; i < salts.length; i++) {
            bytes memory code = bytecodes[i];
            bytes32 salt = salts[i];

            address addr;
            assembly {
                addr := create2(0, add(code, 0x20), mload(code), salt)
            }

            require(addr != address(0), "Deployment failed");
            deployed[i] = addr;

            emit ContractDeployed(msg.sender, addr, salt);
        }
    }
}
