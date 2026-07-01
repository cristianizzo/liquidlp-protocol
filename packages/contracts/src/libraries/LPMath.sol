// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LPMath
/// @notice Math utilities for LP position valuation
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
    /// @param reserve0 Reserve of token0
    /// @param reserve1 Reserve of token1
    /// @param totalSupply Total LP token supply
    /// @param price0 Chainlink price of token0 (18 decimals)
    /// @param price1 Chainlink price of token1 (18 decimals)
    /// @param amount Amount of LP tokens to price
    /// @return value Fair value in USD (18 decimals)
    function fairLPValueV2(
        uint256 reserve0,
        uint256 reserve1,
        uint256 totalSupply,
        uint256 price0,
        uint256 price1,
        uint256 amount
    ) internal pure returns (uint256 value) {
        // Fair value = 2 * sqrt(k * price0 * price1) / totalSupply * amount
        // k = reserve0 * reserve1
        uint256 sqrtK = sqrt(reserve0 * reserve1);
        uint256 sqrtP = sqrt(price0 * price1);
        value = (2 * sqrtK * sqrtP * amount) / (totalSupply * 1e18);
    }

    /// @notice Apply haircut (safety discount) to a value
    /// @param value Original value
    /// @param haircutBps Haircut in basis points
    /// @return Discounted value
    function applyHaircut(uint256 value, uint256 haircutBps) internal pure returns (uint256) {
        return (value * (10_000 - haircutBps)) / 10_000;
    }

    /// @notice Calculate absolute deviation between two values in basis points
    function deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 10_000;
        uint256 diff = a > b ? a - b : b - a;
        return (diff * 10_000) / a;
    }
}
