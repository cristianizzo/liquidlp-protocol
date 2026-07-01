// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title PriceValidator
/// @notice Cross-validates oracle prices and triggers circuit breakers
/// @dev Implements multiple defense layers against oracle manipulation.
///      All thresholds are configurable by owner (Aragon DAO).
contract PriceValidator {
    ProtocolCore public immutable core;

    // Circuit breaker state
    mapping(address => bool) public poolPaused;
    mapping(address => uint256) public lastKnownPrice;
    mapping(address => uint256) public lastPriceTimestamp;

    // --- Configurable Thresholds ---
    uint256 public maxPriceDeviationBps = 300; // 3% TWAP vs Chainlink
    uint256 public maxVolatilityBps = 1000; // 10% in 5 minutes
    uint256 public minPoolTvl = 1_000_000e18; // $1M minimum
    uint256 public stalePriceThreshold = 3600; // 1 hour
    uint256 public tvlDropThresholdBps = 3000; // 30% TVL drop triggers pause

    // --- Absolute Bounds ---
    uint256 public constant MIN_DEVIATION_BPS = 100; // 1%
    uint256 public constant MAX_DEVIATION_BPS_CAP = 1000; // 10%
    uint256 public constant MIN_VOLATILITY_BPS = 300; // 3%
    uint256 public constant MAX_VOLATILITY_BPS_CAP = 3000; // 30%
    uint256 public constant MIN_TVL_FLOOR = 100_000e18; // $100K absolute min
    uint256 public constant MIN_STALE_THRESHOLD = 600; // 10 minutes
    uint256 public constant MAX_STALE_THRESHOLD = 86_400; // 24 hours
    uint256 public constant MIN_TVL_DROP_BPS = 1000; // 10%
    uint256 public constant MAX_TVL_DROP_BPS = 8000; // 80%

    // Volatility tracking
    struct PriceSnapshot {
        uint256 price;
        uint256 timestamp;
    }
    mapping(address => PriceSnapshot[]) public priceHistory;

    // --- Events ---
    event CircuitBreakerTriggered(address indexed pool, string reason);
    event CircuitBreakerReset(address indexed pool);
    event PriceValidated(address indexed pool, uint256 price, uint256 confidence);
    event ParameterUpdated(string name, uint256 oldValue, uint256 newValue);

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == core.owner() || msg.sender == core.guardian(), "NOT_AUTHORIZED");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
        _;
    }

    constructor(address _core) {
        core = ProtocolCore(_core);
    }

    // --- Admin Setters ---

    function setMaxPriceDeviation(uint256 _bps) external onlyOwner {
        require(_bps >= MIN_DEVIATION_BPS && _bps <= MAX_DEVIATION_BPS_CAP, "OUT_OF_BOUNDS");
        emit ParameterUpdated("maxPriceDeviationBps", maxPriceDeviationBps, _bps);
        maxPriceDeviationBps = _bps;
    }

    function setMaxVolatility(uint256 _bps) external onlyOwner {
        require(_bps >= MIN_VOLATILITY_BPS && _bps <= MAX_VOLATILITY_BPS_CAP, "OUT_OF_BOUNDS");
        emit ParameterUpdated("maxVolatilityBps", maxVolatilityBps, _bps);
        maxVolatilityBps = _bps;
    }

    function setMinPoolTvl(uint256 _minTvl) external onlyOwner {
        require(_minTvl >= MIN_TVL_FLOOR, "BELOW_ABSOLUTE_MIN");
        emit ParameterUpdated("minPoolTvl", minPoolTvl, _minTvl);
        minPoolTvl = _minTvl;
    }

    function setStalePriceThreshold(uint256 _seconds) external onlyOwner {
        require(_seconds >= MIN_STALE_THRESHOLD && _seconds <= MAX_STALE_THRESHOLD, "OUT_OF_BOUNDS");
        emit ParameterUpdated("stalePriceThreshold", stalePriceThreshold, _seconds);
        stalePriceThreshold = _seconds;
    }

    function setTvlDropThreshold(uint256 _bps) external onlyOwner {
        require(_bps >= MIN_TVL_DROP_BPS && _bps <= MAX_TVL_DROP_BPS, "OUT_OF_BOUNDS");
        emit ParameterUpdated("tvlDropThresholdBps", tvlDropThresholdBps, _bps);
        tvlDropThresholdBps = _bps;
    }

    // --- Core Logic ---

    function validatePrice(
        address pool,
        uint256 twapPrice,
        uint256 chainlinkPrice,
        uint256 poolTvl
    ) external returns (bool valid, uint256 adjustedHaircutBps) {
        require(!poolPaused[pool], "POOL_CIRCUIT_BREAKER");

        adjustedHaircutBps = 0;

        // Check 1: TWAP vs Chainlink deviation
        uint256 deviation = _calculateDeviation(twapPrice, chainlinkPrice);
        if (deviation > maxPriceDeviationBps) {
            poolPaused[pool] = true;
            emit CircuitBreakerTriggered(pool, "ORACLE_DEVIATION");
            return (false, 0);
        }

        // Check 2: Pool TVL minimum
        if (poolTvl < minPoolTvl) {
            poolPaused[pool] = true;
            emit CircuitBreakerTriggered(pool, "TVL_TOO_LOW");
            return (false, 0);
        }

        // Check 3: TVL drop detection
        if (lastKnownPrice[pool] > 0 && lastPriceTimestamp[pool] > 0) {
            uint256 elapsed = block.timestamp - lastPriceTimestamp[pool];
            if (elapsed <= 1 hours && poolTvl < lastKnownPrice[pool]) {
                uint256 tvlDropBps = ((lastKnownPrice[pool] - poolTvl) * 10_000) / lastKnownPrice[pool];
                if (tvlDropBps >= tvlDropThresholdBps) {
                    poolPaused[pool] = true;
                    emit CircuitBreakerTriggered(pool, "TVL_DROP");
                    return (false, 0);
                }
            }
        }

        // Check 4: Volatility check
        uint256 volatility = _checkVolatility(pool, twapPrice);
        if (volatility > maxVolatilityBps) {
            adjustedHaircutBps = 500; // +5% haircut during high volatility
        }

        // Check 5: Staleness check
        if (lastPriceTimestamp[pool] > 0) {
            uint256 elapsed = block.timestamp - lastPriceTimestamp[pool];
            if (elapsed > stalePriceThreshold) {
                adjustedHaircutBps += 200; // +2% haircut for stale prices
            }
        }

        // Record price snapshot
        lastKnownPrice[pool] = twapPrice;
        lastPriceTimestamp[pool] = block.timestamp;
        priceHistory[pool].push(PriceSnapshot(twapPrice, block.timestamp));

        emit PriceValidated(pool, twapPrice, 10_000 - adjustedHaircutBps);
        return (true, adjustedHaircutBps);
    }

    function resetCircuitBreaker(address pool) external onlyOwnerOrGuardian {
        poolPaused[pool] = false;
        emit CircuitBreakerReset(pool);
    }

    function triggerCircuitBreaker(address pool, string calldata reason) external onlyOwnerOrGuardian {
        poolPaused[pool] = true;
        emit CircuitBreakerTriggered(pool, reason);
    }

    // --- Internal ---

    function _calculateDeviation(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 10_000;
        uint256 diff = a > b ? a - b : b - a;
        return (diff * 10_000) / a;
    }

    function _checkVolatility(address pool, uint256 currentPrice) internal view returns (uint256) {
        PriceSnapshot[] storage history = priceHistory[pool];
        if (history.length == 0) return 0;

        uint256 targetTimestamp = block.timestamp - 300;
        for (uint256 i = history.length; i > 0; i--) {
            if (history[i - 1].timestamp <= targetTimestamp) {
                return _calculateDeviation(currentPrice, history[i - 1].price);
            }
        }
        return 0;
    }
}
