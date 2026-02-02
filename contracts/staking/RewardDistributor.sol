// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title RewardDistributor
 * @dev Merkle-tree based reward distribution
 *
 * Features:
 * - Efficient batch reward distribution using merkle proofs
 * - Multiple distribution epochs
 * - Claimable rewards per epoch
 */
contract RewardDistributor is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable rewardToken;

    struct Epoch {
        bytes32 merkleRoot;
        uint256 totalRewards;
        uint256 claimedRewards;
        uint256 startTime;
        uint256 endTime;
    }

    uint256 public currentEpoch;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => bool)) public claimed;

    event EpochCreated(uint256 indexed epoch, bytes32 merkleRoot, uint256 totalRewards);
    event RewardClaimed(uint256 indexed epoch, address indexed account, uint256 amount);

    constructor(address _rewardToken) Ownable(msg.sender) {
        rewardToken = IERC20(_rewardToken);
    }

    /**
     * @dev Create a new distribution epoch
     * @param merkleRoot Merkle root of the reward distribution
     * @param totalRewards Total rewards for this epoch
     * @param duration Duration in seconds
     */
    function createEpoch(
        bytes32 merkleRoot,
        uint256 totalRewards,
        uint256 duration
    ) external onlyOwner {
        require(merkleRoot != bytes32(0), "Invalid merkle root");
        require(totalRewards > 0, "Invalid total rewards");

        currentEpoch++;

        epochs[currentEpoch] = Epoch({
            merkleRoot: merkleRoot,
            totalRewards: totalRewards,
            claimedRewards: 0,
            startTime: block.timestamp,
            endTime: block.timestamp + duration
        });

        // Transfer rewards to contract
        rewardToken.safeTransferFrom(msg.sender, address(this), totalRewards);

        emit EpochCreated(currentEpoch, merkleRoot, totalRewards);
    }

    /**
     * @dev Claim rewards for an epoch
     * @param epoch Epoch number
     * @param amount Reward amount
     * @param merkleProof Merkle proof
     */
    function claim(
        uint256 epoch,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external {
        require(epoch > 0 && epoch <= currentEpoch, "Invalid epoch");
        require(!claimed[epoch][msg.sender], "Already claimed");

        Epoch storage epochData = epochs[epoch];
        require(block.timestamp >= epochData.startTime, "Not started");
        require(block.timestamp <= epochData.endTime, "Expired");

        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        require(
            MerkleProof.verify(merkleProof, epochData.merkleRoot, leaf),
            "Invalid proof"
        );

        claimed[epoch][msg.sender] = true;
        epochData.claimedRewards += amount;

        rewardToken.safeTransfer(msg.sender, amount);

        emit RewardClaimed(epoch, msg.sender, amount);
    }

    /**
     * @dev Claim rewards for multiple epochs
     * @param epochNumbers Array of epoch numbers
     * @param amounts Array of amounts
     * @param merkleProofs Array of merkle proofs
     */
    function claimMultiple(
        uint256[] calldata epochNumbers,
        uint256[] calldata amounts,
        bytes32[][] calldata merkleProofs
    ) external {
        require(
            epochNumbers.length == amounts.length &&
            amounts.length == merkleProofs.length,
            "Length mismatch"
        );

        uint256 totalAmount = 0;

        for (uint256 i = 0; i < epochNumbers.length; i++) {
            uint256 epoch = epochNumbers[i];
            uint256 amount = amounts[i];

            require(epoch > 0 && epoch <= currentEpoch, "Invalid epoch");
            require(!claimed[epoch][msg.sender], "Already claimed");

            Epoch storage epochData = epochs[epoch];
            require(block.timestamp >= epochData.startTime, "Not started");
            require(block.timestamp <= epochData.endTime, "Expired");

            bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
            require(
                MerkleProof.verify(merkleProofs[i], epochData.merkleRoot, leaf),
                "Invalid proof"
            );

            claimed[epoch][msg.sender] = true;
            epochData.claimedRewards += amount;
            totalAmount += amount;

            emit RewardClaimed(epoch, msg.sender, amount);
        }

        if (totalAmount > 0) {
            rewardToken.safeTransfer(msg.sender, totalAmount);
        }
    }

    /**
     * @dev Check if an account can claim for an epoch
     * @param epoch Epoch number
     * @param account Account address
     * @param amount Expected amount
     * @param merkleProof Merkle proof
     */
    function canClaim(
        uint256 epoch,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external view returns (bool) {
        if (epoch == 0 || epoch > currentEpoch) return false;
        if (claimed[epoch][account]) return false;

        Epoch memory epochData = epochs[epoch];
        if (block.timestamp < epochData.startTime) return false;
        if (block.timestamp > epochData.endTime) return false;

        bytes32 leaf = keccak256(abi.encodePacked(account, amount));
        return MerkleProof.verify(merkleProof, epochData.merkleRoot, leaf);
    }

    /**
     * @dev Recover unclaimed rewards after epoch ends
     * @param epoch Epoch number
     */
    function recoverUnclaimedRewards(uint256 epoch) external onlyOwner {
        require(epoch > 0 && epoch <= currentEpoch, "Invalid epoch");

        Epoch storage epochData = epochs[epoch];
        require(block.timestamp > epochData.endTime, "Epoch not ended");

        uint256 unclaimed = epochData.totalRewards - epochData.claimedRewards;
        if (unclaimed > 0) {
            epochData.claimedRewards = epochData.totalRewards;
            rewardToken.safeTransfer(owner(), unclaimed);
        }
    }

    /**
     * @dev Get epoch info
     * @param epoch Epoch number
     */
    function getEpochInfo(uint256 epoch) external view returns (
        bytes32 merkleRoot,
        uint256 totalRewards,
        uint256 claimedRewards,
        uint256 startTime,
        uint256 endTime,
        bool active
    ) {
        Epoch memory epochData = epochs[epoch];
        return (
            epochData.merkleRoot,
            epochData.totalRewards,
            epochData.claimedRewards,
            epochData.startTime,
            epochData.endTime,
            block.timestamp >= epochData.startTime && block.timestamp <= epochData.endTime
        );
    }
}
