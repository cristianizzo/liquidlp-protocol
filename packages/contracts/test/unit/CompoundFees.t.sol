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
import {RiskManager} from "../../src/security/RiskManager.sol";

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
        core.registerOracle(ILPAdapter.LPType.UniswapV3, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
        pm.setLendingEngine(address(le));
        vm.stopPrank();

        // Deposit a position as alice
        vm.prank(alice);
        positionId = pm.deposit(lpToken, 42, 100e18, marketId);
    }

    /// @dev Helper to build CompoundFeesParams (replaces 8-param call pattern)
    function _cfParams(
        uint256 _posId,
        address _feeRecipient,
        uint256 _protocolBps,
        address _rewardRecipient,
        uint256 _callerBps,
        uint256 _threshold,
        address _dustTo,
        uint256 _slippage
    )
        internal
        pure
        returns (IPositionManager.CompoundFeesParams memory)
    {
        return IPositionManager.CompoundFeesParams({
            positionId: _posId,
            protocolFeeRecipient: _feeRecipient,
            protocolFeeBps: _protocolBps,
            callerRewardRecipient: _rewardRecipient,
            callerRewardBps: _callerBps,
            minFeeThreshold: _threshold,
            dustRefundTo: _dustTo,
            maxSlippageBps: _slippage
        });
    }

    /// @dev Fund adapter with tokens and set mock fees
    function _setupFees(uint256 fee0, uint256 fee1) internal {
        adapter.setMockFees(fee0, fee1);
        if (fee0 > 0) token0.mint(address(adapter), fee0);
        if (fee1 > 0) token1.mint(address(adapter), fee1);
    }

    // ========== Access Control ==========

    /// @notice Compounding runs through a wired RiskManager (recording the reinvested delta) and
    ///         is NOT blocked by the market supply cap — compounding a position's own fees is
    ///         track-only, not cap-enforced.
    function test_compoundFees_notBlockedBySupplyCap() public {
        RiskManager rm = new RiskManager(address(core));
        vm.startPrank(owner);
        core.setRiskManager(address(rm));
        rm.setMarketSupplyCap(marketId, 1); // effectively "at cap"
        vm.stopPrank();

        _setupFees(1e18, 1000e6);

        // Must succeed despite the cap (would revert SUPPLY_CAP_REACHED if it were cap-enforced).
        vm.prank(keeper);
        (uint256 f0, uint256 f1,) =
            pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 0, alice, 0));
        assertTrue(f0 > 0 || f1 > 0, "compound ran through the RiskManager path");
    }

    function test_compoundFees_revertsNotAuthorized() public {
        _setupFees(1e18, 2000e6);
        vm.prank(alice);
        vm.expectRevert("NOT_AUTHORIZED");
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, alice, 50, 1000, alice, 0));
    }

    function test_compoundFees_keeperCanCall() public {
        _setupFees(1e18, 2000e6);
        vm.prank(keeper);
        (uint256 f0, uint256 f1, uint256 liq) =
            pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 0, alice, 0));
        assertGt(f0, 0);
        assertGt(f1, 0);
        assertGt(liq, 0);
    }

    function test_compoundFees_poolAdminCanCall() public {
        _setupFees(1e18, 2000e6);
        vm.prank(owner);
        (uint256 f0,,) = pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, owner, 50, 0, alice, 0));
        assertGt(f0, 0);
    }

    // ========== Input Validation ==========

    function test_compoundFees_revertsFeesTooHigh() public {
        _setupFees(1e18, 2000e6);
        vm.prank(keeper);
        vm.expectRevert("FEES_TOO_HIGH");
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 4000, keeper, 1001, 0, alice, 0));
    }

    function test_compoundFees_revertsZeroRefundAddress() public {
        _setupFees(1e18, 2000e6);
        vm.prank(keeper);
        vm.expectRevert("ZERO_REFUND_ADDRESS");
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 0, address(0), 0));
    }

    function test_compoundFees_revertsPositionNotFound() public {
        vm.prank(keeper);
        vm.expectRevert("POSITION_NOT_FOUND");
        pm.compoundFees(_cfParams(999, address(feeCollector), 200, keeper, 50, 0, alice, 0));
    }

    function test_compoundFees_revertsClosedPosition() public {
        vm.prank(alice);
        pm.withdraw(positionId);

        _setupFees(1e18, 2000e6);
        vm.prank(keeper);
        vm.expectRevert("POSITION_NOT_ACTIVE");
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 0, alice, 0));
    }

    // ========== Zero Fees ==========

    function test_compoundFees_returnsZeroWhenNoFees() public {
        // No fees set (default 0)
        vm.prank(keeper);
        (uint256 f0, uint256 f1, uint256 liq) =
            pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 0, alice, 0));
        assertEq(f0, 0);
        assertEq(f1, 0);
        assertEq(liq, 0);
    }

    // ========== Threshold Check ==========

    function test_compoundFees_belowThresholdReverts() public {
        _setupFees(500, 500); // Below threshold
        vm.prank(keeper);
        vm.expectRevert("BELOW_MIN_FEE_THRESHOLD");
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 1000, alice, 0));
    }

    function test_compoundFees_aboveThresholdProceeds() public {
        _setupFees(2000, 500); // fee0 >= threshold
        vm.prank(keeper);
        (,, uint256 liq) = pm.compoundFees(_cfParams(positionId, address(feeCollector), 0, keeper, 0, 1000, alice, 0));
        assertGt(liq, 0);
    }

    function test_compoundFees_zeroThresholdAlwaysProceeds() public {
        _setupFees(1, 1); // Tiny fees
        vm.prank(keeper);
        (,, uint256 liq) = pm.compoundFees(_cfParams(positionId, address(feeCollector), 0, keeper, 0, 0, alice, 0));
        assertGt(liq, 0);
    }

    // ========== Fee Split ==========

    function test_compoundFees_protocolFeeGoesToFeeCollector() public {
        uint256 fee0 = 10_000e18; // 10K WETH
        uint256 fee1 = 20_000e6; // 20K USDC
        _setupFees(fee0, fee1);

        uint256 protocolBps = 200; // 2%

        vm.prank(keeper);
        pm.compoundFees(_cfParams(positionId, address(feeCollector), protocolBps, keeper, 0, 0, alice, 0));

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
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 0, rewardRecipient, callerBps, 0, alice, 0));

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
            pm.compoundFees(_cfParams(positionId, address(feeCollector), protocolBps, keeper, callerBps, 0, alice, 0));

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
        pm.compoundFees(
            _cfParams(positionId, address(feeCollector), protocolBps, rewardRecipient, callerBps, 0, alice, 0)
        );

        // Verify all tokens accounted for (no tokens left in PM)
        assertEq(token0.balanceOf(address(pm)), 0, "PM should have zero token0");
        assertEq(token1.balanceOf(address(pm)), 0, "PM should have zero token1");
    }

    function test_compoundFees_zeroProtocolFee() public {
        _setupFees(1e18, 2000e6);

        vm.prank(keeper);
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 0, keeper, 50, 0, alice, 0));

        // No protocol fees collected
        assertEq(feeCollector.accumulatedFees(address(token0)), 0);
        assertEq(feeCollector.accumulatedFees(address(token1)), 0);
    }

    function test_compoundFees_zeroCallerReward() public {
        _setupFees(1e18, 2000e6);
        address rewardRecipient = makeAddr("rewardRecipient");

        vm.prank(keeper);
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, rewardRecipient, 0, 0, alice, 0));

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
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 0, alice, 0));
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
        (uint256 f0,,) = pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 0, alice, 0));
        assertGt(f0, 0);
    }

    // ========== Max Fee Boundary ==========

    function test_compoundFees_maxFee500Bps() public {
        _setupFees(1e18, 2000e6);
        // Exactly 5% total (300 protocol + 200 caller) — should work
        vm.prank(keeper);
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 300, keeper, 200, 0, alice, 0));
    }

    function test_compoundFees_exceedsMaxFeeReverts() public {
        _setupFees(1e18, 2000e6);
        // 501 bps total exceeds the 5% cap
        vm.prank(keeper);
        vm.expectRevert("FEES_TOO_HIGH");
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 301, keeper, 200, 0, alice, 0));
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

    function test_compounder_revertsPositionNotFound() public {
        vm.prank(alice);
        vm.expectRevert("POSITION_NOT_FOUND");
        compounder.compoundPosition(999);
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
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(oracle));
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

    // ========== _distributeFees (via compoundFees) ==========

    function test_distributeFees_onlyProtocolFee_noCallerReward() public {
        uint256 fee0 = 10_000e18;
        uint256 fee1 = 20_000e6;
        _setupFees(fee0, fee1);

        // 5% protocol, 0% caller
        vm.prank(keeper);
        (,, uint256 liq) = pm.compoundFees(_cfParams(positionId, address(feeCollector), 500, keeper, 0, 0, alice, 0));

        // 95% reinvested
        uint256 expectedReinvest0 = fee0 - (fee0 * 500 / 10_000);
        uint256 expectedReinvest1 = fee1 - (fee1 * 500 / 10_000);
        assertEq(liq, expectedReinvest0 + expectedReinvest1);
        assertEq(token0.balanceOf(keeper), 0, "No caller reward");
    }

    function test_distributeFees_onlyCallerReward_noProtocolFee() public {
        uint256 fee0 = 10_000e18;
        _setupFees(fee0, 0);

        address rewardTo = makeAddr("rewardTo");
        // 0% protocol, 3% caller
        vm.prank(keeper);
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 0, rewardTo, 300, 0, alice, 0));

        assertEq(feeCollector.accumulatedFees(address(token0)), 0, "No protocol fee");
        assertEq(token0.balanceOf(rewardTo), fee0 * 300 / 10_000, "Caller gets 3%");
    }

    function test_distributeFees_singleTokenFee() public {
        // Only token0 has fees, token1 = 0
        _setupFees(5e18, 0);

        vm.prank(keeper);
        (uint256 f0, uint256 f1, uint256 liq) =
            pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 0, alice, 0));

        assertEq(f0, 5e18);
        assertEq(f1, 0);
        assertGt(liq, 0);
        // Protocol gets 2% of token0 only
        assertEq(feeCollector.accumulatedFees(address(token0)), 5e18 * 200 / 10_000);
        assertEq(feeCollector.accumulatedFees(address(token1)), 0);
    }

    function test_distributeFees_dustAmounts() public {
        // Very small fees — just above threshold
        _setupFees(1001, 0);

        vm.prank(keeper);
        (uint256 f0,, uint256 liq) =
            pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 1000, alice, 0));

        assertEq(f0, 1001);
        // 2% of 1001 = 20 (truncated), 0.5% of 1001 = 5 (truncated)
        // Reinvested = 1001 - 20 - 5 = 976
        assertGt(liq, 0);
    }

    function test_distributeFees_maxProtocolAndCallerFee() public {
        // 3% protocol + 2% caller = 5% total (max allowed)
        _setupFees(10_000e18, 10_000e6);

        vm.prank(keeper);
        (,, uint256 liq) = pm.compoundFees(_cfParams(positionId, address(feeCollector), 300, keeper, 200, 0, alice, 0));

        // 95% reinvested (5% total fee taken)
        uint256 expectedReinvest0 = (10_000e18 * 9500) / 10_000;
        uint256 expectedReinvest1 = (10_000e6 * 9500) / 10_000;
        assertEq(liq, expectedReinvest0 + expectedReinvest1);
    }

    // ========== batchCompound error event ==========

    event CompoundFailed(uint256 indexed positionId, bytes reason);

    function test_batchCompound_emitsCompoundFailed() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999; // doesn't exist

        vm.expectEmit(true, false, false, false);
        emit CompoundFailed(999, "");

        vm.prank(alice);
        compounder.batchCompound(ids);
    }

    // ========== Compound slippage ==========

    function test_compoundFees_slippageBpsOverflow_reverts() public {
        _setupFees(1e18, 2000e6);
        vm.prank(keeper);
        vm.expectRevert("SLIPPAGE_BPS_OVERFLOW");
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 0, alice, 10_001));
    }

    function test_compoundFees_withSlippage_succeeds() public {
        _setupFees(10_000e18, 20_000e6);
        // 2% max slippage — mock adapter returns used == reinvested, so no slippage
        vm.prank(keeper);
        (,, uint256 liq) = pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 0, alice, 200));
        assertGt(liq, 0);
    }

    function test_compoundFees_zeroSlippage_noCheck() public {
        _setupFees(1e18, 2000e6);
        // maxSlippageBps = 0 skips slippage check entirely
        vm.prank(keeper);
        pm.compoundFees(_cfParams(positionId, address(feeCollector), 200, keeper, 50, 0, alice, 0));
    }
}
