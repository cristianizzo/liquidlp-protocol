// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";

/// @title UniswapV3Adapter
/// @notice Handles Uniswap V3 NFT position deposits, withdrawals, and unwinding
contract UniswapV3Adapter is ILPAdapter {
    // Uniswap V3 contracts (set per chain in constructor)
    address public immutable nftManager; // INonfungiblePositionManager
    address public immutable factory; // IUniswapV3Factory

    address public protocol; // Only LiquidLP protocol can call

    modifier onlyProtocol() {
        require(msg.sender == protocol, "NOT_PROTOCOL");
        _;
    }

    constructor(address _nftManager, address _factory, address _protocol) {
        nftManager = _nftManager;
        factory = _factory;
        protocol = _protocol;
    }

    /// @inheritdoc ILPAdapter
    function validateAndLock(
        address lpToken,
        uint256 tokenId,
        uint256, /* amount — unused for NFTs */
        address from
    )
        external
        onlyProtocol
        returns (LPInfo memory info)
    {
        require(lpToken == nftManager, "NOT_UNISWAP_V3");

        // Get position data from NFT manager
        // (,, token0, token1, fee, tickLower, tickUpper, liquidity,,,,)
        //     = INonfungiblePositionManager(nftManager).positions(tokenId);

        // Verify position has liquidity
        // require(liquidity > 0, "NO_LIQUIDITY");

        // Transfer NFT from user to this contract
        // IERC721(nftManager).transferFrom(from, address(this), tokenId);

        // Get pool address
        // address pool = IUniswapV3Factory(factory).getPool(token0, token1, fee);

        // info = LPInfo({
        //     lpType: LPType.UniswapV3,
        //     token0: token0,
        //     token1: token1,
        //     feeTier: fee,
        //     tickLower: tickLower,
        //     tickUpper: tickUpper,
        //     liquidity: liquidity,
        //     pool: pool
        // });
    }

    /// @inheritdoc ILPAdapter
    function unlock(
        address, /* lpToken */
        uint256 tokenId,
        uint256, /* amount — unused for NFTs */
        address to
    )
        external
        onlyProtocol
    {
        // Transfer NFT back to user
        // IERC721(nftManager).transferFrom(address(this), to, tokenId);
    }

    /// @inheritdoc ILPAdapter
    function unwind(
        address, /* lpToken */
        uint256 tokenId,
        uint128 liquidityToRemove
    )
        external
        onlyProtocol
        returns (uint256 amount0, uint256 amount1)
    {
        // Step 1: Decrease liquidity
        // INonfungiblePositionManager(nftManager).decreaseLiquidity(
        //     INonfungiblePositionManager.DecreaseLiquidityParams({
        //         tokenId: tokenId,
        //         liquidity: liquidityToRemove,
        //         amount0Min: 0,
        //         amount1Min: 0,
        //         deadline: block.timestamp
        //     })
        // );

        // Step 2: Collect tokens
        // (amount0, amount1) = INonfungiblePositionManager(nftManager).collect(
        //     INonfungiblePositionManager.CollectParams({
        //         tokenId: tokenId,
        //         recipient: msg.sender,
        //         amount0Max: type(uint128).max,
        //         amount1Max: type(uint128).max
        //     })
        // );
    }

    /// @inheritdoc ILPAdapter
    function collectFees(
        address, /* lpToken */
        uint256 tokenId
    )
        external
        onlyProtocol
        returns (uint256 fees0, uint256 fees1)
    {
        // Collect without decreasing liquidity (fees only)
        // First decrease 0 liquidity to update fee tracking
        // INonfungiblePositionManager(nftManager).decreaseLiquidity(
        //     DecreaseLiquidityParams(tokenId, 0, 0, 0, block.timestamp)
        // );
        // Then collect
        // (fees0, fees1) = INonfungiblePositionManager(nftManager).collect(...)
    }

    /// @inheritdoc ILPAdapter
    function lpType() external pure returns (LPType) {
        return LPType.UniswapV3;
    }

    /// @inheritdoc ILPAdapter
    function isSupported(address lpToken) external view returns (bool) {
        return lpToken == nftManager;
    }
}
