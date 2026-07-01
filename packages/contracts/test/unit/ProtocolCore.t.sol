// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";

contract ProtocolCoreTest is Test {
    ProtocolCore public core;
    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public user = makeAddr("user");

    // Events — must redeclare to test with vm.expectEmit
    event AdapterRegistered(ILPAdapter.LPType indexed lpType, address indexed adapter);
    event OracleRegistered(ILPAdapter.LPType indexed lpType, address indexed oracle);
    event MarketRegistered(uint256 indexed marketId, address indexed market);
    event PoolWhitelisted(address indexed pool);
    event PoolRemoved(address indexed pool);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event KeeperUpdated(address indexed keeper, bool status);

    function setUp() public {
        core = new ProtocolCore(owner, guardian);
    }

    // ========== Constructor ==========

    function test_constructor_setsOwnerAndGuardian() public view {
        assertEq(core.owner(), owner);
        assertEq(core.guardian(), guardian);
        assertFalse(core.paused());
        assertEq(core.nextMarketId(), 0);
    }

    function test_constructor_revertsZeroOwner() public {
        vm.expectRevert("ZERO_OWNER");
        new ProtocolCore(address(0), guardian);
    }

    function test_constructor_revertsZeroGuardian() public {
        vm.expectRevert("ZERO_GUARDIAN");
        new ProtocolCore(owner, address(0));
    }

    // ========== registerAdapter ==========

    function test_registerAdapter_success() public {
        address adapter = makeAddr("adapter");

        vm.expectEmit(true, true, false, false);
        emit AdapterRegistered(ILPAdapter.LPType.UniswapV3, adapter);

        vm.prank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, adapter);

        assertEq(core.adapters(ILPAdapter.LPType.UniswapV3), adapter);
    }

    function test_registerAdapter_overwriteExisting() public {
        address adapter1 = makeAddr("adapter1");
        address adapter2 = makeAddr("adapter2");

        vm.startPrank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, adapter1);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, adapter2);
        vm.stopPrank();

        assertEq(core.adapters(ILPAdapter.LPType.UniswapV3), adapter2);
    }

    function test_registerAdapter_revertsNotOwner() public {
        vm.prank(user);
        vm.expectRevert("NOT_OWNER");
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, makeAddr("adapter"));
    }

    function test_registerAdapter_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(0));
    }

    function test_registerAdapter_guardianCannotRegister() public {
        vm.prank(guardian);
        vm.expectRevert("NOT_OWNER");
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, makeAddr("adapter"));
    }

    // ========== registerOracle ==========

    function test_registerOracle_success() public {
        address oracle = makeAddr("oracle");

        vm.expectEmit(true, true, false, false);
        emit OracleRegistered(ILPAdapter.LPType.UniswapV3, oracle);

        vm.prank(owner);
        core.registerOracle(ILPAdapter.LPType.UniswapV3, oracle);

        assertEq(core.oracles(ILPAdapter.LPType.UniswapV3), oracle);
    }

    function test_registerOracle_revertsNotOwner() public {
        vm.prank(user);
        vm.expectRevert("NOT_OWNER");
        core.registerOracle(ILPAdapter.LPType.UniswapV3, makeAddr("oracle"));
    }

    function test_registerOracle_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(0));
    }

    // ========== maxRegisteredLPType (PM-4) ==========

    function test_registerAdapter_updatesMaxLPType() public {
        assertEq(core.maxRegisteredLPType(), 0);

        vm.prank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, makeAddr("v2"));
        assertEq(core.maxRegisteredLPType(), 0); // UniswapV2 = 0

        vm.prank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, makeAddr("v3"));
        assertEq(core.maxRegisteredLPType(), 1); // UniswapV3 = 1

        vm.prank(owner);
        core.registerAdapter(ILPAdapter.LPType.PancakeSwapV3, makeAddr("pcv3"));
        assertEq(core.maxRegisteredLPType(), 5); // PancakeSwapV3 = 5
    }

    function test_registerAdapter_maxOnlyIncreases() public {
        vm.startPrank(owner);
        core.registerAdapter(ILPAdapter.LPType.PancakeSwapV3, makeAddr("pcv3")); // = 5
        assertEq(core.maxRegisteredLPType(), 5);

        core.registerAdapter(ILPAdapter.LPType.UniswapV2, makeAddr("v2")); // = 0
        assertEq(core.maxRegisteredLPType(), 5); // Still 5, not downgraded
        vm.stopPrank();
    }

    // ========== registerMarket ==========

    function test_registerMarket_success() public {
        address market = makeAddr("market");

        vm.expectEmit(true, true, false, false);
        emit MarketRegistered(0, market);

        vm.prank(owner);
        uint256 id = core.registerMarket(market);

        assertEq(id, 0);
        assertEq(core.markets(0), market);
        assertEq(core.nextMarketId(), 1);
    }

    function test_registerMarket_incrementsId() public {
        vm.startPrank(owner);
        uint256 id1 = core.registerMarket(makeAddr("market1"));
        uint256 id2 = core.registerMarket(makeAddr("market2"));
        uint256 id3 = core.registerMarket(makeAddr("market3"));
        vm.stopPrank();

        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(id3, 2);
        assertEq(core.nextMarketId(), 3);
    }

    function test_registerMarket_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.registerMarket(address(0));
    }

    function test_registerMarket_revertsNotOwner() public {
        vm.prank(user);
        vm.expectRevert("NOT_OWNER");
        core.registerMarket(makeAddr("market"));
    }

    // ========== whitelistPool ==========

    function test_whitelistPool_success() public {
        address pool = makeAddr("pool");

        vm.expectEmit(true, false, false, false);
        emit PoolWhitelisted(pool);

        vm.prank(owner);
        core.whitelistPool(pool);

        assertTrue(core.isPoolSupported(pool));
        assertEq(core.poolAddedAt(pool), block.timestamp);
    }

    function test_whitelistPool_revertsAlreadyWhitelisted() public {
        address pool = makeAddr("pool");
        vm.startPrank(owner);
        core.whitelistPool(pool);

        vm.expectRevert("ALREADY_WHITELISTED");
        core.whitelistPool(pool);
        vm.stopPrank();
    }

    function test_whitelistPool_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.whitelistPool(address(0));
    }

    function test_whitelistPool_revertsNotOwner() public {
        vm.prank(user);
        vm.expectRevert("NOT_OWNER");
        core.whitelistPool(makeAddr("pool"));
    }

    // ========== removePool ==========

    function test_removePool_success() public {
        address pool = makeAddr("pool");

        vm.startPrank(owner);
        core.whitelistPool(pool);
        assertTrue(core.isPoolSupported(pool));

        vm.expectEmit(true, false, false, false);
        emit PoolRemoved(pool);

        core.removePool(pool);
        vm.stopPrank();

        assertFalse(core.isPoolSupported(pool));
        // poolAddedAt preserved for historical reference
        assertGt(core.poolAddedAt(pool), 0);
    }

    function test_removePool_revertsNotWhitelisted() public {
        vm.prank(owner);
        vm.expectRevert("NOT_WHITELISTED");
        core.removePool(makeAddr("pool"));
    }

    function test_removePool_revertsNotOwner() public {
        address pool = makeAddr("pool");
        vm.prank(owner);
        core.whitelistPool(pool);

        vm.prank(user);
        vm.expectRevert("NOT_OWNER");
        core.removePool(pool);
    }

    function test_removePool_canReWhitelistAfterRemoval() public {
        address pool = makeAddr("pool");

        vm.startPrank(owner);
        core.whitelistPool(pool);
        core.removePool(pool);
        assertFalse(core.isPoolSupported(pool));

        // Advance time so new timestamp is different
        vm.warp(block.timestamp + 1000);

        // Re-whitelist should work (pool is no longer in whitelist)
        core.whitelistPool(pool);
        assertTrue(core.isPoolSupported(pool));
        vm.stopPrank();
    }

    // ========== setKeeper ==========

    function test_setKeeper_enable() public {
        address keeper = makeAddr("keeper");

        vm.expectEmit(true, false, false, true);
        emit KeeperUpdated(keeper, true);

        vm.prank(owner);
        core.setKeeper(keeper, true);

        assertTrue(core.keepers(keeper));
    }

    function test_setKeeper_disable() public {
        address keeper = makeAddr("keeper");

        vm.startPrank(owner);
        core.setKeeper(keeper, true);
        assertTrue(core.keepers(keeper));

        core.setKeeper(keeper, false);
        assertFalse(core.keepers(keeper));
        vm.stopPrank();
    }

    function test_setKeeper_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.setKeeper(address(0), true);
    }

    function test_setKeeper_revertsNotOwner() public {
        vm.prank(user);
        vm.expectRevert("NOT_OWNER");
        core.setKeeper(makeAddr("keeper"), true);
    }

    // ========== transferOwnership (two-step) ==========

    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);

    function test_transferOwnership_twoStep() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: Propose
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, newOwner);

        vm.prank(owner);
        core.transferOwnership(newOwner);

        // Owner hasn't changed yet
        assertEq(core.owner(), owner);
        assertEq(core.pendingOwner(), newOwner);

        // Step 2: Accept
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, newOwner);

        vm.prank(newOwner);
        core.acceptOwnership();

        assertEq(core.owner(), newOwner);
        assertEq(core.pendingOwner(), address(0));
    }

    function test_transferOwnership_onlyPendingCanAccept() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        core.transferOwnership(newOwner);

        vm.prank(user);
        vm.expectRevert("NOT_PENDING_OWNER");
        core.acceptOwnership();
    }

    function test_transferOwnership_newOwnerCanAct() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        core.transferOwnership(newOwner);
        vm.prank(newOwner);
        core.acceptOwnership();

        // Old owner can no longer act
        vm.prank(owner);
        vm.expectRevert("NOT_OWNER");
        core.setKeeper(makeAddr("keeper"), true);

        // New owner can act
        vm.prank(newOwner);
        core.setKeeper(makeAddr("keeper"), true);
    }

    function test_transferOwnership_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.transferOwnership(address(0));
    }

    function test_transferOwnership_revertsNotOwner() public {
        vm.prank(user);
        vm.expectRevert("NOT_OWNER");
        core.transferOwnership(makeAddr("newOwner"));
    }

    // ========== setGuardian ==========

    function test_setGuardian_success() public {
        address newGuardian = makeAddr("newGuardian");

        vm.expectEmit(true, true, false, false);
        emit GuardianUpdated(guardian, newGuardian);

        vm.prank(owner);
        core.setGuardian(newGuardian);

        assertEq(core.guardian(), newGuardian);
    }

    function test_setGuardian_newGuardianCanPause() public {
        address newGuardian = makeAddr("newGuardian");

        vm.prank(owner);
        core.setGuardian(newGuardian);

        // Old guardian can no longer pause
        vm.prank(guardian);
        vm.expectRevert("NOT_GUARDIAN");
        core.pause();

        // New guardian can pause
        vm.prank(newGuardian);
        core.pause();
        assertTrue(core.paused());
    }

    function test_setGuardian_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("ZERO_ADDRESS");
        core.setGuardian(address(0));
    }

    function test_setGuardian_revertsNotOwner() public {
        vm.prank(guardian);
        vm.expectRevert("NOT_OWNER");
        core.setGuardian(makeAddr("newGuardian"));
    }

    // ========== pause / unpause ==========

    function test_pause_byGuardian() public {
        vm.expectEmit(true, false, false, false);
        emit Paused(guardian);

        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused());
    }

    function test_pause_byOwner() public {
        vm.expectEmit(true, false, false, false);
        emit Paused(owner);

        vm.prank(owner);
        core.pause();
        assertTrue(core.paused());
    }

    function test_pause_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert("NOT_GUARDIAN");
        core.pause();
    }

    function test_pause_revertsAlreadyPaused() public {
        vm.prank(guardian);
        core.pause();

        vm.prank(guardian);
        vm.expectRevert("ALREADY_PAUSED");
        core.pause();
    }

    function test_unpause_byOwner() public {
        vm.prank(guardian);
        core.pause();

        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);

        vm.prank(owner);
        core.unpause();
        assertFalse(core.paused());
    }

    function test_unpause_revertsNotOwner() public {
        vm.prank(guardian);
        core.pause();

        // Guardian CANNOT unpause (security feature)
        vm.prank(guardian);
        vm.expectRevert("NOT_OWNER");
        core.unpause();
    }

    function test_unpause_revertsNotPaused() public {
        vm.prank(owner);
        vm.expectRevert("NOT_PAUSED");
        core.unpause();
    }

    function test_pause_unpause_cycle() public {
        // Pause
        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused());

        // Unpause
        vm.prank(owner);
        core.unpause();
        assertFalse(core.paused());

        // Pause again
        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused());
    }

    // ========== getAdapter / getOracle ==========

    function test_getAdapter_success() public {
        address adapter = makeAddr("adapter");
        vm.prank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, adapter);

        assertEq(core.getAdapter(ILPAdapter.LPType.UniswapV3), adapter);
    }

    function test_getAdapter_revertsNotFound() public {
        vm.expectRevert("ADAPTER_NOT_FOUND");
        core.getAdapter(ILPAdapter.LPType.UniswapV3);
    }

    function test_getOracle_success() public {
        address oracle = makeAddr("oracle");
        vm.prank(owner);
        core.registerOracle(ILPAdapter.LPType.Curve, oracle);

        assertEq(core.getOracle(ILPAdapter.LPType.Curve), oracle);
    }

    function test_getOracle_revertsNotFound() public {
        vm.expectRevert("ORACLE_NOT_FOUND");
        core.getOracle(ILPAdapter.LPType.Curve);
    }

    // ========== isPoolSupported ==========

    function test_isPoolSupported_falseByDefault() public view {
        assertFalse(core.isPoolSupported(address(0xdead)));
    }

    function test_isPoolSupported_trueAfterWhitelist() public {
        address pool = makeAddr("pool");
        vm.prank(owner);
        core.whitelistPool(pool);
        assertTrue(core.isPoolSupported(pool));
    }

    function test_isPoolSupported_falseAfterRemoval() public {
        address pool = makeAddr("pool");
        vm.startPrank(owner);
        core.whitelistPool(pool);
        core.removePool(pool);
        vm.stopPrank();
        assertFalse(core.isPoolSupported(pool));
    }

    // ========== getPoolAge ==========

    function test_getPoolAge_returnsZeroIfNeverAdded() public view {
        assertEq(core.getPoolAge(address(0xdead)), 0);
    }

    function test_getPoolAge_returnsCorrectAge() public {
        address pool = makeAddr("pool");
        vm.prank(owner);
        core.whitelistPool(pool);

        vm.warp(block.timestamp + 3600);
        assertEq(core.getPoolAge(pool), 3600);
    }

    function test_getPoolAge_preservedAfterRemoval() public {
        address pool = makeAddr("pool");
        vm.startPrank(owner);
        core.whitelistPool(pool);
        vm.stopPrank();

        vm.warp(block.timestamp + 5000);

        vm.prank(owner);
        core.removePool(pool);

        // Pool age still available (historical)
        assertGt(core.getPoolAge(pool), 0);
    }

    // ========== Multiple LP types ==========

    function test_registerMultipleAdaptersAndOracles() public {
        vm.startPrank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, makeAddr("v2adapter"));
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, makeAddr("v3adapter"));
        core.registerAdapter(ILPAdapter.LPType.Curve, makeAddr("curveAdapter"));

        core.registerOracle(ILPAdapter.LPType.UniswapV2, makeAddr("v2oracle"));
        core.registerOracle(ILPAdapter.LPType.UniswapV3, makeAddr("v3oracle"));
        core.registerOracle(ILPAdapter.LPType.Curve, makeAddr("curveOracle"));
        vm.stopPrank();

        assertEq(core.adapters(ILPAdapter.LPType.UniswapV2), makeAddr("v2adapter"));
        assertEq(core.adapters(ILPAdapter.LPType.UniswapV3), makeAddr("v3adapter"));
        assertEq(core.adapters(ILPAdapter.LPType.Curve), makeAddr("curveAdapter"));

        assertEq(core.oracles(ILPAdapter.LPType.UniswapV2), makeAddr("v2oracle"));
        assertEq(core.oracles(ILPAdapter.LPType.UniswapV3), makeAddr("v3oracle"));
        assertEq(core.oracles(ILPAdapter.LPType.Curve), makeAddr("curveOracle"));
    }

    // ========== Fuzz tests ==========

    function testFuzz_registerMarket_anyAddress(address market) public {
        vm.assume(market != address(0));
        vm.prank(owner);
        uint256 id = core.registerMarket(market);
        assertEq(core.markets(id), market);
    }

    function testFuzz_whitelistPool_anyAddress(address pool) public {
        vm.assume(pool != address(0));
        vm.prank(owner);
        core.whitelistPool(pool);
        assertTrue(core.isPoolSupported(pool));
    }

    function testFuzz_getPoolAge_increases(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 365 days);
        address pool = makeAddr("pool");

        vm.prank(owner);
        core.whitelistPool(pool);

        vm.warp(block.timestamp + elapsed);
        assertEq(core.getPoolAge(pool), elapsed);
    }

    function testFuzz_transferOwnership_anyNonZero(address newOwner) public {
        vm.assume(newOwner != address(0));
        vm.prank(owner);
        core.transferOwnership(newOwner);
        assertEq(core.pendingOwner(), newOwner);

        vm.prank(newOwner);
        core.acceptOwnership();
        assertEq(core.owner(), newOwner);
    }
}
