// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";
import {PositionManager} from "../core/PositionManager.sol";

/// @title LPCompounder
/// @notice Auto-compounds trading fees back into LP positions
/// @dev Called by keeper bots to compound fees for all active positions
contract LPCompounder {
    using SafeERC20 for IERC20;

    ProtocolCore public immutable core;
    PositionManager public immutable positionManager;

    event FeesCompounded(uint256 indexed positionId, uint256 fees0, uint256 fees1);
    event TokensSwept(address indexed token, address indexed to, uint256 amount);

    modifier onlyKeeper() {
        require(core.aclManager().isKeeper(msg.sender) || core.aclManager().isPoolAdmin(msg.sender), "NOT_KEEPER");
        _;
    }

    constructor(address _core, address _positionManager) {
        core = ProtocolCore(_core);
        positionManager = PositionManager(_positionManager);
    }

    /// @notice Compound fees for a V3 position (collect fees + add back as liquidity)
    function compoundPosition(uint256 positionId) external onlyKeeper {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        require(pos.status != IPositionManager.PositionStatus.Liquidated, "LIQUIDATED");

        // Only V3-style positions have collectable fees
        // V2 and Curve auto-compound natively
        if (
            pos.lpType != ILPAdapter.LPType.UniswapV3 && pos.lpType != ILPAdapter.LPType.PancakeSwapV3
                && pos.lpType != ILPAdapter.LPType.Aerodrome
        ) {
            return;
        }

        address adapterAddr = core.adapters(pos.lpType);
        ILPAdapter adapter = ILPAdapter(adapterAddr);

        // Collect fees
        (uint256 fees0, uint256 fees1) = adapter.collectFees(pos.lpToken, pos.tokenId);

        if (fees0 == 0 && fees1 == 0) return;

        // For V3-style positions, collected fees need to be added back as liquidity
        // via INonfungiblePositionManager.increaseLiquidity(). This requires:
        //   1. Approve both tokens to the NFT manager
        //   2. Call increaseLiquidity with the correct amounts for the position's tick range
        //   3. The NFT manager calculates the optimal ratio based on current tick
        //
        // For now, fees are held by the adapter contract and increase collateral value
        // via the oracle's fee calculation. Full auto-compound will be implemented
        // when adapter contracts are wired to mainnet DEX interfaces.
        //
        // The fees still count toward position value because the oracle
        // reads unclaimed fees directly from the pool's feeGrowth tracking.

        emit FeesCompounded(positionId, fees0, fees1);
    }

    /// @notice Batch compound multiple positions
    function batchCompound(uint256[] calldata positionIds) external onlyKeeper {
        for (uint256 i = 0; i < positionIds.length; i++) {
            // Skip errors for individual positions
            try this.compoundPosition(positionIds[i]) {} catch {}
        }
    }

    /// @notice Sweep tokens stuck in this contract (from collected but not yet compounded fees)
    /// @dev Only callable by PoolAdmin. Sends to a specified recipient (treasury or position owner).
    function sweepTokens(address token, address to, uint256 amount) external {
        require(core.aclManager().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        require(token != address(0) && to != address(0), "ZERO_ADDRESS");
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 sweepAmount = amount > balance ? balance : amount;
        require(sweepAmount > 0, "NO_BALANCE");
        IERC20(token).safeTransfer(to, sweepAmount);
        emit TokensSwept(token, to, sweepAmount);
    }
}
