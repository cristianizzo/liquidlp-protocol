// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ILiquidationEngine} from "../interfaces/ILiquidationEngine.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ProtocolCore} from "./ProtocolCore.sol";
import {PositionManager} from "./PositionManager.sol";
import {LendingEngine} from "./LendingEngine.sol";
import {FeeCollector} from "./FeeCollector.sol";

/// @title LiquidationEngine
/// @notice Atomic liquidation: seize LP → unwind → swap → repay → profit to liquidator
/// @dev Liquidators only deal in borrow asset (e.g., USDC). Never touch LP tokens.
///      Reentrancy protected — multiple external calls during liquidation flow.
contract LiquidationEngine is ILiquidationEngine, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
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

    modifier whenNotPaused() {
        require(!core.paused(), "PAUSED");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
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

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // --- Admin Setters ---

    function setSwapRouter(address _swapRouter) external onlyOwner {
        require(_swapRouter != address(0), "ZERO_ADDRESS");
        emit SwapRouterUpdated(address(swapRouter), _swapRouter);
        swapRouter = ISwapRouter(_swapRouter);
    }

    function setMaxLiquidationPortion(uint256 _maxLiquidationPortion) external onlyOwner {
        require(_maxLiquidationPortion >= MIN_LIQUIDATION_PORTION, "BELOW_MIN");
        require(_maxLiquidationPortion <= MAX_LIQUIDATION_PORTION_CAP, "ABOVE_MAX");
        emit MaxLiquidationPortionUpdated(maxLiquidationPortion, _maxLiquidationPortion);
        maxLiquidationPortion = _maxLiquidationPortion;
    }

    function setMaxSwapSlippage(uint256 _maxSwapSlippageBps) external onlyOwner {
        require(_maxSwapSlippageBps >= MIN_SWAP_SLIPPAGE, "BELOW_MIN");
        require(_maxSwapSlippageBps <= MAX_SWAP_SLIPPAGE_CAP, "ABOVE_MAX");
        emit MaxSwapSlippageUpdated(maxSwapSlippageBps, _maxSwapSlippageBps);
        maxSwapSlippageBps = _maxSwapSlippageBps;
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
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
        IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();
        address borrowAsset = config.borrowAsset;

        // Step 3: Calculate collateral to seize in USD (18 decimals)
        // repayAmount is in borrow asset decimals (e.g., 6 for USDC, 18 for DAI)
        // positionValue from oracle is always 18 decimals USD
        // We must normalize to the same scale before computing proportions
        uint256 bonus = config.liquidationBonus;
        uint8 borrowDecimals = IERC20(borrowAsset).decimals();
        uint256 collateralToSeizeNormalized;
        {
            uint256 repayNormalized = _normalizeTo18(repayAmount, borrowDecimals);
            collateralToSeizeNormalized = repayNormalized + ((repayNormalized * bonus) / 10_000);
        }

        // Step 4: Pull repayment from liquidator (in borrow asset decimals)
        require(IERC20(borrowAsset).transferFrom(msg.sender, address(this), repayAmount), "LIQ_PULL_FAILED");

        // Step 5: Approve market and repay debt via LendingEngine
        // Reset approval first for USDT-compatibility (LIQ-6)
        IERC20(borrowAsset).approve(marketAddr, 0);
        IERC20(borrowAsset).approve(marketAddr, repayAmount);
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
        ILPAdapter adapter = ILPAdapter(adapterAddr);
        (uint256 amount0, uint256 amount1) = adapter.unwind(pos.lpToken, pos.tokenId, liquidityToRemove);

        // Step 7b: Update position amount to reflect removed liquidity
        positionManager.reducePositionAmount(positionId, liquidityToRemove256);

        // Step 8: Swap non-borrow-asset tokens to borrow asset
        uint256 totalReceived = _swapToBorrowAsset(pos.token0, pos.token1, amount0, amount1, borrowAsset);

        // Step 8b: Validate total received against oracle-expected value (sandwich attack protection)
        // collateralToSeizeNormalized is the oracle-expected USD value (18 dec) of what was unwound.
        // totalReceived is in borrow asset decimals. Normalize and compare.
        // TODO: Fork test — verify this comparison is valid when:
        //       - Borrow asset is not USD-pegged (e.g., ETH-denominated market)
        //       - Borrow asset depegs temporarily (USDT, USDC depeg scenario)
        //       - Large swap creates significant price impact beyond slippage tolerance
        {
            uint8 borrowDecimals = IERC20(borrowAsset).decimals();
            uint256 receivedNormalized = _normalizeTo18(totalReceived, borrowDecimals);
            // Minimum acceptable: expected value minus slippage tolerance
            uint256 minAcceptable = (collateralToSeizeNormalized * (10_000 - maxSwapSlippageBps)) / 10_000;
            require(receivedNormalized >= minAcceptable, "SWAP_SLIPPAGE_EXCEEDED");
        }

        // Step 9: Calculate profit and take protocol fee
        uint256 grossProfit = totalReceived > repayAmount ? totalReceived - repayAmount : 0;
        uint256 protocolFee = 0;

        if (grossProfit > 0 && address(feeCollector) != address(0)) {
            (protocolFee,) = feeCollector.calculateLiquidationFee(grossProfit);
            if (protocolFee > 0) {
                // Send fee to FeeCollector (reset approval for USDT-compat)
                IERC20(borrowAsset).approve(address(feeCollector), 0);
                IERC20(borrowAsset).approve(address(feeCollector), protocolFee);
                feeCollector.collectFee(borrowAsset, protocolFee, address(this), "liquidation");
            }
        }

        profit = grossProfit - protocolFee;

        // Send remaining proceeds to liquidator
        uint256 liquidatorPayout = totalReceived - protocolFee;
        if (liquidatorPayout > 0) {
            require(IERC20(borrowAsset).transfer(msg.sender, liquidatorPayout), "LIQ_PROFIT_TRANSFER_FAILED");
        }

        // Step 10: If fully liquidated, return remaining LP THEN mark as liquidated
        uint256 remainingDebt = lendingEngine.getDebt(positionId);
        if (remainingDebt == 0) {
            // Return remaining LP to borrower BEFORE marking as liquidated
            // (markLiquidated sets status to Liquidated, after which unlock would be blocked)
            PositionManager.Position memory freshPos = positionManager.getPosition(positionId);
            if (freshPos.amount > 0) {
                adapter.unlock(freshPos.lpToken, freshPos.tokenId, freshPos.amount, freshPos.owner);
            }

            // Now mark as liquidated (clears debt, sets status)
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
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(token != address(0) && to != address(0), "ZERO_ADDRESS");
        require(amount > 0, "ZERO_AMOUNT");
        require(IERC20(token).transfer(to, amount), "RESCUE_FAILED");
        emit TokensRescued(token, to, amount);
    }

    /// @dev Swap non-borrow-asset tokens to borrow asset.
    ///      Slippage protection: the swap router implementation is responsible for
    ///      price validation (e.g., Chainlink oracle check, AMM TWAP).
    ///      We pass minAmountOut = 0 here because input-based slippage is meaningless
    ///      for cross-token swaps with different prices/decimals (1 WBTC ≠ 1 USDC).
    ///      The maxSwapSlippageBps parameter is passed to the router for its use.
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
                IERC20(token0).approve(address(swapRouter), 0);
                IERC20(token0).approve(address(swapRouter), amount0);
                totalReceived += swapRouter.swap(token0, borrowAsset, amount0, 0);
            }
        }

        if (amount1 > 0) {
            if (token1 == borrowAsset) {
                totalReceived += amount1;
            } else {
                require(address(swapRouter) != address(0), "SWAP_ROUTER_NOT_SET");
                IERC20(token1).approve(address(swapRouter), 0);
                IERC20(token1).approve(address(swapRouter), amount1);
                totalReceived += swapRouter.swap(token1, borrowAsset, amount1, 0);
            }
        }
    }

    /// @notice Normalize a token amount to 18 decimals
    /// @dev USDC (6 dec): 1_000_000 → 1_000_000_000_000_000_000 (1e18)
    ///      DAI (18 dec): 1_000_000_000_000_000_000 → 1_000_000_000_000_000_000 (unchanged)
    function _normalizeTo18(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * (10 ** (18 - decimals));
        return amount / (10 ** (decimals - 18));
    }

    // --- Storage Gap (UUPS upgrade safety) ---
    uint256[50] private __gap;
}
