// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";

/// @title UniswapV2Adapter
/// @notice Handles Uniswap V2 LP token deposits, withdrawals, and unwinding
contract UniswapV2Adapter is ILPAdapter {
    address public immutable factory; // IUniswapV2Factory
    address public immutable router; // IUniswapV2Router02
    address public protocol;

    // Track locked LP tokens per position
    mapping(address => mapping(address => uint256)) public lockedBalances; // pair → user → amount

    modifier onlyProtocol() {
        require(msg.sender == protocol, "NOT_PROTOCOL");
        _;
    }

    constructor(address _factory, address _router, address _protocol) {
        factory = _factory;
        router = _router;
        protocol = _protocol;
    }

    /// @inheritdoc ILPAdapter
    function validateAndLock(
        address lpToken,
        uint256, /* tokenId — unused for ERC-20 */
        uint256 amount,
        address from
    )
        external
        onlyProtocol
        returns (LPInfo memory info)
    {
        require(amount > 0, "ZERO_AMOUNT");

        // Verify this is a valid Uniswap V2 pair
        // address token0 = IUniswapV2Pair(lpToken).token0();
        // address token1 = IUniswapV2Pair(lpToken).token1();
        // address expectedPair = IUniswapV2Factory(factory).getPair(token0, token1);
        // require(lpToken == expectedPair, "INVALID_PAIR");

        // Transfer LP tokens from user
        // IERC20(lpToken).transferFrom(from, address(this), amount);

        // lockedBalances[lpToken][from] += amount;

        // info = LPInfo({
        //     lpType: LPType.UniswapV2,
        //     token0: token0,
        //     token1: token1,
        //     feeTier: 3000, // V2 always 0.3%
        //     tickLower: 0, // Not applicable for V2
        //     tickUpper: 0,
        //     liquidity: uint128(amount),
        //     pool: lpToken
        // });
    }

    /// @inheritdoc ILPAdapter
    function unlock(
        address lpToken,
        uint256,
        /* tokenId */
        uint256 amount,
        address to
    )
        external
        onlyProtocol
    {
        // IERC20(lpToken).transfer(to, amount);
        // lockedBalances[lpToken][to] -= amount;
    }

    /// @inheritdoc ILPAdapter
    function unwind(
        address lpToken,
        uint256, /* tokenId */
        uint128 liquidityToRemove
    )
        external
        onlyProtocol
        returns (uint256 amount0, uint256 amount1)
    {
        // Approve router to spend LP tokens
        // IERC20(lpToken).approve(router, uint256(liquidityToRemove));

        // Remove liquidity atomically
        // address token0 = IUniswapV2Pair(lpToken).token0();
        // address token1 = IUniswapV2Pair(lpToken).token1();
        // (amount0, amount1) = IUniswapV2Router02(router).removeLiquidity(
        //     token0, token1,
        //     uint256(liquidityToRemove),
        //     0, 0, // min amounts (slippage handled by LiquidationEngine)
        //     msg.sender,
        //     block.timestamp
        // );
    }

    /// @inheritdoc ILPAdapter
    function collectFees(address, uint256) external pure returns (uint256, uint256) {
        // V2 LP tokens auto-compound fees — no separate collection needed
        // Fees are embedded in the LP token value
        return (0, 0);
    }

    /// @inheritdoc ILPAdapter
    function lpType() external pure returns (LPType) {
        return LPType.UniswapV2;
    }

    /// @inheritdoc ILPAdapter
    function isSupported(address lpToken) external view returns (bool) {
        // Check if this address is a valid Uniswap V2 pair from our factory
        // try IUniswapV2Pair(lpToken).factory() returns (address f) {
        //     return f == factory;
        // } catch {
        //     return false;
        // }
        return false; // Placeholder
    }
}
