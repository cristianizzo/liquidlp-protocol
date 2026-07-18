// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {LeverageTransformer} from "../../../src/periphery/LeverageTransformer.sol";

/// @title V2Transform
/// @notice E2E fork tests for V2 LP position leverage via LeverageTransformer.
contract V2Transform is E2EBase {
    LeverageTransformer public leverageTransformer;
    uint256 public v2MarketId;

    address constant FLASH_POOL = Constants.UNI_V3_WETH_USDC_500;

    function setUp() public override {
        super.setUp();

        // Create a V2 market
        vm.startPrank(deployer);
        (v2MarketId,) = marketFactory.createMarket(
            ILPAdapter.LPType.UniswapV2, Constants.USDC, 6500, 7500, 500, 10_000_000e6, 0, 0, "volatile"
        );
        vm.stopPrank();

        // Fund Bob and supply to V2 market
        _fundUsdc(bob, 50_000e6);
        address v2MarketAddr = core.markets(v2MarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(v2MarketAddr, 50_000e6);
        IMarket(v2MarketAddr).supply(50_000e6);
        vm.stopPrank();

        // Deploy LeverageTransformer
        leverageTransformer = new LeverageTransformer(
            address(core), address(positionManager), address(lendingEngine), Constants.UNI_V3_SWAP_ROUTER
        );

        vm.prank(deployer);
        aclManager.addTransformer(address(leverageTransformer));
    }

    function test_leverageUp_V2() public {
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);

        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        vm.roll(block.number + 2);

        uint256 valueBefore = _getPositionValue(positionId);
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 flashAmount = maxBorrow / 3;

        bytes memory swapPathToWeth = abi.encodePacked(Constants.USDC, uint24(3000), Constants.WETH);

        LeverageTransformer.LeverageUpParams memory params = LeverageTransformer.LeverageUpParams({
            positionId: positionId,
            flashAmount: flashAmount,
            flashLoanPool: FLASH_POOL,
            swapPath0: "",
            swapPath1: swapPathToWeth,
            swap0Portion: 5000
        });

        bytes memory calldata_ = abi.encodeWithSelector(LeverageTransformer.leverageUp.selector, params);

        vm.prank(alice);
        positionManager.transform(positionId, address(leverageTransformer), calldata_);

        uint256 valueAfter = _getPositionValue(positionId);
        uint256 debtAfter = _getDebt(positionId);
        uint256 hfAfter = _getHealthFactor(positionId);

        assertGt(valueAfter, valueBefore, "Position value should increase from added collateral");
        assertGt(debtAfter, 0, "Should have debt after leverage up");
        assertGe(hfAfter, 1e18, "Health factor must be >= 1.0 after transform");
    }

    function test_leverageDown_V2() public {
        uint256 lpAmount = _createV2Position(alice, 0.5 ether, 1000e6);

        vm.startPrank(alice);
        IUniswapV2Pair(Constants.UNI_V2_WETH_USDC).approve(address(v2Adapter), lpAmount);
        uint256 positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, v2MarketId);
        vm.stopPrank();

        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = maxBorrow / 3;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        uint256 debtBefore = _getDebt(positionId);
        uint256 valueBefore = _getPositionValue(positionId);

        uint256 repayAmount = debtBefore / 2;
        uint128 liquidityToRemove = uint128(lpAmount) / 3;
        uint256 flashAmount = repayAmount;

        bytes memory swapWethToUsdc = abi.encodePacked(Constants.WETH, uint24(3000), Constants.USDC);

        LeverageTransformer.LeverageDownParams memory params = LeverageTransformer.LeverageDownParams({
            positionId: positionId,
            flashAmount: flashAmount,
            flashLoanPool: FLASH_POOL,
            repayAmount: repayAmount,
            liquidityToRemove: liquidityToRemove,
            swapPath0: "",
            swapPath1: swapWethToUsdc
        });

        bytes memory calldata_ = abi.encodeWithSelector(LeverageTransformer.leverageDown.selector, params);

        vm.prank(alice);
        positionManager.transform(positionId, address(leverageTransformer), calldata_);

        uint256 debtAfter = _getDebt(positionId);
        uint256 valueAfter = _getPositionValue(positionId);
        uint256 hfAfter = _getHealthFactor(positionId);

        assertLt(debtAfter, debtBefore, "Debt should decrease");
        assertLt(valueAfter, valueBefore, "Position value should decrease (collateral removed)");
        assertGe(hfAfter, 1e18, "Health factor must be >= 1.0");
    }

    function test_revert_directCall_V2() public {
        LeverageTransformer.LeverageUpParams memory params = LeverageTransformer.LeverageUpParams({
            positionId: 0,
            flashAmount: 1000e6,
            flashLoanPool: FLASH_POOL,
            swapPath0: "",
            swapPath1: "",
            swap0Portion: 5000
        });

        vm.prank(alice);
        vm.expectRevert("ONLY_POSITION_MANAGER");
        leverageTransformer.leverageUp(params);
    }
}
