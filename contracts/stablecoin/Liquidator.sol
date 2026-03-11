// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./CDPVault.sol";

/**
 * @title Liquidator
 * @notice Helper contract to batch-check which positions are liquidatable.
 */
contract Liquidator {
    CDPVault public immutable vault;

    constructor(address _vault) {
        vault = CDPVault(payable(_vault));
    }

    /**
     * @notice Check which users from a list are eligible for liquidation
     * @param users Array of addresses to check
     * @return liquidatable Array of addresses that can be liquidated
     * @return ratios Array of corresponding collateral ratios
     */
    function checkLiquidatable(address[] calldata users)
        external
        view
        returns (address[] memory liquidatable, uint256[] memory ratios)
    {
        uint256 count = 0;
        uint256[] memory tempRatios = new uint256[](users.length);
        bool[] memory isLiquidatable = new bool[](users.length);

        for (uint256 i = 0; i < users.length; i++) {
            uint256 ratio = vault.getCollateralRatio(users[i]);
            if (ratio < vault.LIQUIDATION_THRESHOLD()) {
                isLiquidatable[i] = true;
                tempRatios[i] = ratio;
                count++;
            }
        }

        liquidatable = new address[](count);
        ratios = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < users.length; i++) {
            if (isLiquidatable[i]) {
                liquidatable[idx] = users[i];
                ratios[idx] = tempRatios[i];
                idx++;
            }
        }
    }
}
