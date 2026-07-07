// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "./ILPAdapter.sol";

/// @title IPositionManager
/// @notice Manages LP position deposits, withdrawals, and position state
interface IPositionManager {
    enum PositionStatus {
        Active, // LP deposited, no debt
        Borrowed, // LP deposited, has outstanding debt
        Closed, // User withdrew LP (debt fully repaid)
        Liquidated // Position was seized by liquidator
    }

    struct Position {
        uint256 id;
        address owner;
        address lpToken;
        uint256 tokenId; // 0 for ERC-20 LP tokens
        uint256 amount; // 0 for NFT positions
        ILPAdapter.LPType lpType;
        address pool;
        address token0;
        address token1;
        uint256 marketId;
        PositionStatus status;
        uint256 depositTimestamp;
        uint256 depositBlock; // Block number at deposit (for borrow cooldown)
    }

    event PositionCreated(
        uint256 indexed positionId,
        address indexed owner,
        address lpToken,
        uint256 tokenId,
        ILPAdapter.LPType lpType,
        uint256 value
    );

    event PositionClosed(uint256 indexed positionId, address indexed owner);

    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 debtRepaid);

    function deposit(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        uint256 marketId
    )
        external
        returns (uint256 positionId);

    function withdraw(uint256 positionId) external;

    /// @notice Add collateral to an existing position by providing underlying tokens
    /// @param positionId The position to add collateral to
    /// @param amount0 Amount of token0 to add
    /// @param amount1 Amount of token1 to add
    function addCollateral(uint256 positionId, uint256 amount0, uint256 amount1) external;

    function getPosition(uint256 positionId) external view returns (Position memory);

    function getPositionsByOwner(address owner) external view returns (uint256[] memory);

    function getPositionValue(uint256 positionId) external view returns (uint256);

    function getHealthFactor(uint256 positionId) external view returns (uint256);
}
