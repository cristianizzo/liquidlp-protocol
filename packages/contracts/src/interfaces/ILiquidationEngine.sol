// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ILiquidationEngine
/// @notice Handles atomic liquidation of unhealthy positions
interface ILiquidationEngine {
    event LiquidationExecuted(
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 repayAmount,
        uint256 collateralSeized,
        uint256 liquidatorProfit
    );

    /// @notice Liquidate an unhealthy position
    /// @dev Atomically: seize LP → unwind → swap to borrow asset → repay debt → send profit
    /// @param positionId The position to liquidate
    /// @param repayAmount Amount of debt to repay
    /// @return profit The liquidator's profit in borrow asset
    function liquidate(uint256 positionId, uint256 repayAmount) external returns (uint256 profit);

    /// @notice Check if a position is liquidatable
    /// @param positionId The position to check
    /// @return liquidatable Whether the position can be liquidated
    /// @return maxRepay Maximum repayable amount
    function isLiquidatable(uint256 positionId) external view returns (bool liquidatable, uint256 maxRepay);

    /// @notice Get the liquidation bonus for a position's LP type
    /// @param positionId The position to check
    /// @return bonus Liquidation bonus in basis points
    function getLiquidationBonus(uint256 positionId) external view returns (uint256 bonus);
}
