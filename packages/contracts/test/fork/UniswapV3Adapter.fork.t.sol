// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {
    INonfungiblePositionManager,
    IUniswapV3Factory,
    IUniswapV3Pool
} from "../../src/interfaces/external/IUniswapV3.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @title UniswapV3AdapterForkTest
/// @notice Fork tests against REAL Uniswap V3 on Ethereum mainnet
/// @dev Run with: ETH_RPC_URL=<rpc> forge test --match-contract UniswapV3AdapterForkTest -vvv
contract UniswapV3AdapterForkTest is Test {
    // --- Mainnet addresses ---
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNI_V3_NFT_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNI_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    UniswapV3Adapter public adapter;
    INonfungiblePositionManager public nftManager;

    ProtocolCore public core;
    address public owner = makeAddr("owner");
    address public protocol = makeAddr("protocol");

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpcUrl);

        core = new ProtocolCore(owner, owner);
        adapter = new UniswapV3Adapter(UNI_V3_NFT_MANAGER, UNI_V3_FACTORY, address(core), protocol);
        nftManager = INonfungiblePositionManager(UNI_V3_NFT_MANAGER);
    }

    // --- Helper: find a real position and impersonate its owner ---

    function _findAndImpersonatePosition(
        address token0,
        address token1,
        uint24 fee
    )
        internal
        returns (uint256 tokenId, address posOwner, bool found)
    {
        uint256 startId = 800_000;
        for (uint256 i = startId; i > startId - 5000; i--) {
            try nftManager.positions(i) returns (
                uint96,
                address,
                address t0,
                address t1,
                uint24 f,
                int24,
                int24,
                uint128 liq,
                uint256,
                uint256,
                uint128,
                uint128
            ) {
                if (liq > 0 && t0 == token0 && t1 == token1 && f == fee) {
                    posOwner = nftManager.ownerOf(i);
                    return (i, posOwner, true);
                }
            } catch {
                continue;
            }
        }
        return (0, address(0), false);
    }

    // ========================================================
    // TEST 1: isSupported
    // ========================================================

    function test_isSupported() public view {
        assertTrue(adapter.isSupported(UNI_V3_NFT_MANAGER));
        assertFalse(adapter.isSupported(address(0x1234)));
    }

    // ========================================================
    // TEST 2: lpType
    // ========================================================

    function test_lpType() public view {
        assertEq(uint8(adapter.lpType()), uint8(ILPAdapter.LPType.UniswapV3));
    }

    // ========================================================
    // TEST 3: validateAndLock — real position
    // ========================================================

    function test_validateAndLock_realPosition() public {
        (uint256 tokenId, address posOwner, bool found) = _findAndImpersonatePosition(USDC, WETH, 500);
        if (!found) {
            emit log("No USDC/WETH 500 position found, skipping");
            return;
        }

        emit log_named_uint("Testing position", tokenId);
        emit log_named_address("Owner", posOwner);

        // Read position data before lock
        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = nftManager.positions(tokenId);

        // Owner approves adapter
        vm.prank(posOwner);
        nftManager.approve(address(adapter), tokenId);

        // Lock the position
        vm.prank(protocol);
        ILPAdapter.LPInfo memory info = adapter.validateAndLock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);

        // Verify adapter now owns the NFT
        assertEq(nftManager.ownerOf(tokenId), address(adapter));

        // Verify returned info
        assertEq(info.token0, USDC);
        assertEq(info.token1, WETH);
        assertEq(info.feeTier, 500);
        assertEq(info.tickLower, tickLower);
        assertEq(info.tickUpper, tickUpper);
        assertEq(info.liquidity, liquidity);
        assertEq(uint8(info.lpType), uint8(ILPAdapter.LPType.UniswapV3));
        assertTrue(info.pool != address(0));

        emit log_named_uint("Liquidity", liquidity);
        emit log_named_int("TickLower", int256(tickLower));
        emit log_named_int("TickUpper", int256(tickUpper));
    }

    // ========================================================
    // TEST 4: unlock — return NFT to owner
    // ========================================================

    function test_unlock_returnsNFT() public {
        (uint256 tokenId, address posOwner, bool found) = _findAndImpersonatePosition(USDC, WETH, 500);
        if (!found) {
            emit log("Skipping");
            return;
        }

        // Lock
        vm.prank(posOwner);
        nftManager.approve(address(adapter), tokenId);
        vm.prank(protocol);
        adapter.validateAndLock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);
        assertEq(nftManager.ownerOf(tokenId), address(adapter));

        // Unlock
        vm.prank(protocol);
        adapter.unlock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);

        // Owner has NFT back
        assertEq(nftManager.ownerOf(tokenId), posOwner);
    }

    // ========================================================
    // TEST 5: unwind — remove liquidity and collect tokens
    // ========================================================

    function test_unwind_removesLiquidityAndCollects() public {
        (uint256 tokenId, address posOwner, bool found) = _findAndImpersonatePosition(USDC, WETH, 500);
        if (!found) {
            emit log("Skipping");
            return;
        }

        // Read initial liquidity
        (,,,,,,, uint128 initialLiquidity,,,,) = nftManager.positions(tokenId);

        // Lock position
        vm.prank(posOwner);
        nftManager.approve(address(adapter), tokenId);
        vm.prank(protocol);
        adapter.validateAndLock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);

        // Record protocol's token balances before unwind
        uint256 usdcBefore = IERC20(USDC).balanceOf(protocol);
        uint256 wethBefore = IERC20(WETH).balanceOf(protocol);

        // Unwind half the liquidity
        uint128 removeAmount = initialLiquidity / 2;

        vm.prank(protocol);
        (uint256 amount0, uint256 amount1) = adapter.unwind(UNI_V3_NFT_MANAGER, tokenId, removeAmount);

        // Tokens should be sent to protocol (msg.sender)
        uint256 usdcAfter = IERC20(USDC).balanceOf(protocol);
        uint256 wethAfter = IERC20(WETH).balanceOf(protocol);

        emit log_named_uint("USDC received", usdcAfter - usdcBefore);
        emit log_named_uint("WETH received", wethAfter - wethBefore);
        emit log_named_uint("amount0 returned", amount0);
        emit log_named_uint("amount1 returned", amount1);

        // At least one token should have been received
        assertTrue((usdcAfter - usdcBefore) > 0 || (wethAfter - wethBefore) > 0, "Must receive tokens from unwind");

        // Returned amounts should match balance changes
        assertEq(usdcAfter - usdcBefore, amount0, "USDC balance must match amount0");
        assertEq(wethAfter - wethBefore, amount1, "WETH balance must match amount1");

        // Remaining liquidity should be reduced
        (,,,,,,, uint128 remainingLiquidity,,,,) = nftManager.positions(tokenId);
        assertLt(remainingLiquidity, initialLiquidity, "Liquidity must decrease");
        assertApproxEqAbs(remainingLiquidity, initialLiquidity - removeAmount, 1, "Liquidity reduced by removeAmount");
    }

    // ========================================================
    // TEST 6: unwind full — remove all liquidity
    // ========================================================

    function test_unwind_fullLiquidity() public {
        (uint256 tokenId, address posOwner, bool found) = _findAndImpersonatePosition(USDC, WETH, 500);
        if (!found) {
            emit log("Skipping");
            return;
        }

        (,,,,,,, uint128 initialLiquidity,,,,) = nftManager.positions(tokenId);

        vm.prank(posOwner);
        nftManager.approve(address(adapter), tokenId);
        vm.prank(protocol);
        adapter.validateAndLock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);

        // Unwind ALL liquidity
        vm.prank(protocol);
        (uint256 amount0, uint256 amount1) = adapter.unwind(UNI_V3_NFT_MANAGER, tokenId, initialLiquidity);

        // Position should have 0 liquidity
        (,,,,,,, uint128 remainingLiquidity,,,,) = nftManager.positions(tokenId);
        assertEq(remainingLiquidity, 0, "All liquidity should be removed");

        assertTrue(amount0 > 0 || amount1 > 0, "Must receive tokens");

        emit log_named_uint("Full unwind - USDC", amount0);
        emit log_named_uint("Full unwind - WETH", amount1);
    }

    // ========================================================
    // TEST 7: collectFees — collect without removing liquidity
    // ========================================================

    function test_collectFees() public {
        (uint256 tokenId, address posOwner, bool found) = _findAndImpersonatePosition(USDC, WETH, 500);
        if (!found) {
            emit log("Skipping");
            return;
        }

        (,,,,,,, uint128 initialLiquidity,,,,) = nftManager.positions(tokenId);

        vm.prank(posOwner);
        nftManager.approve(address(adapter), tokenId);
        vm.prank(protocol);
        adapter.validateAndLock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);

        // Collect fees
        vm.prank(protocol);
        (uint256 fees0, uint256 fees1) = adapter.collectFees(UNI_V3_NFT_MANAGER, tokenId);

        // Liquidity decreases by 1 wei (used to trigger fee sync)
        (,,,,,,, uint128 liquidityAfter,,,,) = nftManager.positions(tokenId);
        assertApproxEqAbs(liquidityAfter, initialLiquidity, 1, "Liquidity should only decrease by 1 wei (fee sync)");

        emit log_named_uint("Fees0 (USDC)", fees0);
        emit log_named_uint("Fees1 (WETH)", fees1);
        // Fees may be 0 if position hasn't earned any — that's OK
    }

    // ========================================================
    // TEST 8: Access control — only protocol can call
    // ========================================================

    function test_onlyProtocol_validateAndLock() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("NOT_PROTOCOL");
        adapter.validateAndLock(UNI_V3_NFT_MANAGER, 1, 0, makeAddr("x"));
    }

    function test_onlyProtocol_unlock() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("NOT_PROTOCOL");
        adapter.unlock(UNI_V3_NFT_MANAGER, 1, 0, makeAddr("x"));
    }

    function test_onlyProtocol_unwind() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("NOT_PROTOCOL");
        adapter.unwind(UNI_V3_NFT_MANAGER, 1, 100);
    }

    function test_onlyProtocol_collectFees() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("NOT_PROTOCOL");
        adapter.collectFees(UNI_V3_NFT_MANAGER, 1);
    }

    // ========================================================
    // TEST 9: validateAndLock reverts for wrong LP token
    // ========================================================

    function test_validateAndLock_revertsWrongLPToken() public {
        vm.prank(protocol);
        vm.expectRevert("NOT_UNISWAP_V3");
        adapter.validateAndLock(address(0x1234), 1, 0, makeAddr("x"));
    }

    // ========================================================
    // TEST 10: Full lifecycle — lock, partial unwind, collect fees, unlock
    // ========================================================

    function test_fullLifecycle() public {
        (uint256 tokenId, address posOwner, bool found) = _findAndImpersonatePosition(USDC, WETH, 500);
        if (!found) {
            emit log("Skipping");
            return;
        }

        (,,,,,,, uint128 initialLiquidity,,,,) = nftManager.positions(tokenId);
        require(initialLiquidity > 100, "Need meaningful liquidity");

        // 1. Lock
        vm.prank(posOwner);
        nftManager.approve(address(adapter), tokenId);
        vm.prank(protocol);
        ILPAdapter.LPInfo memory info = adapter.validateAndLock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);
        assertEq(nftManager.ownerOf(tokenId), address(adapter));

        // 2. Partial unwind (25%)
        uint128 removeAmount = initialLiquidity / 4;
        vm.prank(protocol);
        (uint256 a0, uint256 a1) = adapter.unwind(UNI_V3_NFT_MANAGER, tokenId, removeAmount);
        emit log_named_uint("Partial unwind USDC", a0);
        emit log_named_uint("Partial unwind WETH", a1);

        // 3. Collect fees
        vm.prank(protocol);
        (uint256 f0, uint256 f1) = adapter.collectFees(UNI_V3_NFT_MANAGER, tokenId);
        emit log_named_uint("Fees USDC", f0);
        emit log_named_uint("Fees WETH", f1);

        // 4. Liquidity should be 75% of original
        (,,,,,,, uint128 remaining,,,,) = nftManager.positions(tokenId);
        assertApproxEqAbs(remaining, initialLiquidity - removeAmount, 1);

        // 5. Unlock — return to owner
        vm.prank(protocol);
        adapter.unlock(UNI_V3_NFT_MANAGER, tokenId, 0, posOwner);
        assertEq(nftManager.ownerOf(tokenId), posOwner);

        emit log("Full lifecycle completed successfully");
    }
}
