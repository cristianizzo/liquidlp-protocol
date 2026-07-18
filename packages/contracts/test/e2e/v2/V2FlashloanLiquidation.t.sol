// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {FlashloanLiquidator} from "../../../src/periphery/FlashloanLiquidator.sol";
import {IUniswapV2Pair} from "../../../src/interfaces/external/IUniswapV2.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";

/// @title V2FlashloanLiquidation
/// @notice Flash loan liquidation tests with real V2 LP positions on forked mainnet
contract V2FlashloanLiquidation is E2EBase {
    FlashloanLiquidator public flashLiquidator;
    address public flashPool;
    uint256 public v2MarketId;

    function setUp() public override {
        super.setUp();

        // Create a V2 market (the default ethUsdcMarketId is V3)
        vm.startPrank(deployer);
        (v2MarketId,) = marketFactory.createMarket(
            ILPAdapter.LPType.UniswapV2, Constants.USDC, 6500, 7500, 500, 10_000_000e6, 0, 0, "volatile"
        );
        vm.stopPrank();

        // Fund Bob with extra USDC and supply to V2 market
        _fundUsdc(bob, 50_000e6);
        address v2MarketAddr = core.markets(v2MarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(v2MarketAddr, 50_000e6);
        IMarket(v2MarketAddr).supply(50_000e6);
        vm.stopPrank();

        // Use 0.05% pool for flash loan (position LP is V2, no conflict)
        flashPool = Constants.UNI_V3_WETH_USDC_500;

        // Deploy FlashloanLiquidator with real Uniswap V3 SwapRouter
        flashLiquidator = new FlashloanLiquidator(
            address(core),
            address(positionManager),
            address(liquidationEngine),
            Constants.UNI_V3_SWAP_ROUTER,
            Constants.UNI_V3_FACTORY
        );

        // Wire FeeCollector to LiquidationEngine
        vm.startPrank(deployer);
        liquidationEngine.setFeeCollector(address(feeCollector));
        vm.stopPrank();
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    /// @dev Build swap paths based on token ordering for the V2 WETH/USDC pair
    function _buildSwapPaths(IPositionManager.Position memory pos)
        internal
        pure
        returns (bytes memory path0, bytes memory path1)
    {
        bytes memory swapPathWeth = abi.encodePacked(Constants.WETH, uint24(3000), Constants.USDC);

        if (pos.token0 == Constants.USDC) {
            path0 = bytes(""); // token0 = USDC, no swap needed
            path1 = swapPathWeth; // token1 = WETH, swap to USDC
        } else {
            path0 = swapPathWeth; // token0 = WETH, swap to USDC
            path1 = bytes(""); // token1 = USDC, no swap needed
        }
    }

    /// @dev Create a V2 position, deposit, and borrow a percentage of max borrow
    function _setupV2PositionWithBorrow(uint256 borrowPct) internal returns (uint256 positionId, uint256 borrowAmount) {
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);

        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        borrowAmount = (maxBorrow * borrowPct) / 100;
        require(borrowAmount > 0, "No borrow available");

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);
    }

    /// @dev Crash position value via oracle mock (60% drop)
    function _crashV2Position(uint256 positionId) internal {
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        uint256 crashedValue = (originalValue * 40) / 100; // 60% drop
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, crashedValue);
    }

    // ========================================================================
    // 1. FULL FLASH LIQUIDATION — V2 position
    // ========================================================================

    function test_flashloanLiquidation_V2() public {
        // Step 1: Create V2 position and borrow 90% of max
        (uint256 positionId, uint256 borrowAmount) = _setupV2PositionWithBorrow(90);

        uint256 debtBefore = _getDebt(positionId);
        assertGt(debtBefore, 0, "Should have debt");

        // Step 2: Crash ETH price to make position liquidatable
        _crashV2Position(positionId);

        uint256 hfAfterCrash = _getHealthFactor(positionId);
        assertLt(hfAfterCrash, 1e18, "Should be liquidatable after crash");

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable");
        assertGt(maxRepay, 0, "maxRepay must be > 0");

        // Step 3: Flash liquidate
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        (bytes memory path0, bytes memory path1) = _buildSwapPaths(pos);

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

        // Step 4: Verify debt was reduced
        uint256 debtAfter = _getDebt(positionId);
        assertLt(debtAfter, debtBefore, "Debt must decrease after flash liquidation");

        console.log("=== V2 Flash Liquidation Passed ===");
        console.log("  Debt before: %s USDC", debtBefore / 1e6);
        console.log("  Debt after:  %s USDC", debtAfter / 1e6);
        console.log("  Repaid:      %s USDC", (debtBefore - debtAfter) / 1e6);
    }

    // ========================================================================
    // 2. PROFIT CHECK — verify liquidator earns USDC profit
    // ========================================================================

    function test_flashloanLiquidation_V2_profitCheck() public {
        // Step 1: Create V2 position and borrow 90% of max
        (uint256 positionId,) = _setupV2PositionWithBorrow(90);

        // Step 2: Crash position value
        _crashV2Position(positionId);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable");

        // Step 3: Record liquidator balance before
        uint256 liquidatorUsdcBefore = IERC20(Constants.USDC).balanceOf(liquidator);

        // Step 4: Flash liquidate
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        (bytes memory path0, bytes memory path1) = _buildSwapPaths(pos);

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

        // Step 5: Verify liquidator received profit
        uint256 liquidatorUsdcAfter = IERC20(Constants.USDC).balanceOf(liquidator);
        uint256 actualProfit = liquidatorUsdcAfter - liquidatorUsdcBefore;

        assertGt(actualProfit, 0, "Liquidator must receive profit");
        assertEq(actualProfit, profit, "Profit return value must match balance delta");
        assertGt(liquidatorUsdcAfter, liquidatorUsdcBefore, "Liquidator USDC balance must increase");

        console.log("=== V2 Flash Liquidation Profit Check Passed ===");
        console.log("  Liquidator USDC before: %s", liquidatorUsdcBefore / 1e6);
        console.log("  Liquidator USDC after:  %s", liquidatorUsdcAfter / 1e6);
        console.log("  Profit:                 %s USDC", actualProfit / 1e6);
    }

    // ========================================================================
    // 3. REVERT — healthy V2 position cannot be flash-liquidated
    // ========================================================================

    function test_revert_healthyV2_cannotFlashloanLiquidate() public {
        // Step 1: Create V2 position and borrow conservatively (30%)
        (uint256 positionId,) = _setupV2PositionWithBorrow(30);

        // Step 2: Verify position is healthy
        uint256 hf = _getHealthFactor(positionId);
        assertGt(hf, 1e18, "Position should be healthy");

        (bool canLiq,) = liquidationEngine.isLiquidatable(positionId);
        assertFalse(canLiq, "Position should NOT be liquidatable");

        // Step 3: Attempt flash liquidation — should revert
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        (bytes memory path0, bytes memory path1) = _buildSwapPaths(pos);

        uint256 debt = _getDebt(positionId);

        vm.prank(liquidator);
        vm.expectRevert("NOT_LIQUIDATABLE");
        flashLiquidator.liquidate(
            FlashloanLiquidator.LiquidateParams({
                positionId: positionId,
                repayAmount: debt,
                flashLoanPool: flashPool,
                swapPath0: path0,
                swapPath1: path1,
                minProfit: 0
            })
        );

        console.log("=== Healthy V2 Revert Passed ===");
    }
}
