// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {ILPOracleHub} from "../../src/interfaces/ILPOracleHub.sol";

/// @notice Mock oracle for testing — returns configurable prices
contract MockLPOracle is ILPOracle {
    uint256 public mockPrice = 50_000e18; // Default $50,000
    bool public healthy = true;

    // Optional override to simulate a fee-only position (principalValue == 0, totalValue > 0).
    uint256 public mockPrincipal;
    bool public principalOverride;

    function setPrice(uint256 _price) external {
        mockPrice = _price;
    }

    function setHealthy(bool _healthy) external {
        healthy = _healthy;
    }

    /// @notice Force principalValue independently of totalValue (e.g. fee-only positions)
    function setPrincipalValue(uint256 _principal) external {
        mockPrincipal = _principal;
        principalOverride = true;
    }

    function getPrice(address, uint256, uint256) external view override returns (ILPOracleHub.PriceResult memory) {
        return ILPOracleHub.PriceResult({
            totalValue: mockPrice,
            principalValue: principalOverride ? mockPrincipal : mockPrice,
            feeValue: 0,
            confidence: 10_000,
            timestamp: block.timestamp
        });
    }

    function getRawPrice(address, uint256, uint256) external view override returns (uint256) {
        return mockPrice;
    }

    function isHealthy() external view override returns (bool) {
        return healthy;
    }
}
