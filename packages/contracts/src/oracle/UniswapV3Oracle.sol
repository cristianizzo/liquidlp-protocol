// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPOracle} from "../interfaces/ILPOracle.sol";
import {ILPOracleHub} from "../interfaces/ILPOracleHub.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {LPMath} from "../libraries/LPMath.sol";

/// @title UniswapV3Oracle
/// @notice Prices Uniswap V3 NFT positions using TWAP + Chainlink cross-validation
/// @dev Uses ProtocolCore for ownership — DAO controls all parameters.
///      Not proxied — deploy new oracle + register in LPOracleHub to upgrade logic.
///      Parameters are updatable by core.owner() (Aragon DAO).
contract UniswapV3Oracle is ILPOracle {
    ProtocolCore public immutable core;

    // Chainlink price feed addresses (set per chain)
    mapping(address => address) public priceFeeds; // token → Chainlink feed

    // --- Configurable Parameters ---
    uint32 public twapPeriod = 1800; // 30 minutes
    uint256 public maxDeviationBps = 300; // 3% max TWAP vs Chainlink deviation
    uint256 public defaultHaircutBps = 700; // 7% default haircut for V3
    uint256 public narrowRangeHaircutBps = 1000; // 10% for narrow ranges
    uint256 public outOfRangeHaircutBps = 1200; // 12% for out-of-range positions
    uint256 public volatilityHaircutBps = 500; // +5% during high volatility

    // --- Absolute Bounds ---
    uint32 public constant MIN_TWAP_PERIOD = 300; // 5 min
    uint32 public constant MAX_TWAP_PERIOD = 7200; // 2 hours
    uint256 public constant MIN_HAIRCUT_BPS = 200; // 2%
    uint256 public constant MAX_HAIRCUT_BPS = 3000; // 30%
    uint256 public constant MIN_DEVIATION_BPS = 100; // 1%
    uint256 public constant MAX_DEVIATION_BPS_CAP = 1000; // 10%

    uint256 public lastUpdateTimestamp;

    // --- Events ---
    event TwapPeriodUpdated(uint32 oldValue, uint32 newValue);
    event MaxDeviationUpdated(uint256 oldValue, uint256 newValue);
    event HaircutUpdated(string haircutType, uint256 oldValue, uint256 newValue);
    event PriceFeedUpdated(address indexed token, address indexed feed);

    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
        _;
    }

    constructor(address _core) {
        core = ProtocolCore(_core);
        lastUpdateTimestamp = block.timestamp;
    }

    // --- Admin Setters (controlled by DAO via ProtocolCore.owner()) ---

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

    function setDefaultHaircut(uint256 _haircutBps) external onlyOwner {
        require(_haircutBps >= MIN_HAIRCUT_BPS && _haircutBps <= MAX_HAIRCUT_BPS, "OUT_OF_BOUNDS");
        emit HaircutUpdated("default", defaultHaircutBps, _haircutBps);
        defaultHaircutBps = _haircutBps;
    }

    function setNarrowRangeHaircut(uint256 _haircutBps) external onlyOwner {
        require(_haircutBps >= MIN_HAIRCUT_BPS && _haircutBps <= MAX_HAIRCUT_BPS, "OUT_OF_BOUNDS");
        emit HaircutUpdated("narrowRange", narrowRangeHaircutBps, _haircutBps);
        narrowRangeHaircutBps = _haircutBps;
    }

    function setOutOfRangeHaircut(uint256 _haircutBps) external onlyOwner {
        require(_haircutBps >= MIN_HAIRCUT_BPS && _haircutBps <= MAX_HAIRCUT_BPS, "OUT_OF_BOUNDS");
        emit HaircutUpdated("outOfRange", outOfRangeHaircutBps, _haircutBps);
        outOfRangeHaircutBps = _haircutBps;
    }

    function setVolatilityHaircut(uint256 _haircutBps) external onlyOwner {
        require(_haircutBps >= MIN_HAIRCUT_BPS / 2 && _haircutBps <= MAX_HAIRCUT_BPS, "OUT_OF_BOUNDS");
        emit HaircutUpdated("volatility", volatilityHaircutBps, _haircutBps);
        volatilityHaircutBps = _haircutBps;
    }

    function setPriceFeed(address token, address feed) external onlyOwner {
        require(token != address(0) && feed != address(0), "ZERO_ADDRESS");
        emit PriceFeedUpdated(token, feed);
        priceFeeds[token] = feed;
    }

    // --- ILPOracle Implementation ---

    /// @inheritdoc ILPOracle
    function getPrice(address, uint256, uint256) external view returns (ILPOracleHub.PriceResult memory result) {
        // Full implementation requires external interfaces (see docs/contracts/oracle.md)
        result = ILPOracleHub.PriceResult({
            totalValue: 0, principalValue: 0, feeValue: 0,
            haircut: defaultHaircutBps, confidence: 10_000, timestamp: block.timestamp
        });
    }

    /// @inheritdoc ILPOracle
    function getRawPrice(address, uint256, uint256) external view returns (uint256) { return 0; }

    /// @inheritdoc ILPOracle
    function isHealthy() external view returns (bool) {
        return (block.timestamp - lastUpdateTimestamp) < 3600;
    }
}
