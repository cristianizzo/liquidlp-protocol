// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionManager} from "../core/PositionManager.sol";
import {LendingEngine} from "../core/LendingEngine.sol";

/// @title MigrationHelper
/// @notice Helps users migrate positions between markets in a single transaction
contract MigrationHelper {
    PositionManager public immutable positionManager;
    LendingEngine public immutable lendingEngine;

    constructor(address _positionManager, address _lendingEngine) {
        positionManager = PositionManager(_positionManager);
        lendingEngine = LendingEngine(_lendingEngine);
    }

    /// @notice Migrate a position from one market to another
    /// @dev Repays debt → withdraws LP → deposits into new market → re-borrows
    function migratePosition(
        uint256 positionId,
        uint256 newMarketId,
        uint256 newBorrowAmount
    )
        external
        returns (uint256 newPositionId)
    {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        require(pos.owner == msg.sender, "NOT_OWNER");

        // Step 1: Repay existing debt
        uint256 debt = lendingEngine.getDebt(positionId);
        if (debt > 0) {
            lendingEngine.repay(positionId, type(uint256).max);
        }

        // Step 2: Withdraw LP from old market
        positionManager.withdraw(positionId);

        // Step 3: Deposit LP into new market
        newPositionId = positionManager.deposit(pos.lpToken, pos.tokenId, pos.amount, newMarketId);

        // Step 4: Borrow in new market (if requested)
        if (newBorrowAmount > 0) {
            lendingEngine.borrow(newPositionId, newBorrowAmount);
        }
    }
}
