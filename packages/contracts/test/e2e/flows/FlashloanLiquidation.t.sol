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

        // Wire FeeCollector to LiquidationEngine so protocol earns liquidation fees
        vm.startPrank(deployer);
        liquidationEngine.setFeeCollector(address(feeCollector));
        feeCollector.setLiquidationFee(500); // 5% of liquidator bonus goes to protocol
        vm.stopPrank();
    }

    // ========================================================================
    // 1. FULL FLOW — V3 flash liquidation with real Uniswap pool
    // ========================================================================

    function test_flashLiquidation_V3_fullFlow() public {
        // === BEFORE STATE ===
        uint256 aliceUsdcStart = IERC20(Constants.USDC).balanceOf(alice);
        uint256 aliceWethStart = IERC20(Constants.WETH).balanceOf(alice);
        uint256 liquidatorUsdcStart = IERC20(Constants.USDC).balanceOf(liquidator);
        uint256 protocolUsdcStart = IERC20(Constants.USDC).balanceOf(address(feeCollector));
        uint256 protocolWethStart = IERC20(Constants.WETH).balanceOf(address(feeCollector));
        address marketAddr = core.markets(ethUsdcMarketId);
        uint256 marketUsdcStart = IERC20(Constants.USDC).balanceOf(marketAddr);

        // Step 1: Alice creates a V3 WETH/USDC position and deposits it
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 aliceUsdcAfterDeposit = IERC20(Constants.USDC).balanceOf(alice);
        uint256 aliceWethAfterDeposit = IERC20(Constants.WETH).balanceOf(alice);

        // Step 2: Alice borrows aggressively
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 90) / 100;
        require(borrowAmount > 0, "No borrow available");

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        uint256 aliceUsdcAfterBorrow = IERC20(Constants.USDC).balanceOf(alice);

        // Step 3: Mock price crash to make position liquidatable
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        uint256 crashedValue = (originalValue * 40) / 100;
        // Drop to 40% of original value — deeply underwater
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, crashedValue);

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

        // === AFTER STATE ===
        IPositionManager.Position memory posAfter = positionManager.getPosition(positionId);
        uint256 valueAfter = _getPositionValue(positionId);
        uint256 aliceUsdcEnd = IERC20(Constants.USDC).balanceOf(alice);
        uint256 aliceWethEnd = IERC20(Constants.WETH).balanceOf(alice);
        uint256 protocolUsdcEnd = IERC20(Constants.USDC).balanceOf(address(feeCollector));
        uint256 protocolWethEnd = IERC20(Constants.WETH).balanceOf(address(feeCollector));
        uint256 marketUsdcEnd = IERC20(Constants.USDC).balanceOf(marketAddr);

        console.log("=========================================================");
        console.log("       FLASH LIQUIDATION - FULL METRICS REPORT");
        console.log("=========================================================");
        console.log("");
        console.log("--- BORROWER (Alice) ---");
        console.log("  WETH deposited into LP:   1.0 ETH");
        console.log("  USDC deposited into LP:   2,000 USDC");
        console.log("  USDC borrowed:            %s USDC", borrowAmount / 1e6);
        console.log("  USDC balance start:       %s", aliceUsdcStart / 1e6);
        console.log("  USDC balance after borrow:%s", aliceUsdcAfterBorrow / 1e6);
        console.log("  USDC balance end:         %s", aliceUsdcEnd / 1e6);
        console.log("  WETH balance start:       %s", aliceWethStart / 1e15);
        console.log("  WETH balance end:         %s", aliceWethEnd / 1e15);
        console.log("  Position status:          %s", uint8(posAfter.status) == 3 ? "LIQUIDATED" : "Active");
        console.log("  Debt remaining:           %s USDC", debtAfter / 1e6);
        console.log("");
        console.log("--- POSITION ---");
        console.log("  Value (original):         $%s", originalValue / 1e18);
        console.log("  Value (after crash 60%%):  $%s", crashedValue / 1e18);
        console.log("  Value (after liquidation): $%s", valueAfter / 1e18);
        console.log("  Health factor at crash:    < 1.0 (liquidatable)");
        console.log("");
        console.log("--- LIQUIDATOR (Bot/MEV) ---");
        console.log("  Capital required:         0 (flash loan)");
        console.log("  Flash loan amount:        %s USDC", maxRepay / 1e6);
        console.log("  Flash loan fee:           ~0.01%%");
        console.log("  USDC before:              %s", callerUsdcBefore / 1e6);
        console.log("  USDC after:               %s", callerUsdcAfter / 1e6);
        console.log("  PROFIT:                   %s USDC", actualProfit / 1e6);
        console.log("");
        console.log("--- PROTOCOL (FeeCollector) ---");
        console.log("  USDC fees earned:         %s", (protocolUsdcEnd - protocolUsdcStart) / 1e6);
        console.log("  WETH fees earned:         %s", (protocolWethEnd - protocolWethStart) / 1e15);
        console.log("");
        console.log("--- LENDING MARKET ---");
        console.log("  USDC in market start:     %s", marketUsdcStart / 1e6);
        console.log("  USDC in market end:       %s", marketUsdcEnd / 1e6);
        console.log("  Debt repaid to market:    %s USDC", (borrowAmount - debtAfter) / 1e6);
        console.log("  Lenders made whole:       %s", marketUsdcEnd >= marketUsdcStart ? "YES" : "NO");
        console.log("");
        console.log("=========================================================");
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
