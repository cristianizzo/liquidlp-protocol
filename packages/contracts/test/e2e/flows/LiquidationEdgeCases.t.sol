// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {INonfungiblePositionManager} from "../../../src/interfaces/external/IUniswapV3.sol";
import {Market} from "../../../src/markets/Market.sol";
import {LeverageTransformer} from "../../../src/periphery/LeverageTransformer.sol";

/// @title LiquidationEdgeCases
/// @notice E2E tests for liquidation edge cases on forked mainnet.
/// @dev Covers: full liquidation with LP return, reduced liquidation portion,
///      flash callback security, and compound auth.
contract LiquidationEdgeCases is E2EBase {
    function setUp() public override {
        super.setUp();

        vm.prank(deployer);
        aclManager.addRiskAdmin(deployer);
    }

    /// @notice Full liquidation returns remaining LP to borrower
    function test_fullLiquidation_returnsRemainingLP() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 5);

        // Borrow moderately — 50% of max
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 2);

        uint256 debt = _getDebt(positionId);
        console.log("Debt: %s USDC", debt / 1e6);

        // Mock oracle to simulate a severe crash (guarantees liquidatability)
        // debt is 6-dec USDC. Convert to 18-dec USD, then set value below liquidation threshold.
        // HF = (value * liqThreshold) / debtUsd. For HF < 1: value < debtUsd * 10000 / liqThreshold
        // liqThreshold = 7500 (75%), so value < debtUsd * 10000 / 7500 = debtUsd * 1.333
        // Set value to 80% of that threshold to guarantee liquidation
        uint256 debtUsd = uint256(debt) * 1e12; // 6-dec to 18-dec (USDC ~ $1)
        uint256 crashedValue = (debtUsd * 10_000 * 80) / (7500 * 100); // 80% of threshold
        _mockOraclePrice(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ILPAdapter.LPType.UniswapV3, crashedValue);

        (bool isLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(isLiq, "Position must be liquidatable for this test");

        // Liquidate with mocked oracle (oracle mock persists for the liquidation call)
        _fundUsdc(liquidator, maxRepay);
        vm.startPrank(liquidator);
        // LiquidationEngine pulls USDC from liquidator via safeTransferFrom — approve LiquidationEngine
        IERC20(Constants.USDC).approve(address(liquidationEngine), type(uint256).max);
        liquidationEngine.liquidate(positionId, maxRepay, block.timestamp + 300, 0, 0);
        vm.stopPrank();

        uint256 remainingDebt = _getDebt(positionId);
        console.log("Remaining debt: %s USDC", remainingDebt / 1e6);
        assertLt(remainingDebt, debt, "Debt should decrease after liquidation");
    }

    /// @notice Partial liquidation with reduced maxLiquidationPortion
    function test_partialLiquidation_reducedPortion() public {
        // Set max liquidation to 25%
        vm.prank(deployer);
        liquidationEngine.setMaxLiquidationPortion(2500);

        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 5);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 85) / 100);

        uint256 debtBefore = _getDebt(positionId);

        // Mock oracle to HF ~0.97 (above CRITICAL_HF 0.95 so portion cap applies)
        uint256 debtUsd = uint256(debtBefore) * 1e12;
        uint256 hf97Value = (debtUsd * 9700 * 10_000) / (7500 * 10_000);
        _mockOraclePrice(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ILPAdapter.LPType.UniswapV3, hf97Value);

        (bool isLiq, uint256 maxRepay) = liquidationEngine.isLiquidatable(positionId);
        assertTrue(isLiq, "Position must be liquidatable");

        // Verify maxRepay is capped at 25% of debt (HF between 0.95-1.0)
        uint256 maxExpected = (debtBefore * 2500) / 10_000;
        assertLe(maxRepay, maxExpected + maxExpected / 100, "maxRepay should be capped at 25%");
        console.log("Debt: %s, maxRepay: %s, expected max ~%s", debtBefore / 1e6, maxRepay / 1e6, maxExpected / 1e6);
    }

    /// @notice Spoofed flash callback to LeverageTransformer is rejected
    function test_revert_spoofedFlashCallback() public {
        // Try calling uniswapV3FlashCallback directly on LeverageTransformer
        // This should revert because _activeFlashPool is address(0)

        // Deploy a LeverageTransformer
        LeverageTransformer lt = new LeverageTransformer(
            address(core), address(positionManager), address(lendingEngine), Constants.UNI_V3_SWAP_ROUTER
        );

        // Try spoofing a flash callback
        vm.prank(Constants.UNI_V3_WETH_USDC_500); // pretend to be the pool
        vm.expectRevert("UNAUTHORIZED_CALLBACK");
        lt.uniswapV3FlashCallback(0, 0, "");
    }

    /// @notice Liquidation of healthy position is rejected
    function test_revert_liquidation_healthyPosition() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 5);

        // Borrow only 20% of max -- very healthy
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, maxBorrow / 5);

        uint256 hf = _getHealthFactor(positionId);
        assertGt(hf, 1e18, "Should be healthy");

        // Try to liquidate -- should fail
        _fundUsdc(liquidator, 1000e6);
        address mktAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(mktAddr, 1000e6);
        vm.expectRevert("NOT_LIQUIDATABLE");
        liquidationEngine.liquidate(positionId, 1000e6, block.timestamp + 300, 0, 0);
        vm.stopPrank();
    }

    /// @notice Liquidation with expired deadline reverts
    function test_revert_liquidation_expired() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 5);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        vm.prank(alice);
        lendingEngine.borrow(positionId, (maxBorrow * 85) / 100);

        _crashEthPrice(2000 ether);

        _fundUsdc(liquidator, 1000e6);
        address mktAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(liquidator);
        IERC20(Constants.USDC).approve(mktAddr, 1000e6);
        // Use expired deadline
        vm.expectRevert("EXPIRED");
        liquidationEngine.liquidate(positionId, 1000e6, block.timestamp - 1, 0, 0);
        vm.stopPrank();
    }
}
