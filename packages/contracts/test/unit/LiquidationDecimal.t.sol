// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {MockPriceFeedRegistry} from "../mocks/MockPriceFeedRegistry.sol";

/// @title LiquidationDecimalTest
/// @notice Full liquidation flow tests with REAL decimal configurations
/// @dev Tests the complete borrow → price drop → liquidate → swap → profit flow
///      using 6-decimal USDC and 8-decimal WBTC to exercise all decimal conversion paths:
///      - PositionManager.getHealthFactor (debt → USD via PriceFeedRegistry)
///      - LendingEngine._getMaxBorrow (USD → borrow asset decimals)
///      - LiquidationEngine._getRepayValueUsd (borrow amount → USD)
///      - LiquidationEngine slippage check (receivedUsd vs collateralToSeize)
///      - Profit/payout math (native borrow asset decimals)
contract LiquidationDecimalTest is Test {
    ProtocolCore public core;
    PositionManager public pm;
    LendingEngine public le;
    LiquidationEngine public liq;
    LPOracleHub public oracleHub;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    InterestRateModel public irm;

    MockERC20 public weth;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public liquidator = makeAddr("liquidator");
    address public lpToken = makeAddr("lpToken");

    function setUp() public {
        weth = new MockERC20("WETH", "WETH", 18);
        irm = new InterestRateModel(200, 600, 10_000, 8000);
        core = new ProtocolCore(owner, guardian);

        LPOracleHub ohImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(ohImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );

        PositionManager pmImpl = new PositionManager();
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        LendingEngine leImpl = new LendingEngine();
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        LiquidationEngine liqImpl = new LiquidationEngine();
        liq = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(liqImpl),
                    abi.encodeCall(LiquidationEngine.initialize, (address(core), address(pm), address(le)))
                )
            )
        );

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();

        vm.startPrank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        oracleHub.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        pm.setAuthorized(address(le), true);
        pm.setAuthorized(address(liq), true);
        pm.setLendingEngine(address(le));
        vm.stopPrank();
    }

    // ========== 6-Decimal USDC Full Liquidation Flow ==========

    function test_fullFlow_6decUSDC_withPriceFeedRegistry() public {
        // Setup: 6-decimal USDC market with PriceFeedRegistry
        MockERC20 usdc6 = new MockERC20("USDC", "USDC", 6);
        MockMarket market6 = new MockMarket(address(usdc6), address(irm));
        MockSwapRouter router6 = new MockSwapRouter(address(usdc6));
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        registry.setPrice(address(usdc6), 1e18); // $1.00

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(market6));
        liq.setSwapRouter(address(router6));
        pm.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        // Fund: market + swap router + adapter
        usdc6.mint(address(market6), 10_000_000e6);
        usdc6.mint(address(router6), 10_000_000e6);
        usdc6.mint(address(adapter), 10_000_000e6);
        weth.mint(address(adapter), 10_000_000e18);

        // Adapter: 100 units → 25 WETH + 25K USDC6
        // Swap rate: 1 WETH = 1000 USDC6 → 25*1000 + 25K = $50K
        adapter.setTokenReturns(address(weth), address(usdc6));
        adapter.setUnwindAmounts(25e18, 25_000e6);
        adapter.setTotalLiquidity(100e18);
        router6.setExchangeRate(address(weth), 1000e6); // 1 WETH = 1000 USDC (6 dec)

        // Alice deposits, oracle = $50K
        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        // Borrow 30K USDC (6 dec)
        // _getMaxBorrow: 50_000e18 * 6500 / 10000 = 32_500e18 USD
        // via registry: 32_500e18 * 1e6 / 1e18 = 32_500e6 USDC
        // 30_000e6 <= 32_500e6 ✓
        vm.prank(alice);
        le.borrow(posId, 30_000e6);

        uint256 debt = le.getDebt(posId);
        assertEq(debt, 30_000e6, "Debt should be 30K in 6-dec");

        // Price drops to $39K → HF = (39K * 7500) / (30K * 10000) = 0.975
        // getHealthFactor: debtUsd = registry.getUsdValue(USDC, 30_000e6, 6) = 30_000e18
        // HF = (39_000e18 * 7500 * 1e18) / (30_000e18 * 10_000) = 0.975e18
        oracle.setPrice(39_000e18);

        uint256 hf = pm.getHealthFactor(posId);
        assertLt(hf, 1e18, "Should be liquidatable");
        assertGt(hf, 0.95e18, "Should be partial liquidation (not critical)");

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq, "Must be liquidatable");
        assertGt(maxRepay, 0, "maxRepay must be > 0");

        // maxRepay is in 6-dec USDC (50% of 30K = 15K)
        assertEq(maxRepay, 15_000e6, "maxRepay should be 50% of 30K USDC");

        // Liquidate with full maxRepay
        usdc6.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc6.approve(address(liq), maxRepay);

        uint256 liqBalBefore = usdc6.balanceOf(liquidator);

        vm.prank(liquidator);
        uint256 profit = liq.liquidate(posId, maxRepay, block.timestamp + 1 hours);

        // Verify outcomes
        uint256 debtAfter = le.getDebt(posId);
        assertEq(debtAfter, 15_000e6, "Debt should be halved");

        uint256 amountAfter = pm.getPosition(posId).amount;
        assertLt(amountAfter, 100e18, "Position amount must decrease");

        // Profit is in 6-dec USDC
        assertGt(profit, 0, "Liquidator should profit");

        // Liquidator received back repayAmount + profit (minus protocol fee)
        uint256 liqBalAfter = usdc6.balanceOf(liquidator);
        assertGt(liqBalAfter, liqBalBefore - maxRepay, "Liquidator net balance should increase");
    }

    function test_fullFlow_6decUSDC_withoutRegistry_fallback() public {
        // Same flow but WITHOUT PriceFeedRegistry — tests fallback normalization
        MockERC20 usdc6 = new MockERC20("USDC", "USDC", 6);
        MockMarket market6 = new MockMarket(address(usdc6), address(irm));
        MockSwapRouter router6 = new MockSwapRouter(address(usdc6));

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(market6));
        liq.setSwapRouter(address(router6));
        // NO setPriceFeedRegistry — testing fallback path
        vm.stopPrank();

        usdc6.mint(address(market6), 10_000_000e6);
        usdc6.mint(address(router6), 10_000_000e6);
        usdc6.mint(address(adapter), 10_000_000e6);
        weth.mint(address(adapter), 10_000_000e18);

        adapter.setTokenReturns(address(weth), address(usdc6));
        adapter.setUnwindAmounts(25e18, 25_000e6);
        adapter.setTotalLiquidity(100e18);
        router6.setExchangeRate(address(weth), 1000e6);

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        // Borrow — fallback _getMaxBorrow normalizes to 6-dec
        vm.prank(alice);
        le.borrow(posId, 30_000e6);

        // Drop price → liquidatable
        oracle.setPrice(39_000e18);

        // Fallback HF: debt=30_000e6, normalized=30_000e18
        uint256 hf = pm.getHealthFactor(posId);
        assertLt(hf, 1e18, "Should be liquidatable via fallback");

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq);

        usdc6.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc6.approve(address(liq), maxRepay);

        vm.prank(liquidator);
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours);

        assertLt(pm.getPosition(posId).amount, 100e18, "Position amount must decrease");
        assertLt(le.getDebt(posId), 30_000e6, "Debt must decrease");
    }

    // ========== 8-Decimal WBTC Full Liquidation Flow ==========

    function test_fullFlow_8decWBTC_withPriceFeedRegistry() public {
        // WBTC at $60K as borrow asset — exercises non-$1 price conversion
        MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
        MockMarket marketBtc = new MockMarket(address(wbtc), address(irm));
        MockSwapRouter routerBtc = new MockSwapRouter(address(wbtc));
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        registry.setPrice(address(wbtc), 60_000e18); // $60K per BTC

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(marketBtc));
        liq.setSwapRouter(address(routerBtc));
        pm.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        wbtc.mint(address(marketBtc), 100e8); // 100 BTC
        wbtc.mint(address(routerBtc), 100e8);
        wbtc.mint(address(adapter), 100e8);
        weth.mint(address(adapter), 10_000e18);

        // 100 units → 25 WETH + 0.5 WBTC
        // At $2K/ETH and $60K/BTC: 25*2K + 0.5*60K = $50K + $30K = $80K
        // But oracle says $100K (LP has additional value from fees/IL)
        adapter.setTokenReturns(address(weth), address(wbtc));
        adapter.setUnwindAmounts(25e18, 5e7); // 25 WETH + 0.5 WBTC
        adapter.setTotalLiquidity(100e18);
        // 1 WETH → 0.0333 WBTC (at $2K ETH / $60K BTC)
        routerBtc.setExchangeRate(address(weth), 333e4); // 0.0333 WBTC in 8-dec

        oracle.setPrice(100_000e18); // $100K collateral
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        // Borrow 0.5 WBTC ($30K)
        // _getMaxBorrow: 100_000e18 * 6500 / 10000 = 65_000e18 USD
        // via registry: mulDiv(65_000e18, 1e8, 60_000e18) = 1.083e8 = 1.083 WBTC
        // 5e7 (0.5 BTC) <= 1.083e8 ✓
        vm.prank(alice);
        le.borrow(posId, 5e7); // 0.5 WBTC

        uint256 debt = le.getDebt(posId);
        assertEq(debt, 5e7, "Debt should be 0.5 WBTC");

        // Price drops to $50K → HF = (50K * 7500) / (30K * 10000) = 1.25 (still healthy!)
        // Need bigger drop. At $38K: HF = (38K * 7500) / (30K * 10K) = 0.95
        oracle.setPrice(38_000e18);

        // HF: debtUsd = registry.getUsdValue(WBTC, 5e7, 8) = mulDiv(5e7, 60_000e18, 1e8) = 30_000e18
        // HF = (38_000e18 * 7500 * 1e18) / (30_000e18 * 10_000) = 0.95e18
        uint256 hf = pm.getHealthFactor(posId);
        assertLt(hf, 1e18, "Should be liquidatable");

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq, "Must be liquidatable");

        // maxRepay is in 8-dec WBTC
        assertGt(maxRepay, 0);

        wbtc.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        wbtc.approve(address(liq), maxRepay);

        vm.prank(liquidator);
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours);

        assertLt(pm.getPosition(posId).amount, 100e18, "Position amount must decrease");
    }

    // ========== Underwater 6-dec Liquidation (Bad Debt Prevention) ==========

    function test_fullFlow_6decUSDC_underwater_liquidatable() public {
        // Critically underwater position (HF < 0.95) with 6-dec USDC
        // Tests that the slippage baseline fix works with real decimals
        MockERC20 usdc6 = new MockERC20("USDC", "USDC", 6);
        MockMarket market6 = new MockMarket(address(usdc6), address(irm));
        MockSwapRouter router6 = new MockSwapRouter(address(usdc6));
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        registry.setPrice(address(usdc6), 1e18);

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(market6));
        liq.setSwapRouter(address(router6));
        pm.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        usdc6.mint(address(market6), 10_000_000e6);
        usdc6.mint(address(router6), 10_000_000e6);
        usdc6.mint(address(adapter), 10_000_000e6);
        weth.mint(address(adapter), 10_000_000e18);

        // Both tokens are WETH so 100% goes through swap
        adapter.setTokenReturns(address(weth), address(weth));
        adapter.setUnwindAmounts(25e18, 25e18); // 50 WETH total
        adapter.setTotalLiquidity(100e18);

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 30_000e6);

        // Drop to $30K → HF = 0.75 (critically underwater)
        oracle.setPrice(30_000e18);
        // Fair swap rate at $30K: 30_000/50 = 600 USDC/WETH
        router6.setExchangeRate(address(weth), 600e6); // 600 USDC6 per WETH

        uint256 hf = pm.getHealthFactor(posId);
        assertLt(hf, 0.95e18, "Must be critically underwater");

        (bool canLiq, uint256 maxRepay) = liq.isLiquidatable(posId);
        assertTrue(canLiq);
        assertEq(maxRepay, 30_000e6, "Critical: 100% liquidation");

        usdc6.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc6.approve(address(liq), maxRepay);

        // This MUST succeed — underwater positions must be liquidatable
        vm.prank(liquidator);
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours);

        assertEq(le.getDebt(posId), 0, "Debt should be fully repaid");
    }

    // ========== Slippage Check with 6-dec ==========

    function test_slippageCheck_6dec_reverts() public {
        // 6-dec USDC with too much slippage → should revert
        MockERC20 usdc6 = new MockERC20("USDC", "USDC", 6);
        MockMarket market6 = new MockMarket(address(usdc6), address(irm));
        MockSwapRouter router6 = new MockSwapRouter(address(usdc6));
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        registry.setPrice(address(usdc6), 1e18);

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(market6));
        liq.setSwapRouter(address(router6));
        pm.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        usdc6.mint(address(market6), 10_000_000e6);
        usdc6.mint(address(router6), 10_000_000e6);
        usdc6.mint(address(adapter), 10_000_000e6);
        weth.mint(address(adapter), 10_000_000e18);

        adapter.setTokenReturns(address(weth), address(usdc6));
        adapter.setUnwindAmounts(25e18, 25_000e6);
        adapter.setTotalLiquidity(100e18);
        // 50% slippage on swap: fair rate 780 → 390 (massive price impact)
        router6.setExchangeRate(address(weth), 390e6);

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 30_000e6);

        oracle.setPrice(39_000e18); // HF ≈ 0.975

        (, uint256 maxRepay) = liq.isLiquidatable(posId);

        usdc6.mint(liquidator, maxRepay);
        vm.prank(liquidator);
        usdc6.approve(address(liq), maxRepay);

        vm.prank(liquidator);
        vm.expectRevert("SWAP_SLIPPAGE_EXCEEDED");
        liq.liquidate(posId, maxRepay, block.timestamp + 1 hours);
    }

    // ========== MaxBorrow with PriceFeedRegistry ==========

    function test_maxBorrow_6dec_respectsLTV() public {
        MockERC20 usdc6 = new MockERC20("USDC", "USDC", 6);
        MockMarket market6 = new MockMarket(address(usdc6), address(irm));
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        registry.setPrice(address(usdc6), 1e18);

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(market6));
        pm.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        usdc6.mint(address(market6), 10_000_000e6);

        adapter.setTokenReturns(address(weth), address(usdc6));
        adapter.setUnwindAmounts(25e18, 25_000e6);
        adapter.setTotalLiquidity(100e18);

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        // maxBorrow = 50_000 * 0.65 = 32_500 USDC
        uint256 maxBorrow = le.getMaxBorrow(posId);
        assertEq(maxBorrow, 32_500e6, "maxBorrow must be in 6-dec USDC");

        // Borrow at max
        vm.prank(alice);
        le.borrow(posId, 32_500e6);

        // Borrow 1 more should fail
        vm.prank(alice);
        vm.expectRevert("EXCEEDS_MAX_LTV");
        le.borrow(posId, 1);
    }

    function test_maxBorrow_8decWBTC_respectsLTV() public {
        MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
        MockMarket marketBtc = new MockMarket(address(wbtc), address(irm));
        MockPriceFeedRegistry registry = new MockPriceFeedRegistry();
        registry.setPrice(address(wbtc), 60_000e18);

        vm.startPrank(owner);
        uint256 marketId = core.registerMarket(address(marketBtc));
        pm.setPriceFeedRegistry(address(registry));
        vm.stopPrank();

        wbtc.mint(address(marketBtc), 1000e8);

        adapter.setTokenReturns(address(weth), address(wbtc));
        adapter.setUnwindAmounts(25e18, 5e7);
        adapter.setTotalLiquidity(100e18);

        oracle.setPrice(100_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        // maxBorrow = 100_000 * 0.65 / 60_000 = 1.0833 WBTC = 108_333_333 (8 dec)
        uint256 maxBorrow = le.getMaxBorrow(posId);
        // mulDiv(65_000e18, 1e8, 60_000e18) = 108_333_333 = ~1.083 WBTC
        assertApproxEqAbs(maxBorrow, 108_333_333, 1, "maxBorrow must be in 8-dec WBTC");

        // Borrow 0.5 WBTC — within LTV
        vm.prank(alice);
        le.borrow(posId, 5e7);

        assertEq(le.getDebt(posId), 5e7);
    }
}
