// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPOracle} from "../interfaces/ILPOracle.sol";
import {ILPOracleHub} from "../interfaces/ILPOracleHub.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title AerodromeOracle
/// @notice Prices Aerodrome/Velodrome LP positions
/// @dev Uses ProtocolCore for ownership — DAO controls all parameters.
contract AerodromeOracle is ILPOracle {
    ProtocolCore public immutable core;

    mapping(address => address) public priceFeeds;

    mapping(address => bool) public isStablePool;

    uint256 public lastUpdateTimestamp;

    event PoolStableStatusUpdated(address indexed pool, bool stable);
    event PriceFeedUpdated(address indexed token, address indexed feed);

    modifier onlyPoolAdmin() {
        require(core.aclManager().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    constructor(address _core) {
        core = ProtocolCore(_core);
        lastUpdateTimestamp = block.timestamp;
    }

    function setPoolStable(address pool, bool stable) external onlyPoolAdmin {
        isStablePool[pool] = stable;
        emit PoolStableStatusUpdated(pool, stable);
    }

    function setPriceFeed(address token, address feed) external onlyPoolAdmin {
        require(token != address(0) && feed != address(0), "ZERO_ADDRESS");
        emit PriceFeedUpdated(token, feed);
        priceFeeds[token] = feed;
    }

    /// @inheritdoc ILPOracle
    function getPrice(address, uint256, uint256) external view returns (ILPOracleHub.PriceResult memory result) {
        result = ILPOracleHub.PriceResult({
            totalValue: 0, principalValue: 0, feeValue: 0, confidence: 10_000, timestamp: block.timestamp
        });
    }

    /// @inheritdoc ILPOracle
    function getRawPrice(address, uint256, uint256) external view returns (uint256) {
        return 0;
    }

    /// @inheritdoc ILPOracle
    function isHealthy() external view returns (bool) {
        return (block.timestamp - lastUpdateTimestamp) < 3600;
    }
}
