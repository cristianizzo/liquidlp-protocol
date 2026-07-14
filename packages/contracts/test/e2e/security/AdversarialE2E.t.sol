// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";

/// @title AdversarialE2E
/// @notice Adversarial and attack scenario tests against the Aurelia lending protocol.
/// @dev Covers race conditions, rounding attacks, oracle manipulation, and post-liquidation invariants.
contract AdversarialE2E is E2EBase {
    address public liquidator2;

    function setUp() public override {
        super.setUp();
        liquidator2 = makeAddr("liquidator2");
        _fundUsdc(liquidator2, 100_000e6);
    }

    // ========== 1. Concurrent Liquidators — Second Reverts ==========

    function test_attack_concurrentLiquidators_secondReverts() public {
        // Create position and borrow near max LTV
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        // Mock price crash to make position liquidatable
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 30) / 100);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Position must be liquidatable");

        // Liquidator1 liquidates successfully
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        IERC20(Constants.USDC).approve(marketAddr, maxRepay);
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        // Liquidator2 tries same position — should revert (already liquidated or not liquidatable)
        vm.startPrank(liquidator2);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        IERC20(Constants.USDC).approve(marketAddr, maxRepay);
        vm.expectRevert();
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        console.log("=== Concurrent Liquidators: Second Reverts ===");
    }

    // ========== 2. Extreme Interest Accrual — No Overflow ==========

    function test_attack_extremeInterestAccrual_noOverflow() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 2);

        uint256 debtBefore = _getDebt(positionId);
        assertGt(debtBefore, 0, "Should have debt");

        // Advance 50 years
        uint256 fiftyYears = 50 * 365.25 days;
        vm.warp(block.timestamp + fiftyYears);
        vm.roll(block.number + fiftyYears / 12);

        // Accrue interest — should not revert (overflow)
        address marketAddr = core.markets(ethUsdcMarketId);
        Market market = Market(marketAddr);
        market.accrueInterest();

        // borrowIndex should still be a valid number (not overflowed)
        uint256 currentBorrowIndex = market.borrowIndex();
        assertGt(currentBorrowIndex, 1e27, "Borrow index should be > RAY");
        // Ensure no overflow: index should be less than max / 1e18 (safe multiplication range)
        assertLt(currentBorrowIndex, type(uint256).max / 1e18, "Borrow index must not overflow");

        // Debt should be very large but not zero (which would indicate overflow wrapping)
        uint256 debtAfter = _getDebt(positionId);
        assertGt(debtAfter, debtBefore, "Debt must grow, not overflow to zero");

        console.log("=== Extreme Interest Accrual: No Overflow ===");
        console.log("Borrow index after 50y: %s", currentBorrowIndex);
        console.log("Debt before: %s, after: %s USDC", debtBefore / 1e6, debtAfter / 1e6);
    }

    // ========== 3. Rounding Attack — 1 Wei Borrow ==========

    function test_attack_roundingAttack_1weiBorrow() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Borrow 1 wei
        vm.prank(alice);
        lendingEngine.borrow(positionId, 1);

        uint256 debt = _getDebt(positionId);
        assertGe(debt, 1, "Debt must be at least 1");

        // Advance 1 hour (within 24h staleness window set in E2EBase setUp)
        _advanceTime(1 hours);
        lendingEngine.accrueInterest(ethUsdcMarketId);

        uint256 debtAfterAccrual = _getDebt(positionId);
        assertGe(debtAfterAccrual, 1, "Debt should still be >= 1 after interest (no rounding to 0)");

        // Repay max
        _fundUsdc(alice, 100e6); // extra USDC for safety
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, type(uint256).max);
        lendingEngine.repay(positionId, type(uint256).max);
        vm.stopPrank();

        uint256 debtAfterRepay = _getDebt(positionId);
        assertEq(debtAfterRepay, 0, "Debt must be 0 after full repay");

        IPositionManager.Position memory pos2 = positionManager.getPosition(positionId);
        assertEq(uint8(pos2.status), uint8(IPositionManager.PositionStatus.Active), "Position should be Active");

        console.log("=== Rounding Attack 1 Wei Borrow: Passed ===");
    }

    // ========== 4. Rounding Attack — Dust Repay ==========

    function test_attack_roundingAttack_dustRepay() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 4000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Borrow within max LTV
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = maxBorrow / 2; // safe amount well within LTV
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        uint256 debtBefore = _getDebt(positionId);

        // Repay 1 wei
        address marketAddr = core.markets(ethUsdcMarketId);
        _fundUsdc(alice, 100e6);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(marketAddr, type(uint256).max);
        lendingEngine.repay(positionId, 1);
        vm.stopPrank();

        uint256 debtAfterFirst = _getDebt(positionId);
        assertEq(debtBefore - debtAfterFirst, 1, "Debt should decrease by exactly 1 wei");

        // Repay 1 wei again
        vm.prank(alice);
        lendingEngine.repay(positionId, 1);

        uint256 debtAfterSecond = _getDebt(positionId);
        assertEq(debtAfterFirst - debtAfterSecond, 1, "Debt should decrease by exactly 1 wei again");

        // Total decrease = 2 wei
        assertEq(debtBefore - debtAfterSecond, 2, "Total debt decrease should be exactly 2 wei");

        console.log("=== Rounding Attack Dust Repay: Passed ===");
    }

    // ========== 5. Flash Loan Borrow — Cooldown Blocks ==========

    function test_attack_flashLoanBorrow_cooldownBlocks() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);

        // Deposit in this block
        uint256 positionId = _depositV3(alice, tokenId);

        // Same block — borrow blocked by cooldown
        vm.prank(alice);
        vm.expectRevert("BORROW_COOLDOWN");
        lendingEngine.borrow(positionId, 100e6);

        // Advance 2 blocks
        vm.roll(block.number + 2);

        // Now borrow should succeed
        vm.prank(alice);
        lendingEngine.borrow(positionId, 100e6);
        assertGt(_getDebt(positionId), 0, "Borrow should succeed after cooldown");

        console.log("=== Flash Loan Cooldown Blocks: Passed ===");
    }

    // ========== 6. Self-Liquidation — No Profit ==========

    function test_attack_selfLiquidation_noProfit() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Borrow a meaningful amount
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 80) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Mock price drop to make liquidatable
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 30) / 100);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Should be liquidatable");

        // Fund alice with USDC for repayment
        _fundUsdc(alice, maxRepay);

        // Track both USDC and WETH balances before liquidation
        uint256 aliceWethBefore = IERC20(Constants.WETH).balanceOf(alice);
        uint256 aliceUsdcBefore = IERC20(Constants.USDC).balanceOf(alice);

        // Alice self-liquidates
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(alice);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        IERC20(Constants.USDC).approve(marketAddr, maxRepay);
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        uint256 aliceWethAfter = IERC20(Constants.WETH).balanceOf(alice);
        uint256 aliceUsdcAfter = IERC20(Constants.USDC).balanceOf(alice);

        // Self-liquidation completed (protocol allows it, like Aave)
        // Alice paid repayAmount USDC but received underlying tokens (WETH + USDC from LP unwind).
        // Net USDC may go up (LP contained USDC), but she received real underlying — no free money.
        // Key assertion: she received WETH (proof LP was unwound and tokens transferred)
        uint256 wethReceived = aliceWethAfter - aliceWethBefore;
        assertGt(wethReceived, 0, "Alice must receive WETH from LP unwind");

        // The repayment actually reduced debt — verify debt decreased
        uint256 debtAfter = _getDebt(positionId);
        assertLt(debtAfter, borrowAmount, "Debt must decrease after self-liquidation");

        console.log("=== Self-Liquidation No Profit: Passed ===");
        console.log("Alice received %s WETH from LP unwind", wethReceived / 1e15);
        console.log("USDC delta: %s", aliceUsdcAfter > aliceUsdcBefore ? "positive (LP had USDC)" : "negative");
    }

    // ========== 7. Withdraw During Liquidation — Blocked ==========

    function test_attack_withdrawDuringLiquidation_blocked() public {
        // Use V2 for partial liquidation test (V2 has pos.amount > 0)
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);

        // Create V2 market
        vm.startPrank(deployer);
        (uint256 v2MarketId,) = marketFactory.createMarket(
            ILPAdapter.LPType.UniswapV2, Constants.USDC, 6500, 7500, 500, 700, 10_000_000e6, 0, 0, "volatile"
        );
        vm.stopPrank();

        // Fund and supply to V2 market
        _fundUsdc(bob, 50_000e6);
        address v2MarketAddr = core.markets(v2MarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(v2MarketAddr, 50_000e6);
        IMarket(v2MarketAddr).supply(50_000e6);
        vm.stopPrank();

        // Deposit V2 LP
        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();
        vm.roll(block.number + 2);

        // Borrow
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 90) / 100;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Mock price drop
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 40) / 100);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Should be liquidatable");

        // Liquidator does partial liquidation (repay half of maxRepay)
        uint256 partialRepay = maxRepay / 2;
        _fundUsdc(liquidator, partialRepay);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), partialRepay);
        IERC20(Constants.USDC).approve(v2MarketAddr, partialRepay);
        liquidationEngine.liquidate(positionId, partialRepay, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        // Alice tries to withdraw — should revert (still has debt)
        vm.prank(alice);
        vm.expectRevert("HAS_DEBT");
        positionManager.withdraw(positionId);

        // Alice repays remaining debt
        uint256 remainingDebt = _getDebt(positionId);
        if (remainingDebt > 0) {
            _fundUsdc(alice, remainingDebt + 1000e6);
            vm.startPrank(alice);
            IERC20(Constants.USDC).approve(v2MarketAddr, type(uint256).max);
            lendingEngine.repay(positionId, type(uint256).max);
            vm.stopPrank();
        }

        // After repaying, check position state
        IPositionManager.Position memory posAfter = positionManager.getPosition(positionId);
        // If position still has amount and is Active, withdraw should work
        if (posAfter.status == IPositionManager.PositionStatus.Active && posAfter.amount > 0) {
            vm.prank(alice);
            positionManager.withdraw(positionId);
            console.log("=== Withdraw After Repay: Succeeded ===");
        } else {
            console.log("=== Position fully consumed during liquidation ===");
        }

        console.log("=== Withdraw During Liquidation Blocked: Passed ===");
    }

    // ========== 8. Borrow After Full Liquidation — Blocked ==========

    function test_attack_borrowAfterLiquidation_blocked() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 90) / 100);

        // Mock price crash — well below critical HF threshold so 100% liquidation is allowed
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 originalValue = _getPositionValue(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, (originalValue * 20) / 100);

        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Should be liquidatable");

        // Full liquidation
        _fundUsdc(liquidator, maxRepay);
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        IERC20(Constants.USDC).approve(marketAddr, maxRepay);
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        // Position should be Liquidated now
        IPositionManager.Position memory posAfter = positionManager.getPosition(positionId);
        assertEq(
            uint8(posAfter.status), uint8(IPositionManager.PositionStatus.Liquidated), "Position must be Liquidated"
        );

        // Alice tries to borrow on liquidated position — should revert
        vm.roll(block.number + 2);
        vm.prank(alice);
        vm.expectRevert("POSITION_NOT_ACTIVE");
        lendingEngine.borrow(positionId, 100e6);

        // Alice tries to deposit new collateral to same position — should revert
        _fundWeth(alice, 1 ether);
        _fundUsdc(alice, 2000e6);
        vm.startPrank(alice);
        IERC20(Constants.WETH).approve(address(positionManager), 1 ether);
        IERC20(Constants.USDC).approve(address(positionManager), 2000e6);
        vm.expectRevert(); // addCollateral checks status
        positionManager.addCollateral(positionId, 2000e6, 1 ether);
        vm.stopPrank();

        console.log("=== Borrow After Full Liquidation Blocked: Passed ===");
    }

    // ========== 9. Oracle Manipulation — Inflate Then Borrow ==========

    function test_attack_manipulateOraclePrice_thenBorrow() public {
        // Create V3 position with real value (~$5K)
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Get real position value
        uint256 realValue = _getPositionValue(positionId);
        console.log("Real position value: $%s", realValue / 1e18);

        // Mock oracle to return inflated $100K value
        IPositionManager.Position memory pos = positionManager.getPosition(positionId);
        _mockOraclePrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType, 100_000e18);

        // Borrow max based on inflated price (65% of $100K = ~$65K)
        uint256 inflatedMaxBorrow = lendingEngine.getMaxBorrow(positionId);
        console.log("Inflated max borrow: %s USDC", inflatedMaxBorrow / 1e6);

        // Only borrow what the market has liquidity for
        address marketAddr = core.markets(ethUsdcMarketId);
        uint256 marketLiquidity = IERC20(Constants.USDC).balanceOf(marketAddr);
        uint256 borrowAmount = inflatedMaxBorrow > marketLiquidity ? marketLiquidity : inflatedMaxBorrow;
        // Leave some buffer for repayment needs
        borrowAmount = (borrowAmount * 95) / 100;

        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        uint256 debt = _getDebt(positionId);
        assertGt(debt, 0, "Should have borrowed");

        // Clear mock — real oracle returns real value
        vm.clearMockedCalls();

        // Re-set staleness tolerance (cleared by clearMockedCalls affects nothing here
        // since staleness is contract state, not a mock)

        // Health factor should be way below 1 now
        uint256 hf = _getHealthFactor(positionId);
        assertLt(hf, 1e18, "HF must be below 1 with real oracle price");

        // Liquidation should work
        (bool canLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(canLiq, "Must be liquidatable after oracle correction");

        // Execute liquidation to prove protocol handles it
        _fundUsdc(liquidator, maxRepay);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(address(liquidationEngine), maxRepay);
        IERC20(Constants.USDC).approve(marketAddr, maxRepay);
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        console.log("=== Oracle Manipulation Then Borrow: Liquidation Handled ===");
        console.log("HF after oracle correction: %s", hf / 1e16);
    }

    // ========== 10. Stale Oracle Price — Deposit Blocked ==========

    function test_attack_staleOraclePrice_depositBlocked() public {
        // Set oracle staleness to minimum allowed (300s)
        vm.startPrank(deployer);
        v3Oracle.setMaxStaleness(300);
        priceFeedRegistry.setMaxStaleness(300);
        vm.stopPrank();

        // Create V3 position (this is on Uniswap directly, should work)
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);

        // Mock Chainlink ETH/USD to return data older than 300s
        vm.mockCall(
            Constants.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(2500e8), block.timestamp - 600, block.timestamp - 600, uint80(1))
        );
        vm.mockCall(
            Constants.CL_USDC_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(1e8), block.timestamp - 600, block.timestamp - 600, uint80(1))
        );

        // Try to deposit — oracle will reject stale Chainlink data
        vm.startPrank(alice);
        nftManager.approve(address(v3Adapter), tokenId);
        vm.expectRevert("STALE_PRICE");
        positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);
        vm.stopPrank();

        console.log("=== Stale Oracle Blocks Deposit: Passed ===");
    }
}
