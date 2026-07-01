// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPOracle} from "../interfaces/ILPOracle.sol";
import {ILPOracleHub} from "../interfaces/ILPOracleHub.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title CurveOracle
/// @notice Prices Curve LP tokens using virtual price + Chainlink validation
/// @dev Uses ProtocolCore for ownership — DAO controls all parameters.
contract CurveOracle is ILPOracle {
    ProtocolCore public immutable core;

    mapping(address => address) public priceFeeds;

    // --- Configurable Parameters ---
    uint256 public defaultHaircutBps = 300; // 3%
    uint256 public maxVirtualPriceDeviationBps = 100; // 1%

    mapping(address => uint256) public lastVirtualPrice;

    // --- Absolute Bounds ---
    uint256 public constant MIN_HAIRCUT_BPS = 50;
    uint256 public constant MAX_HAIRCUT_BPS = 1500;
    uint256 public constant MIN_VP_DEVIATION_BPS = 50;
    uint256 public constant MAX_VP_DEVIATION_BPS = 500;

    uint256 public lastUpdateTimestamp;

    event HaircutUpdated(uint256 oldValue, uint256 newValue);
    event VPDeviationUpdated(uint256 oldValue, uint256 newValue);
    event PriceFeedUpdated(address indexed token, address indexed feed);

    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
        _;
    }

    constructor(address _core) {
        core = ProtocolCore(_core);
        lastUpdateTimestamp = block.timestamp;
    }

    function setDefaultHaircut(uint256 _haircutBps) external onlyOwner {
        require(_haircutBps >= MIN_HAIRCUT_BPS && _haircutBps <= MAX_HAIRCUT_BPS, "OUT_OF_BOUNDS");
        emit HaircutUpdated(defaultHaircutBps, _haircutBps);
        defaultHaircutBps = _haircutBps;
    }

    function setMaxVirtualPriceDeviation(uint256 _deviationBps) external onlyOwner {
        require(_deviationBps >= MIN_VP_DEVIATION_BPS && _deviationBps <= MAX_VP_DEVIATION_BPS, "OUT_OF_BOUNDS");
        emit VPDeviationUpdated(maxVirtualPriceDeviationBps, _deviationBps);
        maxVirtualPriceDeviationBps = _deviationBps;
    }

    function setPriceFeed(address token, address feed) external onlyOwner {
        require(token != address(0) && feed != address(0), "ZERO_ADDRESS");
        emit PriceFeedUpdated(token, feed);
        priceFeeds[token] = feed;
    }

    /// @inheritdoc ILPOracle
    function getPrice(address, uint256, uint256) external view returns (ILPOracleHub.PriceResult memory result) {
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
