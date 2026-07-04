// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LPMath} from "../../src/libraries/LPMath.sol";

/// @dev Wrapper to make internal LPMath functions callable externally (for vm.expectRevert)
contract LPMathWrapper {
    function fairLPValueV2(
        uint256 r0,
        uint256 r1,
        uint256 ts,
        uint256 p0,
        uint256 p1,
        uint256 amt
    )
        external
        pure
        returns (uint256)
    {
        return LPMath.fairLPValueV2(r0, r1, ts, p0, p1, amt);
    }

    function applyHaircut(uint256 value, uint256 bps) external pure returns (uint256) {
        return LPMath.applyHaircut(value, bps);
    }
}

contract LPMathTest is Test {
    using LPMath for uint256;

    LPMathWrapper public wrapper;

    function setUp() public {
        wrapper = new LPMathWrapper();
    }

    function test_sqrt() public pure {
        assertEq(LPMath.sqrt(0), 0);
        assertEq(LPMath.sqrt(1), 1);
        assertEq(LPMath.sqrt(4), 2);
        assertEq(LPMath.sqrt(9), 3);
        assertEq(LPMath.sqrt(100), 10);
        assertEq(LPMath.sqrt(1e18), 1e9);
    }

    function test_sqrt_nonPerfect() public pure {
        // sqrt(2) ≈ 1.414... → should return 1
        assertEq(LPMath.sqrt(2), 1);
        // sqrt(8) ≈ 2.828... → should return 2
        assertEq(LPMath.sqrt(8), 2);
    }

    function test_applyHaircut() public pure {
        uint256 value = 10_000e18;

        // 5% haircut
        uint256 result = LPMath.applyHaircut(value, 500);
        assertEq(result, 9500e18);

        // 10% haircut
        result = LPMath.applyHaircut(value, 1000);
        assertEq(result, 9000e18);

        // 0% haircut
        result = LPMath.applyHaircut(value, 0);
        assertEq(result, 10_000e18);
    }

    function test_deviationBps() public pure {
        // Same values → 0 deviation
        assertEq(LPMath.deviationBps(100, 100), 0);

        // 5% deviation
        assertEq(LPMath.deviationBps(100, 95), 500);

        // 10% deviation
        assertEq(LPMath.deviationBps(100, 90), 1000);
    }

    function test_fairLPValueV2() public pure {
        // Pool: 100 ETH / 200,000 USDC
        // ETH price: $2,000, USDC price: $1
        // LP supply: 1000 tokens
        // Pricing 10 tokens
        uint256 value = LPMath.fairLPValueV2(
            100e18, // reserve0 (ETH)
            200_000e18, // reserve1 (USDC)
            1000e18, // totalSupply
            2000e18, // price0 (ETH = $2000)
            1e18, // price1 (USDC = $1)
            10e18 // amount (10 LP tokens)
        );

        // Each LP token should be worth ~$400 (200K + 200K = 400K / 1000)
        // 10 LP tokens = ~$4000
        // With sqrt method the value should be close
        assertGt(value, 3500e18);
        assertLt(value, 4500e18);
    }

    function test_fairLPValueV2_revertsZeroTotalSupply() public {
        vm.expectRevert("ZERO_TOTAL_SUPPLY");
        wrapper.fairLPValueV2(1000e18, 1000e6, 0, 2000e18, 1e18, 100e18);
    }

    function test_applyHaircut_revertsExceedsMax() public {
        vm.expectRevert("HAIRCUT_TOO_LARGE");
        wrapper.applyHaircut(1000e18, 10_001);
    }

    function test_applyHaircut_maxHaircutReturnsZero() public pure {
        uint256 result = LPMath.applyHaircut(1000e18, 10_000);
        assertEq(result, 0);
    }

    function testFuzz_haircutNeverExceedsValue(uint256 value, uint256 haircutBps) public pure {
        value = bound(value, 0, type(uint128).max);
        haircutBps = bound(haircutBps, 0, 10_000);
        uint256 result = LPMath.applyHaircut(value, haircutBps);
        assertLe(result, value);
    }
}
