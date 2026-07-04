// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiquidationEngine} from "../interfaces/ILiquidationEngine.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolCore} from "./ProtocolCore.sol";
import {ACLManager} from "./ACLManager.sol";
import {PositionManager} from "./PositionManager.sol";
import {LendingEngine} from "./LendingEngine.sol";
import {FeeCollector} from "./FeeCollector.sol";
import {PriceFeedRegistry} from "../oracle/PriceFeedRegistry.sol";

/// @title LiquidationEngine
/// @notice Atomic liquidation: seize LP → unwind → swap → repay → profit to liquidator
/// @dev Liquidators only deal in borrow asset (e.g., USDC). Never touch LP tokens.
///      Reentrancy protected — multiple external calls during liquidation flow.
///
///      Slippage check converts borrow asset to USD via PriceFeedRegistry when configured.
///      Falls back to USD-peg assumption (decimal normalization) when registry is not set.
contract LiquidationEngine is ILiquidationEngine, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for OZIERC20;

    ProtocolCore public core;
    PositionManager public positionManager;
    LendingEngine public lendingEngine;

    ISwapRouter public swapRouter;
    FeeCollector public feeCollector;

    // --- Configurable Parameters ---
    uint256 public maxLiquidationPortion = 5000; // 50%
    uint256 public maxSwapSlippageBps = 300; // 3%

    // --- Absolute Bounds ---
    uint256 public constant MIN_LIQUIDATION_PORTION = 1000;
    uint256 public constant MAX_LIQUIDATION_PORTION_CAP = 10_000;
    uint256 public constant MIN_SWAP_SLIPPAGE = 50;
    uint256 public constant MAX_SWAP_SLIPPAGE_CAP = 1000;
    uint256 public constant LIQUIDATION_THRESHOLD = 1e18;

    // --- Events ---
    event MaxLiquidationPortionUpdated(uint256 oldValue, uint256 newValue);
    event MaxSwapSlippageUpdated(uint256 oldValue, uint256 newValue);
    event SwapRouterUpdated(address oldRouter, address newRouter);
    event FeeCollectorUpdated(address oldCollector, address newCollector);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier whenNotPaused() {
        require(!core.paused(), "PAUSED");
        _;
    }

    modifier onlyPoolAdmin() {
        require(_acl().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    modifier onlyRiskAdmin() {
        ACLManager acl = _acl();
        require(acl.isRiskAdmin(msg.sender) || acl.isPoolAdmin(msg.sender), "NOT_RISK_ADMIN");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _core, address _positionManager, address _lendingEngine) external initializer {
        require(_core != address(0) && _positionManager != address(0) && _lendingEngine != address(0), "ZERO_ADDRESS");
        core = ProtocolCore(_core);
        positionManager = PositionManager(_positionManager);
        lendingEngine = LendingEngine(_lendingEngine);

        // Set defaults (state variable initializers don't run in proxy context)
        maxLiquidationPortion = 5000;
        maxSwapSlippageBps = 300;
    }

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

    // --- Admin Setters ---

    function setSwapRouter(address _swapRouter) external onlyPoolAdmin {
        require(_swapRouter != address(0), "ZERO_ADDRESS");
        require(_swapRouter.code.length > 0, "NOT_CONTRACT");
        emit SwapRouterUpdated(address(swapRouter), _swapRouter);
        swapRouter = ISwapRouter(_swapRouter);
    }

    function setMaxLiquidationPortion(uint256 _maxLiquidationPortion) external onlyRiskAdmin {
        require(_maxLiquidationPortion >= MIN_LIQUIDATION_PORTION, "BELOW_MIN");
        require(_maxLiquidationPortion <= MAX_LIQUIDATION_PORTION_CAP, "ABOVE_MAX");
        emit MaxLiquidationPortionUpdated(maxLiquidationPortion, _maxLiquidationPortion);
        maxLiquidationPortion = _maxLiquidationPortion;
    }

    function setMaxSwapSlippage(uint256 _maxSwapSlippageBps) external onlyRiskAdmin {
        require(_maxSwapSlippageBps >= MIN_SWAP_SLIPPAGE, "BELOW_MIN");
        require(_maxSwapSlippageBps <= MAX_SWAP_SLIPPAGE_CAP, "ABOVE_MAX");
        emit MaxSwapSlippageUpdated(maxSwapSlippageBps, _maxSwapSlippageBps);
        maxSwapSlippageBps = _maxSwapSlippageBps;
    }

    function setFeeCollector(address _feeCollector) external onlyPoolAdmin {
        require(_feeCollector != address(0), "ZERO_ADDRESS");
        emit FeeCollectorUpdated(address(feeCollector), _feeCollector);
        feeCollector = FeeCollector(_feeCollector);
    }

    // --- Core Logic ---

    /// @inheritdoc ILiquidationEngine
    function liquidate(
        uint256 positionId,
        uint256 repayAmount,
        uint256 deadline
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 profit)
    {
        require(repayAmount > 0, "ZERO_AMOUNT");
        require(block.timestamp <= deadline, "EXPIRED");

        // Step 0: Accrue interest BEFORE health factor check (LIQ-5)
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        lendingEngine.accrueInterest(pos.marketId);

        // Step 1: Verify position is liquidatable (now with fresh interest)
        (bool canLiquidate, uint256 maxRepay) = isLiquidatable(positionId);
        require(canLiquidate, "NOT_LIQUIDATABLE");
        require(repayAmount <= maxRepay, "EXCEEDS_MAX_REPAY");

        // Step 2: Get market config
        address marketAddr = core.markets(pos.marketId);
        require(marketAddr != address(0), "MARKET_NOT_FOUND");
        IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();
        address borrowAsset = config.borrowAsset;

        // Step 3: Calculate collateral to seize in USD (18 decimals)
        // Convert repayAmount to USD via PriceFeedRegistry (Aave-style)
        // This works for any borrow asset (USDC, WBTC, ETH, etc.)
        uint256 bonus = config.liquidationBonus;
        uint8 borrowDecimals = IERC20(borrowAsset).decimals();
        uint256 collateralToSeizeNormalized;
        {
            uint256 repayUsd = _getRepayValueUsd(borrowAsset, repayAmount, borrowDecimals);
            collateralToSeizeNormalized = repayUsd + ((repayUsd * bonus) / 10_000);
        }

        // Step 4: Pull repayment from liquidator (in borrow asset decimals)
        // Balance-delta check: ensure exact amount received (rejects fee-on-transfer tokens)
        uint256 balBefore = IERC20(borrowAsset).balanceOf(address(this));
        OZIERC20(borrowAsset).safeTransferFrom(msg.sender, address(this), repayAmount);
        uint256 balAfter = IERC20(borrowAsset).balanceOf(address(this));
        require(balAfter >= balBefore && balAfter - balBefore == repayAmount, "FEE_ON_TRANSFER_UNSUPPORTED");

        // Step 5: Approve market and repay debt via LendingEngine
        OZIERC20(borrowAsset).forceApprove(marketAddr, repayAmount);
        lendingEngine.repayOnBehalf(positionId, repayAmount);

        // Step 6: Calculate liquidity to remove proportional to collateral seized
        // Both collateralToSeizeNormalized and positionValue are now in 18-decimal USD
        // Use uint256 for math to avoid truncation for V2 LP tokens (V3 is uint128 but V2 is uint256)
        uint256 positionValue = positionManager.getPositionValue(positionId);
        uint256 totalLiquidity = pos.amount;
        uint256 liquidityToRemove256;
        if (positionValue == 0 || collateralToSeizeNormalized >= positionValue) {
            liquidityToRemove256 = totalLiquidity;
        } else {
            liquidityToRemove256 = (totalLiquidity * collateralToSeizeNormalized) / positionValue;
        }
        require(liquidityToRemove256 > 0, "ZERO_LIQUIDITY");

        // Cast to uint128 for adapter.unwind() — V3 uses uint128 liquidity natively.
        // For V2, amounts should fit in uint128 (max ~3.4e38, far above any real LP supply).
        require(liquidityToRemove256 <= type(uint128).max, "LIQUIDITY_OVERFLOW");
        uint128 liquidityToRemove = uint128(liquidityToRemove256);

        // Step 7: Atomic LP unwinding via adapter
        address adapterAddr = core.adapters(pos.lpType);
        require(adapterAddr != address(0), "ADAPTER_NOT_SET");
        ILPAdapter adapter = ILPAdapter(adapterAddr);

        // Step 7a: Reduce position amount BEFORE external unwind call (CEI pattern)
        positionManager.reducePositionAmount(positionId, liquidityToRemove256);

        (uint256 amount0, uint256 amount1) = adapter.unwind(pos.lpToken, pos.tokenId, liquidityToRemove);

        // Step 8: Swap non-borrow-asset tokens to borrow asset
        uint256 totalReceived = _swapToBorrowAsset(pos.token0, pos.token1, amount0, amount1, borrowAsset);

        // Step 8b: Validate total received against oracle-expected value (sandwich attack protection)
        // When position is underwater (seize >= positionValue), use positionValue as baseline
        // instead of the bonus-inflated collateralToSeize. This ensures underwater positions
        // remain liquidatable — preventing bad debt is more important than the liquidator bonus.
        {
            uint256 receivedUsd = _getRepayValueUsd(borrowAsset, totalReceived, borrowDecimals);
            uint256 slippageBaseline =
                collateralToSeizeNormalized >= positionValue ? positionValue : collateralToSeizeNormalized;
            uint256 minAcceptable = (slippageBaseline * (10_000 - maxSwapSlippageBps)) / 10_000;
            require(receivedUsd >= minAcceptable, "SWAP_SLIPPAGE_EXCEEDED");
        }

        // Step 9: Calculate profit and take protocol fee
        uint256 grossProfit = totalReceived > repayAmount ? totalReceived - repayAmount : 0;
        uint256 protocolFee = 0;

        if (grossProfit > 0 && address(feeCollector) != address(0)) {
            (protocolFee,) = feeCollector.calculateLiquidationFee(grossProfit);
            if (protocolFee > grossProfit) protocolFee = grossProfit; // Clamp to prevent underflow
            if (protocolFee > 0) {
                OZIERC20(borrowAsset).forceApprove(address(feeCollector), protocolFee);
                feeCollector.collectFee(borrowAsset, protocolFee, address(this), "liquidation");
            }
        }

        profit = grossProfit - protocolFee;

        // Send remaining proceeds to liquidator
        uint256 liquidatorPayout = totalReceived - protocolFee;
        if (liquidatorPayout > 0) {
            OZIERC20(borrowAsset).safeTransfer(msg.sender, liquidatorPayout);
        }

        // Step 10: Handle full debt repayment
        uint256 remainingDebt = lendingEngine.getDebt(positionId);
        if (remainingDebt == 0) {
            PositionManager.Position memory freshPos = positionManager.getPosition(positionId);

            if (freshPos.amount > 0) {
                // Remaining LP exists — return to borrower, then reduce tracked amount to 0
                adapter.unlock(freshPos.lpToken, freshPos.tokenId, freshPos.amount, freshPos.owner);
                positionManager.reducePositionAmount(positionId, freshPos.amount);
            }

            // Mark as terminal state (clears debt, sets status to Liquidated)
            positionManager.markLiquidated(positionId, msg.sender, repayAmount);
        }

        emit LiquidationExecuted(positionId, msg.sender, repayAmount, collateralToSeizeNormalized, profit);
    }

    /// @notice Health factor below which 100% liquidation is allowed (prevents bad debt)
    uint256 public constant CRITICAL_HF_THRESHOLD = 0.95e18; // 0.95

    /// @inheritdoc ILiquidationEngine
    function isLiquidatable(uint256 positionId) public view returns (bool liquidatable, uint256 maxRepay) {
        uint256 healthFactor = positionManager.getHealthFactor(positionId);

        if (healthFactor >= LIQUIDATION_THRESHOLD) {
            return (false, 0);
        }

        uint256 totalDebt = lendingEngine.getDebt(positionId);
        if (totalDebt == 0) return (false, 0);

        // LIQ-4: Allow 100% liquidation when severely underwater
        // to prevent bad debt accumulation
        if (healthFactor < CRITICAL_HF_THRESHOLD) {
            maxRepay = totalDebt; // Full liquidation allowed
        } else {
            maxRepay = (totalDebt * maxLiquidationPortion) / 10_000;
        }

        if (maxRepay == 0) maxRepay = 1;

        return (true, maxRepay);
    }

    /// @inheritdoc ILiquidationEngine
    function getLiquidationBonus(uint256 positionId) public view returns (uint256) {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        address marketAddr = core.markets(pos.marketId);
        return IMarket(marketAddr).getConfig().liquidationBonus;
    }

    // --- Internal ---

    /// @notice Rescue tokens stuck in this contract (e.g., failed swap, unexpected transfer)
    /// @dev Only callable by owner (DAO). Cannot rescue tokens during an active liquidation (nonReentrant).
    function rescueTokens(address token, address to, uint256 amount) external onlyPoolAdmin nonReentrant {
        require(token != address(0) && to != address(0), "ZERO_ADDRESS");
        require(amount > 0, "ZERO_AMOUNT");
        OZIERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    /// @notice Convert borrow asset amount to 18-dec USD value
    /// @dev Uses PriceFeedRegistry if available, falls back to decimal normalization (assumes $1 peg)
    function _getRepayValueUsd(address borrowAsset, uint256 amount, uint8 decimals) internal view returns (uint256) {
        require(decimals <= 36, "INVALID_DECIMALS");
        PriceFeedRegistry registry = positionManager.priceFeedRegistry();
        if (address(registry) != address(0)) {
            return registry.getUsdValue(borrowAsset, amount, decimals);
        }
        // Fallback: assume USD-pegged (1 token = $1), overflow-safe
        if (decimals < 18) {
            return Math.mulDiv(amount, 10 ** (18 - decimals), 1);
        } else if (decimals > 18) {
            return amount / (10 ** (decimals - 18));
        }
        return amount;
    }

    /// @dev Swap non-borrow-asset tokens to borrow asset.
    ///      Slippage protection: the swap router implementation is responsible for
    ///      price validation (e.g., Chainlink oracle check, AMM TWAP).
    ///      We pass minAmountOut = 0 to the router because per-swap slippage is checked
    ///      post-trade against oracle value (Step 8b), not per-swap.
    ///      This is intentional: cross-token swaps with different prices/decimals
    ///      (1 WBTC ≠ 1 USDC) make input-based minAmountOut meaningless.
    function _swapToBorrowAsset(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        address borrowAsset
    )
        internal
        returns (uint256 totalReceived)
    {
        if (amount0 > 0) {
            if (token0 == borrowAsset) {
                totalReceived += amount0;
            } else {
                require(address(swapRouter) != address(0), "SWAP_ROUTER_NOT_SET");
                OZIERC20(token0).forceApprove(address(swapRouter), amount0);
                totalReceived += swapRouter.swap(token0, borrowAsset, amount0, 0);
            }
        }

        if (amount1 > 0) {
            if (token1 == borrowAsset) {
                totalReceived += amount1;
            } else {
                require(address(swapRouter) != address(0), "SWAP_ROUTER_NOT_SET");
                OZIERC20(token1).forceApprove(address(swapRouter), amount1);
                totalReceived += swapRouter.swap(token1, borrowAsset, amount1, 0);
            }
        }
    }

    // --- Storage Gap (UUPS upgrade safety) ---
    uint256[50] private __gap;
}
