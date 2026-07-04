// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LPMath
/// @notice Math utilities for LP position valuation
/// @dev Uses OZ Math.mulDiv for overflow-safe full-precision multiplication.
///      All prices are 18-decimal USD. Reserves are in native token decimals.
library LPMath {
    /// @notice Babylonian square root
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Calculate fair value of V2 LP token using sqrt(k) method
    /// @dev Formula: value = 2 * sqrt(reserve0 * reserve1) * sqrt(price0 * price1) * amount / (totalSupply * 1e18)
    ///      Uses mulDiv to prevent overflow on reserve0 * reserve1 and price0 * price1.
    /// @param reserve0 Reserve of token0 (native decimals)
    /// @param reserve1 Reserve of token1 (native decimals)
    /// @param totalSupply Total LP token supply
    /// @param price0 Chainlink price of token0 (18 decimals USD)
    /// @param price1 Chainlink price of token1 (18 decimals USD)
    /// @param amount Amount of LP tokens to price
    /// @return value Fair value in USD (18 decimals)
    function fairLPValueV2(
        uint256 reserve0,
        uint256 reserve1,
        uint256 totalSupply,
        uint256 price0,
        uint256 price1,
        uint256 amount
    )
        internal
        pure
        returns (uint256 value)
    {
        require(totalSupply > 0, "ZERO_TOTAL_SUPPLY");

        // sqrt(k) = sqrt(reserve0 * reserve1) — use mulDiv to prevent overflow
        uint256 k = Math.mulDiv(reserve0, reserve1, 1);
        uint256 sqrtK = sqrt(k);

        // sqrt(price0 * price1) — use mulDiv to prevent overflow
        uint256 pp = Math.mulDiv(price0, price1, 1);
        uint256 sqrtP = sqrt(pp);

        // value = 2 * sqrtK * sqrtP * amount / (totalSupply * 1e18)
        // Split into two mulDiv calls to prevent overflow on the numerator
        uint256 numerator = Math.mulDiv(2 * sqrtK, sqrtP, 1);
        value = Math.mulDiv(numerator, amount, totalSupply * 1e18);
    }

    /// @notice Apply haircut (safety discount) to a value
    /// @param value Original value
    /// @param haircutBps Haircut in basis points (max 10_000)
    /// @return Discounted value
    function applyHaircut(uint256 value, uint256 haircutBps) internal pure returns (uint256) {
        require(haircutBps <= 10_000, "HAIRCUT_TOO_LARGE");
        return Math.mulDiv(value, 10_000 - haircutBps, 10_000);
    }

    /// @notice Calculate absolute deviation between two values in basis points
    /// @dev Anchored to first parameter (a): deviation = |a - b| / a * 10000
    ///      Returns 10_000 (100%) if either value is 0.
    function deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 10_000;
        uint256 diff = a > b ? a - b : b - a;
        return Math.mulDiv(diff, 10_000, a);
    }
}
