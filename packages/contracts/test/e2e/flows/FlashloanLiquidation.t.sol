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
            address(core),
            address(positionManager),
            address(liquidationEngine),
            Constants.UNI_V3_SWAP_ROUTER,
            Constants.UNI_V3_FACTORY
        );

        // Wire FeeCollector to LiquidationEngine so protocol earns liquidation fees
        vm.startPrank(deployer);
        liquidationEngine.setFeeCollector(address(feeCollector));
        // Default liquidationFeeBps = 7000 (70% of bonus → protocol, 30% → liquidator)
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
        // Borrowing must credit Alice exactly borrowAmount USDC (only the borrow happened since deposit).
        assertEq(
            aliceUsdcAfterBorrow, aliceUsdcAfterDeposit + borrowAmount, "borrow must credit Alice exactly borrowAmount"
        );

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
        // The value returned by liquidate() must match the observed USDC gain, and be positive.
        assertGt(profit, 0, "liquidate() must report positive profit");
        assertEq(profit, actualProfit, "returned profit must equal liquidator's USDC gain");
        // Capital-free: the liquidator never dips below its starting USDC across the whole flow.
        assertGe(callerUsdcAfter, liquidatorUsdcStart, "capital-free liquidation: no net USDC outlay");

        // The key: liquidator did NOT need to spend their own USDC
        // The flash loan provided the capital, profit comes from liquidation bonus
        // Verify the profit is reasonable (liquidation bonus ~5% of seized collateral)

        // === AFTER STATE ===
        IPositionManager.Position memory posAfter = positionManager.getPosition(positionId);
        uint256 valueAfter = _getPositionValue(positionId);
        uint256 aliceUsdcEnd = IERC20(Constants.USDC).balanceOf(alice);
        uint256 aliceWethEnd = IERC20(Constants.WETH).balanceOf(alice);
        // Liquidation returns any residual collateral to the borrower — Alice's WETH can only
        // go up (or stay flat if fully seized) relative to her post-deposit balance.
        assertGe(aliceWethEnd, aliceWethAfterDeposit, "borrower must not lose WETH beyond what was deposited");
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

    // ========================================================================
    // HELPER: Run a full liquidation scenario and log all metrics
    // ========================================================================

    function _runScenario(string memory name, uint256 borrowPct, uint256 dumpAmountEth) internal {
        address marketAddr = core.markets(ethUsdcMarketId);
        uint256 protocolUsdcBefore = IERC20(Constants.USDC).balanceOf(address(feeCollector));
        uint256 protocolWethBefore = IERC20(Constants.WETH).balanceOf(address(feeCollector));
        uint256 marketUsdcBefore = IERC20(Constants.USDC).balanceOf(marketAddr);
        uint256 liquidatorUsdcBefore = IERC20(Constants.USDC).balanceOf(liquidator);

        // Deposit and borrow
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * borrowPct) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        uint256 originalValue = _getPositionValue(positionId);
        uint256 hfBefore = _getHealthFactor(positionId);

        // Real price crash: dump ETH into pool + mock Chainlink to match
        int256 crashedEthPrice = _crashEthPrice(dumpAmountEth);

        uint256 crashedValue = _getPositionValue(positionId);
        uint256 hfAfterCrash = _getHealthFactor(positionId);
        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        require(canLiq, "Not liquidatable - increase dumpAmountEth");

        // Build swap paths
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

        // Flash liquidate
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

        // Measure results
        uint256 debtAfter = _getDebt(positionId);
        uint256 liquidatorUsdcAfter = IERC20(Constants.USDC).balanceOf(liquidator);
        uint256 protocolUsdcEarned = IERC20(Constants.USDC).balanceOf(address(feeCollector)) - protocolUsdcBefore;
        uint256 protocolWethEarned = IERC20(Constants.WETH).balanceOf(address(feeCollector)) - protocolWethBefore;
        uint256 marketUsdcAfter = IERC20(Constants.USDC).balanceOf(marketAddr);
        uint256 liquidatorProfit = liquidatorUsdcAfter - liquidatorUsdcBefore;
        IPositionManager.Position memory posAfter = positionManager.getPosition(positionId);
        string memory status = uint8(posAfter.status) == 3 ? "LIQUIDATED" : "Active (partial)";

        // Log
        console.log("");
        console.log("=========================================================");
        console.log("  SCENARIO: %s", name);
        console.log("=========================================================");
        console.log("  Borrow:              %s%% of max LTV", borrowPct);
        console.log("  ETH dump:            %s ETH", dumpAmountEth / 1e18);
        console.log("  Crashed ETH price:   $%s (8 dec)", uint256(crashedEthPrice));
        console.log("");
        console.log("  Position value:      $%s -> $%s", originalValue / 1e18, crashedValue / 1e18);
        console.log("  Health factor:       %s -> %s", hfBefore / 1e16, hfAfterCrash / 1e16);
        console.log("  Borrowed:            %s USDC", borrowAmount / 1e6);
        console.log("  Max repay:           %s USDC", maxRepay / 1e6);
        console.log("  Debt after:          %s USDC", debtAfter / 1e6);
        console.log("  Position status:     %s", status);
        console.log("");
        uint256 protocolWethUsd = (protocolWethEarned * uint256(crashedEthPrice)) / 1e8 / 1e18;
        uint256 protocolTotalUsd = protocolUsdcEarned / 1e6 + protocolWethUsd;
        console.log("  Protocol USDC fee:   %s USDC", protocolUsdcEarned / 1e6);
        console.log("  Protocol WETH fee:   0.%s ETH (~$%s)", protocolWethEarned / 1e14, protocolWethUsd);
        console.log("  Protocol total:      ~$%s", protocolTotalUsd);
        console.log("  Liquidator profit:   %s USDC", liquidatorProfit / 1e6);
        if (protocolTotalUsd + liquidatorProfit / 1e6 > 0) {
            uint256 totalBonus = protocolTotalUsd + liquidatorProfit / 1e6;
            console.log("  Protocol share:      %s%% of bonus", (protocolTotalUsd * 100) / totalBonus);
            console.log("  Liquidator share:    %s%% of bonus", (liquidatorProfit / 1e6 * 100) / totalBonus);
        }
        console.log("  Market USDC:         %s -> %s", marketUsdcBefore / 1e6, marketUsdcAfter / 1e6);
        bool safe = (marketUsdcAfter + debtAfter) >= marketUsdcBefore;
        console.log("  Lenders safe:        %s", safe ? "YES" : "NO");
        console.log("=========================================================");

        // Clear mocks for next scenario
        vm.clearMockedCalls();
        vm.startPrank(deployer);
        priceFeedRegistry.setMaxStaleness(86_400);
        vm.stopPrank();
    }

    // ========================================================================
    // 4. PARTIAL LIQUIDATION — mild crash, 50% cap, position stays active
    // ========================================================================

    function test_scenario_partialLiquidation() public {
        // 95% borrow, moderate ETH dump → HF drops below 1, partial liquidation
        _runScenario("PARTIAL LIQUIDATION", 95, 4100 ether);
    }

    // ========================================================================
    // 5. FULL LIQUIDATION — large dump, position fully liquidated
    // ========================================================================

    function test_scenario_fullLiquidation() public {
        // 95% borrow, larger ETH dump → underwater, full liquidation
        _runScenario("FULL LIQUIDATION", 95, 4200 ether);
    }

    // ========================================================================
    // 6. BIG MARKET CRASH — massive dump, severe underwater
    // ========================================================================

    function test_scenario_bigMarketCrash() public {
        // 95% borrow, big ETH dump → severe crash
        _runScenario("BIG MARKET CRASH", 95, 4250 ether);
    }

    // ========================================================================
    // 7. AGGRESSIVE BORROW — 95% LTV, moderate dump
    // ========================================================================

    function test_scenario_aggressiveBorrow() public {
        // 95% borrow, moderate dump → barely liquidatable
        _runScenario("AGGRESSIVE BORROW", 95, 4100 ether);
    }

    // ========================================================================
    // 8. SECURITY — fake flash pool (not from Uniswap V3 factory) is rejected
    // ========================================================================

    function test_revert_fakeFlashPool() public {
        // Setup a liquidatable position
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 crashedValue = (_getPositionValue(positionId) * 40) / 100;
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, crashedValue);

        // Deploy a fake pool with correct tokens/fee but not registered in the V3 factory
        FakeFlashPoolLiq fake = new FakeFlashPoolLiq(Constants.USDC, Constants.WETH);

        bytes memory swapPathWeth = abi.encodePacked(Constants.WETH, uint24(3000), Constants.USDC);

        vm.prank(liquidator);
        vm.expectRevert("INVALID_FLASH_POOL");
        flashLiquidator.liquidate(
            FlashloanLiquidator.LiquidateParams({
                positionId: positionId,
                repayAmount: 1000e6,
                flashLoanPool: address(fake),
                swapPath0: "",
                swapPath1: swapPathWeth,
                minProfit: 0
            })
        );
    }
}

/// @notice Minimal fake pool that returns correct token0/token1/fee but isn't in the factory
contract FakeFlashPoolLiq {
    address public token0;
    address public token1;

    constructor(address _t0, address _t1) {
        token0 = _t0 < _t1 ? _t0 : _t1;
        token1 = _t0 < _t1 ? _t1 : _t0;
    }

    function fee() external pure returns (uint24) {
        return 3000;
    }

    function flash(address, uint256, uint256, bytes calldata) external pure {
        revert("SHOULD_NOT_REACH");
    }
}
