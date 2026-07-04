// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {IUniswapV2Pair, IUniswapV2Factory, IUniswapV2Router} from "../interfaces/external/IUniswapV2.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title UniswapV2Adapter
/// @notice Handles Uniswap V2 ERC-20 LP token deposits, withdrawals, and unwinding
/// @dev V2 LP tokens are fungible ERC-20s. Key differences from V3:
///      - No tick ranges — full price range
///      - Fees auto-compound into reserves (no separate collectFees)
///      - LP token amount IS the liquidity
///      - removeLiquidity via V2 Router
contract UniswapV2Adapter is ILPAdapter {
    IUniswapV2Factory public immutable v2Factory;
    IUniswapV2Router public immutable v2Router;
    ProtocolCore public immutable core;

    // --- Events ---
    event PositionLocked(address indexed pair, address indexed from, uint256 amount);
    event PositionUnlocked(address indexed pair, address indexed to, uint256 amount);
    event LiquidityUnwound(address indexed pair, uint256 liquidityRemoved, uint256 amount0, uint256 amount1);

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyProtocol() {
        ACLManager acl = _acl();
        require(acl.isPositionManager(msg.sender) || acl.isLiquidationEngine(msg.sender), "NOT_AUTHORIZED");
        _;
    }

    constructor(address _factory, address _router, address _core) {
        require(_factory != address(0) && _router != address(0) && _core != address(0), "ZERO_ADDRESS");
        v2Factory = IUniswapV2Factory(_factory);
        v2Router = IUniswapV2Router(_router);
        core = ProtocolCore(_core);
    }

    // --- ILPAdapter ---

    /// @inheritdoc ILPAdapter
    function validateAndLock(
        address lpToken,
        uint256, /* tokenId */
        uint256 amount,
        address from
    )
        external
        onlyProtocol
        returns (LPInfo memory info)
    {
        require(amount > 0, "ZERO_AMOUNT");
        require(amount <= type(uint128).max, "AMOUNT_OVERFLOW");
        require(from != address(0), "ZERO_FROM");

        // Verify this is a valid V2 pair from our factory (validate before interacting)
        require(lpToken.code.length > 0, "NOT_CONTRACT");
        IUniswapV2Pair pair = IUniswapV2Pair(lpToken);
        require(pair.factory() == address(v2Factory), "NOT_OUR_FACTORY");
        address token0 = pair.token0();
        address token1 = pair.token1();
        require(v2Factory.getPair(token0, token1) == lpToken, "INVALID_PAIR");

        // Transfer LP tokens from user to adapter
        require(pair.transferFrom(from, address(this), amount), "TRANSFER_FAILED");

        info = LPInfo({
            lpType: LPType.UniswapV2,
            token0: token0,
            token1: token1,
            feeTier: 3000, // V2 always 0.3%
            tickLower: 0,
            tickUpper: 0,
            liquidity: uint128(amount),
            pool: lpToken
        });

        emit PositionLocked(lpToken, from, amount);
    }

    /// @inheritdoc ILPAdapter
    function unlock(
        address lpToken,
        uint256, /* tokenId */
        uint256 amount,
        address to
    )
        external
        onlyProtocol
    {
        require(to != address(0), "ZERO_RECIPIENT");
        require(to != address(this), "CANNOT_UNLOCK_TO_SELF");
        require(amount > 0, "ZERO_AMOUNT");

        require(IUniswapV2Pair(lpToken).transfer(to, amount), "TRANSFER_FAILED");

        emit PositionUnlocked(lpToken, to, amount);
    }

    /// @inheritdoc ILPAdapter
    /// @dev Approves router, calls removeLiquidity. Tokens sent to msg.sender.
    ///      Slippage is 0 — handled at LiquidationEngine level.
    function unwind(
        address lpToken,
        uint256, /* tokenId */
        uint128 liquidityToRemove
    )
        external
        onlyProtocol
        returns (uint256 amount0, uint256 amount1)
    {
        require(liquidityToRemove > 0, "ZERO_LIQUIDITY");

        // Validate pair before interacting
        require(lpToken.code.length > 0, "NOT_CONTRACT");
        IUniswapV2Pair pair = IUniswapV2Pair(lpToken);
        require(pair.factory() == address(v2Factory), "NOT_OUR_FACTORY");
        address token0 = pair.token0();
        address token1 = pair.token1();

        // Safe approval: reset to 0 first (USDT-style compatibility)
        pair.approve(address(v2Router), 0);
        require(pair.approve(address(v2Router), uint256(liquidityToRemove)), "APPROVE_FAILED");

        // Remove liquidity — tokens to caller
        (amount0, amount1) = v2Router.removeLiquidity(
            token0,
            token1,
            uint256(liquidityToRemove),
            0,
            0, // slippage handled by LiquidationEngine
            msg.sender,
            block.timestamp
        );

        emit LiquidityUnwound(lpToken, uint256(liquidityToRemove), amount0, amount1);
    }

    /// @inheritdoc ILPAdapter
    /// @dev V2 fees auto-compound into reserves. No separate collection needed.
    function collectFees(address, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    /// @inheritdoc ILPAdapter
    function lpType() external pure returns (LPType) {
        return LPType.UniswapV2;
    }

    /// @inheritdoc ILPAdapter
    /// @dev Checks if address is a contract AND is a V2 pair from our factory
    function isSupported(address lpToken) external view returns (bool) {
        if (lpToken == address(0)) return false;
        uint256 size;
        assembly { size := extcodesize(lpToken) }
        if (size == 0) return false;

        try IUniswapV2Pair(lpToken).factory() returns (address f) {
            return f == address(v2Factory);
        } catch {
            return false;
        }
    }
}
