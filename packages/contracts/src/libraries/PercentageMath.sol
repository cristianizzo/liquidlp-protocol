// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PercentageMath
/// @notice Overflow-safe percentage math using basis points (BPS = 10_000)
/// @dev Uses OZ Math.mulDiv for full-precision 512-bit intermediate multiplication.
///      Prevents overflow reverts on large values that the old raw multiplication caused.
library PercentageMath {
    uint256 internal constant BPS = 10_000;

    /// @notice Calculate percentage of a value: result = value * bps / 10000
    /// @param value The base value
    /// @param bps Percentage in basis points
    function percentMul(uint256 value, uint256 bps) internal pure returns (uint256) {
        if (value == 0 || bps == 0) return 0;
        return Math.mulDiv(value, bps, BPS);
    }

    /// @notice Divide by a percentage: result = value * 10000 / bps
    /// @param value The base value
    /// @param bps Percentage in basis points (must be > 0)
    function percentDiv(uint256 value, uint256 bps) internal pure returns (uint256) {
        require(bps > 0, "DIV_BY_ZERO");
        return Math.mulDiv(value, BPS, bps);
    }
}
