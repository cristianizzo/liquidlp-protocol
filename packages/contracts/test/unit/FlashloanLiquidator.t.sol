// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../../src/core/ProtocolCore.sol";
import {ACLManager} from "../../src/core/ACLManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {LendingEngine} from "../../src/core/LendingEngine.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {LPOracleHub} from "../../src/oracle/LPOracleHub.sol";
import {InterestRateModel} from "../../src/markets/InterestRateModel.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {FlashloanLiquidator} from "../../src/periphery/FlashloanLiquidator.sol";
import {MockLPAdapter} from "../mocks/MockLPAdapter.sol";
import {MockLPOracle} from "../mocks/MockLPOracle.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";

/// @notice Mock Uniswap V3 pool that simulates flash loans
/// @dev Holds borrow asset tokens. On flash(), transfers requested amounts to recipient,
///      calls uniswapV3FlashCallback, then verifies repayment was received.
contract MockFlashPool {
    address public token0;
    address public token1;
    uint24 public fee = 3000;
    uint256 public flashFee = 100; // small fee in absolute terms

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setFlashFee(uint256 _fee) external {
        flashFee = _fee;
    }

    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external {
        uint256 balance0Before = MockERC20(token0).balanceOf(address(this));
        uint256 balance1Before = MockERC20(token1).balanceOf(address(this));

        // Transfer requested amounts to recipient
        if (amount0 > 0) {
            MockERC20(token0).transfer(recipient, amount0);
        }
        if (amount1 > 0) {
            MockERC20(token1).transfer(recipient, amount1);
        }

        // Calculate fees
        uint256 fee0 = amount0 > 0 ? flashFee : 0;
        uint256 fee1 = amount1 > 0 ? flashFee : 0;

        // Call the callback on the recipient
        FlashloanLiquidator(recipient).uniswapV3FlashCallback(fee0, fee1, data);

        // Verify repayment: pool must have at least original balance + fee
        if (amount0 > 0) {
            require(MockERC20(token0).balanceOf(address(this)) >= balance0Before + fee0, "FLASH_NOT_REPAID_0");
        }
        if (amount1 > 0) {
            require(MockERC20(token1).balanceOf(address(this)) >= balance1Before + fee1, "FLASH_NOT_REPAID_1");
        }
    }
}

