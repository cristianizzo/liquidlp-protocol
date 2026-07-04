// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {UniswapV2Oracle} from "../../src/oracle/UniswapV2Oracle.sol";
import {IUniswapV2Pair} from "../../src/interfaces/external/IUniswapV2.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {ILPOracleHub} from "../../src/interfaces/ILPOracleHub.sol";

/// @title UniswapV2OracleForkTest
/// @notice Fork tests against REAL Uniswap V2 on Ethereum mainnet
/// @dev Run with: ETH_RPC_URL=<rpc> forge test --match-contract UniswapV2OracleForkTest -vvv
contract UniswapV2OracleForkTest is Test {
    // Mainnet addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNI_V2_WETH_USDC = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;

    // Chainlink feeds
    address constant CL_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant CL_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    ACLManager public aclManager;
    ProtocolCore public core;
    UniswapV2Oracle public oracle;

    address public owner = makeAddr("owner");

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpcUrl);

        vm.startPrank(owner);
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));
        oracle = new UniswapV2Oracle(address(core));

        oracle.setPriceFeed(WETH, CL_ETH_USD);
        oracle.setPriceFeed(USDC, CL_USDC_USD);
        // Fork may have stale Chainlink data — increase tolerance for testing
        oracle.setMaxStaleness(86_400); // 24h for fork tests
        vm.stopPrank();
    }

    // ========== Basic Pricing ==========

    function test_priceWethUsdcPair() public view {
        IUniswapV2Pair pair = IUniswapV2Pair(UNI_V2_WETH_USDC);
        uint256 totalSupply = pair.totalSupply();

        // Price 1% of total supply
        uint256 amount = totalSupply / 100;
        uint256 rawPrice = oracle.getRawPrice(UNI_V2_WETH_USDC, 0, amount);

        // Should be non-zero
        assertGt(rawPrice, 0, "Price should be non-zero");

        // Sanity: 1% of a major V2 pool should be worth between $10K and $10M
        assertGt(rawPrice, 10_000e18, "Price too low");
        assertLt(rawPrice, 10_000_000e18, "Price too high");
    }

    function test_getPriceAppliesHaircut() public view {
        IUniswapV2Pair pair = IUniswapV2Pair(UNI_V2_WETH_USDC);
        uint256 amount = pair.totalSupply() / 100;

        uint256 rawPrice = oracle.getRawPrice(UNI_V2_WETH_USDC, 0, amount);
        ILPOracleHub.PriceResult memory result = oracle.getPrice(UNI_V2_WETH_USDC, 0, amount);

        // totalValue should be less than rawPrice (haircut applied)
        assertLt(result.totalValue, rawPrice, "Haircut not applied");

        // principalValue should equal raw
        assertEq(result.principalValue, rawPrice, "Principal should equal raw");

        // feeValue should be 0 (V2 auto-compounds)
        assertEq(result.feeValue, 0, "V2 fees should be 0");

        // haircut should be 500 (5%)
        assertEq(result.haircut, 500);

        // totalValue should be ~95% of raw
        uint256 expected = (rawPrice * 9500) / 10_000;
        assertApproxEqAbs(result.totalValue, expected, 1);
    }

    // ========== Edge Cases ==========

    function test_zeroAmount_returnsZero() public view {
        assertEq(oracle.getRawPrice(UNI_V2_WETH_USDC, 0, 0), 0);
    }

    function test_fullSupply_pricing() public view {
        IUniswapV2Pair pair = IUniswapV2Pair(UNI_V2_WETH_USDC);
        uint256 totalSupply = pair.totalSupply();

        uint256 fullPrice = oracle.getRawPrice(UNI_V2_WETH_USDC, 0, totalSupply);

        // Full supply value should roughly equal 2 * sqrt(k * p0 * p1)
        // For a pool with real reserves, this should be a large number
        assertGt(fullPrice, 0);
    }

    // ========== Decimal Handling ==========

    function test_crossDecimalPricing() public view {
        // WETH/USDC pair: WETH=18dec, USDC=6dec
        // The oracle normalizes both to 18 decimals
        IUniswapV2Pair pair = IUniswapV2Pair(UNI_V2_WETH_USDC);
        (uint112 r0, uint112 r1,) = pair.getReserves();

        // Both reserves should be non-zero
        assertGt(r0, 0);
        assertGt(r1, 0);

        // Price should work correctly despite different decimals
        uint256 price = oracle.getRawPrice(UNI_V2_WETH_USDC, 0, 1e18);
        assertGt(price, 0, "Cross-decimal pricing failed");
    }

    // ========== Stale Feed ==========

    function test_staleFeed_reverts() public {
        // Set tight staleness, then warp past it
        vm.prank(owner);
        oracle.setMaxStaleness(300); // 5 min
        vm.warp(block.timestamp + 1 hours);

        IUniswapV2Pair pair = IUniswapV2Pair(UNI_V2_WETH_USDC);
        uint256 amount = pair.totalSupply() / 100;

        vm.expectRevert("STALE_PRICE");
        oracle.getRawPrice(UNI_V2_WETH_USDC, 0, amount);
    }

    // ========== Missing Feed ==========

    function test_missingFeed_reverts() public {
        // Deploy oracle without feeds
        vm.prank(owner);
        UniswapV2Oracle oracle2 = new UniswapV2Oracle(address(core));

        IUniswapV2Pair pair = IUniswapV2Pair(UNI_V2_WETH_USDC);
        uint256 amount = pair.totalSupply() / 100;

        vm.expectRevert("NO_PRICE_FEED");
        oracle2.getRawPrice(UNI_V2_WETH_USDC, 0, amount);
    }

    // ========== Admin ==========

    function test_setHaircut() public {
        vm.prank(owner);
        oracle.setDefaultHaircut(1000); // 10%
        assertEq(oracle.defaultHaircutBps(), 1000);
    }

    function test_setHaircut_revertsOutOfBounds() public {
        vm.prank(owner);
        vm.expectRevert("OUT_OF_BOUNDS");
        oracle.setDefaultHaircut(50); // Below min 100
    }

    function test_setStaleness() public {
        vm.prank(owner);
        oracle.setMaxStaleness(7200); // 2 hours
        assertEq(oracle.maxStaleness(), 7200);
    }

    // ========== Proportional Pricing ==========

    function test_priceIsProportionalToAmount() public view {
        IUniswapV2Pair pair = IUniswapV2Pair(UNI_V2_WETH_USDC);
        uint256 totalSupply = pair.totalSupply();

        uint256 price1pct = oracle.getRawPrice(UNI_V2_WETH_USDC, 0, totalSupply / 100);
        uint256 price10pct = oracle.getRawPrice(UNI_V2_WETH_USDC, 0, totalSupply / 10);

        // 10% should be ~10x of 1% (within rounding)
        assertApproxEqRel(price10pct, price1pct * 10, 0.01e18); // 1% tolerance
    }
}
