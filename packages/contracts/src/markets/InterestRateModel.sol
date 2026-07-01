// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title InterestRateModel
/// @notice Kinked interest rate model — gentle slope below kink, steep above
/// @dev Incentivizes utilization near the kink point (target utilization)
contract InterestRateModel {
    // All rates are per-second, scaled by 1e18
    // Annual rates are converted: ratePerSecond = annualRate / 365.25 / 86400

    uint256 public immutable baseRatePerSecond; // Rate at 0% utilization
    uint256 public immutable slope1PerSecond; // Slope below kink
    uint256 public immutable slope2PerSecond; // Slope above kink (steep)
    uint256 public immutable kink; // Target utilization (bps, e.g., 8000 = 80%)

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365.25 days;

    constructor(
        uint256 baseRateAnnualBps, // e.g., 200 = 2%
        uint256 slope1AnnualBps, // e.g., 600 = 6%
        uint256 slope2AnnualBps, // e.g., 10000 = 100%
        uint256 _kink // e.g., 8000 = 80%
    ) {
        baseRatePerSecond = (baseRateAnnualBps * 1e18) / BPS / SECONDS_PER_YEAR;
        slope1PerSecond = (slope1AnnualBps * 1e18) / BPS / SECONDS_PER_YEAR;
        slope2PerSecond = (slope2AnnualBps * 1e18) / BPS / SECONDS_PER_YEAR;
        kink = _kink;
    }

    /// @notice Calculate borrow rate based on utilization
    /// @param utilization Current utilization in basis points (0-10000)
    /// @return ratePerSecond The borrow rate per second (1e18 scale)
    function getBorrowRate(uint256 utilization) external view returns (uint256 ratePerSecond) {
        if (utilization <= kink) {
            // Below kink: base + slope1 * (utilization / kink)
            ratePerSecond = baseRatePerSecond + (slope1PerSecond * utilization) / kink;
        } else {
            // Above kink: base + slope1 + slope2 * ((utilization - kink) / (10000 - kink))
            uint256 rateAtKink = baseRatePerSecond + slope1PerSecond;
            uint256 excessUtilization = utilization - kink;
            uint256 excessRange = BPS - kink;
            ratePerSecond = rateAtKink + (slope2PerSecond * excessUtilization) / excessRange;
        }
    }

    /// @notice Calculate supply rate (what lenders earn)
    /// @param utilization Current utilization in bps
    /// @param protocolFeeBps Protocol's cut of interest in bps
    /// @return ratePerSecond The supply rate per second (1e18 scale)
    function getSupplyRate(
        uint256 utilization,
        uint256 protocolFeeBps
    ) external view returns (uint256 ratePerSecond) {
        uint256 borrowRate = this.getBorrowRate(utilization);
        // Supply rate = borrow rate * utilization * (1 - protocolFee)
        uint256 protocolCut = (borrowRate * protocolFeeBps) / BPS;
        ratePerSecond = ((borrowRate - protocolCut) * utilization) / BPS;
    }

    /// @notice Get annual percentage rate for display
    function getBorrowRateAPR(uint256 utilization) external view returns (uint256 aprBps) {
        uint256 ratePerSecond = this.getBorrowRate(utilization);
        aprBps = (ratePerSecond * SECONDS_PER_YEAR * BPS) / 1e18;
    }
}
