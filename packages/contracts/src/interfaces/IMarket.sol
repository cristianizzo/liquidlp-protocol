// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "./ILPAdapter.sol";

/// @title IMarket
/// @notice Isolated lending market for a specific LP type
interface IMarket {
    struct MarketConfig {
        ILPAdapter.LPType lpType;
        address borrowAsset; // USDC, USDT, etc.
        uint256 maxLtv; // Maximum LTV in basis points (e.g., 6500 = 65%)
        uint256 liquidationThreshold; // Liquidation trigger in bps
        uint256 liquidationBonus; // Bonus for liquidators in bps
        uint256 borrowCap; // Max total borrows
        uint256 minPoolTvl; // Min underlying pool TVL required
        uint256 minPoolAge; // Min pool age in seconds
    }

    struct MarketState {
        uint256 totalSupply; // Total lender deposits
        uint256 totalBorrow; // Total outstanding borrows
        uint256 supplyRate; // Current supply APY (ray)
        uint256 borrowRate; // Current borrow APY (ray)
        uint256 utilization; // Current utilization (bps)
        uint256 lastAccrualTimestamp;
    }

    event Supply(address indexed supplier, uint256 amount, uint256 shares);
    event Withdraw(address indexed supplier, uint256 amount, uint256 shares);

    /// @notice Supply lending assets to the market
    /// @param amount Amount of borrow asset to supply
    /// @return shares Share tokens received
    function supply(uint256 amount) external returns (uint256 shares);

    /// @notice Withdraw lending assets from the market
    /// @param shares Amount of share tokens to redeem
    /// @return amount Borrow asset received
    function withdraw(uint256 shares) external returns (uint256 amount);

    /// @notice Get current market state
    function getMarketState() external view returns (MarketState memory);

    /// @notice Get market configuration
    function getConfig() external view returns (MarketConfig memory);
}