/// @notice Mock Uniswap V3 factory that maps token pairs to pools
contract MockV3Factory {
    mapping(bytes32 => address) public pools;

    function registerPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[keccak256(abi.encodePacked(tokenA, tokenB, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        address pool = pools[keccak256(abi.encodePacked(tokenA, tokenB, fee))];
        if (pool != address(0)) return pool;
        return pools[keccak256(abi.encodePacked(tokenB, tokenA, fee))];
    }
}

contract FlashloanLiquidatorTest is Test {
    ProtocolCore public core;
    ACLManager public aclManager;
    PositionManager public pm;
    LendingEngine public le;
    LiquidationEngine public liq;
    LPOracleHub public oracleHub;
    MockLPAdapter public adapter;
    MockLPOracle public oracle;
    MockMarket public market;
    MockERC20 public usdc;
    MockERC20 public weth;
    InterestRateModel public irm;
    MockSwapRouter public swapRouter;
    FlashloanLiquidator public flashLiquidator;
    MockFlashPool public flashPool;
    MockV3Factory public v3Factory;

    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public caller = makeAddr("caller");
    address public lpToken = makeAddr("lpToken");

    uint256 public marketId;

    event FlashLiquidation(
        uint256 indexed positionId, address indexed liquidator, address borrowAsset, uint256 repayAmount, uint256 profit
    );

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        weth = new MockERC20("WETH", "WETH", 18);
        irm = new InterestRateModel(200, 600, 10_000, 8000);

        aclManager = new ACLManager(owner);
        core = new ProtocolCore(owner, address(aclManager));

        // OracleHub proxy
        LPOracleHub ohImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(ohImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );

        // PositionManager proxy
        PositionManager pmImpl = new PositionManager();
        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        // LendingEngine proxy
        LendingEngine leImpl = new LendingEngine();
        le = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(pm)))
                )
            )
        );

        // LiquidationEngine proxy
        LiquidationEngine liqImpl = new LiquidationEngine();
        liq = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(liqImpl),
                    abi.encodeCall(LiquidationEngine.initialize, (address(core), address(pm), address(le)))
                )
            )
        );

        // Mocks
        adapter = new MockLPAdapter(ILPAdapter.LPType.UniswapV2);
        adapter.setSupportedToken(lpToken, true);
        oracle = new MockLPOracle();
        oracle.setPrice(50_000e18);
        market = new MockMarket(address(usdc), address(irm));
        market.setLpType(ILPAdapter.LPType.UniswapV2);

        // Swap router mock — outputs USDC
        swapRouter = new MockSwapRouter(address(usdc));
        // 1 WETH = 2000 USDC (in 18-dec mock terms)
        swapRouter.setExchangeRate(address(weth), 2000e18);

        // Flash pool: token0 = usdc, token1 = weth
        // Order tokens to match what the liquidator expects
        flashPool = new MockFlashPool(address(usdc), address(weth));

        // Factory that recognizes the flash pool as genuine
        v3Factory = new MockV3Factory();
        v3Factory.registerPool(address(usdc), address(weth), 3000, address(flashPool));

        // Deploy FlashloanLiquidator
        flashLiquidator =
            new FlashloanLiquidator(address(core), address(pm), address(liq), address(swapRouter), address(v3Factory));

        // Register and grant roles
        vm.startPrank(owner);
        aclManager.addEmergencyAdmin(guardian);
        aclManager.addLendingEngine(address(le));
        aclManager.addLiquidationEngine(address(liq));
        aclManager.addPositionManager(address(pm));
        core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(adapter));
        core.registerOracle(ILPAdapter.LPType.UniswapV2, address(oracle));
        core.whitelistPool(lpToken);
        marketId = core.registerMarket(address(market));
        pm.setLendingEngine(address(le));
        vm.stopPrank();

        // Configure adapter to return WETH and USDC
        adapter.setTokenReturns(address(weth), address(usdc));
        adapter.setUnwindAmounts(25e18, 25_000e18);
        adapter.setTotalLiquidity(100e18);

        // Fund market, adapter, flash pool, and swap router with tokens
        usdc.mint(address(market), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);
        usdc.mint(address(adapter), 1_000_000e18);
        usdc.mint(address(flashPool), 1_000_000e18);
        weth.mint(address(flashPool), 1_000_000e18);
        usdc.mint(address(swapRouter), 1_000_000e18);
    }

    // --- Helpers ---

    /// @notice Create a position and borrow, then make it liquidatable by dropping oracle price
    function _createLiquidatablePosition() internal returns (uint256 posId) {
        vm.prank(alice);
        posId = pm.deposit(lpToken, 0, 100e18, marketId);
        vm.roll(block.number + 2);

        // Alice borrows $30K (within 65% LTV of $50K)
        vm.prank(alice);
        le.borrow(posId, 30_000e18);

        // Oracle price drops to $30K -> HF = ($30K * 7500 / 10000) / $30K = 0.75
        oracle.setPrice(30_000e18);
    }

    // ========== Constructor ==========

    function test_constructor_revertsZeroAddress() public {
        vm.expectRevert("ZERO_ADDRESS");
        new FlashloanLiquidator(address(0), address(pm), address(liq), address(swapRouter), address(v3Factory));

        vm.expectRevert("ZERO_ADDRESS");
        new FlashloanLiquidator(address(core), address(0), address(liq), address(swapRouter), address(v3Factory));

        vm.expectRevert("ZERO_ADDRESS");
        new FlashloanLiquidator(address(core), address(pm), address(0), address(swapRouter), address(v3Factory));

        vm.expectRevert("ZERO_ADDRESS");
        new FlashloanLiquidator(address(core), address(pm), address(liq), address(0), address(v3Factory));

        vm.expectRevert("ZERO_ADDRESS");
        new FlashloanLiquidator(address(core), address(pm), address(liq), address(swapRouter), address(0));
    }

    function test_liquidate_revertsFakeFlashPool() public {
        uint256 posId = _createLiquidatablePosition();

        // A fake pool with correct tokens/fee but NOT registered in the factory
        MockFlashPool fakePool = new MockFlashPool(address(usdc), address(weth));
        usdc.mint(address(fakePool), 1_000_000e18);

        bytes memory swapPath = abi.encodePacked(address(weth), uint24(3000), address(usdc));

        vm.prank(caller);
        vm.expectRevert("INVALID_FLASH_POOL");
        flashLiquidator.liquidate(
            FlashloanLiquidator.LiquidateParams({
                positionId: posId,
                repayAmount: 10_000e18,
                flashLoanPool: address(fakePool),
                swapPath0: "",
                swapPath1: swapPath,
                minProfit: 0
            })
        );
    }

    // ========== Flash Liquidation Success ==========

    function test_flashLiquidate_success() public {
        uint256 posId = _createLiquidatablePosition();

        (, uint256 maxRepay) = liq.isLiquidatable(posId);
        uint256 repayAmount = maxRepay;

        // Build swap path for WETH -> USDC (packed encoding)
        bytes memory swapPath0 = abi.encodePacked(address(weth), uint24(3000), address(usdc));
        // token1 is USDC (the borrow asset) so no swap needed — empty path
        bytes memory swapPath1 = bytes("");

        uint256 callerUsdcBefore = usdc.balanceOf(caller);

        vm.prank(caller);
        flashLiquidator.liquidate(
            FlashloanLiquidator.LiquidateParams({
                positionId: posId,
                repayAmount: repayAmount,
                flashLoanPool: address(flashPool),
                swapPath0: swapPath0,
                swapPath1: swapPath1,
                minProfit: 0
            })
        );

        uint256 callerUsdcAfter = usdc.balanceOf(caller);
        // Caller should have received profit (liquidation bonus proceeds exceed flash fee)
        assertGe(callerUsdcAfter, callerUsdcBefore, "Caller must receive profit");

        // Position debt should be reduced
        uint256 debtAfter = le.getDebt(posId);
        assertLt(debtAfter, 30_000e18, "Debt must decrease");
    }

    // ========== Insufficient Profit ==========

    function test_flashLiquidate_revertsInsufficientProfit() public {
        uint256 posId = _createLiquidatablePosition();

        (, uint256 maxRepay) = liq.isLiquidatable(posId);

        bytes memory swapPath0 = abi.encodePacked(address(weth), uint24(3000), address(usdc));
        bytes memory swapPath1 = bytes("");

        // Set minProfit absurdly high — should revert with INSUFFICIENT_PROFIT
        vm.prank(caller);
        vm.expectRevert("INSUFFICIENT_PROFIT");
        flashLiquidator.liquidate(
            FlashloanLiquidator.LiquidateParams({
                positionId: posId,
                repayAmount: maxRepay,
                flashLoanPool: address(flashPool),
                swapPath0: swapPath0,
                swapPath1: swapPath1,
                minProfit: type(uint256).max
            })
        );
    }

    // ========== Skip Swap When Token == BorrowAsset ==========

    function test_flashLiquidate_skipsSwapForBorrowAsset() public {
        // Set token0 = USDC (same as borrow asset). Adapter returns USDC for both sides.
        adapter.setTokenReturns(address(usdc), address(usdc));
        adapter.setUnwindAmounts(25_000e18, 25_000e18);

        oracle.setPrice(50_000e18);
        vm.prank(alice);
        uint256 posId = pm.deposit(lpToken, 0, 100e18, marketId);
        vm.roll(block.number + 2);
        vm.prank(alice);
        le.borrow(posId, 30_000e18);
        oracle.setPrice(30_000e18);

        (, uint256 maxRepay) = liq.isLiquidatable(posId);

        // Both tokens are borrow asset — no swap paths needed
        vm.prank(caller);
        flashLiquidator.liquidate(
            FlashloanLiquidator.LiquidateParams({
                positionId: posId,
                repayAmount: maxRepay,
                flashLoanPool: address(flashPool),
                swapPath0: bytes(""),
                swapPath1: bytes(""),
                minProfit: 0
            })
        );

        // Should succeed without calling swap router
        uint256 debtAfter = le.getDebt(posId);
        assertLt(debtAfter, 30_000e18, "Debt must decrease");
    }

    // ========== Callback Security ==========

    function test_flashCallback_revertsNonPool() public {
        bytes memory fakeData = abi.encode(
            FlashloanLiquidator.FlashCallbackData({
                positionId: 1,
                repayAmount: 1000e18,
                borrowAsset: address(usdc),
                token0: address(weth),
                token1: address(usdc),
                marketAddr: address(market),
                swapPath0: bytes(""),
                swapPath1: bytes(""),
                minProfit: 0,
                caller: caller,
                flashLoanPool: address(flashPool) // expects flashPool as sender
            })
        );

        // Call from an address that is NOT the flash pool
        vm.prank(caller);
        vm.expectRevert("NOT_FLASH_POOL");
        flashLiquidator.uniswapV3FlashCallback(0, 0, fakeData);
    }

    // ========== Position Not Found ==========

    function test_flashLiquidate_revertsPositionNotFound() public {
        uint256 invalidPositionId = 999;

        vm.prank(caller);
        vm.expectRevert("POSITION_NOT_FOUND");
        flashLiquidator.liquidate(
            FlashloanLiquidator.LiquidateParams({
                positionId: invalidPositionId,
                repayAmount: 1000e18,
                flashLoanPool: address(flashPool),
                swapPath0: bytes(""),
                swapPath1: bytes(""),
                minProfit: 0
            })
        );
    }
}
