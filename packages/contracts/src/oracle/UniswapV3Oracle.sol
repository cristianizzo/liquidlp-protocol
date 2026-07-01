// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPOracle} from "../interfaces/ILPOracle.sol";
import {ILPOracleHub} from "../interfaces/ILPOracleHub.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {LPMath} from "../libraries/LPMath.sol";
import {INonfungiblePositionManager, IUniswapV3Pool, IUniswapV3Factory} from "../interfaces/external/IUniswapV3.sol";

/// @notice Chainlink AggregatorV3 minimal interface
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @title TickMathLib
/// @notice Computes sqrt price for ticks of size 1.0001 (Uniswap V3 canonical implementation)
library TickMathLib {
    int24 internal constant MIN_TICK = -887_272;
    int24 internal constant MAX_TICK = 887_272;
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(int256(MAX_TICK)), "T");

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
}

/// @title LiquidityAmountsLib
/// @notice Computes token amounts from liquidity and sqrt price ranges
library LiquidityAmountsLib {
    /// @notice Full-precision 512-bit multiplication then division
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
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

    function getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return mulDiv(uint256(liquidity) << 96, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96) / sqrtRatioAX96;
    }

    function getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, 1 << 96);
    }

    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }
}

/// @title UniswapV3Oracle
/// @notice Prices Uniswap V3 NFT positions using TWAP + Chainlink cross-validation
/// @dev Full implementation with multi-layer defense against oracle manipulation.
///
/// !! IMPORTANT: NOT YET VALIDATED AGAINST REAL MAINNET DATA !!
///
/// TODO before mainnet deployment:
///   [ ] Fork test: price a real ETH/USDC V3 position and compare to known value
///   [ ] Fork test: price a real WBTC/ETH V3 position (cross-decimal: 8 dec / 18 dec)
///   [ ] Fork test: verify _validatePriceConsistency with real TWAP vs Chainlink ratio
///   [ ] Fork test: verify decimal normalization in valuation for 6/8/18 dec tokens
///   [ ] Fork test: verify out-of-range position pricing (100% one token)
///   [ ] Fork test: verify narrow range vs wide range haircut selection
///   [ ] Fork test: verify tokensOwed (fee) calculation against real accumulated fees
///   [ ] Verify TickMathLib matches Uniswap's canonical TickMath for edge ticks
///   [ ] Verify LiquidityAmountsLib matches Uniswap's canonical LiquidityAmounts
///   [ ] Test with Chainlink feeds that return different decimal counts (8 vs 18)
///   [ ] Test pool.observe() behavior when observation cardinality is insufficient
///   [ ] Test behavior when TWAP period exceeds pool's observation history
///   [ ] Stress test mulDiv with extreme values (max liquidity + min tick range)
///   [ ] Professional audit of oracle math (critical path for protocol security)
///
/// Pricing flow:
///   1. Read position from NFT manager (tickLower, tickUpper, liquidity, fees)
///   2. Get pool, compute TWAP tick via pool.observe()
///   3. Convert TWAP tick to sqrtPrice, calculate token amounts
///   4. Normalize token amounts to 18 decimals (handles 6/8/18 dec tokens)
///   5. Price tokens via Chainlink feeds (also normalized to 18 dec)
///   6. Cross-validate TWAP vs Chainlink (revert if deviation exceeds threshold)
///   7. Apply position-specific haircut (range width, in/out of range)
///   8. Return safe (haircut-adjusted) value
contract UniswapV3Oracle is ILPOracle {
    ProtocolCore public immutable core;
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable factory;

    mapping(address => address) public priceFeeds; // token -> Chainlink feed

    // --- Configurable Parameters ---
    uint32 public twapPeriod = 1800; // 30 minutes
    uint256 public maxDeviationBps = 300; // 3%
    uint256 public defaultHaircutBps = 700; // 7%
    uint256 public narrowRangeHaircutBps = 1000; // 10%
    uint256 public outOfRangeHaircutBps = 1200; // 12%
    uint256 public volatilityHaircutBps = 500; // +5% (additive, for future PriceValidator integration)
    uint256 public maxStaleness = 3600; // 1 hour Chainlink staleness

    // --- Absolute Bounds ---
    uint32 public constant MIN_TWAP_PERIOD = 300;
    uint32 public constant MAX_TWAP_PERIOD = 7200;
    uint256 public constant MIN_HAIRCUT_BPS = 200;
    uint256 public constant MAX_HAIRCUT_BPS = 3000;
    uint256 public constant MIN_DEVIATION_BPS = 100;
    uint256 public constant MAX_DEVIATION_BPS_CAP = 1000;

    // --- Events ---
    event TwapPeriodUpdated(uint32 oldValue, uint32 newValue);
    event MaxDeviationUpdated(uint256 oldValue, uint256 newValue);
    event HaircutUpdated(string haircutType, uint256 oldValue, uint256 newValue);
    event PriceFeedUpdated(address indexed token, address indexed feed);
    event MaxStalenessUpdated(uint256 oldValue, uint256 newValue);

    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
        _;
    }

    constructor(address _core, address _positionManager) {
        core = ProtocolCore(_core);
        positionManager = INonfungiblePositionManager(_positionManager);
        factory = IUniswapV3Factory(INonfungiblePositionManager(_positionManager).factory());
    }

    // --- Admin ---

    function setTwapPeriod(uint32 _twapPeriod) external onlyOwner {
        require(_twapPeriod >= MIN_TWAP_PERIOD && _twapPeriod <= MAX_TWAP_PERIOD, "OUT_OF_BOUNDS");
        emit TwapPeriodUpdated(twapPeriod, _twapPeriod);
        twapPeriod = _twapPeriod;
    }

    function setMaxDeviation(uint256 _maxDeviationBps) external onlyOwner {
        require(_maxDeviationBps >= MIN_DEVIATION_BPS && _maxDeviationBps <= MAX_DEVIATION_BPS_CAP, "OUT_OF_BOUNDS");
        emit MaxDeviationUpdated(maxDeviationBps, _maxDeviationBps);
        maxDeviationBps = _maxDeviationBps;
    }

    function setDefaultHaircut(uint256 _bps) external onlyOwner {
        require(_bps >= MIN_HAIRCUT_BPS && _bps <= MAX_HAIRCUT_BPS, "OUT_OF_BOUNDS");
        emit HaircutUpdated("default", defaultHaircutBps, _bps);
        defaultHaircutBps = _bps;
    }

    function setNarrowRangeHaircut(uint256 _bps) external onlyOwner {
        require(_bps >= MIN_HAIRCUT_BPS && _bps <= MAX_HAIRCUT_BPS, "OUT_OF_BOUNDS");
        emit HaircutUpdated("narrowRange", narrowRangeHaircutBps, _bps);
        narrowRangeHaircutBps = _bps;
    }

    function setOutOfRangeHaircut(uint256 _bps) external onlyOwner {
        require(_bps >= MIN_HAIRCUT_BPS && _bps <= MAX_HAIRCUT_BPS, "OUT_OF_BOUNDS");
        emit HaircutUpdated("outOfRange", outOfRangeHaircutBps, _bps);
        outOfRangeHaircutBps = _bps;
    }

    function setVolatilityHaircut(uint256 _bps) external onlyOwner {
        require(_bps >= MIN_HAIRCUT_BPS / 2 && _bps <= MAX_HAIRCUT_BPS, "OUT_OF_BOUNDS");
        emit HaircutUpdated("volatility", volatilityHaircutBps, _bps);
        volatilityHaircutBps = _bps;
    }

    function setMaxStaleness(uint256 _maxStaleness) external onlyOwner {
        require(_maxStaleness >= 300 && _maxStaleness <= 86_400, "OUT_OF_BOUNDS");
        emit MaxStalenessUpdated(maxStaleness, _maxStaleness);
        maxStaleness = _maxStaleness;
    }

    function setPriceFeed(address token, address feed) external onlyOwner {
        require(token != address(0) && feed != address(0), "ZERO_ADDRESS");
        emit PriceFeedUpdated(token, feed);
        priceFeeds[token] = feed;
    }

    // --- ILPOracle Implementation ---

    /// @inheritdoc ILPOracle
    function getPrice(
        address, /* lpToken */
        uint256 tokenId,
        uint256 /* amount */
    )
        external
        view
        returns (ILPOracleHub.PriceResult memory result)
    {
        result = _computePrice(tokenId);
    }

    /// @inheritdoc ILPOracle
    function getRawPrice(
        address, /* lpToken */
        uint256 tokenId,
        uint256 /* amount */
    )
        external
        view
        returns (uint256)
    {
        ILPOracleHub.PriceResult memory result = _computePrice(tokenId);
        // Reverse the haircut to get raw value
        if (result.haircut >= 10_000) return 0;
        return (result.totalValue * 10_000) / (10_000 - result.haircut);
    }

    /// @inheritdoc ILPOracle
    function isHealthy() external view returns (bool) {
        // Oracle is healthy if it can respond (always true for a view-only oracle).
        // Staleness is checked per-feed in _getChainlinkPrice.
        return true;
    }

    // --- Internal: Core Pricing Logic ---

    function _computePrice(uint256 tokenId) internal view returns (ILPOracleHub.PriceResult memory result) {
        // Step 1: Read position data from NFT manager
        (
            ,,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,,,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = positionManager.positions(tokenId);

        require(liquidity > 0, "NO_LIQUIDITY");

        // Step 2: Get pool and TWAP tick
        address pool = factory.getPool(token0, token1, fee);
        require(pool != address(0), "POOL_NOT_FOUND");

        int24 twapTick = _getTwapTick(pool);

        // Step 3: Calculate token amounts at TWAP tick
        uint160 sqrtPriceX96 = TickMathLib.getSqrtRatioAtTick(twapTick);
        uint160 sqrtPriceAX96 = TickMathLib.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMathLib.getSqrtRatioAtTick(tickUpper);

        (uint256 amount0, uint256 amount1) =
            LiquidityAmountsLib.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity);

        // Step 4: Get token decimals and Chainlink prices (both normalized to 18 dec)
        uint8 dec0 = IERC20(token0).decimals();
        uint8 dec1 = IERC20(token1).decimals();
        uint256 price0 = _getChainlinkPrice(token0); // 18 decimals USD
        uint256 price1 = _getChainlinkPrice(token1); // 18 decimals USD

        // Step 5: Cross-validate TWAP vs Chainlink
        _validatePriceConsistency(twapTick, price0, price1, dec0, dec1);

        // Step 6: Calculate principal value in USD (18 decimals)
        // Normalize token amounts to 18 dec before multiplying by 18-dec price
        // TODO: Verify with real tokens — amount0 from getAmountsForLiquidity is in token0's
        //       native decimals. Confirm this assumption with fork tests against real V3 positions.
        uint256 amount0Normalized = _normalizeTo18(amount0, dec0);
        uint256 amount1Normalized = _normalizeTo18(amount1, dec1);

        uint256 principalValue = (amount0Normalized * price0) / 1e18 + (amount1Normalized * price1) / 1e18;

        // Step 7: Calculate fee value (50% discount for safety)
        // tokensOwed are in native decimals — normalize before pricing
        uint256 feeValue =
            ((_normalizeTo18(uint256(tokensOwed0), dec0) * price0)
                    / 1e18
                    + (_normalizeTo18(uint256(tokensOwed1), dec1) * price1)
                    / 1e18) / 2;

        // Step 8: Apply haircut based on position characteristics
        uint256 haircut = _computeHaircut(tickLower, tickUpper, twapTick);
        uint256 totalValue = LPMath.applyHaircut(principalValue + feeValue, haircut);

        // Step 9: Compute confidence score
        uint256 confidence = _computeConfidence(tickLower, tickUpper, twapTick);

        result = ILPOracleHub.PriceResult({
            totalValue: totalValue,
            principalValue: principalValue,
            feeValue: feeValue,
            haircut: haircut,
            confidence: confidence,
            timestamp: block.timestamp
        });
    }

    // --- Internal: TWAP ---

    /// @notice Get TWAP tick from pool using observe()
    /// @dev Uses configurable twapPeriod. Rounds towards negative infinity.
    /// TODO: Fork test — verify pool.observe() works when:
    ///       - Pool has sufficient observation cardinality for twapPeriod
    ///       - Pool was recently created (short history)
    ///       - Pool has low activity (sparse observations)
    function _getTwapTick(address pool) internal view returns (int24 twapTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriod;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int56 period = int56(uint56(twapPeriod));

        twapTick = int24(tickCumulativesDelta / period);
        // Round towards negative infinity for consistency
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % period != 0)) {
            twapTick--;
        }
    }

    // --- Internal: Chainlink ---

    /// @notice Get price from Chainlink feed, normalized to 18 decimals
    /// @dev Reverts if price is invalid, negative, or stale
    function _getChainlinkPrice(address token) internal view returns (uint256) {
        address feed = priceFeeds[token];
        require(feed != address(0), "NO_PRICE_FEED");

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        require(answer > 0, "INVALID_PRICE");
        require(block.timestamp - updatedAt <= maxStaleness, "STALE_PRICE");

        uint8 feedDecimals = IAggregatorV3(feed).decimals();
        if (feedDecimals < 18) {
            return uint256(answer) * (10 ** (18 - feedDecimals));
        } else if (feedDecimals > 18) {
            return uint256(answer) / (10 ** (feedDecimals - 18));
        }
        return uint256(answer);
    }

    // --- Internal: Cross-Validation ---

    /// @notice Cross-validate TWAP-implied price ratio vs Chainlink ratio
    /// @dev The TWAP gives a token1/token0 ratio in pool-native decimals.
    ///      We must account for different token decimals when comparing to Chainlink.
    /// TODO: This is the MOST CRITICAL function to fork-test. The decimal adjustment
    ///       (twapRatioRaw * 10^(dec0-dec1)) must be verified against real pools:
    ///       - ETH/USDC pool (18/6 dec) — most common, must work
    ///       - WBTC/ETH pool (8/18 dec) — reversed decimal relationship
    ///       - DAI/USDC pool (18/6 dec) — stablecoin pair, ratio near 1.0
    function _validatePriceConsistency(
        int24 twapTick,
        uint256 price0,
        uint256 price1,
        uint8 dec0,
        uint8 dec1
    )
        internal
        view
    {
        if (price0 == 0 || price1 == 0) return;

        // TWAP ratio: sqrtPrice^2 / 2^192 gives token1/token0 in raw pool units
        // For a pool with token0=WETH(18dec) and token1=USDC(6dec),
        // the raw ratio is in USDC_units/WETH_units = (6dec)/(18dec) units
        // We need to adjust for decimal difference to compare with Chainlink
        uint160 twapSqrtPrice = TickMathLib.getSqrtRatioAtTick(twapTick);
        uint256 twapPriceSq = uint256(twapSqrtPrice) * uint256(twapSqrtPrice);
        // Raw TWAP ratio (token1_raw_per_token0_raw) in Q192 format
        // Normalize to 18 decimals: mulDiv(twapPriceSq, 1e18, 2^192)
        // Note: 2^192 fits in uint256 (≈ 6.27e57, max uint256 ≈ 1.16e77)
        uint256 twapRatioRaw = LiquidityAmountsLib.mulDiv(twapPriceSq, 1e18, uint256(1) << 192);

        // Adjust for decimal difference:
        // twapRatioRaw is in (token1_native / token0_native) units
        // To get a decimal-normalized ratio, multiply by 10^(dec0-dec1)
        // Example: WETH(18)/USDC(6) → multiply by 10^12 to normalize
        uint256 twapRatioNormalized;
        if (dec0 >= dec1) {
            twapRatioNormalized = twapRatioRaw * (10 ** (dec0 - dec1));
        } else {
            twapRatioNormalized = twapRatioRaw / (10 ** (dec1 - dec0));
        }

        // Chainlink ratio: price0/price1 (both 18 dec USD)
        // This gives "how many token1-values per token0-value" = token1_per_token0 in USD terms
        uint256 chainlinkRatio = (price0 * 1e18) / price1;

        uint256 deviation = LPMath.deviationBps(twapRatioNormalized, chainlinkRatio);
        require(deviation <= maxDeviationBps, "ORACLE_DEVIATION");
    }

    // --- Internal: Haircut & Confidence ---

    /// @notice Determine haircut based on position characteristics
    function _computeHaircut(int24 tickLower, int24 tickUpper, int24 currentTick) internal view returns (uint256) {
        // Out of range — position is 100% one token, higher risk
        if (currentTick < tickLower || currentTick >= tickUpper) {
            return outOfRangeHaircutBps;
        }
        // Narrow range (< 200 ticks) — higher IL risk
        int24 rangeWidth = tickUpper - tickLower;
        if (rangeWidth < 200) {
            return narrowRangeHaircutBps;
        }
        return defaultHaircutBps;
    }

    /// @notice Compute oracle confidence based on position state (0-10000 bps)
    function _computeConfidence(int24 tickLower, int24 tickUpper, int24 currentTick) internal pure returns (uint256) {
        // Out of range: 70% confidence
        if (currentTick < tickLower || currentTick >= tickUpper) {
            return 7000;
        }
        // In range: 80-100% based on how centered the tick is
        int24 rangeWidth = tickUpper - tickLower;
        int24 center = tickLower + rangeWidth / 2;
        int24 distFromCenter = currentTick > center ? currentTick - center : center - currentTick;
        int24 halfRange = rangeWidth / 2;

        if (halfRange == 0) return 8000;
        uint256 centeredness = uint256(int256(halfRange - distFromCenter)) * 2000 / uint256(int256(halfRange));
        return 8000 + centeredness; // 8000-10000
    }

    // --- Internal: Helpers ---

    /// @notice Normalize a token amount to 18 decimals
    function _normalizeTo18(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals == 18) return amount;
        if (tokenDecimals < 18) return amount * (10 ** (18 - tokenDecimals));
        return amount / (10 ** (tokenDecimals - 18));
    }
}
