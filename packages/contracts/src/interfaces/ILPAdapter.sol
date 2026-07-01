// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ILPAdapter
/// @notice Common interface for all DEX LP adapters
/// @dev Each adapter handles deposit/withdraw/unwinding for a specific DEX
interface ILPAdapter {
    enum LPType {
        UniswapV2,
        UniswapV3,
        Curve,
        Aerodrome,
        PancakeSwapV2,
        PancakeSwapV3
    }

    struct LPInfo {
        LPType lpType;
        address token0;
        address token1;
        uint24 feeTier;
        int24 tickLower; // V3 only
        int24 tickUpper; // V3 only
        uint128 liquidity;
        address pool;
    }

    /// @notice Validate and lock an LP position into the protocol
    /// @param lpToken Address of LP token (ERC-20) or NFT manager (ERC-721)
    /// @param tokenId NFT token ID (0 for ERC-20 LP tokens)
    /// @param amount Amount of LP tokens (0 for NFT positions)
    /// @param from Owner of the LP position
    /// @return info Parsed LP position information
    function validateAndLock(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        address from
    )
        external
        returns (LPInfo memory info);

    /// @notice Unlock and return LP position to owner
    /// @param lpToken Address of LP token or NFT manager
    /// @param tokenId NFT token ID (0 for ERC-20)
    /// @param amount Amount to return (0 for NFT)
    /// @param to Recipient address
    function unlock(address lpToken, uint256 tokenId, uint256 amount, address to) external;

    /// @notice Atomically unwind LP position into underlying tokens
    /// @param lpToken Address of LP token or NFT manager
    /// @param tokenId NFT token ID (0 for ERC-20)
    /// @param liquidityToRemove Amount of liquidity to remove
    /// @return amount0 Amount of token0 received
    /// @return amount1 Amount of token1 received
    function unwind(
        address lpToken,
        uint256 tokenId,
        uint128 liquidityToRemove
    )
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Collect accumulated trading fees from LP position
    /// @param lpToken Address of LP token or NFT manager
    /// @param tokenId NFT token ID
    /// @return fees0 Fees collected in token0
    /// @return fees1 Fees collected in token1
    function collectFees(address lpToken, uint256 tokenId) external returns (uint256 fees0, uint256 fees1);

    /// @notice Get the LP type this adapter handles
    function lpType() external view returns (LPType);

    /// @notice Check if this adapter supports a given LP token/pool
    function isSupported(address lpToken) external view returns (bool);
}
