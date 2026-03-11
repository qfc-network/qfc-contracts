// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title SigmoidLib
 * @notice 8-segment piecewise linear approximation of sigmoid bonding curve pricing.
 *         P(s) = P_MAX / (1 + e^(-k * (s - S_MID)))
 *         Segments break at 0, 125M, 250M, 375M, 500M, 625M, 750M, 875M, 1B tokens.
 */
library SigmoidLib {
    /// @notice Maximum price at full supply (0.001 QFC in wei)
    uint256 internal constant P_MAX = 1e15;

    /// @notice Inflection point of the sigmoid (500M tokens with 18 decimals)
    uint256 internal constant S_MID = 500_000_000e18;

    /// @notice Total supply cap (1B tokens with 18 decimals)
    uint256 internal constant MAX_SUPPLY = 1_000_000_000e18;

    /// @notice Segment size (125M tokens with 18 decimals)
    uint256 internal constant SEGMENT_SIZE = 125_000_000e18;

    /// @notice Number of segments
    uint256 internal constant NUM_SEGMENTS = 8;

    // Pre-computed sigmoid prices at each breakpoint (in wei).
    // These approximate P_MAX / (1 + e^(-k*(s - S_MID))) with k chosen
    // so the curve transitions smoothly from ~0 to P_MAX over 1B supply.
    // Using k ≈ 1.2e-26 (scaled for 18-decimal supply):
    //   s=0:      ~18 (≈0)
    //   s=125M:   ~674
    //   s=250M:   ~17,986
    //   s=375M:   ~119,203
    //   s=500M:   ~500,000 (P_MAX/2)
    //   s=625M:   ~880,797
    //   s=750M:   ~982,014
    //   s=875M:   ~999,326
    //   s=1B:     ~999,982

    uint256 internal constant P0 = 18;          // price at s = 0
    uint256 internal constant P1 = 674;         // price at s = 125M
    uint256 internal constant P2 = 17_986;      // price at s = 250M
    uint256 internal constant P3 = 119_203;     // price at s = 375M
    uint256 internal constant P4 = 500_000;     // price at s = 500M (midpoint)
    uint256 internal constant P5 = 880_797;     // price at s = 625M
    uint256 internal constant P6 = 982_014;     // price at s = 750M
    uint256 internal constant P7 = 999_326;     // price at s = 875M
    uint256 internal constant P8 = 999_982;     // price at s = 1B

    /// @dev Scale factor used for the breakpoint price values above
    uint256 internal constant PRICE_SCALE = 1_000_000;

    error SupplyExceedsMax();
    error ZeroAmount();

    /**
     * @notice Get the price per token at a given supply level.
     * @param supply Current total supply of tokens (18 decimals)
     * @return price Price in wei per token (18 decimals)
     */
    function getPrice(uint256 supply) internal pure returns (uint256) {
        if (supply >= MAX_SUPPLY) revert SupplyExceedsMax();

        // Determine which segment we're in
        uint256 segIndex = supply / SEGMENT_SIZE;
        if (segIndex >= NUM_SEGMENTS) segIndex = NUM_SEGMENTS - 1;

        uint256 segStart = segIndex * SEGMENT_SIZE;
        uint256 offset = supply - segStart;

        (uint256 pStart, uint256 pEnd) = _getSegmentPrices(segIndex);

        // Linear interpolation: pStart + (pEnd - pStart) * offset / SEGMENT_SIZE
        // All arithmetic in scaled form, then convert to wei
        uint256 scaledPrice;
        if (pEnd >= pStart) {
            scaledPrice = pStart + ((pEnd - pStart) * offset) / SEGMENT_SIZE;
        } else {
            scaledPrice = pStart - ((pStart - pEnd) * offset) / SEGMENT_SIZE;
        }

        return (scaledPrice * P_MAX) / PRICE_SCALE;
    }

    /**
     * @notice Calculate the total QFC cost to buy `amount` tokens starting at `currentSupply`.
     * @dev Uses trapezoidal integration across segments.
     * @param currentSupply Current token supply
     * @param amount Number of tokens to buy
     * @return cost Total QFC cost in wei
     */
    function getCostForTokens(uint256 currentSupply, uint256 amount) internal pure returns (uint256) {
        if (amount == 0) revert ZeroAmount();
        if (currentSupply + amount > MAX_SUPPLY) revert SupplyExceedsMax();

        uint256 remaining = amount;
        uint256 supply = currentSupply;
        uint256 totalCost = 0;

        while (remaining > 0) {
            uint256 segIndex = supply / SEGMENT_SIZE;
            if (segIndex >= NUM_SEGMENTS) segIndex = NUM_SEGMENTS - 1;

            uint256 segEnd = (segIndex + 1) * SEGMENT_SIZE;
            if (segEnd > MAX_SUPPLY) segEnd = MAX_SUPPLY;

            uint256 chunk = segEnd - supply;
            if (chunk > remaining) chunk = remaining;

            // Trapezoidal: cost = (priceAtStart + priceAtEnd) / 2 * chunk
            uint256 priceStart = getPrice(supply);
            uint256 priceEnd = getPrice(supply + chunk - 1);

            // cost = (priceStart + priceEnd) * chunk / 2 / 1e18
            // We divide by 1e18 because both price and chunk are in wei/token-decimals
            totalCost += ((priceStart + priceEnd) * chunk) / (2 * 1e18);

            supply += chunk;
            remaining -= chunk;
        }

        return totalCost;
    }

    /**
     * @notice Calculate how many tokens can be purchased with `qfcAmount` QFC.
     * @dev Uses binary search over getCostForTokens.
     * @param currentSupply Current token supply
     * @param qfcAmount Amount of QFC in wei
     * @return tokens Number of tokens purchasable
     */
    function getTokensForQfc(uint256 currentSupply, uint256 qfcAmount) internal pure returns (uint256) {
        if (qfcAmount == 0) revert ZeroAmount();

        uint256 maxTokens = MAX_SUPPLY - currentSupply;
        if (maxTokens == 0) return 0;

        // Binary search
        uint256 low = 0;
        uint256 high = maxTokens;

        // Quick check: can we afford even 1 token unit?
        uint256 minCost = getCostForTokens(currentSupply, 1e18);
        if (qfcAmount < minCost) {
            // Return proportional fraction
            return (qfcAmount * 1e18) / minCost;
        }

        // Check if we can afford all remaining
        uint256 maxCost = getCostForTokens(currentSupply, maxTokens);
        if (qfcAmount >= maxCost) return maxTokens;

        // Use 1e18 as step for search (whole tokens)
        low = 1e18;
        high = maxTokens;

        while (high - low > 1e18) {
            uint256 mid = (low + high) / 2;
            // Round mid to nearest token
            mid = (mid / 1e18) * 1e18;
            if (mid == 0) mid = 1e18;

            uint256 cost = getCostForTokens(currentSupply, mid);
            if (cost <= qfcAmount) {
                low = mid;
            } else {
                high = mid;
            }
        }

        return low;
    }

    /**
     * @dev Returns the start and end prices (scaled) for a given segment index.
     */
    function _getSegmentPrices(uint256 segIndex) private pure returns (uint256 pStart, uint256 pEnd) {
        if (segIndex == 0) return (P0, P1);
        if (segIndex == 1) return (P1, P2);
        if (segIndex == 2) return (P2, P3);
        if (segIndex == 3) return (P3, P4);
        if (segIndex == 4) return (P4, P5);
        if (segIndex == 5) return (P5, P6);
        if (segIndex == 6) return (P6, P7);
        if (segIndex == 7) return (P7, P8);
        return (P7, P8); // fallback
    }
}
