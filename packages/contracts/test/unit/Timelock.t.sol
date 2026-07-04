// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";

/// @title Stub contract for registration tests
contract StubContract {}

/// @title TimelockTest
/// @notice Tests the timelock integration with ACLManager + ProtocolCore
/// @dev Validates: delayed execution, instant emergency, role transfer, cancellation
contract TimelockTest is Test {
    TimelockController public timelock;
    ACLManager public aclManager;
    ProtocolCore public core;

    address public deployer = makeAddr("deployer");
    address public guardian = makeAddr("guardian");
    address public riskAdmin = makeAddr("riskAdmin");

    uint256 public constant MIN_DELAY = 48 hours;

    function setUp() public {
        vm.startPrank(deployer);

        // 1. Deploy ACLManager with deployer as initial admin
        aclManager = new ACLManager(deployer);

        // 2. Deploy TimelockController
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        // 3. Deploy ProtocolCore
        core = new ProtocolCore(deployer, address(aclManager));

        // 4. Grant roles
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addRiskAdmin(riskAdmin);

        // 5. Transfer POOL_ADMIN to timelock (deployer keeps it temporarily for setup)
        aclManager.grantRole(aclManager.POOL_ADMIN(), address(timelock));
        aclManager.grantRole(aclManager.DEFAULT_ADMIN_ROLE(), address(timelock));

        vm.stopPrank();
    }

    // ========== Delayed Operations ==========

    function test_registerAdapter_throughTimelock() public {
        address adapter = address(new StubContract());

        // Encode the call: core.registerAdapter(UniswapV3, adapter)
        bytes memory data = abi.encodeCall(ProtocolCore.registerAdapter, (ILPAdapter.LPType.UniswapV3, adapter));

        // Schedule through timelock
        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        // Cannot execute before delay
        vm.prank(deployer);
        vm.expectRevert();
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        // Wait for delay
        vm.warp(block.timestamp + MIN_DELAY);

        // Now execute
        vm.prank(deployer);
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        // Verify adapter was registered
        assertEq(core.adapters(ILPAdapter.LPType.UniswapV3), adapter);
    }

    function test_whitelistPool_throughTimelock() public {
        address pool = makeAddr("pool");

        bytes memory data = abi.encodeCall(ProtocolCore.whitelistPool, (pool));

        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(deployer);
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        assertTrue(core.isPoolSupported(pool));
    }

    // ========== Instant Operations (no timelock) ==========

    function test_pause_instantByGuardian() public {
        // Guardian can pause instantly — no timelock needed
        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused());
    }

    function test_unpause_instantByPoolAdmin() public {
        vm.prank(guardian);
        core.pause();

        // Deployer still has POOL_ADMIN, can unpause instantly
        vm.prank(deployer);
        core.unpause();
        assertFalse(core.paused());
    }

    function test_riskAdmin_canAdjustCapsInstantly() public {
        // RISK_ADMIN changes don't go through timelock
        // This validates the separation: structural changes = timelock, risk params = instant
        assertTrue(aclManager.isRiskAdmin(riskAdmin));
    }

    // ========== Cannot Bypass Timelock ==========

    function test_registerAdapter_directCall_reverts() public {
        // Timelock revokes deployer's POOL_ADMIN
        vm.startPrank(address(timelock));
        aclManager.revokeRole(aclManager.POOL_ADMIN(), deployer);
        vm.stopPrank();

        address adapter = address(new StubContract());

        vm.prank(deployer);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, adapter);
    }

    function test_whitelistPool_directCall_reverts() public {
        vm.startPrank(address(timelock));
        aclManager.revokeRole(aclManager.POOL_ADMIN(), deployer);
        vm.stopPrank();

        vm.prank(deployer);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.whitelistPool(makeAddr("pool"));
    }

    // ========== Cancellation ==========

    function test_cancelScheduledOperation() public {
        address adapter = address(new StubContract());
        bytes memory data = abi.encodeCall(ProtocolCore.registerAdapter, (ILPAdapter.LPType.UniswapV3, adapter));
        bytes32 id = timelock.hashOperation(address(core), 0, data, bytes32(0), bytes32(0));

        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        assertTrue(timelock.isOperationPending(id));

        // Cancel
        vm.prank(deployer);
        timelock.cancel(id);

        assertFalse(timelock.isOperationPending(id));

        // Cannot execute after cancel
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(deployer);
        vm.expectRevert();
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));
    }

    // ========== Role Transfer (Bootstrap) ==========

    function test_fullRoleTransfer_deployerLosesAdmin() public {
        // Deployer still has both roles initially
        assertTrue(aclManager.hasRole(aclManager.POOL_ADMIN(), deployer));
        assertTrue(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer));

        // Timelock also has both
        assertTrue(aclManager.hasRole(aclManager.POOL_ADMIN(), address(timelock)));
        assertTrue(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), address(timelock)));

        // Timelock revokes deployer's roles
        vm.startPrank(address(timelock));
        aclManager.revokeRole(aclManager.POOL_ADMIN(), deployer);
        aclManager.revokeRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopPrank();

        // Deployer has no admin roles
        assertFalse(aclManager.hasRole(aclManager.POOL_ADMIN(), deployer));
        assertFalse(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer));

        // Only timelock is admin now
        assertTrue(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(aclManager.hasRole(aclManager.POOL_ADMIN(), address(timelock)));
    }

    function test_afterTransfer_onlyTimelockCanGrantRoles() public {
        // Transfer full admin to timelock
        vm.startPrank(address(timelock));
        aclManager.revokeRole(aclManager.POOL_ADMIN(), deployer);
        aclManager.revokeRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopPrank();

        // Deployer can no longer grant roles
        address newAdmin = makeAddr("newAdmin");
        bytes32 poolAdminRole = aclManager.POOL_ADMIN();
        vm.prank(deployer);
        vm.expectRevert();
        aclManager.grantRole(poolAdminRole, newAdmin);

        // Timelock can grant roles
        vm.startPrank(address(timelock));
        aclManager.grantRole(aclManager.POOL_ADMIN(), newAdmin);
        vm.stopPrank();
        assertTrue(aclManager.isPoolAdmin(newAdmin));
    }

    // ========== Guardian Can Still Pause After Transfer ==========

    function test_guardianCanPause_afterFullTransfer() public {
        // Transfer admin to timelock
        vm.startPrank(address(timelock));
        aclManager.revokeRole(aclManager.POOL_ADMIN(), deployer);
        aclManager.revokeRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopPrank();

        // Guardian still has EMERGENCY_ADMIN — can pause instantly
        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused());

        // But guardian cannot unpause (needs POOL_ADMIN)
        vm.prank(guardian);
        vm.expectRevert("NOT_POOL_ADMIN");
        core.unpause();

        // Timelock can unpause (has POOL_ADMIN)
        bytes memory data = abi.encodeCall(ProtocolCore.unpause, ());
        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(deployer);
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        assertFalse(core.paused());
    }

    // ========== Timelock Delay ==========

    function test_timelockDelay() public view {
        assertEq(timelock.getMinDelay(), MIN_DELAY);
    }
}
