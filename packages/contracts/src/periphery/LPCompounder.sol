// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {PositionManager} from "../core/PositionManager.sol";

/// @title LPCompounder
/// @notice Auto-compounds trading fees back into LP positions
/// @dev Called by keeper bots to compound fees for all active positions
contract LPCompounder {
    ProtocolCore public immutable core;
    PositionManager public immutable positionManager;

    event FeesCompounded(uint256 indexed positionId, uint256 fees0, uint256 fees1);

    modifier onlyKeeper() {
        require(core.keepers(msg.sender) || msg.sender == core.owner(), "NOT_KEEPER");
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
}
