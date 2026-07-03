// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title CircuitBreaker
/// @notice Granular pause mechanism for individual markets and pools
/// @dev EmergencyAdmin/Keeper can pause. Only PoolAdmin can unpause.
contract CircuitBreaker {
    ProtocolCore public immutable core;

    // Per-market pause state
    mapping(uint256 => bool) public marketPaused;
    mapping(uint256 => string) public pauseReason;
    mapping(uint256 => uint256) public pausedAt;

    // Per-pool pause state
    mapping(address => bool) public poolPaused;

    // --- Events ---
    event MarketPaused(uint256 indexed marketId, string reason);
    event MarketUnpaused(uint256 indexed marketId);
    event PoolPaused(address indexed pool, string reason);
    event PoolUnpaused(address indexed pool);

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyGuardianOrKeeper() {
        ACLManager acl = _acl();
        require(
            acl.isEmergencyAdmin(msg.sender) || acl.isPoolAdmin(msg.sender) || acl.isKeeper(msg.sender),
            "NOT_AUTHORIZED"
        );
        _;
    }

    modifier onlyPoolAdmin() {
        require(_acl().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    constructor(address _core) {
        core = ProtocolCore(_core);
    }

    /// @notice Pause a specific market
    function pauseMarket(uint256 marketId, string calldata reason) external onlyGuardianOrKeeper {
        marketPaused[marketId] = true;
        pauseReason[marketId] = reason;
        pausedAt[marketId] = block.timestamp;
        emit MarketPaused(marketId, reason);
    }

    /// @notice Unpause a market (guardian/owner only, after investigation)
    function unpauseMarket(uint256 marketId) external onlyPoolAdmin {
        marketPaused[marketId] = false;
        pauseReason[marketId] = "";
        emit MarketUnpaused(marketId);
    }

    /// @notice Pause all operations for a specific pool
    function pausePool(address pool, string calldata reason) external onlyGuardianOrKeeper {
        poolPaused[pool] = true;
        emit PoolPaused(pool, reason);
    }

    /// @notice Unpause a pool (guardian/owner only, after investigation)
    function unpausePool(address pool) external onlyPoolAdmin {
        poolPaused[pool] = false;
        emit PoolUnpaused(pool);
    }

    /// @notice Check if operations are allowed for a market
    function isOperationAllowed(uint256 marketId) external view returns (bool) {
        if (core.paused()) return false;
        if (marketPaused[marketId]) return false;
        return true;
    }

    /// @notice Check if a pool's positions can be managed
    function isPoolOperationAllowed(address pool) external view returns (bool) {
        if (core.paused()) return false;
        if (poolPaused[pool]) return false;
        return true;
    }
}
