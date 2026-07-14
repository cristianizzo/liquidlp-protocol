// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";
import {CircuitBreaker} from "../security/CircuitBreaker.sol";

/// @title PriceValidator
/// @notice Cross-validates oracle prices and triggers circuit breakers
/// @dev Implements defense layers against oracle manipulation.
///      Triggers CircuitBreaker.pausePool() — unified pause system with PositionManager.
///      All thresholds are configurable by RISK_ADMIN.
contract PriceValidator {
    ProtocolCore public immutable core;
    CircuitBreaker public immutable circuitBreaker;

    mapping(address => uint256) public lastKnownTvl;
    mapping(address => uint256) public lastPriceTimestamp;

    // --- Configurable Thresholds ---
    uint256 public maxPriceDeviationBps = 300; // 3% TWAP vs Chainlink
    uint256 public maxVolatilityBps = 1000; // 10% in 5 minutes
    uint256 public minPoolTvl = 1_000_000e18; // $1M minimum
    uint256 public stalePriceThreshold = 3600; // 1 hour
    uint256 public tvlDropThresholdBps = 3000; // 30% TVL drop triggers pause

    // --- Absolute Bounds ---
    uint256 public constant MIN_DEVIATION_BPS = 100;
    uint256 public constant MAX_DEVIATION_BPS_CAP = 1000;
    uint256 public constant MIN_VOLATILITY_BPS = 300;
    uint256 public constant MAX_VOLATILITY_BPS_CAP = 3000;
    uint256 public constant MIN_TVL_FLOOR = 100_000e18;
    uint256 public constant MIN_STALE_THRESHOLD = 600;
    uint256 public constant MAX_STALE_THRESHOLD = 86_400;
    uint256 public constant MIN_TVL_DROP_BPS = 1000;
    uint256 public constant MAX_TVL_DROP_BPS = 8000;

    // Volatility tracking
    struct PriceSnapshot {
        uint256 price;
        uint256 timestamp;
    }

    mapping(address => PriceSnapshot[]) public priceHistory;
    mapping(address => uint256) public priceHistoryIndex; // ring buffer write index

    // --- Events ---
    event PriceValidated(address indexed pool, uint256 price, uint256 confidence);
    event ParameterUpdated(string name, uint256 oldValue, uint256 newValue);

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyRiskAdmin() {
        ACLManager acl = _acl();
        require(acl.isRiskAdmin(msg.sender) || acl.isPoolAdmin(msg.sender), "NOT_RISK_ADMIN");
        _;
    }

    modifier onlyKeeper() {
        ACLManager acl = _acl();
        require(acl.isKeeper(msg.sender) || acl.isPoolAdmin(msg.sender), "NOT_KEEPER");
        _;
    }

    constructor(address _core, address _circuitBreaker) {
        require(_core != address(0) && _circuitBreaker != address(0), "ZERO_ADDRESS");
        require(_core.code.length > 0 && _circuitBreaker.code.length > 0, "NOT_CONTRACT");
        core = ProtocolCore(_core);
        circuitBreaker = CircuitBreaker(_circuitBreaker);
        require(address(circuitBreaker.core()) == _core, "CORE_MISMATCH");
    }

    // --- Admin Setters ---

    function setMaxPriceDeviation(uint256 _bps) external onlyRiskAdmin {
        require(_bps >= MIN_DEVIATION_BPS && _bps <= MAX_DEVIATION_BPS_CAP, "OUT_OF_BOUNDS");
        emit ParameterUpdated("maxPriceDeviationBps", maxPriceDeviationBps, _bps);
        maxPriceDeviationBps = _bps;
    }

    function setMaxVolatility(uint256 _bps) external onlyRiskAdmin {
        require(_bps >= MIN_VOLATILITY_BPS && _bps <= MAX_VOLATILITY_BPS_CAP, "OUT_OF_BOUNDS");
        emit ParameterUpdated("maxVolatilityBps", maxVolatilityBps, _bps);
        maxVolatilityBps = _bps;
    }

    function setMinPoolTvl(uint256 _minTvl) external onlyRiskAdmin {
        require(_minTvl >= MIN_TVL_FLOOR, "BELOW_ABSOLUTE_MIN");
        emit ParameterUpdated("minPoolTvl", minPoolTvl, _minTvl);
        minPoolTvl = _minTvl;
    }

    function setStalePriceThreshold(uint256 _seconds) external onlyRiskAdmin {
        require(_seconds >= MIN_STALE_THRESHOLD && _seconds <= MAX_STALE_THRESHOLD, "OUT_OF_BOUNDS");
        emit ParameterUpdated("stalePriceThreshold", stalePriceThreshold, _seconds);
        stalePriceThreshold = _seconds;
    }

    function setTvlDropThreshold(uint256 _bps) external onlyRiskAdmin {
        require(_bps >= MIN_TVL_DROP_BPS && _bps <= MAX_TVL_DROP_BPS, "OUT_OF_BOUNDS");
        emit ParameterUpdated("tvlDropThresholdBps", tvlDropThresholdBps, _bps);
        tvlDropThresholdBps = _bps;
    }

    // --- Core Logic ---

    /// @notice Validate price and trigger circuit breaker if needed
    /// @dev Called by keeper only. Writes to CircuitBreaker (unified pause system).
    function validatePrice(
        address pool,
        uint256 twapPrice,
        uint256 chainlinkPrice,
        uint256 poolTvl
    )
        external
        onlyKeeper
        returns (bool valid, uint256 adjustedRiskBps)
    {
        require(!circuitBreaker.poolPaused(pool), "POOL_CIRCUIT_BREAKER");

        adjustedRiskBps = 0;

        // Check 1: TWAP vs Chainlink deviation
        uint256 deviation = _calculateDeviation(twapPrice, chainlinkPrice);
        if (deviation > maxPriceDeviationBps) {
            circuitBreaker.pausePool(pool, "ORACLE_DEVIATION");
            return (false, 0);
        }

        // Check 2: Pool TVL minimum
        if (poolTvl < minPoolTvl) {
            circuitBreaker.pausePool(pool, "TVL_TOO_LOW");
            return (false, 0);
        }

        // Check 3: TVL drop detection
        if (lastKnownTvl[pool] > 0 && lastPriceTimestamp[pool] > 0) {
            uint256 elapsed = block.timestamp - lastPriceTimestamp[pool];
            if (elapsed <= 1 hours && poolTvl < lastKnownTvl[pool]) {
                uint256 tvlDropBps = ((lastKnownTvl[pool] - poolTvl) * 10_000) / lastKnownTvl[pool];
                if (tvlDropBps >= tvlDropThresholdBps) {
                    circuitBreaker.pausePool(pool, "TVL_DROP");
                    return (false, 0);
                }
            }
        }

        // Check 4: Volatility check
        uint256 volatility = _checkVolatility(pool, twapPrice);
        if (volatility > maxVolatilityBps) {
            adjustedRiskBps = 500; // +5% risk premium during high volatility
        }

        // Check 5: Staleness check
        if (lastPriceTimestamp[pool] > 0) {
            uint256 elapsed = block.timestamp - lastPriceTimestamp[pool];
            if (elapsed > stalePriceThreshold) {
                adjustedRiskBps += 200; // +2% risk premium for stale prices
            }
        }

        // Record price snapshot (ring buffer — overwrites oldest entry at 100 cap)
        lastKnownTvl[pool] = poolTvl;
        lastPriceTimestamp[pool] = block.timestamp;
        if (priceHistory[pool].length < 100) {
            priceHistory[pool].push(PriceSnapshot(twapPrice, block.timestamp));
        } else {
            uint256 idx = priceHistoryIndex[pool] % 100;
            priceHistory[pool][idx] = PriceSnapshot(twapPrice, block.timestamp);
            priceHistoryIndex[pool] = (idx + 1) % 100;
        }

        emit PriceValidated(pool, twapPrice, 10_000 - adjustedRiskBps);
        return (true, adjustedRiskBps);
    }

    // --- Internal ---

    /// @dev Deviation anchored to parameter `a` (asymmetric by ~0.1% at 3% threshold).
    ///      Same approach as Chainlink deviation checks. Using max(a,b) would add gas
    ///      for negligible precision improvement.
    function _calculateDeviation(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 10_000;
        uint256 diff = a > b ? a - b : b - a;
        return (diff * 10_000) / a;
    }

    function _checkVolatility(address pool, uint256 currentPrice) internal view returns (uint256) {
        PriceSnapshot[] storage history = priceHistory[pool];
        if (history.length == 0) return 0;

        // Find entry closest to 5 minutes ago (ring buffer — entries not chronologically ordered)
        if (block.timestamp < 300) return 0;
        uint256 targetTimestamp = block.timestamp - 300;
        uint256 bestPrice = 0;
        uint256 bestDelta = type(uint256).max;
        for (uint256 i = 0; i < history.length; i++) {
            if (history[i].timestamp <= targetTimestamp) {
                uint256 delta = targetTimestamp - history[i].timestamp;
                if (delta < bestDelta) {
                    bestDelta = delta;
                    bestPrice = history[i].price;
                }
            }
        }
        if (bestPrice == 0) return 0;
        return _calculateDeviation(currentPrice, bestPrice);
    }
}
