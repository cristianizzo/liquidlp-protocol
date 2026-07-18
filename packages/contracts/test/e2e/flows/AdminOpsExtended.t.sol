// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {InterestRateModel} from "../../../src/markets/InterestRateModel.sol";
import {Market} from "../../../src/markets/Market.sol";

/// @title AdminOpsExtended
/// @notice E2E fork tests for admin operations not covered in AdminOperations.t.sol.
/// @dev Covers: interest rate model hot-swap, borrow cooldown, bad debt write-off, deficit elimination.
contract AdminOpsExtended is E2EBase {
    function setUp() public override {
        super.setUp();

        // Grant RISK_ADMIN to deployer for admin tests (eliminateDeficit, setReserveFactor)
        vm.prank(deployer);
        aclManager.addRiskAdmin(deployer);
    }

    // ========== 1. setInterestRateModel hot-swap ==========

    /// @notice Deploy a new IRM with higher rates, swap it on the market with active borrows,
    ///         and verify the new rates apply after accrual.
    function test_setInterestRateModel_hotSwap() public {
        // Alice deposits and borrows to create active debt
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 3);

        uint256 debtAfterBorrow = _getDebt(positionId);
        assertGt(debtAfterBorrow, 0, "Should have debt");

        // Record the current borrow rate from the original model
        address marketAddr = core.markets(ethUsdcMarketId);
        uint256 oldRate = volatileModel.getBorrowRate(5000); // at 50% utilization

        // Deploy new IRM with much higher base rate and slopes
        // Original: baseRate=200bps, slope1=600bps, slope2=10000bps, kink=8000
        // New:      baseRate=1000bps, slope1=2000bps, slope2=20000bps, kink=7000
        InterestRateModel newModel = new InterestRateModel(1000, 2000, 20_000, 7000);
        uint256 newRate = newModel.getBorrowRate(5000);
        assertGt(newRate, oldRate, "New model should have higher rate at same utilization");

        // Hot-swap the interest rate model
        vm.prank(deployer);
        Market(marketAddr).setInterestRateModel(address(newModel));

        // Advance time to accumulate interest under the new model
        _advanceTime(1 hours);
        lendingEngine.accrueInterest(ethUsdcMarketId);

        uint256 debtAfterAccrual = _getDebt(positionId);
        assertGt(debtAfterAccrual, debtAfterBorrow, "Debt should increase after accrual with new model");

        console.log("Old rate (per sec): %s", oldRate);
        console.log("New rate (per sec): %s", newRate);
        console.log("Debt before accrual: %s USDC", debtAfterBorrow / 1e6);
        console.log("Debt after accrual:  %s USDC", debtAfterAccrual / 1e6);
        console.log("=== IRM Hot-Swap Test Passed ===");
    }

    // ========== 2. setBorrowCooldown ==========

    /// @notice Set cooldown to 5 blocks, verify borrow reverts before cooldown, succeeds after.
    function test_setBorrowCooldown() public {
        // Set cooldown to 5 blocks
        vm.prank(deployer);
        lendingEngine.setBorrowCooldown(5);

        // Deposit position
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        // Try borrow immediately (same block as deposit) -- should revert
        vm.prank(alice);
        vm.expectRevert("BORROW_COOLDOWN");
        lendingEngine.borrow(positionId, 100e6);

        // Advance 3 blocks (still within 5-block cooldown) -- should revert
        vm.roll(block.number + 3);
        vm.prank(alice);
        vm.expectRevert("BORROW_COOLDOWN");
        lendingEngine.borrow(positionId, 100e6);

        // Advance past cooldown (total > 5 blocks from deposit)
        vm.roll(block.number + 5);
        vm.prank(alice);
        lendingEngine.borrow(positionId, 100e6);

        assertGt(_getDebt(positionId), 0, "Borrow should succeed after cooldown");

        console.log("=== Borrow Cooldown (5 blocks) Test Passed ===");
    }

    // ========== 3. writeOffDebt bad debt flow ==========

    /// @notice Create underwater position, liquidate partially, write off remaining bad debt.
    function test_writeOffDebt_badDebtFlow() public {
        // Alice deposits and borrows aggressively
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        uint256 debtBefore = _getDebt(positionId);
        assertGt(debtBefore, 0, "Should have debt");

        // Crash ETH price severely to make position deeply underwater
        _crashEthPrice(8000 ether);

        // Verify position is liquidatable
        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable");

        // Liquidate what we can
        if (maxRepay > 0) {
            address marketAddr = core.markets(ethUsdcMarketId);
            vm.startPrank(liquidator);
            IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
            IERC20(Constants.USDC).approve(marketAddr, maxRepay);
            liquidationEngine.liquidate(positionId, maxRepay, block.timestamp + 300, 0, 0);
            vm.stopPrank();
        }

        // Check if there's remaining debt (bad debt)
        uint256 remainingDebt = _getDebt(positionId);

        // Write off bad debt via LendingEngine (onlyLiquidationEngine)
        if (remainingDebt > 0) {
            vm.prank(address(liquidationEngine));
            lendingEngine.writeOffDebt(positionId);

            uint256 debtAfterWriteOff = _getDebt(positionId);
            assertEq(debtAfterWriteOff, 0, "Debt should be zero after write-off");

            // Market should have recorded deficit
            address marketAddr = core.markets(ethUsdcMarketId);
            uint256 marketDeficit = Market(marketAddr).deficit();
            assertGt(marketDeficit, 0, "Market should have deficit after write-off");

            console.log("Remaining debt written off: %s USDC", remainingDebt / 1e6);
            console.log("Market deficit: %s USDC", marketDeficit / 1e6);
        }

        console.log("=== Bad Debt Write-Off Test Passed ===");
    }

    // ========== 4. eliminateDeficit ==========

    /// @notice After writeOffDebt creates a deficit, build reserves via interest, then eliminate deficit.
    function test_eliminateDeficit() public {
        address marketAddr = core.markets(ethUsdcMarketId);

        // Step 1: Set reserve factor so protocol accumulates reserves from interest
        vm.prank(deployer);
        Market(marketAddr).setReserveFactor(2000); // 20%

        // Step 2: Create a position with active debt to generate interest
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        // Step 3: Advance time to accumulate interest (and thus reserves)
        _advanceTime(30 days);
        lendingEngine.accrueInterest(ethUsdcMarketId);

        uint256 reservesBefore = Market(marketAddr).protocolReserves();
        console.log("Protocol reserves after 30 days: %s USDC", reservesBefore / 1e6);
        assertGt(reservesBefore, 0, "Should have accumulated reserves");

        // Step 4: Crash price and create bad debt
        _crashEthPrice(8000 ether);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable after crash");

        // Liquidate
        if (maxRepay > 0) {
            _fundUsdc(liquidator, maxRepay);
            vm.startPrank(liquidator);
            IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
            IERC20(Constants.USDC).approve(marketAddr, maxRepay);
            liquidationEngine.liquidate(positionId, maxRepay, block.timestamp + 300, 0, 0);
            vm.stopPrank();
        }

        // Write off remaining bad debt
        uint256 remainingDebt = _getDebt(positionId);
        if (remainingDebt > 0) {
            vm.prank(address(liquidationEngine));
            lendingEngine.writeOffDebt(positionId);
        }

        uint256 deficitBefore = Market(marketAddr).deficit();
        console.log("Deficit after write-off: %s USDC", deficitBefore / 1e6);

        // Step 5: Eliminate deficit using reserves
        if (deficitBefore > 0) {
            uint256 reservesNow = Market(marketAddr).protocolReserves();
            vm.prank(deployer);
            Market(marketAddr).eliminateDeficit();

            uint256 deficitAfter = Market(marketAddr).deficit();
            uint256 reservesAfter = Market(marketAddr).protocolReserves();

            // Deficit should be reduced (fully if reserves >= deficit, partially otherwise)
            assertLt(deficitAfter, deficitBefore, "Deficit should decrease");
            assertLt(reservesAfter, reservesNow, "Reserves should decrease");

            console.log("Deficit before: %s, after: %s USDC", deficitBefore / 1e6, deficitAfter / 1e6);
            console.log("Reserves before: %s, after: %s USDC", reservesNow / 1e6, reservesAfter / 1e6);
        } else {
            // If no deficit (liquidation covered everything), verify eliminateDeficit reverts
            vm.prank(deployer);
            vm.expectRevert("NO_DEFICIT");
            Market(marketAddr).eliminateDeficit();
            console.log("No deficit to eliminate (liquidation covered all debt)");
        }

        console.log("=== Deficit Elimination Test Passed ===");
    }
}
