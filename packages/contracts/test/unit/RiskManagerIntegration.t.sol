// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {RiskManager} from "../../src/security/RiskManager.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title RiskManagerIntegrationTest
/// @notice Tests that RiskManager limits are enforced in LendingEngine.borrow() and PositionManager.deposit()
contract RiskManagerIntegrationTest is Test {
    ProtocolCore public core;
    PositionManager public pm;
    LendingEngine public le;
    LPOracleHub public oracleHub;
    RiskManager public rm;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockMarket public market;
    MockERC20 public usdc;
    InterestRateModel public irm;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public lpToken = makeAddr("lpToken");

    uint256 public marketId;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        irm = new InterestRateModel(200, 600, 10_000, 8000);
        core = new ProtocolCore(owner, guardian);

        LPOracleHub ohImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(ohImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );

        PositionManager pmImpl = new PositionManager();
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        LendingEngine leImpl = new LendingEngine();
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        oracle.setPrice(50_000e18);
        market = new MockMarket(address(usdc), address(irm));
        rm = new RiskManager(address(core));

        vm.startPrank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        oracleHub.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
        pm.setAuthorized(address(le), true);
        pm.setLendingEngine(address(le));

        // Wire RiskManager
        le.setRiskManager(address(rm));
        pm.setRiskManager(address(rm));
        rm.setAuthorizedCaller(address(le), true);
        vm.stopPrank();

        // Fund market
        usdc.mint(address(market), 200_000_000e18);
    }

    // ========== Max Positions Per User ==========

    function test_deposit_enforces_maxPositionsPerUser() public {
        // Default max = 20
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(alice);
            pm.deposit(lpToken, i + 1, 100e18, marketId);
        }

        // 21st should revert
        vm.prank(alice);
        vm.expectRevert("MAX_POSITIONS_REACHED");
        pm.deposit(lpToken, 21, 100e18, marketId);
    }

    function test_deposit_differentUsersIndependent() public {
        // Alice deposits 20
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(alice);
            pm.deposit(lpToken, i + 1, 100e18, marketId);
        }

        // Bob can still deposit
        vm.prank(bob);
        pm.deposit(lpToken, 100, 100e18, marketId);
    }

    function test_deposit_adminCanIncreaseLimit() public {
        vm.prank(owner);
        rm.setMaxPositionsPerUser(5);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            pm.deposit(lpToken, i + 1, 100e18, marketId);
        }

        vm.prank(alice);
        vm.expectRevert("MAX_POSITIONS_REACHED");
        pm.deposit(lpToken, 6, 100e18, marketId);

        // Owner increases limit
        vm.prank(owner);
        rm.setMaxPositionsPerUser(10);

        // Now Alice can deposit more
        vm.prank(alice);
        pm.deposit(lpToken, 6, 100e18, marketId);
    }

    // ========== Max Position Value ==========

    function test_deposit_enforces_maxPositionValue() public {
        // Default max = $10M. Position at $50K is fine.
        vm.prank(alice);
        pm.deposit(lpToken, 1, 100e18, marketId);

        // Set oracle to $11M — exceeds limit
        oracle.setPrice(11_000_000e18);

        vm.prank(alice);
        vm.expectRevert("POSITION_TOO_LARGE");
        pm.deposit(lpToken, 2, 100e18, marketId);
    }

    function test_deposit_exactlyAtLimit_succeeds() public {
        oracle.setPrice(10_000_000e18); // Exactly $10M
        vm.prank(alice);
        pm.deposit(lpToken, 1, 100e18, marketId);
    }

    // ========== Global Borrow Cap ==========

    function test_borrow_enforces_globalBorrowCap() public {
        // Set global cap to $50K
        vm.prank(owner);
        rm.setGlobalBorrowCap(50_000e18);

        oracle.setPrice(100_000e18); // $100K position
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        // Borrow $40K — within cap
        vm.prank(alice);
        le.borrow(posId, 40_000e18);

        // Borrow $15K more — exceeds $50K global cap
        vm.prank(alice);
        vm.expectRevert("GLOBAL_CAP_REACHED");
        le.borrow(posId, 15_000e18);
    }

    function test_borrow_globalCap_repayFreesCapacity() public {
        vm.prank(owner);
        rm.setGlobalBorrowCap(50_000e18);

        oracle.setPrice(100_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 40_000e18);

        // Repay $20K
        usdc.mint(alice, 20_000e18);
        vm.prank(alice);
        usdc.approve(address(market), 20_000e18);
        vm.prank(alice);
        le.repay(posId, 20_000e18);

        // Now can borrow $25K more (40K - 20K + 25K = 45K < 50K cap)
        vm.prank(alice);
        le.borrow(posId, 25_000e18);
    }

    // ========== Position Value Cap in Borrow ==========

    function test_borrow_enforces_positionValueCap() public {
        // Deposit at valid value ($50K < $10M default cap)
        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        // Admin lowers cap to $5K after deposit — borrow should now fail
        vm.prank(owner);
        rm.setMaxPositionValue(5000e18);

        vm.prank(alice);
        vm.expectRevert("POSITION_TOO_LARGE");
        le.borrow(posId, 1000e18);
    }

    // ========== LP Type Borrow Cap ==========

    function test_borrow_enforces_lpTypeBorrowCap() public {
        vm.prank(owner);
        rm.setLPTypeBorrowCap(ILPAdapter.LPType.UniswapV3, 30_000e18);

        oracle.setPrice(100_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        vm.prank(alice);
        le.borrow(posId, 25_000e18);

        // Exceeds LP type cap (25K + 10K > 30K)
        vm.prank(alice);
        vm.expectRevert("LP_TYPE_CAP_REACHED");
        le.borrow(posId, 10_000e18);
    }

    // ========== Without RiskManager (backward compatible) ==========

    function test_borrow_worksWithoutRiskManager() public {
        // Remove RiskManager
        vm.startPrank(owner);
        le.setRiskManager(address(0));
        pm.setRiskManager(address(0));
        vm.stopPrank();

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 1, 100e18, marketId);
        vm.roll(block.number + 2);

        // Borrow works without RiskManager — only LTV check applies
        vm.prank(alice);
        le.borrow(posId, 30_000e18);
        assertEq(le.getDebt(posId), 30_000e18);
    }

    // ========== Admin ==========

    function test_setRiskManager_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("NOT_OWNER");
        le.setRiskManager(makeAddr("rm"));
    }

    function test_setRiskManager_emitsEvent() public {
        address newRm = address(new RiskManager(address(core)));

        vm.recordLogs();
        vm.prank(owner);
        le.setRiskManager(newRm);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("RiskManagerUpdated(address,address)")) {
                found = true;
            }
        }
        assertTrue(found);
    }
}
