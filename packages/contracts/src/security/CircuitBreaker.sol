// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title CircuitBreaker
/// @notice Granular pause mechanism for individual markets and pools
/// @dev Keepers/guardian can pause. Only guardian/owner can unpause.
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

    modifier onlyGuardianOrKeeper() {
        require(
            msg.sender == core.guardian() || msg.sender == core.owner() || core.keepers(msg.sender),
            "NOT_AUTHORIZED"
        );
        _;
    }

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == core.owner() || msg.sender == core.guardian(), "NOT_AUTHORIZED");
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
    function unpauseMarket(uint256 marketId) external onlyOwnerOrGuardian {
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
    function unpausePool(address pool) external onlyOwnerOrGuardian {
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
