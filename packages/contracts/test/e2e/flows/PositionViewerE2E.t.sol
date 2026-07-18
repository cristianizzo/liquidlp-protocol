// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {PositionViewer} from "../../../src/periphery/PositionViewer.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";

/// @title PositionViewerE2E
/// @notice End-to-end tests for PositionViewer read functions with real positions on forked mainnet
contract PositionViewerE2E is E2EBase {
    function setUp() public override {
        super.setUp();
    }

    // ========================================================================
    // 1. getUserPositions — returns correct position data for a user
    // ========================================================================

    function test_getUserPositions() public {
        // Alice creates and deposits a V3 position, then borrows
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 50) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Query via PositionViewer
        PositionViewer.PositionView[] memory positions = positionViewer.getUserPositions(alice);

        assertEq(positions.length, 1, "Alice should have exactly 1 position");
        assertEq(positions[0].id, positionId, "Position ID must match");
        assertEq(positions[0].owner, alice, "Owner must be alice");
        assertGt(positions[0].collateralValue, 0, "Collateral value must be > 0");
        assertGt(positions[0].debt, 0, "Debt must be > 0");
        assertEq(positions[0].debt, borrowAmount, "Debt must match borrow amount");
        assertGt(positions[0].healthFactor, 1e18, "HF must be > 1.0 (healthy)");
        assertGt(positions[0].maxBorrow, 0, "Max borrow must be > 0");

        console.log("=== getUserPositions Passed ===");
        console.log("  Position ID:      %s", positions[0].id);
        console.log("  Collateral value: $%s", positions[0].collateralValue / 1e18);
        console.log("  Debt:             %s USDC", positions[0].debt / 1e6);
        console.log("  Health factor:    %s", positions[0].healthFactor / 1e16);
    }

    // ========================================================================
    // 2. getPositionView — returns value, debt, HF, token info
    // ========================================================================

    function test_getPositionView() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 40) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Query single position view
        PositionViewer.PositionView memory view_ = positionViewer.getPositionView(positionId);

        assertEq(view_.id, positionId, "Position ID must match");
        assertEq(view_.owner, alice, "Owner must be alice");
        assertGt(view_.collateralValue, 0, "Collateral value must be > 0");
        assertGt(view_.debt, 0, "Debt must be > 0");
        assertGt(view_.healthFactor, 1e18, "HF must be > 1.0");
        assertGt(view_.maxBorrow, 0, "Max borrow must be > 0");
        assertGt(view_.availableToBorrow, 0, "Should have remaining borrow capacity");

        // LP token should be a valid address (V3 NFT manager)
        assertEq(view_.lpToken, Constants.UNI_V3_NFT_MANAGER, "LP token must be V3 NFT manager");
        assertEq(view_.tokenId, tokenId, "Token ID must match the V3 NFT");

        // Cross-check with direct contract calls
        uint256 directValue = _getPositionValue(positionId);
        uint256 directDebt = _getDebt(positionId);
        uint256 directHF = _getHealthFactor(positionId);

        assertEq(view_.collateralValue, directValue, "Collateral value must match direct call");
        assertEq(view_.debt, directDebt, "Debt must match direct call");
        assertEq(view_.healthFactor, directHF, "HF must match direct call");

        console.log("=== getPositionView Passed ===");
        console.log("  Value:     $%s", view_.collateralValue / 1e18);
        console.log("  Debt:      %s USDC", view_.debt / 1e6);
        console.log("  HF:        %s", view_.healthFactor / 1e16);
        console.log("  Available: %s USDC", view_.availableToBorrow / 1e6);
    }

    // ========================================================================
    // 3. getMarketView — returns supply, borrow, rates for a market
    // ========================================================================

    function test_getMarketView() public {
        // Bob has already supplied to the market in setUp via E2EBase
        // Alice borrows to generate utilization
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 60) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Query market view
        PositionViewer.MarketView memory mv = positionViewer.getMarketView(ethUsdcMarketId);

        assertEq(mv.id, ethUsdcMarketId, "Market ID must match");
        assertEq(mv.borrowAsset, Constants.USDC, "Borrow asset must be USDC");
        assertGt(mv.totalSupply, 0, "Total supply must be > 0");
        assertGt(mv.totalBorrow, 0, "Total borrow must be > 0 after borrowing");
        assertGt(mv.utilization, 0, "Utilization must be > 0 after borrowing");
        assertGt(mv.borrowRateAPR, 0, "Borrow rate must be > 0");
        assertEq(mv.maxLtv, 6500, "Max LTV must be 6500 (65%)");

        // Utilization sanity check: totalBorrow <= totalSupply
        assertLe(mv.totalBorrow, mv.totalSupply, "Borrow cannot exceed supply");

        console.log("=== getMarketView Passed ===");
        console.log("  Total supply:  %s USDC", mv.totalSupply / 1e6);
        console.log("  Total borrow:  %s USDC", mv.totalBorrow / 1e6);
        console.log("  Utilization:   %s%%", mv.utilization / 1e16);
        console.log("  Supply APR:    %s%%", mv.supplyRateAPR / 1e16);
        console.log("  Borrow APR:    %s%%", mv.borrowRateAPR / 1e16);
        console.log("  Max LTV:       %s", mv.maxLtv);
    }

    // ========================================================================
    // 4. viewAfterLiquidation — viewer returns correct post-liquidation state
    // ========================================================================

    function test_viewAfterLiquidation() public {
        // Step 1: Alice deposits and borrows aggressively
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 90) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Step 2: Crash price to make position liquidatable
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        uint256 crashedValue = (originalValue * 40) / 100; // 60% drop
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, crashedValue);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable");

        // Step 3: Liquidate directly (not flash)
        address v3MarketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(v3MarketAddr, maxRepay);
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp, 0, 0);
        vm.stopPrank();

        // Step 4: Verify viewer returns correct post-liquidation state
        PositionViewer.PositionView memory viewAfter = positionViewer.getPositionView(positionId);

        // Debt should be reduced or zero
        assertLt(viewAfter.debt, borrowAmount, "Debt must be reduced after liquidation");

        // Cross-check with direct calls
        uint256 directDebt = _getDebt(positionId);
        assertEq(viewAfter.debt, directDebt, "Viewer debt must match direct call post-liquidation");

        // Status should reflect liquidation (status 3 = LIQUIDATED for full, or still active for partial)
        IPositionManager.Position memory posAfter = positionManager.getPosition(positionId);
        assertEq(viewAfter.status, uint8(posAfter.status), "Status must match position state");

        console.log("=== viewAfterLiquidation Passed ===");
        console.log("  Debt before:  %s USDC", borrowAmount / 1e6);
        console.log("  Debt after:   %s USDC", viewAfter.debt / 1e6);
        console.log("  Status:       %s", viewAfter.status == 3 ? "LIQUIDATED" : "Active");
        console.log("  HF after:     %s", viewAfter.healthFactor / 1e16);
    }

    // ========================================================================
    // 5. multiplePositions_view — multiple positions returned correctly
    // ========================================================================

    function test_multiplePositions_view() public {
        // Step 1: Alice creates and deposits two V3 positions
        uint256 tokenId1 = _createV3Position(alice, 0.5 ether, 1000e6);
        uint256 positionId1 = _depositV3(alice, tokenId1);

        uint256 tokenId2 = _createV3Position(alice, 0.3 ether, 600e6);
        uint256 positionId2 = _depositV3(alice, tokenId2);

        vm.roll(block.number + 2);

        // Borrow on position 1 only
        uint256 maxBorrow1 = lendingEngine.getMaxBorrow(positionId1);
        vm.prank(alice);
        lendingEngine.borrow(positionId1, (maxBorrow1 * 30) / 100);

        // Step 2: Query all positions
        PositionViewer.PositionView[] memory positions = positionViewer.getUserPositions(alice);

        assertEq(positions.length, 2, "Alice should have exactly 2 positions");

        // Verify both positions are present (order may vary)
        bool found1 = false;
        bool found2 = false;
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].id == positionId1) {
                found1 = true;
                assertGt(positions[i].debt, 0, "Position 1 should have debt");
                assertEq(positions[i].owner, alice, "Owner must be alice");
                assertGt(positions[i].collateralValue, 0, "Position 1 value must be > 0");
            }
            if (positions[i].id == positionId2) {
                found2 = true;
                assertEq(positions[i].debt, 0, "Position 2 should have no debt");
                assertEq(positions[i].owner, alice, "Owner must be alice");
                assertGt(positions[i].collateralValue, 0, "Position 2 value must be > 0");
            }
        }
        assertTrue(found1, "Position 1 must be in results");
        assertTrue(found2, "Position 2 must be in results");

        console.log("=== multiplePositions_view Passed ===");
        console.log("  Position 1 ID:    %s", positionId1);
        console.log("  Position 1 value: $%s", positions[0].collateralValue / 1e18);
        console.log("  Position 2 ID:    %s", positionId2);
        console.log("  Position 2 value: $%s", positions[1].collateralValue / 1e18);
    }
}
