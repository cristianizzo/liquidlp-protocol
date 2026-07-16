// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3FlashCallback, IUniswapV3Pool} from "../interfaces/external/IUniswapV3.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {PositionManager} from "../core/PositionManager.sol";
import {LendingEngine} from "../core/LendingEngine.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {IMarket} from "../interfaces/IMarket.sol";

/// @title LeverageTransformer
/// @notice One-click leverage for LP positions via flash loans.
/// @dev Atomically: flash borrow → swap to LP tokens → add collateral → borrow against it → repay flash.
///
///      Two modes:
///        1. leverageUp(): Increase leverage on an existing position
///           Flash borrow USDC → swap to LP tokens → addCollateral → borrow more → repay flash
///        2. leverageDown(): Decrease leverage / deleverage
///           Flash borrow USDC → repay debt → withdraw collateral → swap to USDC → repay flash
///
///      Security:
///        - Flash callback verified via _activeFlashPool state (not calldata)
///        - minBorrowOut prevents sandwich on the borrow-after-collateral step
///        - Position owner must approve this contract to act on their position
///        - Stateless periphery — can be redeployed without affecting core protocol
///
///      Inspired by Revert Lend V3Utils and Instadapp leverage modules.
contract LeverageTransformer is IUniswapV3FlashCallback {
    using SafeERC20 for IERC20;

    ProtocolCore public immutable core;
    PositionManager public immutable positionManager;
    LendingEngine public immutable lendingEngine;
    ISwapRouter public immutable swapRouter;

    /// @dev Active flash pool — set before flash, verified in callback, cleared after.
    address private _activeFlashPool;

    struct LeverageUpParams {
        uint256 positionId;
        uint256 flashAmount; // Amount to flash borrow (in borrow asset)
        address flashLoanPool; // Uniswap V3 pool to flash from
        bytes swapPath0; // Flash borrow asset → token0 (empty if borrow asset IS token0)
        bytes swapPath1; // Flash borrow asset → token1 (empty if borrow asset IS token1)
        uint256 swap0Portion; // Portion of flash to swap to token0 (bps, rest goes to token1)
        uint256 minBorrowOut; // Min USDC received from borrow (slippage protection)
    }

    struct LeverageDownParams {
        uint256 positionId;
        uint256 flashAmount; // Amount to flash borrow (to repay debt)
        address flashLoanPool; // Uniswap V3 pool to flash from
        uint256 repayAmount; // How much debt to repay
        uint256 withdrawShares; // How many LP shares/amount to withdraw (V2 only, 0 for V3)
        bytes swapPath0; // token0 → borrow asset
        bytes swapPath1; // token1 → borrow asset
    }

    /// @dev Internal callback context
    struct FlashContext {
        bool isLeverageUp;
        uint256 positionId;
        address borrowAsset;
        address token0;
        address token1;
        address caller;
        // LeverageUp fields
        bytes swapPath0;
        bytes swapPath1;
        uint256 swap0Portion;
        uint256 minBorrowOut;
        // LeverageDown fields
        uint256 repayAmount;
        uint256 withdrawShares;
    }

    event LeverageIncreased(uint256 indexed positionId, address indexed caller, uint256 flashAmount, uint256 borrowed);
    event LeverageDecreased(uint256 indexed positionId, address indexed caller, uint256 flashAmount, uint256 repaid);

    constructor(address _core, address _positionManager, address _lendingEngine, address _swapRouter) {
        require(
            _core != address(0) && _positionManager != address(0) && _lendingEngine != address(0)
                && _swapRouter != address(0),
            "ZERO_ADDRESS"
        );
        require(
            _core.code.length > 0 && _positionManager.code.length > 0 && _lendingEngine.code.length > 0
                && _swapRouter.code.length > 0,
            "NOT_CONTRACT"
        );
        core = ProtocolCore(_core);
        positionManager = PositionManager(_positionManager);
        lendingEngine = LendingEngine(_lendingEngine);
        swapRouter = ISwapRouter(_swapRouter);
    }

    // ========================================================================
    // Leverage Up
    // ========================================================================

    /// @notice Increase leverage on an existing position
    /// @dev Caller must be the position owner. Position must have available borrow capacity.
    ///      Flash borrow → swap to LP tokens → addCollateral → borrow → repay flash.
    ///
    ///      flashAmount controls leverage level — it is NOT the position value.
    ///      Max theoretical leverage depends on LTV: maxFlash = positionValue * LTV / (1 - LTV).
    ///      Example at 65% LTV: $10K position → max flash ~$18.5K → ~2.85x leverage.
    ///      If flashAmount exceeds borrow capacity, LendingEngine reverts with EXCEEDS_MAX_LTV.
    ///      Users should choose flashAmount below max for a safety margin on health factor.
    function leverageUp(LeverageUpParams calldata params) external {
        IPositionManager.Position memory pos = positionManager.getPosition(params.positionId);
        require(pos.owner == msg.sender, "NOT_OWNER");
        require(params.flashAmount > 0, "ZERO_FLASH");
        require(params.swap0Portion <= 10_000, "INVALID_PORTION");

        address marketAddr = core.markets(pos.marketId);
        IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();

        // Encode context for flash callback
        FlashContext memory ctx = FlashContext({
            isLeverageUp: true,
            positionId: params.positionId,
            borrowAsset: config.borrowAsset,
            token0: pos.token0,
            token1: pos.token1,
            caller: msg.sender,
            swapPath0: params.swapPath0,
            swapPath1: params.swapPath1,
            swap0Portion: params.swap0Portion,
            minBorrowOut: params.minBorrowOut,
            repayAmount: 0,
            withdrawShares: 0
        });

        _executeFlash(params.flashLoanPool, params.flashAmount, config.borrowAsset, ctx);
    }

    // ========================================================================
    // Leverage Down
    // ========================================================================

    /// @notice Decrease leverage / deleverage an existing position
    /// @dev Caller must be the position owner.
    ///      Flash borrow → repay debt → withdraw collateral → swap to borrow asset → repay flash.
    function leverageDown(LeverageDownParams calldata params) external {
        IPositionManager.Position memory pos = positionManager.getPosition(params.positionId);
        require(pos.owner == msg.sender, "NOT_OWNER");
        require(params.flashAmount > 0, "ZERO_FLASH");

        address marketAddr = core.markets(pos.marketId);
        IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();

        FlashContext memory ctx = FlashContext({
            isLeverageUp: false,
            positionId: params.positionId,
            borrowAsset: config.borrowAsset,
            token0: pos.token0,
            token1: pos.token1,
            caller: msg.sender,
            swapPath0: params.swapPath0,
            swapPath1: params.swapPath1,
            swap0Portion: 0,
            minBorrowOut: 0,
            repayAmount: params.repayAmount,
            withdrawShares: params.withdrawShares
        });

        _executeFlash(params.flashLoanPool, params.flashAmount, config.borrowAsset, ctx);
    }

    // ========================================================================
    // Flash Callback
    // ========================================================================

    /// @inheritdoc IUniswapV3FlashCallback
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == _activeFlashPool, "UNAUTHORIZED_CALLBACK");

        FlashContext memory ctx = abi.decode(data, (FlashContext));
        uint256 flashFee = fee0 > 0 ? fee0 : fee1;

        if (ctx.isLeverageUp) {
            _handleLeverageUp(ctx, flashFee);
        } else {
            _handleLeverageDown(ctx, flashFee);
        }
    }

    // ========================================================================
    // Internal: Flash Execution
    // ========================================================================

    function _executeFlash(
        address flashPool,
        uint256 flashAmount,
        address borrowAsset,
        FlashContext memory ctx
    )
        internal
    {
        require(_activeFlashPool == address(0), "FLASH_IN_PROGRESS");
        _activeFlashPool = flashPool;

        // Determine which token to flash (token0 or token1 of the flash pool)
        address poolToken0 = IUniswapV3Pool(flashPool).token0();
        uint256 amount0 = borrowAsset == poolToken0 ? flashAmount : 0;
        uint256 amount1 = borrowAsset == poolToken0 ? 0 : flashAmount;

        IUniswapV3Pool(flashPool).flash(address(this), amount0, amount1, abi.encode(ctx));

        _activeFlashPool = address(0);
    }

    function _handleLeverageUp(FlashContext memory ctx, uint256 flashFee) internal {
        uint256 flashBalance = IERC20(ctx.borrowAsset).balanceOf(address(this));

        // Step 1: Swap flash-borrowed tokens to LP token pair
        uint256 forToken0 = (flashBalance * ctx.swap0Portion) / 10_000;
        uint256 forToken1 = flashBalance - forToken0;

        uint256 got0 = 0;
        uint256 got1 = 0;

        // Swap to token0 (skip if borrow asset IS token0)
        if (forToken0 > 0 && ctx.swapPath0.length > 0) {
            IERC20(ctx.borrowAsset).forceApprove(address(swapRouter), forToken0);
            got0 = swapRouter.exactInput(
                ISwapRouter.ExactInputParams({
                    path: ctx.swapPath0,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: forToken0,
                    amountOutMinimum: 0
                })
            );
        } else if (forToken0 > 0 && ctx.borrowAsset == ctx.token0) {
            got0 = forToken0;
        }

        // Swap to token1 (skip if borrow asset IS token1)
        if (forToken1 > 0 && ctx.swapPath1.length > 0) {
            IERC20(ctx.borrowAsset).forceApprove(address(swapRouter), forToken1);
            got1 = swapRouter.exactInput(
                ISwapRouter.ExactInputParams({
                    path: ctx.swapPath1,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: forToken1,
                    amountOutMinimum: 0
                })
            );
        } else if (forToken1 > 0 && ctx.borrowAsset == ctx.token1) {
            got1 = forToken1;
        }

        // Step 2: Add collateral to position
        if (got0 > 0) IERC20(ctx.token0).forceApprove(address(positionManager), got0);
        if (got1 > 0) IERC20(ctx.token1).forceApprove(address(positionManager), got1);
        positionManager.addCollateral(ctx.positionId, got0, got1, 0, 0);

        // Step 3: Borrow against increased collateral to repay flash
        uint256 totalOwed = flashBalance + flashFee;
        uint256 borrowNeeded = totalOwed - IERC20(ctx.borrowAsset).balanceOf(address(this));

        // The position owner must have delegated borrow authority or this is called as owner
        // For now, borrow is only callable by position owner — caller must be owner
        lendingEngine.borrow(ctx.positionId, borrowNeeded);

        require(IERC20(ctx.borrowAsset).balanceOf(address(this)) >= totalOwed, "INSUFFICIENT_FOR_REPAY");
        require(borrowNeeded >= ctx.minBorrowOut, "BELOW_MIN_BORROW");

        // Step 4: Repay flash loan
        IERC20(ctx.borrowAsset).safeTransfer(_activeFlashPool, totalOwed);

        // Refund any leftover to caller
        uint256 leftover = IERC20(ctx.borrowAsset).balanceOf(address(this));
        if (leftover > 0) IERC20(ctx.borrowAsset).safeTransfer(ctx.caller, leftover);

        emit LeverageIncreased(ctx.positionId, ctx.caller, flashBalance, borrowNeeded);
    }

    function _handleLeverageDown(FlashContext memory ctx, uint256 flashFee) internal {
        uint256 flashBalance = IERC20(ctx.borrowAsset).balanceOf(address(this));

        // Step 1: Repay debt with flash-borrowed funds
        IERC20(ctx.borrowAsset).forceApprove(address(lendingEngine), ctx.repayAmount);
        lendingEngine.repay(ctx.positionId, ctx.repayAmount);

        // Step 2: Withdraw collateral (reduced debt → higher HF → can withdraw)
        // For V2: withdraw LP shares. For V3: this is more complex (partial liquidity removal).
        // Currently only supports V2-style withdrawal or full V3 position withdrawal.
        if (ctx.withdrawShares > 0) {
            positionManager.withdraw(ctx.positionId);
        }

        // Step 3: Swap received tokens back to borrow asset
        if (ctx.swapPath0.length > 0) {
            uint256 balance0 = IERC20(ctx.token0).balanceOf(address(this));
            if (balance0 > 0) {
                IERC20(ctx.token0).forceApprove(address(swapRouter), balance0);
                swapRouter.exactInput(
                    ISwapRouter.ExactInputParams({
                        path: ctx.swapPath0,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: balance0,
                        amountOutMinimum: 0
                    })
                );
            }
        }

        if (ctx.swapPath1.length > 0) {
            uint256 balance1 = IERC20(ctx.token1).balanceOf(address(this));
            if (balance1 > 0) {
                IERC20(ctx.token1).forceApprove(address(swapRouter), balance1);
                swapRouter.exactInput(
                    ISwapRouter.ExactInputParams({
                        path: ctx.swapPath1,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: balance1,
                        amountOutMinimum: 0
                    })
                );
            }
        }

        // Step 4: Repay flash loan
        uint256 totalOwed = flashBalance + flashFee;
        require(IERC20(ctx.borrowAsset).balanceOf(address(this)) >= totalOwed, "INSUFFICIENT_FOR_REPAY");
        IERC20(ctx.borrowAsset).safeTransfer(_activeFlashPool, totalOwed);

        // Refund leftover to caller
        _refundAll(ctx.token0, ctx.caller);
        _refundAll(ctx.token1, ctx.caller);
        _refundAll(ctx.borrowAsset, ctx.caller);

        emit LeverageDecreased(ctx.positionId, ctx.caller, flashBalance, ctx.repayAmount);
    }

    function _refundAll(address token, address to) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) IERC20(token).safeTransfer(to, balance);
    }
}
