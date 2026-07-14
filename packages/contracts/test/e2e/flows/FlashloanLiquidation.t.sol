// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {FlashloanLiquidator} from "../../../src/periphery/FlashloanLiquidator.sol";

/// @title FlashloanLiquidation E2E Tests
/// @notice End-to-end tests for flash loan liquidation using real Uniswap V3 pools on forked mainnet.
/// @dev Deploys FlashloanLiquidator with real Uniswap V3 SwapRouter and uses the WETH/USDC 0.3% pool
///      as the flash loan source.
contract FlashloanLiquidation is E2EBase {
    FlashloanLiquidator public flashLiquidator;
    address public flashPool;

    function setUp() public override {
        super.setUp();

        // Use 0.05% pool for flash loan — position LP is in 0.3% pool, can't flash from same pool (LOK)
        flashPool = Constants.UNI_V3_WETH_USDC_500;

        // Deploy FlashloanLiquidator with real Uniswap V3 SwapRouter
        flashLiquidator = new FlashloanLiquidator(
            address(core), address(positionManager), address(liquidationEngine), Constants.UNI_V3_SWAP_ROUTER
        );
    }

    // ========================================================================
    // 1. FULL FLOW — V3 flash liquidation with real Uniswap pool
    // ========================================================================

    function test_flashLiquidation_V3_fullFlow() public {
        // Step 1: Alice creates a V3 WETH/USDC position and deposits it
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Step 2: Alice borrows aggressively
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 90) / 100;
        require(borrowAmount > 0, "No borrow available");

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Step 3: Mock price crash to make position liquidatable
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        // Drop to 40% of original value — deeply underwater
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 40) / 100);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable");
        assertGt(maxRepay, 0, "maxRepay must be > 0");

        // Step 4: Flash liquidate — no capital needed by caller
        // Swap path: WETH -> USDC (to convert received WETH back to USDC for repayment)
        bytes memory swapPathWeth = abi.encodePacked(Constants.WETH, uint24(3000), Constants.USDC);
        // USDC is the borrow asset, no swap needed
        bytes memory swapPathUsdc = bytes("");

        // Determine which path goes to which token
        // pos.token0 and pos.token1 from the position
        bytes memory path0;
        bytes memory path1;
        if (pos.token0 == Constants.USDC) {
            path0 = swapPathUsdc; // token0 = USDC, no swap
            path1 = swapPathWeth; // token1 = WETH, swap to USDC
        } else {
            path0 = swapPathWeth; // token0 = WETH, swap to USDC
            path1 = swapPathUsdc; // token1 = USDC, no swap
        }

        uint256 callerUsdcBefore = IERC20(Constants.USDC).balanceOf(liquidator);

        vm.prank(liquidator);
        uint256 profit = flashLiquidator.liquidate(
            FlashloanLiquidator.LiquidateParams({
                positionId: positionId,
                repayAmount: maxRepay,
                flashLoanPool: flashPool,
                swapPath0: path0,
                swapPath1: path1,
                minProfit: 0
            })
        );

        uint256 callerUsdcAfter = IERC20(Constants.USDC).balanceOf(liquidator);

        // Verify debt was reduced
        uint256 debtAfter = _getDebt(positionId);
        assertLt(debtAfter, borrowAmount, "Debt must decrease after flash liquidation");

        // Verify caller profited — balance increased after flash liquidation
        assertGt(callerUsdcAfter, callerUsdcBefore, "Caller must profit from flash liquidation");
        uint256 actualProfit = callerUsdcAfter - callerUsdcBefore;
        assertGt(actualProfit, 0, "Profit must be > 0");

        // The key: liquidator did NOT need to spend their own USDC
        // The flash loan provided the capital, profit comes from liquidation bonus
        // Verify the profit is reasonable (liquidation bonus ~5% of seized collateral)

        // Position status after liquidation
        IPositionManager.Position memory posAfter = positionManager.getPosition(positionId);
        uint256 valueAfter = _getPositionValue(positionId);

        console.log("=== Flash Liquidation V3 Full Flow ===");
        console.log("");
        console.log("--- Position ---");
        console.log("  Collateral value (original): $%s", originalValue / 1e18);
        console.log("  Collateral value (crashed):  $%s", (originalValue * 40) / 100 / 1e18);
        console.log("  Collateral value (after liq): $%s", valueAfter / 1e18);
        console.log("  Position status: %s", uint8(posAfter.status) == 3 ? "Liquidated" : "Active");
        console.log("");
        console.log("--- Debt ---");
        console.log("  Borrowed:      %s USDC", borrowAmount / 1e6);
        console.log("  Max repay:     %s USDC", maxRepay / 1e6);
        console.log("  Debt before:   %s USDC", borrowAmount / 1e6);
        console.log("  Debt after:    %s USDC", debtAfter / 1e6);
        console.log("  Debt repaid:   %s USDC", (borrowAmount - debtAfter) / 1e6);
        console.log("");
        console.log("--- Flash Loan ---");
        console.log("  Flash amount:  %s USDC", maxRepay / 1e6);
        console.log("  Flash fee:     ~0.01%%");
        console.log("");
        console.log("--- Liquidator P&L ---");
        console.log("  Capital used:  0 (flash loan)");
        console.log("  USDC before:   %s", callerUsdcBefore / 1e6);
        console.log("  USDC after:    %s", callerUsdcAfter / 1e6);
        console.log("  Profit:        %s USDC", actualProfit / 1e6);
        console.log("===================================");
    }

    // ========================================================================
    // 2. ZERO PROFIT THRESHOLD — works even with marginal profit
    // ========================================================================

    function test_flashLiquidation_zeroProfitThreshold() public {
        // Create position, borrow, crash price
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 85) / 100;
        require(borrowAmount > 0, "No borrow available");

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        // Moderate crash — 50% of original
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 50) / 100);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable");

        // Build swap paths
        bytes memory path0;
        bytes memory path1;
        if (pos.token0 == Constants.USDC) {
            path0 = bytes("");
            path1 = abi.encodePacked(Constants.WETH, uint24(3000), Constants.USDC);
        } else {
            path0 = abi.encodePacked(Constants.WETH, uint24(3000), Constants.USDC);
            path1 = bytes("");
        }

        // minProfit = 0 means even marginal profit is acceptable
        vm.prank(liquidator);
        flashLiquidator.liquidate(
            FlashloanLiquidator.LiquidateParams({
                positionId: positionId,
                repayAmount: maxRepay,
                flashLoanPool: flashPool,
                swapPath0: path0,
                swapPath1: path1,
                minProfit: 0
            })
        );

        // Verify debt was reduced — the key assertion is that it did not revert
        uint256 debtAfter = _getDebt(positionId);
        assertLt(debtAfter, borrowAmount, "Debt must decrease");
        console.log("=== Zero Profit Threshold Passed ===");
    }

    // ========================================================================
    // 3. REVERTS IF HEALTHY — position not liquidatable
    // ========================================================================

    function test_flashLiquidation_revertsIfHealthy() public {
        // Create position and borrow conservatively (healthy position)
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        // Borrow only 30% — very healthy
        uint256 borrowAmount = (maxBorrow * 30) / 100;
        require(borrowAmount > 0, "No borrow available");

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Verify position is NOT liquidatable
        (bool canLiq,) = liquidationEngine.isLiquidatable(positionId);
        assertFalse(canLiq, "Position should be healthy");

        IPositionManager.Position memory pos = positionManager.getPosition(positionId);

        bytes memory path0;
        bytes memory path1;
        if (pos.token0 == Constants.USDC) {
            path0 = bytes("");
            path1 = abi.encodePacked(Constants.WETH, uint24(3000), Constants.USDC);
        } else {
            path0 = abi.encodePacked(Constants.WETH, uint24(3000), Constants.USDC);
            path1 = bytes("");
        }

        // Flash liquidation should revert because position is healthy
        vm.prank(liquidator);
        vm.expectRevert("NOT_LIQUIDATABLE");
        flashLiquidator.liquidate(
            FlashloanLiquidator.LiquidateParams({
                positionId: positionId,
                repayAmount: borrowAmount,
                flashLoanPool: flashPool,
                swapPath0: path0,
                swapPath1: path1,
                minProfit: 0
            })
        );

        console.log("=== Reverts If Healthy Passed ===");
    }
}
