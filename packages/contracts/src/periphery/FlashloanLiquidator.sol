// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3FlashCallback} from "../interfaces/external/IUniswapV3.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {PositionManager} from "../core/PositionManager.sol";
import {LiquidationEngine} from "../core/LiquidationEngine.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";

/// @title FlashloanLiquidator
/// @notice Permissionless flash loan liquidation helper. Enables capital-free liquidations
///         by flash-borrowing the repayment asset from a Uniswap V3 pool, liquidating the
///         position, swapping received tokens back, repaying the flash loan, and sending
///         profit to the caller.
/// @dev Uses Uniswap V3 pool.flash() (fee = pool's fee tier). Supports multi-hop swap paths for
///      exotic token pairs (e.g., WBTC→WETH→USDC). The borrow asset is read dynamically
///      from the market config — not hardcoded to any specific token.
contract FlashloanLiquidator is IUniswapV3FlashCallback {
    using SafeERC20 for IERC20;

    ProtocolCore public immutable core;
    PositionManager public immutable positionManager;
    LiquidationEngine public immutable liquidationEngine;
    ISwapRouter public immutable swapRouter;

    /// @dev Active flash context — set before flash, verified in callback, cleared after
    address private _activeFlashPool;

    /// @dev Packed data passed through the flash loan callback
    struct FlashCallbackData {
        uint256 positionId;
        uint256 repayAmount;
        address borrowAsset;
        address token0;
        address token1;
        address marketAddr;
        bytes swapPath0;
        bytes swapPath1;
        uint256 minProfit;
        address caller;
        address flashLoanPool;
    }

    struct LiquidateParams {
        uint256 positionId;
        uint256 repayAmount;
        address flashLoanPool;
        bytes swapPath0;
        bytes swapPath1;
        uint256 minProfit;
    }

    event FlashLiquidation(
        uint256 indexed positionId, address indexed liquidator, address borrowAsset, uint256 repayAmount, uint256 profit
    );

    constructor(address _core, address _positionManager, address _liquidationEngine, address _swapRouter) {
        require(
            _core != address(0) && _positionManager != address(0) && _liquidationEngine != address(0)
                && _swapRouter != address(0),
            "ZERO_ADDRESS"
        );
        core = ProtocolCore(_core);
        positionManager = PositionManager(_positionManager);
        liquidationEngine = LiquidationEngine(_liquidationEngine);
        swapRouter = ISwapRouter(_swapRouter);
    }

    /// @notice Execute a flash loan liquidation
    /// @param params Liquidation parameters including position, flash pool, swap paths, and min profit
    /// @return profit Amount of borrow asset profit sent to caller
    function liquidate(LiquidateParams calldata params) external returns (uint256 profit) {
        // Read position and market info
        IPositionManager.Position memory pos = positionManager.getPosition(params.positionId);
        require(pos.owner != address(0), "POSITION_NOT_FOUND");

        address marketAddr = core.markets(pos.marketId);
        IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();
        address borrowAsset = config.borrowAsset;

        // Track balance before for accurate profit calculation
        uint256 balanceBefore = IERC20(borrowAsset).balanceOf(address(this));
        FlashCallbackData memory cbData = FlashCallbackData({
            positionId: params.positionId,
            repayAmount: params.repayAmount,
            borrowAsset: borrowAsset,
            token0: pos.token0,
            token1: pos.token1,
            marketAddr: marketAddr,
            swapPath0: params.swapPath0,
            swapPath1: params.swapPath1,
            minProfit: params.minProfit,
            caller: msg.sender,
            flashLoanPool: params.flashLoanPool
        });

        // Verify flash pool contains the borrow asset and determine flash amounts
        address poolToken0 = IUniswapV3PoolMinimal(params.flashLoanPool).token0();
        address poolToken1 = IUniswapV3PoolMinimal(params.flashLoanPool).token1();
        require(poolToken0 == borrowAsset || poolToken1 == borrowAsset, "POOL_MISSING_BORROW_ASSET");
        uint256 flashAmount0 = poolToken0 == borrowAsset ? params.repayAmount : 0;
        uint256 flashAmount1 = poolToken0 == borrowAsset ? 0 : params.repayAmount;

        // Set active flash context before flash (callback verifies msg.sender matches)
        _activeFlashPool = params.flashLoanPool;

        // Execute flash loan — callback will handle liquidation + swaps + repayment
        IUniswapV3PoolMinimal(params.flashLoanPool).flash(address(this), flashAmount0, flashAmount1, abi.encode(cbData));

        // Clear active flash context
        _activeFlashPool = address(0);

        // Transfer profit to caller (balance delta avoids sweeping pre-existing tokens)
        uint256 balanceAfter = IERC20(borrowAsset).balanceOf(address(this));
        profit = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (profit > 0) {
            IERC20(borrowAsset).safeTransfer(msg.sender, profit);
        }
    }

    /// @notice Uniswap V3 flash loan callback — executes the liquidation
    /// @dev Only callable by the flash loan pool specified in the callback data
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        FlashCallbackData memory cb = abi.decode(data, (FlashCallbackData));

        // Security: verify caller is the flash pool set by liquidate() — not from calldata
        require(msg.sender == _activeFlashPool, "NOT_FLASH_POOL");

        uint256 flashFee = fee0 > 0 ? fee0 : fee1;

        // Step 1: Approve and execute liquidation
        IERC20(cb.borrowAsset).forceApprove(address(liquidationEngine), cb.repayAmount);

        liquidationEngine.liquidate(cb.positionId, cb.repayAmount, block.timestamp, 0, 0);

        // Step 2: Swap received tokens back to borrow asset
        // Skip swap if token is already the borrow asset
        if (cb.token0 != cb.borrowAsset && cb.swapPath0.length > 0) {
            uint256 balance0 = IERC20(cb.token0).balanceOf(address(this));
            if (balance0 > 0) {
                IERC20(cb.token0).forceApprove(address(swapRouter), balance0);
                swapRouter.exactInput(
                    ISwapRouter.ExactInputParams({
                        path: cb.swapPath0,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: balance0,
                        amountOutMinimum: 0
                    })
                );
            }
        }

        if (cb.token1 != cb.borrowAsset && cb.swapPath1.length > 0) {
            uint256 balance1 = IERC20(cb.token1).balanceOf(address(this));
            if (balance1 > 0) {
                IERC20(cb.token1).forceApprove(address(swapRouter), balance1);
                swapRouter.exactInput(
                    ISwapRouter.ExactInputParams({
                        path: cb.swapPath1,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: balance1,
                        amountOutMinimum: 0
                    })
                );
            }
        }

        // Step 3: Repay flash loan
        uint256 totalOwed = cb.repayAmount + flashFee;
        uint256 totalBorrowAsset = IERC20(cb.borrowAsset).balanceOf(address(this));
        require(totalBorrowAsset >= totalOwed, "INSUFFICIENT_FOR_REPAY");

        // Repay to the flash loan pool
        IERC20(cb.borrowAsset).safeTransfer(cb.flashLoanPool, totalOwed);

        // Step 4: Profit check
        uint256 profit = IERC20(cb.borrowAsset).balanceOf(address(this));
        require(profit >= cb.minProfit, "INSUFFICIENT_PROFIT");

        emit FlashLiquidation(cb.positionId, cb.caller, cb.borrowAsset, cb.repayAmount, profit);
    }
}

/// @notice Minimal interface for flash loan pool interaction
interface IUniswapV3PoolMinimal {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}
