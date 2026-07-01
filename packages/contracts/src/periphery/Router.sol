// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionManager} from "../core/PositionManager.sol";
import {LendingEngine} from "../core/LendingEngine.sol";

/// @title Router
/// @notice User-facing multicall contract — deposit + borrow in a single transaction
contract Router {
    PositionManager public immutable positionManager;
    LendingEngine public immutable lendingEngine;

    constructor(address _positionManager, address _lendingEngine) {
        positionManager = PositionManager(_positionManager);
        lendingEngine = LendingEngine(_lendingEngine);
    }

    /// @notice Deposit LP and borrow in one transaction
    /// @param lpToken LP token or NFT manager address
    /// @param tokenId NFT token ID (0 for ERC-20)
    /// @param amount LP token amount (0 for NFT)
    /// @param marketId Market to deposit into
    /// @param borrowAmount Amount to borrow (0 to skip borrowing)
    /// @return positionId The created position ID
    function depositAndBorrow(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        uint256 marketId,
        uint256 borrowAmount
    ) external returns (uint256 positionId) {
        // User must approve LP token/NFT to this Router first

        // Step 1: Deposit LP
        positionId = positionManager.deposit(lpToken, tokenId, amount, marketId);

        // Step 2: Borrow (if requested)
        if (borrowAmount > 0) {
            lendingEngine.borrow(positionId, borrowAmount);
        }
    }

    /// @notice Repay all debt and withdraw LP in one transaction
    /// @param positionId Position to close
    function repayAndWithdraw(uint256 positionId) external {
        // Step 1: Repay all debt
        uint256 debt = lendingEngine.getDebt(positionId);
        if (debt > 0) {
            // User must approve borrow asset to this Router
            lendingEngine.repay(positionId, type(uint256).max);
        }

        // Step 2: Withdraw LP
        positionManager.withdraw(positionId);
    }

    /// @notice Batch operation: repay partial + borrow more (rebalance)
    function adjustPosition(
        uint256 positionId,
        uint256 repayAmount,
        uint256 borrowAmount
    ) external {
        if (repayAmount > 0) {
            lendingEngine.repay(positionId, repayAmount);
        }
        if (borrowAmount > 0) {
            lendingEngine.borrow(positionId, borrowAmount);
        }
    }
}
