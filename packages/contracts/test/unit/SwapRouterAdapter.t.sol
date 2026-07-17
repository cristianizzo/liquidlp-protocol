// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {SwapRouterAdapter} from "../../src/periphery/SwapRouterAdapter.sol";
import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract SwapRouterAdapterTest is Test {
    SwapRouterAdapter public adapter;
    MockSwapRouter public mockRouter;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public alice = makeAddr("alice");

    function setUp() public {
        tokenB = new MockERC20("Token B", "TKNB", 18);
        mockRouter = new MockSwapRouter(address(tokenB));
        adapter = new SwapRouterAdapter(address(mockRouter));

        tokenA = new MockERC20("Token A", "TKNA", 18);

        // Fund alice and mock router
        tokenA.mint(alice, 100e18);
        tokenB.mint(address(mockRouter), 100e18);
    }

    // ========== Constructor ==========

    function test_constructor_setsRouter() public view {
        assertEq(adapter.uniswapRouter(), address(mockRouter));
    }

    function test_constructor_revertsZeroAddress() public {
        vm.expectRevert("ZERO_ADDRESS");
        new SwapRouterAdapter(address(0));
    }

    function test_constructor_revertsNotContract() public {
        vm.expectRevert("NOT_CONTRACT");
        new SwapRouterAdapter(makeAddr("eoa"));
    }

    // ========== exactInput ==========

    function test_exactInput_success() public {
        bytes memory path = abi.encodePacked(address(tokenA), uint24(3000), address(tokenB));

        vm.startPrank(alice);
        tokenA.approve(address(adapter), 10e18);

        uint256 amountOut = adapter.exactInput(
            ISwapRouter.ExactInputParams({
                path: path, recipient: alice, deadline: block.timestamp, amountIn: 10e18, amountOutMinimum: 0
            })
        );
        vm.stopPrank();

        assertGt(amountOut, 0, "Should receive output tokens");
        assertEq(tokenA.balanceOf(alice), 90e18, "Should deduct input tokens");
        assertEq(tokenA.balanceOf(address(adapter)), 0, "Adapter should hold no tokenA");
        assertEq(tokenB.balanceOf(address(adapter)), 0, "Adapter should hold no tokenB");
    }

    function test_exactInput_clearsApproval() public {
        bytes memory path = abi.encodePacked(address(tokenA), uint24(3000), address(tokenB));

        vm.startPrank(alice);
        tokenA.approve(address(adapter), 10e18);
        adapter.exactInput(
            ISwapRouter.ExactInputParams({
                path: path, recipient: alice, deadline: block.timestamp, amountIn: 10e18, amountOutMinimum: 0
            })
        );
        vm.stopPrank();

        assertEq(tokenA.allowance(address(adapter), address(mockRouter)), 0, "Should clear approval");
    }

    function test_exactInput_revertsOnETH() public {
        bytes memory path = abi.encodePacked(address(tokenA), uint24(3000), address(tokenB));

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("NO_ETH");
        adapter.exactInput{value: 1 ether}(
            ISwapRouter.ExactInputParams({
                path: path, recipient: alice, deadline: block.timestamp, amountIn: 10e18, amountOutMinimum: 0
            })
        );
    }

    function test_exactInput_revertsInvalidPath() public {
        bytes memory shortPath = abi.encodePacked(address(tokenA)); // only 20 bytes, need 43

        vm.prank(alice);
        vm.expectRevert("INVALID_PATH");
        adapter.exactInput(
            ISwapRouter.ExactInputParams({
                path: shortPath, recipient: alice, deadline: block.timestamp, amountIn: 10e18, amountOutMinimum: 0
            })
        );
    }

    // ========== swap ==========

    function test_swap_success() public {
        vm.startPrank(alice);
        tokenA.approve(address(adapter), 5e18);
        uint256 amountOut = adapter.swap(address(tokenA), address(tokenB), 5e18, 0);
        vm.stopPrank();

        assertGt(amountOut, 0, "Should receive output tokens");
        assertEq(tokenA.balanceOf(address(adapter)), 0, "Adapter should hold no tokenA");
    }

    function test_swap_clearsApproval() public {
        vm.startPrank(alice);
        tokenA.approve(address(adapter), 5e18);
        adapter.swap(address(tokenA), address(tokenB), 5e18, 0);
        vm.stopPrank();

        assertEq(tokenA.allowance(address(adapter), address(mockRouter)), 0, "Should clear approval");
    }

    function test_swap_revertsOnSlippage() public {
        vm.startPrank(alice);
        tokenA.approve(address(adapter), 5e18);
        vm.expectRevert("SLIPPAGE");
        adapter.swap(address(tokenA), address(tokenB), 5e18, type(uint256).max);
        vm.stopPrank();
    }
}
