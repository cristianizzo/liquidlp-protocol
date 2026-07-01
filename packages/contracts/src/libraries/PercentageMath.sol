// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PercentageMath
/// @notice Safe percentage math operations using basis points
library PercentageMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant HALF_BPS = 5000;

    /// @notice Calculate percentage of a value
    /// @param value The base value
    /// @param bps Percentage in basis points
    /// @return result = value * bps / 10000
    function percentMul(uint256 value, uint256 bps) internal pure returns (uint256) {
        if (value == 0 || bps == 0) return 0;
        return (value * bps + HALF_BPS) / BPS;
    }

    /// @notice Divide by a percentage
    /// @param value The base value
    /// @param bps Percentage in basis points
    /// @return result = value * 10000 / bps
    function percentDiv(uint256 value, uint256 bps) internal pure returns (uint256) {
        require(bps > 0, "DIV_BY_ZERO");
        return (value * BPS + bps / 2) / bps;
    }
}
