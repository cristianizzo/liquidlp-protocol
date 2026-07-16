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
/// @notice Permissionless compound helper that collects V3 fees, optionally swaps
///         one side to the other, and reinvests for maximum capital efficiency.
/// @dev When a V3 position is out of range, one side of collected fees can't be
///      reinvested (returned as dust). This contract swaps the "wrong" token into
///      the "right" one before reinvesting, eliminating dust and maximizing compound.
///
///      Flow:
///        1. Call PositionManager.compoundFees() — collects fees & reinvests what it can
///        2. Dust tokens are sent to this contract (via dustRefundTo)
///        3. Swap dust to the needed token via SwapRouter
///        4. Add swapped tokens back to position via addCollateral()
///
///      Permissionless: anyone can call compound() and earn the caller reward (0.5%).
///      Stateless: no storage, can be redeployed anytime without migration.
contract CompoundSwapRouter {
    using SafeERC20 for IERC20;

    ProtocolCore public immutable core;
    PositionManager public immutable positionManager;
    ISwapRouter public immutable swapRouter;
    FeeCollector public immutable feeCollector;

    /// @notice Protocol fee in bps (taken from collected fees before reinvestment)
    uint256 public constant PROTOCOL_FEE_BPS = 200; // 2%
    /// @notice Caller reward in bps (incentive for calling compound)
    uint256 public constant CALLER_REWARD_BPS = 50; // 0.5%

    struct CompoundParams {
        uint256 positionId;
        bytes swapPath; // Path to swap dust token → needed token (empty = no swap)
        uint256 minFeeThreshold; // Min per-token fee to proceed (gas optimization)
        uint256 maxSlippageBps; // Max slippage on reinvestment (bps)
    }

    event Compounded(
        uint256 indexed positionId,
        address indexed caller,
        uint256 fees0,
        uint256 fees1,
        uint256 swapped,
        uint256 addedLiquidity
    );

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

    /// @notice Compound fees with optional dust swap for out-of-range positions
    /// @param params Compound parameters
    /// @return fees0 Total token0 fees collected
    /// @return fees1 Total token1 fees collected
    /// @return addedLiquidity Total liquidity added (from compound + swap reinvestment)
    function compound(CompoundParams calldata params)
        external
        returns (uint256 fees0, uint256 fees1, uint256 addedLiquidity)
    {
        IPositionManager.Position memory pos = positionManager.getPosition(params.positionId);
        require(pos.owner != address(0), "POSITION_NOT_FOUND");

        // Step 1: Compound via PositionManager — dust comes back to this contract
        (fees0, fees1, addedLiquidity) = positionManager.compoundFees(
            params.positionId,
            address(feeCollector),
            PROTOCOL_FEE_BPS,
            msg.sender, // caller reward goes directly to caller
            CALLER_REWARD_BPS,
            params.minFeeThreshold,
            address(this), // dust refund to this contract for swap
            params.maxSlippageBps
        );

        // Step 2: Check for dust — swap if path provided
        uint256 swapped = 0;
        if (params.swapPath.length > 0) {
            uint256 dust0 = IERC20(pos.token0).balanceOf(address(this));
            uint256 dust1 = IERC20(pos.token1).balanceOf(address(this));

            // Swap whichever side has dust
            if (dust0 > 0) {
                IERC20(pos.token0).forceApprove(address(swapRouter), dust0);
                swapped = swapRouter.exactInput(
                    ISwapRouter.ExactInputParams({
                        path: params.swapPath,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: dust0,
                        amountOutMinimum: 0 // Protected by addCollateral slippage
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
                        amountOutMinimum: 0 // Protected by addCollateral slippage
                    })
                );
            }

            // Step 3: Reinvest swapped tokens back into position
            uint256 reinvest0 = IERC20(pos.token0).balanceOf(address(this));
            uint256 reinvest1 = IERC20(pos.token1).balanceOf(address(this));

            if (reinvest0 > 0 || reinvest1 > 0) {
                if (reinvest0 > 0) IERC20(pos.token0).forceApprove(address(positionManager), reinvest0);
                if (reinvest1 > 0) IERC20(pos.token1).forceApprove(address(positionManager), reinvest1);

                positionManager.addCollateral(params.positionId, reinvest0, reinvest1, 0, 0);
            }
        } else {
            // No swap path — refund dust to position owner
            _refundDust(pos.token0, pos.owner);
            _refundDust(pos.token1, pos.owner);
        }

        emit Compounded(params.positionId, msg.sender, fees0, fees1, swapped, addedLiquidity);
    }

    /// @dev Send remaining token balance to recipient
    function _refundDust(address token, address to) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(to, balance);
        }
    }
}
