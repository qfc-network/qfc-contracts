// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ModelRegistry
 * @notice Catalog of supported AI models with pricing, hardware requirements,
 *         and approval status. Only approved models can be used in TaskRegistry.
 */
contract ModelRegistry is Ownable {
    struct Model {
        string modelId;       // e.g. "llama-3-70b"
        string name;          // human-readable name
        uint256 baseFee;      // minimum fee per task (wei)
        uint8 minTier;        // minimum miner tier required (1-3)
        bool approved;
        uint256 registeredAt;
    }

    /// @dev modelId hash => Model
    mapping(bytes32 => Model) private _models;
    /// @dev ordered list of model id hashes
    bytes32[] private _modelIds;

    event ModelRegistered(string indexed modelId, string name, uint256 baseFee, uint8 minTier);
    event ModelApproved(string indexed modelId);
    event ModelRevoked(string indexed modelId);
    event ModelFeeUpdated(string indexed modelId, uint256 newBaseFee);

    error ModelAlreadyExists(string modelId);
    error ModelNotFound(string modelId);
    error InvalidTier(uint8 tier);
    error InvalidFee();

    constructor() Ownable(msg.sender) {}

    /// @notice Register a new AI model in the catalog
    /// @param modelId Unique model identifier
    /// @param name Human-readable name
    /// @param baseFee Minimum fee per task in wei
    /// @param minTier Minimum miner tier required (1-3)
    function registerModel(
        string calldata modelId,
        string calldata name,
        uint256 baseFee,
        uint8 minTier
    ) external onlyOwner {
        if (minTier == 0 || minTier > 3) revert InvalidTier(minTier);
        if (baseFee == 0) revert InvalidFee();

        bytes32 key = keccak256(bytes(modelId));
        if (_models[key].registeredAt != 0) revert ModelAlreadyExists(modelId);

        _models[key] = Model({
            modelId: modelId,
            name: name,
            baseFee: baseFee,
            minTier: minTier,
            approved: true,
            registeredAt: block.timestamp
        });
        _modelIds.push(key);

        emit ModelRegistered(modelId, name, baseFee, minTier);
        emit ModelApproved(modelId);
    }

    /// @notice Approve a previously revoked model
    function approveModel(string calldata modelId) external onlyOwner {
        bytes32 key = keccak256(bytes(modelId));
        if (_models[key].registeredAt == 0) revert ModelNotFound(modelId);
        _models[key].approved = true;
        emit ModelApproved(modelId);
    }

    /// @notice Revoke approval for a model
    function revokeModel(string calldata modelId) external onlyOwner {
        bytes32 key = keccak256(bytes(modelId));
        if (_models[key].registeredAt == 0) revert ModelNotFound(modelId);
        _models[key].approved = false;
        emit ModelRevoked(modelId);
    }

    /// @notice Update the base fee for a model
    function updateBaseFee(string calldata modelId, uint256 newBaseFee) external onlyOwner {
        if (newBaseFee == 0) revert InvalidFee();
        bytes32 key = keccak256(bytes(modelId));
        if (_models[key].registeredAt == 0) revert ModelNotFound(modelId);
        _models[key].baseFee = newBaseFee;
        emit ModelFeeUpdated(modelId, newBaseFee);
    }

    /// @notice Check if a model is approved
    function isApproved(string calldata modelId) external view returns (bool) {
        return _models[keccak256(bytes(modelId))].approved;
    }

    /// @notice Get model details
    function getModel(string calldata modelId) external view returns (Model memory) {
        bytes32 key = keccak256(bytes(modelId));
        if (_models[key].registeredAt == 0) revert ModelNotFound(modelId);
        return _models[key];
    }

    /// @notice Get the base fee for a model
    function getBaseFee(string calldata modelId) external view returns (uint256) {
        bytes32 key = keccak256(bytes(modelId));
        if (_models[key].registeredAt == 0) revert ModelNotFound(modelId);
        return _models[key].baseFee;
    }

    /// @notice Get the minimum miner tier for a model
    function getMinTier(string calldata modelId) external view returns (uint8) {
        bytes32 key = keccak256(bytes(modelId));
        if (_models[key].registeredAt == 0) revert ModelNotFound(modelId);
        return _models[key].minTier;
    }

    /// @notice Total registered models
    function modelCount() external view returns (uint256) {
        return _modelIds.length;
    }

    /// @notice Get model by index (for enumeration)
    function modelAtIndex(uint256 index) external view returns (Model memory) {
        return _models[_modelIds[index]];
    }
}
