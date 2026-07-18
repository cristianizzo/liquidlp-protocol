// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {LPCompounder} from "../../../src/periphery/LPCompounder.sol";
import {IUniswapV3Pool} from "../../../src/interfaces/external/IUniswapV3.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LPCompounderE2E
/// @notice E2E fork tests for LPCompounder standalone compounding with real V3 positions.
/// @dev Tests: happy-path compound, batch compound, admin setters, sweep, access control.
contract LPCompounderE2E is E2EBase {
    LPCompounder public compounder;

    address public keeper = makeAddr("keeper");
    address public treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();

        // Deploy LPCompounder
        compounder = new LPCompounder(address(core), address(positionManager), address(feeCollector));

        // Grant KEEPER role to the compounder so it can call positionManager.compoundFees
        vm.startPrank(deployer);
        aclManager.addKeeper(address(compounder));
        vm.stopPrank();
    }

    // ========== 1. compoundPosition happy path ==========

    /// @notice Deposit V3, generate fees, compound via LPCompounder.
    function test_compoundPosition_happyPath() public {
        // Alice creates and deposits a V3 position
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        uint256 valueBefore = _getPositionValue(positionId);
        console.log("Position value before compound: $%s", valueBefore / 1e18);

        // Generate trading fees via round-trip swaps
        _generateTradingFeesRoundTrip(500 ether);

        // Set threshold to 0 so any fees trigger compound
        vm.prank(deployer);
        compounder.setMinCompoundThreshold(0);

        // Set high slippage tolerance for fork testing (round-trip swaps shift price)
        vm.prank(deployer);
        compounder.setCompoundSlippage(500); // 5%

        // Compound the position -- keeper calls
        compounder.compoundPosition(positionId, keeper);

        uint256 valueAfter = _getPositionValue(positionId);
        console.log("Position value after compound: $%s", valueAfter / 1e18);
        console.log("=== compoundPosition Happy Path Passed ===");
    }

    // ========== 2. batchCompound ==========

    /// @notice Deposit 2 V3 positions, generate fees, batch compound both.
    function test_batchCompound() public {
        // Create two positions for alice
        uint256 tokenId1 = _createV3Position(alice, 1 ether, 2500e6);
        uint256 positionId1 = _depositV3(alice, tokenId1);

        uint256 tokenId2 = _createV3Position(alice, 1 ether, 2500e6);
        uint256 positionId2 = _depositV3(alice, tokenId2);

        // Generate trading fees
        _generateTradingFeesRoundTrip(500 ether);

        // Set threshold to 0 and generous slippage
        vm.startPrank(deployer);
        compounder.setMinCompoundThreshold(0);
        compounder.setCompoundSlippage(500);
        vm.stopPrank();

        // Batch compound both positions
        uint256[] memory ids = new uint256[](2);
        ids[0] = positionId1;
        ids[1] = positionId2;

        compounder.batchCompound(ids);

        console.log("=== batchCompound Passed ===");
    }

    // ========== 3. setCompoundFee ==========

    /// @notice Deployer sets compound fee, verify getters return new values.
    function test_setCompoundFee() public {
        // Default values
        assertEq(compounder.compoundFeeBps(), 250, "Default total fee should be 250 bps");
        assertEq(compounder.callerRewardBps(), 50, "Default caller reward should be 50 bps");

        // Set new fee
        vm.prank(deployer);
        compounder.setCompoundFee(500, 100);

        assertEq(compounder.compoundFeeBps(), 500, "Total fee should be 500 bps");
        assertEq(compounder.callerRewardBps(), 100, "Caller reward should be 100 bps");

        console.log("=== setCompoundFee Passed ===");
    }

    // ========== 4. sweepTokens ==========

    /// @notice If compounder holds dust, deployer can sweep to treasury.
    function test_sweepTokens() public {
        // Send some USDC dust to the compounder
        uint256 dustAmount = 1000e6;
        _fundUsdc(address(compounder), dustAmount);

        uint256 treasuryBefore = IERC20(Constants.USDC).balanceOf(treasury);

        // Deployer sweeps dust to treasury
        vm.prank(deployer);
        compounder.sweepTokens(Constants.USDC, treasury, dustAmount);

        uint256 treasuryAfter = IERC20(Constants.USDC).balanceOf(treasury);
        assertEq(treasuryAfter - treasuryBefore, dustAmount, "Treasury should receive swept dust");

        console.log("=== sweepTokens Passed ===");
    }

    // ========== 5. revert: non-keeper cannot compound ==========

    /// @notice Alice (non-keeper) tries compoundPosition, should revert.
    function test_revert_nonKeeper_cannotCompound() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2500e6);
        uint256 positionId = _depositV3(alice, tokenId);

        // LPCompounder.compoundPosition is permissionless at the compounder level,
        // but positionManager.compoundFees requires KEEPER role on the caller.
        // Deploy a second compounder WITHOUT keeper role to test the revert.
        LPCompounder unauthorizedCompounder =
            new LPCompounder(address(core), address(positionManager), address(feeCollector));

        // No KEEPER role granted to unauthorizedCompounder
        vm.expectRevert("NOT_AUTHORIZED");
        unauthorizedCompounder.compoundPosition(positionId, alice);

        console.log("=== revert nonKeeper Passed ===");
    }

    // ========== Helpers ==========

    /// @notice Generate trading fees via round-trip swaps (WETH->USDC->WETH) to keep price stable
    function _generateTradingFeesRoundTrip(uint256 ethAmount) internal {
        address whale = makeAddr("feeWhale");
        vm.deal(whale, ethAmount + 1 ether);
        vm.startPrank(whale);
        IWETH(Constants.WETH).deposit{value: ethAmount}();
        IWETH(Constants.WETH).approve(Constants.UNI_V3_SWAP_ROUTER, type(uint256).max);
        uint256 usdcOut = _swapExactSingle(Constants.WETH, Constants.USDC, 3000, ethAmount, whale);
        IERC20(Constants.USDC).approve(Constants.UNI_V3_SWAP_ROUTER, usdcOut);
        _swapExactSingle(Constants.USDC, Constants.WETH, 3000, usdcOut, whale);
        vm.stopPrank();
        _advanceTime(35 minutes);
        _syncChainlinkToPool();
    }

    /// @notice Sync Chainlink mock to current pool price after a large swap
    function _syncChainlinkToPool() internal {
        IUniswapV3Pool pool = IUniswapV3Pool(Constants.UNI_V3_WETH_USDC_3000);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        uint256 priceX96 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), uint256(1) << 96);
        uint256 ethPriceUsd8 = Math.mulDiv(uint256(1) << 96, 1e20, priceX96);

        vm.mockCall(
            Constants.CL_ETH_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), int256(ethPriceUsd8), block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(
            Constants.CL_USDC_USD,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), int256(100_000_000), block.timestamp, block.timestamp, uint80(1))
        );
    }
}
