// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {LeverageTransformer} from "../../../src/periphery/LeverageTransformer.sol";
import {IUniswapV3Pool} from "../../../src/interfaces/external/IUniswapV3.sol";

/// @title LeverageTransformerE2E
/// @notice End-to-end fork tests for one-click leverage/deleverage via transform().
/// @dev Tests against real Uniswap V3 positions on forked mainnet.
///
///      Flows tested:
///        1. leverageUp  — deposit LP → flash borrow → swap → addCollateral → borrow → repay flash
///        2. leverageDown — leveraged position → flash borrow → repay debt → swap → repay flash
///        3. Security     — unauthorized caller, non-whitelisted transformer, unhealthy after transform
contract LeverageTransformerE2E is E2EBase {
    LeverageTransformer public leverageTransformer;

    // WETH/USDC 0.05% pool has deep liquidity for flash loans
    address constant FLASH_POOL = Constants.UNI_V3_WETH_USDC_500;

    function setUp() public override {
        super.setUp();

        // Deploy LeverageTransformer with real Uniswap V3 SwapRouter
        leverageTransformer = new LeverageTransformer(
            address(core),
            address(positionManager),
            address(lendingEngine),
            Constants.UNI_V3_SWAP_ROUTER,
            Constants.UNI_V3_FACTORY
        );

        // Grant TRANSFORMER role
        vm.prank(deployer);
        aclManager.addTransformer(address(leverageTransformer));
    }

    /// @notice Full leverage up flow: deposit V3 → transform(leverageUp) → verify leveraged
    function test_leverageUp_V3() public {
        // 1. Alice creates and deposits a V3 position
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2); // cooldown

        uint256 valueBefore = _getPositionValue(positionId);
        console.log("Position value before leverage: $%s", valueBefore / 1e18);

        // 2. Calculate flash amount (~30% of position value for moderate leverage)
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 flashAmount = maxBorrow / 3; // conservative — leave room for fees + slippage
        console.log("Flash amount: %s USDC", flashAmount / 1e6);

        // 3. Build swap paths
        // borrowAsset is USDC. We need to swap USDC → WETH for token1, USDC is already token0
        // In WETH/USDC pool: USDC < WETH, so USDC = token0, WETH = token1
        // Swap path: USDC → WETH via 0.3% pool
        bytes memory swapPathToWeth = abi.encodePacked(Constants.USDC, uint24(3000), Constants.WETH);

        LeverageTransformer.LeverageUpParams memory params = LeverageTransformer.LeverageUpParams({
            positionId: positionId,
            flashAmount: flashAmount,
            flashLoanPool: FLASH_POOL,
            swapPath0: "", // USDC is borrowAsset and token0, no swap needed for token0 portion
            swapPath1: swapPathToWeth, // Swap USDC → WETH for token1 portion
            swap0Portion: 5000 // 50/50 split — half stays as USDC (token0), half swaps to WETH (token1)
        });

        // 4. Execute leverage up via transform()
        bytes memory calldata_ = abi.encodeWithSelector(LeverageTransformer.leverageUp.selector, params);

        vm.prank(alice);
        positionManager.transform(positionId, address(leverageTransformer), calldata_);

        // 5. Verify leverage was applied
        uint256 valueAfter = _getPositionValue(positionId);
        uint256 debtAfter = _getDebt(positionId);
        uint256 hfAfter = _getHealthFactor(positionId);

        console.log("Position value after leverage: $%s", valueAfter / 1e18);
        console.log("Debt after leverage: %s USDC", debtAfter / 1e6);
        console.log("Health factor: %s", hfAfter / 1e16);

        assertGt(valueAfter, valueBefore, "Position value should increase from added collateral");
        assertGt(debtAfter, 0, "Should have debt after leverage up");
        assertGe(hfAfter, 1e18, "Health factor must be >= 1.0 after transform");
    }

    /// @notice Full leverage down flow: leveraged → flash → repay debt → remove collateral → swap → repay flash
    function test_leverageDown_V3() public {
        // 1. Set up leveraged position
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = maxBorrow / 3;
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        uint256 debtBefore = _getDebt(positionId);
        uint256 valueBefore = _getPositionValue(positionId);
        console.log("Debt before deleverage: %s USDC", debtBefore / 1e6);
        console.log("Position value before: $%s", valueBefore / 1e18);

        // 2. Calculate how much liquidity to remove
        uint256 repayAmount = debtBefore / 2;

        // Get current liquidity from the NFT
        (,,,,,,, uint128 currentLiquidity,,,,) = nftManager.positions(tokenId);
        // Remove 30% of liquidity — enough to cover flash repayment after swaps
        uint128 liquidityToRemove = currentLiquidity / 3;

        // Flash enough to cover repayment
        uint256 flashAmount = repayAmount;

        // Swap WETH → USDC for flash repayment (USDC is already borrowAsset)
        bytes memory swapWethToUsdc = abi.encodePacked(Constants.WETH, uint24(3000), Constants.USDC);

        LeverageTransformer.LeverageDownParams memory params = LeverageTransformer.LeverageDownParams({
            positionId: positionId,
            flashAmount: flashAmount,
            flashLoanPool: FLASH_POOL,
            repayAmount: repayAmount,
            liquidityToRemove: liquidityToRemove,
            swapPath0: "", // USDC is borrowAsset, no swap needed
            swapPath1: swapWethToUsdc // WETH → USDC
        });

        bytes memory calldata_ = abi.encodeWithSelector(LeverageTransformer.leverageDown.selector, params);

        vm.prank(alice);
        positionManager.transform(positionId, address(leverageTransformer), calldata_);

        // 3. Verify
        uint256 debtAfter = _getDebt(positionId);
        uint256 valueAfter = _getPositionValue(positionId);
        uint256 hfAfter = _getHealthFactor(positionId);

        console.log("Debt after deleverage: %s USDC", debtAfter / 1e6);
        console.log("Position value after: $%s", valueAfter / 1e18);
        console.log("Health factor after: %s", hfAfter / 1e16);

        assertLt(debtAfter, debtBefore, "Debt should decrease");
        assertLt(valueAfter, valueBefore, "Position value should decrease (collateral removed)");
        assertGe(hfAfter, 1e18, "Health factor must be >= 1.0");
    }

    // ========== Security Tests ==========

    /// @notice Non-owner cannot call transform
    function test_revert_nonOwner_cannotTransform() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        LeverageTransformer.LeverageUpParams memory params = LeverageTransformer.LeverageUpParams({
            positionId: positionId,
            flashAmount: 1000e6,
            flashLoanPool: FLASH_POOL,
            swapPath0: "",
            swapPath1: "",
            swap0Portion: 5000
        });

        bytes memory calldata_ = abi.encodeWithSelector(LeverageTransformer.leverageUp.selector, params);

        vm.prank(bob); // bob is not the owner
        vm.expectRevert("NOT_POSITION_OWNER");
        positionManager.transform(positionId, address(leverageTransformer), calldata_);
    }

    /// @notice Non-whitelisted transformer is rejected
    function test_revert_nonWhitelistedTransformer() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        // Deploy a second transformer that's NOT whitelisted
        LeverageTransformer rogue = new LeverageTransformer(
            address(core),
            address(positionManager),
            address(lendingEngine),
            Constants.UNI_V3_SWAP_ROUTER,
            Constants.UNI_V3_FACTORY
        );

        bytes memory calldata_ = abi.encodeWithSelector(
            LeverageTransformer.leverageUp.selector,
            LeverageTransformer.LeverageUpParams({
                positionId: positionId,
                flashAmount: 1000e6,
                flashLoanPool: FLASH_POOL,
                swapPath0: "",
                swapPath1: "",
                swap0Portion: 5000
            })
        );

        vm.prank(alice);
        vm.expectRevert("NOT_TRANSFORMER");
        positionManager.transform(positionId, address(rogue), calldata_);
    }

    /// @notice Direct call to leverageUp (not via transform) is rejected
    function test_revert_directCall_blocked() public {
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

    /// @notice Fake flash pool (not from Uniswap V3 factory) is rejected
    function test_revert_fakeFlashPool() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Deploy a contract that mimics V3 pool interface but isn't registered in factory
        FakeFlashPool fake = new FakeFlashPool(Constants.USDC, Constants.WETH);

        LeverageTransformer.LeverageUpParams memory params = LeverageTransformer.LeverageUpParams({
            positionId: positionId,
            flashAmount: 1000e6,
            flashLoanPool: address(fake),
            swapPath0: "",
            swapPath1: "",
            swap0Portion: 5000
        });

        bytes memory calldata_ = abi.encodeWithSelector(LeverageTransformer.leverageUp.selector, params);

        vm.prank(alice);
        vm.expectRevert("INVALID_FLASH_POOL");
        positionManager.transform(positionId, address(leverageTransformer), calldata_);
    }
}

/// @notice Minimal fake pool that returns correct token0/token1/fee but isn't in the factory
contract FakeFlashPool {
    address public token0;
    address public token1;

    constructor(address _t0, address _t1) {
        token0 = _t0 < _t1 ? _t0 : _t1;
        token1 = _t0 < _t1 ? _t1 : _t0;
    }

    function fee() external pure returns (uint24) {
        return 3000;
    }

    function flash(address, uint256, uint256, bytes calldata) external pure {
        revert("SHOULD_NOT_REACH");
    }
}
