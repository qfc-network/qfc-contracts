// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ModelRegistry
 * @notice Registry for AI models available on the QFC Inference Marketplace.
 * @dev Owner registers models with tier requirements and base fees.
 *      Tiers: 1 = small (<7B), 2 = medium (7B-30B), 3 = large (30B+).
 */
contract ModelRegistry is Ownable {
    struct Model {
        string name;
        uint8 minTier;
        uint256 baseFee;
        bool active;
    }

    /// @notice Model ID => Model info
    mapping(bytes32 => Model) private _models;

    /// @notice All registered model IDs
    bytes32[] public modelIds;

    event ModelRegistered(bytes32 indexed modelId, string name, uint8 minTier, uint256 baseFee);
    event ModelActiveChanged(bytes32 indexed modelId, bool active);

    error ModelAlreadyExists(bytes32 modelId);
    error ModelNotFound(bytes32 modelId);
    error InvalidTier(uint8 tier);
    error InvalidBaseFee();

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Register a new AI model.
     * @param modelId Unique identifier for the model.
     * @param name Human-readable model name.
     * @param minTier Minimum miner tier required (1-3).
     * @param baseFee Base fee in native token (wei).
     */
    function registerModel(
        bytes32 modelId,
        string calldata name,
        uint8 minTier,
        uint256 baseFee
    ) external onlyOwner {
        if (bytes(_models[modelId].name).length != 0) revert ModelAlreadyExists(modelId);
        if (minTier == 0 || minTier > 3) revert InvalidTier(minTier);
        if (baseFee == 0) revert InvalidBaseFee();

        _models[modelId] = Model({
            name: name,
            minTier: minTier,
            baseFee: baseFee,
            active: true
        });
        modelIds.push(modelId);

        emit ModelRegistered(modelId, name, minTier, baseFee);
    }

    /**
     * @notice Activate or deactivate a model.
     * @param modelId The model to update.
     * @param active Whether the model should be active.
     */
    function setModelActive(bytes32 modelId, bool active) external onlyOwner {
        if (bytes(_models[modelId].name).length == 0) revert ModelNotFound(modelId);
        _models[modelId].active = active;
        emit ModelActiveChanged(modelId, active);
    }

    /**
     * @notice Get model details.
     * @param modelId The model identifier.
     * @return model The Model struct.
     */
    function getModel(bytes32 modelId) external view returns (Model memory model) {
        if (bytes(_models[modelId].name).length == 0) revert ModelNotFound(modelId);
        return _models[modelId];
    }

    /**
     * @notice Get the number of registered models.
     * @return count Total model count.
     */
    function getModelCount() external view returns (uint256 count) {
        return modelIds.length;
    }
}
