// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {INonfungiblePositionManager, IUniswapV3Factory} from "../interfaces/external/IUniswapV3.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title UniswapV3Adapter
/// @notice Handles Uniswap V3 NFT position deposits, withdrawals, and unwinding
/// @dev Real implementation — interacts with Uniswap V3 NonfungiblePositionManager.
///      Uses ProtocolCore for ownership. Protocol address updatable if PositionManager migrates.
///
///      Design notes:
///      - unwind() collects decreased liquidity + accumulated fees together (intentional).
///        Fees are part of collateral value in the oracle, so they should be seized during liquidation.
///      - collectFees() calls decreaseLiquidity(1 wei) to trigger fee accounting update,
///        then collects all owed tokens. The 1 wei of liquidity loss is negligible.
///      - amount0Min/amount1Min are 0 in decreaseLiquidity because slippage protection is
///        handled at the LiquidationEngine level via oracle-based post-swap validation.
contract UniswapV3Adapter is ILPAdapter {
    INonfungiblePositionManager public immutable nftManager;
    IUniswapV3Factory public immutable v3Factory;
    ProtocolCore public immutable core;

    // --- Events ---
    event PositionLocked(uint256 indexed tokenId, address indexed from, address pool, uint128 liquidity);
    event PositionUnlocked(uint256 indexed tokenId, address indexed to);
    event LiquidityUnwound(uint256 indexed tokenId, uint128 liquidityRemoved, uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 indexed tokenId, uint256 fees0, uint256 fees1);

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    /// @dev Authorized = PositionManager or LiquidationEngine
    modifier onlyProtocol() {
        ACLManager acl = _acl();
        require(acl.isPositionManager(msg.sender) || acl.isLiquidationEngine(msg.sender), "NOT_AUTHORIZED");
        _;
    }

    constructor(address _nftManager, address _factory, address _core) {
        require(_nftManager != address(0) && _factory != address(0) && _core != address(0), "ZERO_ADDRESS");
        nftManager = INonfungiblePositionManager(_nftManager);
        v3Factory = IUniswapV3Factory(_factory);
        core = ProtocolCore(_core);
    }

    // --- ILPAdapter Implementation ---

    /// @inheritdoc ILPAdapter
    function validateAndLock(
        address lpToken,
        uint256 tokenId,
        uint256, /* amount */
        address from
    )
        external
        onlyProtocol
        returns (LPInfo memory info)
    {
        require(lpToken == address(nftManager), "NOT_UNISWAP_V3");
        require(from != address(0), "ZERO_FROM");

        // Read position data
        (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            nftManager.positions(tokenId);

        require(liquidity > 0, "NO_LIQUIDITY");

        // Transfer NFT from user to adapter
        nftManager.transferFrom(from, address(this), tokenId);
        require(nftManager.ownerOf(tokenId) == address(this), "TRANSFER_FAILED");

        // Get pool address
        address pool = v3Factory.getPool(token0, token1, fee);
        require(pool != address(0), "POOL_NOT_FOUND");

        info = LPInfo({
            lpType: LPType.UniswapV3,
            token0: token0,
            token1: token1,
            feeTier: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            pool: pool
        });

        emit PositionLocked(tokenId, from, pool, liquidity);
    }

    /// @inheritdoc ILPAdapter
    function unlock(
        address lpToken,
        uint256 tokenId,
        uint256, /* amount */
        address to
    )
        external
        onlyProtocol
    {
        require(lpToken == address(nftManager), "NOT_UNISWAP_V3");
        require(to != address(0), "ZERO_RECIPIENT");
        require(to != address(this), "CANNOT_UNLOCK_TO_SELF");
        require(nftManager.ownerOf(tokenId) == address(this), "NOT_HELD");

        nftManager.transferFrom(address(this), to, tokenId);

        emit PositionUnlocked(tokenId, to);
    }

    /// @inheritdoc ILPAdapter
    /// @dev Decreases liquidity, then collects all available tokens (decreased + fees).
    ///      Fees are intentionally included — they're part of collateral value in the oracle.
    ///      Slippage on decreaseLiquidity is 0 because protection is at the LiquidationEngine
    ///      level via oracle-based post-swap validation (SWAP_SLIPPAGE_EXCEEDED check).
    function unwind(
        address lpToken,
        uint256 tokenId,
        uint128 liquidityToRemove
    )
        external
        onlyProtocol
        returns (uint256 amount0, uint256 amount1)
    {
        require(lpToken == address(nftManager), "NOT_UNISWAP_V3");
        require(liquidityToRemove > 0, "ZERO_LIQUIDITY");
        require(nftManager.ownerOf(tokenId) == address(this), "NOT_HELD");

        // Decrease liquidity — amount0Min/amount1Min intentionally 0.
        // Slippage protection is handled by LiquidationEngine which validates
        // total output value against oracle price after the swap step (Aave pattern).
        // Adding min amounts here would be redundant and could cause liquidations
        // to revert during high volatility — exactly when they're needed most.
        nftManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidityToRemove, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );

        // Collect all (decreased liquidity + fees)
        (amount0, amount1) = nftManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: msg.sender, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );

        emit LiquidityUnwound(tokenId, liquidityToRemove, amount0, amount1);
    }

    /// @inheritdoc ILPAdapter
    /// @dev Collects accumulated trading fees without meaningfully removing liquidity.
    ///      Calls decreaseLiquidity(1) to trigger fee accounting update in the pool
    ///      (Uniswap V3 requires a burn to sync tokensOwed with feeGrowthInside).
    ///      The 1 wei of liquidity removed is negligible.
    function collectFees(address lpToken, uint256 tokenId)
        external
        onlyProtocol
        returns (uint256 fees0, uint256 fees1)
    {
        require(lpToken == address(nftManager), "NOT_UNISWAP_V3");
        require(nftManager.ownerOf(tokenId) == address(this), "NOT_HELD");

        // Check if position has liquidity (can't decrease if already 0)
        (,,,,,,, uint128 currentLiquidity,,,,) = nftManager.positions(tokenId);

        if (currentLiquidity > 1) {
            // Burn 1 wei of liquidity to trigger fee accounting sync (skip if only 1 left)
            nftManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: 1, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                })
            );
        }

        // Collect all owed tokens (fees + the 1 wei of liquidity)
        (fees0, fees1) = nftManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: msg.sender, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );

        emit FeesCollected(tokenId, fees0, fees1);
    }

    /// @inheritdoc ILPAdapter
    function lpType() external pure returns (LPType) {
        return LPType.UniswapV3;
    }

    /// @inheritdoc ILPAdapter
    function isSupported(address lpToken) external view returns (bool) {
        return lpToken == address(nftManager);
    }

    /// @notice ERC721 receiver hook — restricts safeTransferFrom to prevent stuck NFTs
    /// @dev validateAndLock uses transferFrom (not safeTransferFrom) so this hook only fires
    ///      if someone calls safeTransferFrom directly. Restricted to V3 NFT manager only,
    ///      initiated by this adapter or the protocol contract.
    function onERC721Received(address operator, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(nftManager), "ONLY_V3_NFT");
        require(
            operator == address(this) || _acl().isPositionManager(operator) || _acl().isLiquidationEngine(operator),
            "UNEXPECTED_OPERATOR"
        );
        return this.onERC721Received.selector;
    }
}
