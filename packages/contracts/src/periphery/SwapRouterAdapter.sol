// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";

/// @title SwapRouterAdapter
/// @notice Wraps the Uniswap V3 SwapRouter to implement our ISwapRouter interface.
/// @dev The real Uniswap V3 SwapRouter uses a callback pattern where it pulls tokens
///      from msg.sender via transferFrom during the swap callback. This adapter receives
///      tokens from the caller first, then forwards the swap to the real router.
///
///      Without this adapter, contracts like CompoundSwapRouter that call the real
///      Uniswap V3 SwapRouter fail with STF (SafeTransferFrom) because the callback
///      context doesn't align with the approval.
///
///      Flow:
///        1. Caller approves this adapter for tokenIn amount
///        2. Caller calls exactInput() or swap()
///        3. Adapter pulls tokens from caller via transferFrom
///        4. Adapter approves real router and forwards the call
///        5. Real router's callback pulls from adapter (works because adapter holds tokens)
///        6. Adapter clears residual approval
contract SwapRouterAdapter is ISwapRouter {
    using SafeERC20 for IERC20;

    address public immutable uniswapRouter;

    constructor(address _uniswapRouter) {
        require(_uniswapRouter != address(0), "ZERO_ADDRESS");
        require(_uniswapRouter.code.length > 0, "NOT_CONTRACT");
        uniswapRouter = _uniswapRouter;
    }

    /// @inheritdoc ISwapRouter
    /// @dev Uses 0.3% fee tier by default. For fee tier control, use exactInput() with
    ///      a caller-supplied path instead. Output tokens are sent to msg.sender.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    )
        external
        override
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(uniswapRouter, amountIn);

        bytes memory path = abi.encodePacked(tokenIn, uint24(3000), tokenOut);
        amountOut = ISwapRouter(uniswapRouter)
            .exactInput(
                ExactInputParams({
                path: path,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: amountOutMin
            })
            );

        IERC20(tokenIn).forceApprove(uniswapRouter, 0);
    }

    /// @inheritdoc ISwapRouter
    /// @dev ETH is not supported — this adapter handles ERC20-to-ERC20 swaps only.
    function exactInput(ExactInputParams calldata params) external payable override returns (uint256 amountOut) {
        require(msg.value == 0, "NO_ETH");
        address tokenIn = _extractTokenIn(params.path);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(tokenIn).forceApprove(uniswapRouter, params.amountIn);

        amountOut = ISwapRouter(uniswapRouter)
            .exactInput(
                ExactInputParams({
                path: params.path,
                recipient: params.recipient,
                deadline: params.deadline,
                amountIn: params.amountIn,
                amountOutMinimum: params.amountOutMinimum
            })
            );

        IERC20(tokenIn).forceApprove(uniswapRouter, 0);
    }

    /// @dev Extract the first token address from a packed Uniswap V3 path.
    ///      Path encoding: [tokenIn (20 bytes)][fee (3 bytes)][tokenOut (20 bytes)]...
    function _extractTokenIn(bytes calldata path) internal pure returns (address tokenIn) {
        require(path.length >= 43, "INVALID_PATH");
        tokenIn = address(bytes20(path[:20]));
    }
}
