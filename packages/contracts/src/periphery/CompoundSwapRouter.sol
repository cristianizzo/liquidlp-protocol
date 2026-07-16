// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {PositionManager} from "../core/PositionManager.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {FeeCollector} from "../core/FeeCollector.sol";

/// @title CompoundSwapRouter
/// @notice Compound V3 fees with automatic dust swap for out-of-range positions.
/// @dev Called through PositionManager.transform() — NOT directly by users.
///
///      When a V3 position is out of range, collected fees in one token can't be
///      reinvested (returned as dust). This contract catches that dust, swaps it
///      to the other token, and reinvests — maximizing compound efficiency.
///
///      Flow:
///        1. User calls positionManager.transform(positionId, this, compoundData)
///        2. PositionManager verifies owner + transformer whitelist
///        3. This contract calls positionManager.compoundFees() — dust comes here
///        4. Swap dust to needed token via SwapRouter
///        5. Call positionManager.addCollateral() to reinvest swapped tokens
///           (allowed because transformedPositionId matches)
///        6. PositionManager verifies health factor (defense in depth)
///
///      Access: position owner calls positionManager.transform() which calls this contract.
///      The caller reward recipient can be any address (e.g., a bot address).
///      This contract must be granted both TRANSFORMER and KEEPER roles.
contract CompoundSwapRouter {
    using SafeERC20 for IERC20;

    ProtocolCore public immutable core;
    PositionManager public immutable positionManager;
    ISwapRouter public immutable swapRouter;
    FeeCollector public immutable feeCollector;

    uint256 public constant PROTOCOL_FEE_BPS = 200; // 2%
    uint256 public constant CALLER_REWARD_BPS = 50; // 0.5%

    struct CompoundParams {
        uint256 positionId;
        bytes swapPath; // Path to swap dust token → needed token (empty = no swap)
        uint256 minFeeThreshold;
        uint256 maxSlippageBps;
        address callerRewardRecipient; // Who receives the 0.5% reward
    }

    event Compounded(uint256 indexed positionId, uint256 fees0, uint256 fees1, uint256 swapped, uint256 addedLiquidity);

    constructor(address _core, address _positionManager, address _swapRouter, address _feeCollector) {
        require(
            _core != address(0) && _positionManager != address(0) && _swapRouter != address(0)
                && _feeCollector != address(0),
            "ZERO_ADDRESS"
        );
        require(
            _core.code.length > 0 && _positionManager.code.length > 0 && _swapRouter.code.length > 0
                && _feeCollector.code.length > 0,
            "NOT_CONTRACT"
        );
        core = ProtocolCore(_core);
        positionManager = PositionManager(_positionManager);
        swapRouter = ISwapRouter(_swapRouter);
        feeCollector = FeeCollector(_feeCollector);
    }

    /// @notice Compound fees with optional dust swap — called by PositionManager.transform()
    function compound(CompoundParams calldata params)
        external
        returns (uint256 fees0, uint256 fees1, uint256 addedLiquidity)
    {
        require(msg.sender == address(positionManager), "ONLY_POSITION_MANAGER");

        IPositionManager.Position memory pos = positionManager.getPosition(params.positionId);

        // Step 1: Compound fees — dust comes to this contract
        (fees0, fees1, addedLiquidity) = positionManager.compoundFees(
            params.positionId,
            address(feeCollector),
            PROTOCOL_FEE_BPS,
            params.callerRewardRecipient,
            CALLER_REWARD_BPS,
            params.minFeeThreshold,
            address(this), // dust refund here for swap
            params.maxSlippageBps
        );

        // Step 2: Swap dust if path provided
        uint256 swapped = 0;
        if (params.swapPath.length > 0) {
            uint256 dust0 = IERC20(pos.token0).balanceOf(address(this));
            uint256 dust1 = IERC20(pos.token1).balanceOf(address(this));

            if (dust0 > 0) {
                IERC20(pos.token0).forceApprove(address(swapRouter), dust0);
                swapped = swapRouter.exactInput(
                    ISwapRouter.ExactInputParams({
                        path: params.swapPath,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: dust0,
                        amountOutMinimum: 0 // Protected by post-transform health check
                    })
                );
            } else if (dust1 > 0) {
                IERC20(pos.token1).forceApprove(address(swapRouter), dust1);
                swapped = swapRouter.exactInput(
                    ISwapRouter.ExactInputParams({
                        path: params.swapPath,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: dust1,
                        amountOutMinimum: 0 // Protected by post-transform health check
                    })
                );
            }

            // Step 3: Reinvest swapped tokens (authorized via transformedPositionId)
            uint256 reinvest0 = IERC20(pos.token0).balanceOf(address(this));
            uint256 reinvest1 = IERC20(pos.token1).balanceOf(address(this));

            if (reinvest0 > 0 || reinvest1 > 0) {
                if (reinvest0 > 0) IERC20(pos.token0).forceApprove(address(positionManager), reinvest0);
                if (reinvest1 > 0) IERC20(pos.token1).forceApprove(address(positionManager), reinvest1);
                positionManager.addCollateral(params.positionId, reinvest0, reinvest1, 0, 0);
            }
        } else {
            // No swap — refund dust to position owner
            _refundAll(pos.token0, pos.owner);
            _refundAll(pos.token1, pos.owner);
        }

        emit Compounded(params.positionId, fees0, fees1, swapped, addedLiquidity);
    }

    function _refundAll(address token, address to) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) IERC20(token).safeTransfer(to, balance);
    }
}
