// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @notice Mock swap router — swaps at 1:1 rate for testing
contract MockSwapRouter is ISwapRouter {
    // tokenOut to mint on swaps (set in test)
    address public outputToken;
    bool public shouldRevert;

    constructor(address _outputToken) {
        outputToken = _outputToken;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function swap(
        address tokenIn,
        address, /* tokenOut */
        uint256 amountIn,
        uint256 amountOutMin
    ) external override returns (uint256 amountOut) {
        require(!shouldRevert, "SWAP_FAILED");

        // Pull tokenIn from caller
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Send outputToken at 1:1 rate (simplification for testing)
        amountOut = amountIn;
        require(amountOut >= amountOutMin, "SLIPPAGE");

        IERC20(outputToken).transfer(msg.sender, amountOut);
    }
}
