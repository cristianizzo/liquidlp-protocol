// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../helpers/ForkTestBase.sol";
import {INonfungiblePositionManager, IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3.sol";
import {IUniswapV2Pair, IUniswapV2Router} from "../../src/interfaces/external/IUniswapV2.sol";
import {ILPOracleHub} from "../../src/interfaces/ILPOracleHub.sol";

/// @notice Minimal WETH deposit interface
interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Uniswap V3 SwapRouter exactInputSingle interface (for whale dumps)
interface ISwapRouterSingle {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title E2EBase
/// @notice Base for end-to-end fork tests. Deploys full protocol + creates real LP positions.
/// @dev Inherits ForkTestBase (deploys all contracts). Adds helpers to create real V2/V3 positions.
///
///      Test accounts:
///        alice    — borrower (deposits LP, borrows)
///        bob      — lender (supplies USDC to market)
///        liquidator — liquidates underwater positions
///
///      LP positions are created against real Uniswap on forked mainnet.
abstract contract E2EBase is ForkTestBase {
    // V3 position helpers
    INonfungiblePositionManager public nftManager;

    // Funded test amounts
    uint256 constant ALICE_ETH = 10 ether;
    uint256 constant ALICE_USDC = 50_000e6;
    uint256 constant BOB_USDC = 100_000e6;
    uint256 constant LIQUIDATOR_USDC = 50_000e6;

    function setUp() public virtual override {
        super.setUp();
        nftManager = INonfungiblePositionManager(Constants.UNI_V3_NFT_MANAGER);

        // Fork may have stale Chainlink data — increase registry staleness tolerance
        vm.startPrank(deployer);
        priceFeedRegistry.setMaxStaleness(86_400); // 24h for fork testing
        vm.stopPrank();

        // Fund test accounts
        _fundWeth(alice, ALICE_ETH);
        _fundUsdc(alice, ALICE_USDC);
        _fundUsdc(bob, BOB_USDC);
        _fundUsdc(liquidator, LIQUIDATOR_USDC);

        // Bob supplies USDC to the market (provides borrowable liquidity)
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(marketAddr, BOB_USDC);
        IMarket(marketAddr).supply(BOB_USDC);
        vm.stopPrank();
    }

    // ========== V3 Position Helpers ==========

    /// @notice Create a real V3 WETH/USDC position on Uniswap
    /// @param user The user who will own the position
    /// @param wethAmount Amount of WETH to provide
    /// @param usdcAmount Amount of USDC to provide
    /// @return tokenId The V3 NFT position ID
    function _createV3Position(address user, uint256 wethAmount, uint256 usdcAmount)
        internal
        returns (uint256 tokenId)
    {
        vm.startPrank(user);

        IERC20(Constants.WETH).approve(address(nftManager), wethAmount);
        IERC20(Constants.USDC).approve(address(nftManager), usdcAmount);

        // Get current tick to create an in-range position
        IUniswapV3Pool pool = IUniswapV3Pool(Constants.UNI_V3_WETH_USDC_3000);
        (, int24 currentTick,,,,,) = pool.slot0();

        // Round tick to spacing (60 for 0.3% fee tier)
        int24 spacing = 60;
        int24 tickLower = ((currentTick - 1000) / spacing) * spacing;
        int24 tickUpper = ((currentTick + 1000) / spacing) * spacing;

        // Determine token ordering (USDC is token0 in WETH/USDC pool)
        address token0 = Constants.USDC < Constants.WETH ? Constants.USDC : Constants.WETH;
        address token1 = Constants.USDC < Constants.WETH ? Constants.WETH : Constants.USDC;
        uint256 amount0 = token0 == Constants.USDC ? usdcAmount : wethAmount;
        uint256 amount1 = token0 == Constants.USDC ? wethAmount : usdcAmount;

        (tokenId,,,) = nftManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: user,
                deadline: block.timestamp + 300
            })
        );

        vm.stopPrank();
    }

    /// @notice Deposit a V3 position into the protocol
    /// @return positionId The protocol position ID
    function _depositV3(address user, uint256 tokenId) internal returns (uint256 positionId) {
        vm.startPrank(user);

        // Approve NFT transfer to PositionManager (via adapter)
        nftManager.approve(address(v3Adapter), tokenId);

        // Deposit into protocol
        positionId = positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);

        vm.stopPrank();
    }

    // ========== V2 Position Helpers ==========

    /// @notice Create a real V2 WETH/USDC LP position
    /// @return lpAmount Amount of LP tokens received
    function _createV2Position(
        address user,
        uint256 wethAmount,
        uint256 usdcAmount
    )
        internal
        returns (uint256 lpAmount)
    {
        vm.startPrank(user);

        IUniswapV2Router router = IUniswapV2Router(Constants.UNI_V2_ROUTER);
        IERC20(Constants.WETH).approve(address(router), wethAmount);
        IERC20(Constants.USDC).approve(address(router), usdcAmount);

        (,, lpAmount) = router.addLiquidity(
            Constants.WETH, Constants.USDC, wethAmount, usdcAmount, 0, 0, user, block.timestamp + 300
        );

        vm.stopPrank();
    }

    /// @notice Deposit V2 LP tokens into the protocol
    /// @param marketId The market to deposit into (caller must pass the correct V2 market)
    function _depositV2(address user, uint256 lpAmount, uint256 marketId) internal returns (uint256 positionId) {
        vm.startPrank(user);

        IUniswapV2Pair pair = IUniswapV2Pair(Constants.UNI_V2_WETH_USDC);
        pair.approve(address(v2Adapter), lpAmount);

        positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, marketId);

        vm.stopPrank();
    }

    // ========== Price Manipulation Helpers ==========

    /// @notice Mock oracleHub.getPrice to return a specific USD value
    /// @dev Bypasses TWAP/Chainlink deviation checks — use for liquidation tests
    function _mockOraclePrice(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        ILPAdapter.LPType lpType,
        uint256 valueUsd
    )
        internal
    {
        vm.mockCall(
            address(oracleHub),
            abi.encodeWithSelector(ILPOracleHub.getPrice.selector, lpToken, tokenId, amount, lpType),
            abi.encode(
                ILPOracleHub.PriceResult({
                    totalValue: valueUsd,
                    principalValue: valueUsd,
                    feeValue: 0,
                    confidence: 9500,
                    timestamp: block.timestamp
                })
            )
        );
    }

    // ========== View Helpers ==========

    function _getDebt(uint256 positionId) internal view returns (uint256) {
        return lendingEngine.getDebt(positionId);
    }

    function _getPositionValue(uint256 positionId) internal view returns (uint256) {
        return positionManager.getPositionValue(positionId);
    }

    function _getHealthFactor(uint256 positionId) internal view returns (uint256) {
        return positionManager.getHealthFactor(positionId);
    }

    // ========== Real Price Crash Helper ==========

    /// @notice Crash ETH price by dumping WETH into the real Uniswap V3 pool, then mock Chainlink to match.
    /// @dev Steps:
    ///   1. Create a whale address, deal ETH, wrap to WETH
    ///   2. Swap WETH → USDC in the real 0.3% pool (crashes the pool price)
    ///   3. Advance time 35 min so 30-min TWAP fully absorbs the new price
    ///   4. Read the post-crash tick from pool.slot0()
    ///   5. Convert tick → ETH/USD price using TickMath
    ///   6. Mock Chainlink ETH/USD to return that exact price (USDC/USD stays ~$1)
    ///   This ensures TWAP ≈ Chainlink within the 3% deviation tolerance.
    /// @param dumpAmountEth Amount of ETH to dump (e.g. 5000 ether for a big crash)
    /// @return crashedEthPrice The ETH/USD price (8 decimals) that Chainlink now returns
    function _crashEthPrice(uint256 dumpAmountEth) internal returns (int256 crashedEthPrice) {
        IUniswapV3Pool pool = IUniswapV3Pool(Constants.UNI_V3_WETH_USDC_3000);

        // --- Step 1: Create whale with WETH ---
        address whale = makeAddr("ethDumpWhale");
        vm.deal(whale, dumpAmountEth + 1 ether); // extra for gas
        vm.startPrank(whale);
        IWETH(Constants.WETH).deposit{value: dumpAmountEth}();

        // --- Step 2: Dump WETH into the real pool via SwapRouter ---
        IWETH(Constants.WETH).approve(Constants.UNI_V3_SWAP_ROUTER, dumpAmountEth);
        ISwapRouterSingle(Constants.UNI_V3_SWAP_ROUTER)
            .exactInputSingle(
                ISwapRouterSingle.ExactInputSingleParams({
                tokenIn: Constants.WETH,
                tokenOut: Constants.USDC,
                fee: 3000,
                recipient: whale,
                deadline: block.timestamp + 300,
                amountIn: dumpAmountEth,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
            );
        vm.stopPrank();

        // --- Step 3: Advance time so TWAP fully absorbs the crash ---
        // 35 minutes > 30-min TWAP window — entire window is post-crash
        _advanceTime(35 minutes);

        // --- Step 4: Read the actual post-crash sqrtPriceX96 from pool ---
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        // --- Step 5: Convert pool sqrtPriceX96 to Chainlink 8-decimal ETH/USD ---
        // Pool: USDC(token0, 6dec) / WETH(token1, 18dec)
        // sqrtPriceX96 = sqrt(token1/token0) * 2^96, so price = sqrtPriceX96^2 / 2^192 = WETH_raw / USDC_raw
        // ETH/USD (human) = USDC_human / WETH_human = (1/price) * 10^(18-6) = 10^12 * 2^192 / sqrtPriceX96^2
        // Chainlink 8-dec = ETH/USD * 10^8 = 10^20 * 2^192 / sqrtPriceX96^2
        // Split via mulDiv: priceX96 = sqrtPriceX96^2 / 2^96, then ethPriceUsd8 = 2^96 * 10^20 / priceX96
        uint256 priceX96 = _mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), uint256(1) << 96);
        uint256 ethPriceUsd8 = _mulDiv(uint256(1) << 96, 1e20, priceX96);

        crashedEthPrice = int256(ethPriceUsd8);
        require(crashedEthPrice > 0, "Crashed price must be positive");

        // --- Step 6: Mock Chainlink ETH/USD feed ---
        vm.mockCall(
            Constants.CL_ETH_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(
                uint80(1), // roundId
                crashedEthPrice, // answer (8 decimals)
                block.timestamp, // startedAt
                block.timestamp, // updatedAt
                uint80(1) // answeredInRound
            )
        );

        // Keep USDC/USD at $1 (already correct, but re-mock to ensure freshness)
        vm.mockCall(
            Constants.CL_USDC_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(
                uint80(1), // roundId
                int256(100_000_000), // $1.00 with 8 decimals
                block.timestamp, // startedAt
                block.timestamp, // updatedAt
                uint80(1) // answeredInRound
            )
        );

        console.log("=== ETH Price Crash ===");
        console.log("  Dump amount:    %s ETH", dumpAmountEth / 1e18);
        console.log("  Chainlink mock:  $%s (8 dec)", uint256(crashedEthPrice));
    }

    // --- TickMath (inlined to avoid import conflicts) ---

    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= 887_272, "T");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    /// @notice Full-precision 512-bit mulDiv (same as LiquidityAmountsLib)
    function _mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        if (prod1 == 0) {
            require(denominator > 0);
            assembly { result := div(prod0, denominator) }
            return result;
        }
        require(denominator > prod1);
        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }
        unchecked {
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            result = prod0 * inverse;
        }
    }
}

// V3 pool slot0 is already in IUniswapV3Pool (src/interfaces/external/IUniswapV3.sol)
// V2 router addLiquidity is already in IUniswapV2Router (src/interfaces/external/IUniswapV2.sol)
