// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {LPCompounder} from "../../src/periphery/LPCompounder.sol";

/// @title CompoundFeesTest
/// @notice Unit tests for PositionManager.compoundFees and LPCompounder
contract CompoundFeesTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    FeeCollector public feeCollector;
    LPOracleHub public oracleHub;
    LPCompounder public compounder;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockMarket public market;
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public usdc;
    LendingEngine public le;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public keeper = makeAddr("keeper");
    address public treasury = makeAddr("treasury");
    address public insurance = makeAddr("insurance");
    address public lpToken = makeAddr("lpToken");

    uint256 public marketId;
    uint256 public positionId;

    event FeesCompoundedInternal(uint256 indexed positionId, uint256 fees0, uint256 fees1, uint256 addedLiquidity);

    function setUp() public {
        // Deploy tokens
        token0 = new MockERC20("WETH", "WETH", 18);
        token1 = new MockERC20("USDC", "USDC", 6);
        usdc = new MockERC20("USDC-Market", "USDC", 6);

        // Deploy ACLManager and core
        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        // Deploy FeeCollector
        feeCollector = new FeeCollector(address(core), treasury, insurance);

        // Deploy oracle hub (UUPS proxy)
        LPOracleHub oracleHubImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(oracleHubImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );

        // Deploy PositionManager (UUPS proxy)
        PositionManager pmImpl = new PositionManager();
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        // Deploy LendingEngine (UUPS proxy)
        LendingEngine leImpl = new LendingEngine();
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        // Deploy LPCompounder
        compounder = new LPCompounder(address(core), address(pm), address(feeCollector));

        // Deploy mocks
        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV3);
        adapter.setSupportedToken(lpToken, true);
        adapter.setTokenReturns(address(token0), address(token1));
        oracle = new MockLPOracle();
        InterestRateModel irm = new InterestRateModel(200, 600, 10_000, 8000);
        market = new MockMarket(address(usdc), address(irm));

        // Register everything
        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(address(le));
        aclManager.addPositionManager(address(pm));
        aclManager.addKeeper(address(compounder));
        aclManager.addKeeper(keeper);
        core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(adapter));
        oracleHub.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
        pm.setLendingEngine(address(le));
        vm.stopPrank();

        // Deposit a position as alice
        vm.prank(alice);
        positionId = pm.deposit(lpToken, 42, 100e18, marketId);
    }

    /// @dev Fund adapter with tokens and set mock fees
    function _setupFees(uint256 fee0, uint256 fee1) internal {
        adapter.setMockFees(fee0, fee1);
        if (fee0 > 0) token0.mint(address(adapter), fee0);
        if (fee1 > 0) token1.mint(address(adapter), fee1);
    }

    // ========== Access Control ==========

    function test_compoundFees_revertsNotAuthorized() public {
        _setupFees(1e18, 2000e6);
        vm.prank(alice);
        vm.expectRevert("NOT_AUTHORIZED");
        pm.compoundFees(positionId, address(feeCollector), 200, alice, 50, 1000, alice);
    }

    function test_compoundFees_keeperCanCall() public {
        _setupFees(1e18, 2000e6);
        vm.prank(keeper);
        (uint256 f0, uint256 f1, uint256 liq) =
            pm.compoundFees(positionId, address(feeCollector), 200, keeper, 50, 0, alice);
        assertGt(f0, 0);
        assertGt(f1, 0);
        assertGt(liq, 0);
    }

    function test_compoundFees_poolAdminCanCall() public {
        _setupFees(1e18, 2000e6);
        vm.prank(owner);
        (uint256 f0,,) = pm.compoundFees(positionId, address(feeCollector), 200, owner, 50, 0, alice);
        assertGt(f0, 0);
    }

    // ========== Input Validation ==========

    function test_compoundFees_revertsFeesTooHigh() public {
        _setupFees(1e18, 2000e6);
        vm.prank(keeper);
        vm.expectRevert("FEES_TOO_HIGH");
        pm.compoundFees(positionId, address(feeCollector), 4000, keeper, 1001, 0, alice);
    }

    function test_compoundFees_revertsZeroRefundAddress() public {
        _setupFees(1e18, 2000e6);
        vm.prank(keeper);
        vm.expectRevert("ZERO_REFUND_ADDRESS");
        pm.compoundFees(positionId, address(feeCollector), 200, keeper, 50, 0, address(0));
    }

    function test_compoundFees_revertsPositionNotFound() public {
        vm.prank(keeper);
        vm.expectRevert("POSITION_NOT_FOUND");
        pm.compoundFees(999, address(feeCollector), 200, keeper, 50, 0, alice);
    }

    function test_compoundFees_revertsClosedPosition() public {
        vm.prank(alice);
        pm.withdraw(positionId);

        _setupFees(1e18, 2000e6);
        vm.prank(keeper);
        vm.expectRevert("POSITION_NOT_ACTIVE");
        pm.compoundFees(positionId, address(feeCollector), 200, keeper, 50, 0, alice);
    }

    // ========== Zero Fees ==========

    function test_compoundFees_returnsZeroWhenNoFees() public {
        // No fees set (default 0)
        vm.prank(keeper);
        (uint256 f0, uint256 f1, uint256 liq) =
            pm.compoundFees(positionId, address(feeCollector), 200, keeper, 50, 0, alice);
        assertEq(f0, 0);
        assertEq(f1, 0);
        assertEq(liq, 0);
    }

    // ========== Threshold Check ==========

    function test_compoundFees_belowThresholdReturnsEarly() public {
        _setupFees(500, 500); // Below default threshold of 1000
        vm.prank(keeper);
        (uint256 f0, uint256 f1, uint256 liq) =
            pm.compoundFees(positionId, address(feeCollector), 200, keeper, 50, 1000, alice);
        // Fees were collected but no liquidity added (threshold not met)
        assertEq(f0, 500);
        assertEq(f1, 500);
        assertEq(liq, 0);
    }

    function test_compoundFees_aboveThresholdProceeds() public {
        _setupFees(2000, 500); // fee0 >= threshold
        vm.prank(keeper);
        (,, uint256 liq) = pm.compoundFees(positionId, address(feeCollector), 0, keeper, 0, 1000, alice);
        assertGt(liq, 0);
    }

    function test_compoundFees_zeroThresholdAlwaysProceeds() public {
        _setupFees(1, 1); // Tiny fees
        vm.prank(keeper);
        (,, uint256 liq) = pm.compoundFees(positionId, address(feeCollector), 0, keeper, 0, 0, alice);
        assertGt(liq, 0);
    }

    // ========== Fee Split ==========

    function test_compoundFees_protocolFeeGoesToFeeCollector() public {
        uint256 fee0 = 10_000e18; // 10K WETH
        uint256 fee1 = 20_000e6; // 20K USDC
        _setupFees(fee0, fee1);

        uint256 protocolBps = 200; // 2%

        vm.prank(keeper);
        pm.compoundFees(positionId, address(feeCollector), protocolBps, keeper, 0, 0, alice);

        // FeeCollector should have received 2% of each token
        uint256 expectedFee0 = (fee0 * protocolBps) / 10_000; // 200 WETH
        uint256 expectedFee1 = (fee1 * protocolBps) / 10_000; // 400 USDC
        assertEq(feeCollector.accumulatedFees(address(token0)), expectedFee0);
        assertEq(feeCollector.accumulatedFees(address(token1)), expectedFee1);
    }

    function test_compoundFees_callerRewardGoesToRecipient() public {
        uint256 fee0 = 10_000e18;
        uint256 fee1 = 20_000e6;
        _setupFees(fee0, fee1);

        address rewardRecipient = makeAddr("rewardRecipient");
        uint256 callerBps = 50; // 0.5%

        vm.prank(keeper);
        pm.compoundFees(positionId, address(feeCollector), 0, rewardRecipient, callerBps, 0, alice);

        uint256 expectedReward0 = (fee0 * callerBps) / 10_000;
        uint256 expectedReward1 = (fee1 * callerBps) / 10_000;
        assertEq(token0.balanceOf(rewardRecipient), expectedReward0);
        assertEq(token1.balanceOf(rewardRecipient), expectedReward1);
    }

    function test_compoundFees_remainderReinvested() public {
        uint256 fee0 = 10_000e18;
        uint256 fee1 = 20_000e6;
        _setupFees(fee0, fee1);

        uint256 protocolBps = 200; // 2%
        uint256 callerBps = 50; // 0.5%

        vm.prank(keeper);
        (,, uint256 addedLiquidity) =
            pm.compoundFees(positionId, address(feeCollector), protocolBps, keeper, callerBps, 0, alice);

        // Reinvested = total - protocol - caller = 97.5%
        uint256 pFee0 = (fee0 * protocolBps) / 10_000;
        uint256 cReward0 = (fee0 * callerBps) / 10_000;
        uint256 reinvest0 = fee0 - pFee0 - cReward0;

        uint256 pFee1 = (fee1 * protocolBps) / 10_000;
        uint256 cReward1 = (fee1 * callerBps) / 10_000;
        uint256 reinvest1 = fee1 - pFee1 - cReward1;

        // MockLPAdapter.addLiquidity returns (amount0 + amount1, amount0, amount1)
        assertEq(addedLiquidity, reinvest0 + reinvest1);
    }

    function test_compoundFees_fullSplitAccounting() public {
        uint256 fee0 = 10_000e18;
        uint256 fee1 = 20_000e6;
        _setupFees(fee0, fee1);

        uint256 protocolBps = 200;
        uint256 callerBps = 50;
        address rewardRecipient = makeAddr("rewardRecipient");

        vm.prank(keeper);
        pm.compoundFees(positionId, address(feeCollector), protocolBps, rewardRecipient, callerBps, 0, alice);

        // Verify all tokens accounted for (no tokens left in PM)
        assertEq(token0.balanceOf(address(pm)), 0, "PM should have zero token0");
        assertEq(token1.balanceOf(address(pm)), 0, "PM should have zero token1");
    }

    function test_compoundFees_zeroProtocolFee() public {
        _setupFees(1e18, 2000e6);

        vm.prank(keeper);
        pm.compoundFees(positionId, address(feeCollector), 0, keeper, 50, 0, alice);

        // No protocol fees collected
        assertEq(feeCollector.accumulatedFees(address(token0)), 0);
        assertEq(feeCollector.accumulatedFees(address(token1)), 0);
    }

    function test_compoundFees_zeroCallerReward() public {
        _setupFees(1e18, 2000e6);
        address rewardRecipient = makeAddr("rewardRecipient");

        vm.prank(keeper);
        pm.compoundFees(positionId, address(feeCollector), 200, rewardRecipient, 0, 0, alice);

        // No caller reward
        assertEq(token0.balanceOf(rewardRecipient), 0);
        assertEq(token1.balanceOf(rewardRecipient), 0);
    }

    // ========== Event ==========

    function test_compoundFees_emitsEvent() public {
        uint256 fee0 = 1e18;
        uint256 fee1 = 2000e6;
        _setupFees(fee0, fee1);

        vm.expectEmit(true, false, false, false);
        emit FeesCompoundedInternal(positionId, fee0, fee1, 0);

        vm.prank(keeper);
        pm.compoundFees(positionId, address(feeCollector), 200, keeper, 50, 0, alice);
    }

    // ========== Borrowed Position ==========

    function test_compoundFees_worksOnBorrowedPosition() public {
        // Set debt to make position Borrowed
        vm.prank(address(le));
        pm.updateDebt(positionId, 5000e18);

        IPositionManager.Position memory pos = pm.getPosition(positionId);
        assertEq(uint8(pos.status), uint8(IPositionManager.PositionStatus.Borrowed));

        _setupFees(1e18, 2000e6);
        vm.prank(keeper);
        (uint256 f0,,) = pm.compoundFees(positionId, address(feeCollector), 200, keeper, 50, 0, alice);
        assertGt(f0, 0);
    }

    // ========== Max Fee Boundary ==========

    function test_compoundFees_maxFee5000Bps() public {
        _setupFees(1e18, 2000e6);
        // Exactly 50% total — should work
        vm.prank(keeper);
        pm.compoundFees(positionId, address(feeCollector), 2500, keeper, 2500, 0, alice);
    }

    function test_compoundFees_exceedsMaxFeeReverts() public {
        _setupFees(1e18, 2000e6);
        vm.prank(keeper);
        vm.expectRevert("FEES_TOO_HIGH");
        pm.compoundFees(positionId, address(feeCollector), 2501, keeper, 2500, 0, alice);
    }

    // ========== LPCompounder Integration ==========

    function test_compounder_compoundPosition() public {
        _setupFees(1e18, 2000e6);

        vm.prank(alice);
        compounder.compoundPosition(positionId);

        // Protocol fee (2% of fees) tracked in FeeCollector
        assertGt(feeCollector.accumulatedFees(address(token0)), 0);
        // Caller reward (0.5%) goes to alice
        assertGt(token0.balanceOf(alice), 0);
    }

    function test_compounder_compoundPositionWithRecipient() public {
        _setupFees(1e18, 2000e6);
        address rewardTo = makeAddr("rewardTo");

        vm.prank(alice);
        compounder.compoundPosition(positionId, rewardTo);

        assertGt(token0.balanceOf(rewardTo), 0);
    }

    function test_compounder_revertsNonV3() public {
        // Deploy a V2 adapter and position
        MockLPAdapter v2Adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV2);
        address v2LpToken = makeAddr("v2LP");
        v2Adapter.setSupportedToken(v2LpToken, true);
        // Set pool return so whitelisting works
        v2Adapter.setTokenReturns(address(token0), address(token1));

        // Create a V2-typed market
        MockMarket v2Market = new MockMarket(address(usdc), address(new InterestRateModel(200, 600, 10_000, 8000)));
        v2Market.setLpType(ILPAdapter.LPType.UniswapV2);

        vm.startPrank(owner);
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(v2Adapter));
        oracleHub.registerOracle(ILPAdapter.LPType.UniswapV2, address(oracle));
        core.whitelistPool(v2LpToken);
        uint256 v2MarketId = core.registerMarket(address(v2Market));
        vm.stopPrank();

        vm.prank(alice);
        uint256 v2PosId = pm.deposit(v2LpToken, 1, 100e18, v2MarketId);

        // Verify it's a V2 position
        IPositionManager.Position memory pos = pm.getPosition(v2PosId);
        assertEq(uint8(pos.lpType), uint8(ILPAdapter.LPType.UniswapV2));

        vm.prank(alice);
        vm.expectRevert("UNSUPPORTED_LP_TYPE");
        compounder.compoundPosition(v2PosId);
    }

    function test_compounder_batchCompound() public {
        // Create second position
        vm.prank(alice);
        uint256 posId2 = pm.deposit(lpToken, 43, 50e18, marketId);

        // Fund adapter with enough fees for both
        _setupFees(2e18, 4000e6);

        address caller = makeAddr("batchCaller");
        vm.prank(caller);
        uint256[] memory ids = new uint256[](2);
        ids[0] = positionId;
        ids[1] = posId2;
        compounder.batchCompound(ids);

        // Caller should have received rewards for first position
        // (second may fail due to adapter fees being consumed — that's ok, silently skipped)
        assertGt(token0.balanceOf(caller) + token1.balanceOf(caller), 0);
    }

    function test_compounder_batchCompound_skipsFailures() public {
        // One valid position + one invalid
        _setupFees(1e18, 2000e6);

        uint256[] memory ids = new uint256[](2);
        ids[0] = positionId;
        ids[1] = 999; // doesn't exist

        vm.prank(alice);
        // Should not revert
        compounder.batchCompound(ids);
    }

    // ========== LPCompounder Admin ==========

    function test_compounder_setCompoundFee() public {
        vm.prank(owner);
        compounder.setCompoundFee(500, 100);
        assertEq(compounder.compoundFeeBps(), 500);
        assertEq(compounder.callerRewardBps(), 100);
    }

    function test_compounder_setCompoundFee_revertsTooHigh() public {
        vm.prank(owner);
        vm.expectRevert("FEE_TOO_HIGH");
        compounder.setCompoundFee(1001, 100);
    }

    function test_compounder_setCompoundFee_revertsCallerExceedsTotal() public {
        vm.prank(owner);
        vm.expectRevert("CALLER_EXCEEDS_TOTAL");
        compounder.setCompoundFee(200, 201);
    }

    function test_compounder_setCompoundFee_revertsNotAuthorized() public {
        vm.prank(alice);
        vm.expectRevert("NOT_AUTHORIZED");
        compounder.setCompoundFee(500, 100);
    }

    function test_compounder_setMinCompoundThreshold() public {
        vm.prank(owner);
        compounder.setMinCompoundThreshold(5000);
        assertEq(compounder.minCompoundThreshold(), 5000);
    }

    function test_compounder_sweepTokens() public {
        // Send some tokens to compounder
        token0.mint(address(compounder), 1e18);

        vm.prank(owner);
        compounder.sweepTokens(address(token0), treasury, 1e18);
        assertEq(token0.balanceOf(treasury), 1e18);
    }

    function test_compounder_sweepTokens_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert("NOT_POOL_ADMIN");
        compounder.sweepTokens(address(token0), treasury, 1e18);
    }
}
