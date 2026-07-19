// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../E2EBase.t.sol";
import {LeverageTransformer} from "../../../src/periphery/LeverageTransformer.sol";

/// @title TransformSecurityE2E
/// @notice End-to-end security tests for the transform() pattern in PositionManager.
/// @dev Tests transient auth scoping, reentrancy protection, and health factor enforcement.
contract TransformSecurityE2E is E2EBase {
    LeverageTransformer public leverageTransformer;

    address constant FLASH_POOL = Constants.UNI_V3_WETH_USDC_500;

    function setUp() public override {
        super.setUp();

        leverageTransformer = new LeverageTransformer(
            address(core),
            address(positionManager),
            address(lendingEngine),
            Constants.UNI_V3_SWAP_ROUTER,
            Constants.UNI_V3_FACTORY
        );

        vm.prank(deployer);
        aclManager.addTransformer(address(leverageTransformer));
    }

    /// @notice Verify transformedPositionId is cleared after successful transform
    function test_transientAuth_clearedAfterTransform() public {
        uint256 tokenId = _createV3Position(alice, 2 ether, 5000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // Before transform — should be 0
        assertEq(positionManager.transformedPositionId(), 0, "Should be 0 before transform");

        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 flashAmount = maxBorrow / 5; // small leverage

        bytes memory swapPath = abi.encodePacked(Constants.USDC, uint24(3000), Constants.WETH);

        bytes memory calldata_ = abi.encodeWithSelector(
            LeverageTransformer.leverageUp.selector,
            LeverageTransformer.LeverageUpParams({
                positionId: positionId,
                flashAmount: flashAmount,
                flashLoanPool: FLASH_POOL,
                swapPath0: "",
                swapPath1: swapPath,
                swap0Portion: 5000,
                minSwapOut0: 0,
                minSwapOut1: 0
            })
        );

        vm.prank(alice);
        positionManager.transform(positionId, address(leverageTransformer), calldata_);

        // After transform — should be cleared back to 0
        assertEq(positionManager.transformedPositionId(), 0, "Should be 0 after transform");
        assertEq(positionManager.activeTransformer(), address(0), "Transformer should be cleared");
    }

    /// @notice Paused protocol rejects transform
    function test_revert_paused_blocksTransform() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);

        // Pause the protocol via ProtocolCore (emergency admin = guardian)
        vm.prank(guardian);
        core.pause();

        bytes memory calldata_ = abi.encodeWithSelector(
            LeverageTransformer.leverageUp.selector,
            LeverageTransformer.LeverageUpParams({
                positionId: positionId,
                flashAmount: 1000e6,
                flashLoanPool: FLASH_POOL,
                swapPath0: "",
                swapPath1: "",
                swap0Portion: 5000,
                minSwapOut0: 0,
                minSwapOut1: 0
            })
        );

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        positionManager.transform(positionId, address(leverageTransformer), calldata_);

        // Unpause (pool admin = deployer)
        vm.prank(deployer);
        core.unpause();
    }

    /// @notice Two users can't interfere with each other's positions via transform
    function test_crossUser_isolation() public {
        // Alice creates position
        uint256 tokenIdAlice = _createV3Position(alice, 1 ether, 2000e6);
        uint256 posIdAlice = _depositV3(alice, tokenIdAlice);

        // Bob creates position (fund both WETH and USDC)
        _fundWeth(bob, 1 ether);
        _fundUsdc(bob, 2000e6);
        uint256 tokenIdBob = _createV3Position(bob, 1 ether, 2000e6);
        uint256 posIdBob = _depositV3(bob, tokenIdBob);

        // Bob tries to transform Alice's position
        bytes memory calldata_ = abi.encodeWithSelector(
            LeverageTransformer.leverageUp.selector,
            LeverageTransformer.LeverageUpParams({
                positionId: posIdAlice, // Alice's position!
                flashAmount: 1000e6,
                flashLoanPool: FLASH_POOL,
                swapPath0: "",
                swapPath1: "",
                swap0Portion: 5000,
                minSwapOut0: 0,
                minSwapOut1: 0
            })
        );

        vm.prank(bob);
        vm.expectRevert("NOT_POSITION_OWNER");
        positionManager.transform(posIdAlice, address(leverageTransformer), calldata_);
    }

    /// @notice Leverage up that would make position unhealthy is rejected
    function test_revert_unhealthyAfterTransform() public {
        uint256 tokenId = _createV3Position(alice, 1 ether, 2000e6);
        uint256 positionId = _depositV3(alice, tokenId);
        vm.roll(block.number + 2);

        // First, borrow near max to get close to liquidation threshold
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);
        uint256 borrowAmount = (maxBorrow * 90) / 100; // borrow 90% of max
        vm.prank(alice);
        lendingEngine.borrow(positionId, borrowAmount);

        // Now try to leverage up more — should fail because HF is already low
        // and the flash fee + slippage will push it below 1.0
        uint256 flashAmount = maxBorrow / 2; // try to add more leverage

        bytes memory swapPath = abi.encodePacked(Constants.USDC, uint24(3000), Constants.WETH);

        bytes memory calldata_ = abi.encodeWithSelector(
            LeverageTransformer.leverageUp.selector,
            LeverageTransformer.LeverageUpParams({
                positionId: positionId,
                flashAmount: flashAmount,
                flashLoanPool: FLASH_POOL,
                swapPath0: "",
                swapPath1: swapPath,
                swap0Portion: 5000,
                minSwapOut0: 0,
                minSwapOut1: 0
            })
        );

        // Should revert — either EXCEEDS_MAX_LTV or UNHEALTHY_AFTER_TRANSFORM
        vm.prank(alice);
        vm.expectRevert();
        positionManager.transform(positionId, address(leverageTransformer), calldata_);
    }
}
