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
import {IERC20} from "../interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolCore} from "./ProtocolCore.sol";
import {ACLManager} from "./ACLManager.sol";
import {PositionManager} from "./PositionManager.sol";
import {LendingEngine} from "./LendingEngine.sol";
import {FeeCollector} from "./FeeCollector.sol";
import {PriceFeedRegistry} from "../oracle/PriceFeedRegistry.sol";

/// @title LiquidationEngine
/// @notice Atomic liquidation: seize LP → unwind → send underlying tokens to liquidator
/// @dev The protocol does NOT swap tokens during liquidation. The liquidator receives
///      the raw underlying tokens (e.g., ETH + USDC) from the LP unwind. This eliminates
///      swap slippage, MEV sandwich attacks, and SwapRouter dependency.
///      For single-asset liquidation UX, use the FlashloanLiquidator periphery contract.
///
///      Protocol fee is taken from the repayment amount (in borrow asset), not from
///      the unwound tokens. This keeps the fee calculation simple and deterministic.
contract LiquidationEngine is ILiquidationEngine, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for OZIERC20;

    ProtocolCore public core;
    PositionManager public positionManager;
    LendingEngine public lendingEngine;

    /// @dev Deprecated — swap removed from liquidation flow. Kept for UUPS storage layout.
    address private __deprecated_swapRouter;
    FeeCollector public feeCollector;

    // --- Configurable Parameters ---
    uint256 public maxLiquidationPortion = 5000; // 50%
    /// @dev Deprecated — no swap in liquidation flow. Kept for UUPS storage layout.
    uint256 private __deprecated_maxSwapSlippageBps;

    // --- Absolute Bounds ---
    uint256 public constant MIN_LIQUIDATION_PORTION = 1000;
    uint256 public constant MAX_LIQUIDATION_PORTION_CAP = 10_000;
    uint256 public constant LIQUIDATION_THRESHOLD = 1e18;

    // --- Events ---
    event MaxLiquidationPortionUpdated(uint256 oldValue, uint256 newValue);
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
    }

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

    // --- Admin Setters ---

    function setMaxLiquidationPortion(uint256 _maxLiquidationPortion) external onlyRiskAdmin {
        require(_maxLiquidationPortion >= MIN_LIQUIDATION_PORTION, "BELOW_MIN");
        require(_maxLiquidationPortion <= MAX_LIQUIDATION_PORTION_CAP, "ABOVE_MAX");
        emit MaxLiquidationPortionUpdated(maxLiquidationPortion, _maxLiquidationPortion);
        maxLiquidationPortion = _maxLiquidationPortion;
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

        // Step 1: Accrue interest BEFORE health factor check
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        lendingEngine.accrueInterest(pos.marketId);

        // Step 2: Verify position is liquidatable (with fresh interest)
        (bool canLiquidate, uint256 maxRepay) = isLiquidatable(positionId);
        require(canLiquidate, "NOT_LIQUIDATABLE");
        require(repayAmount <= maxRepay, "EXCEEDS_MAX_REPAY");

        // Step 3: Get market config
        address marketAddr = core.markets(pos.marketId);
        require(marketAddr != address(0), "MARKET_NOT_FOUND");
        IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();
        address borrowAsset = config.borrowAsset;

        // Step 4: Calculate collateral to seize in USD (18 decimals)
        uint256 bonus = config.liquidationBonus;
        uint8 borrowDecimals = IERC20(borrowAsset).decimals();
        uint256 collateralToSeizeNormalized;
        {
            uint256 repayUsd = _getRepayValueUsd(borrowAsset, repayAmount, borrowDecimals);
            collateralToSeizeNormalized = repayUsd + ((repayUsd * bonus) / 10_000);
        }

        // Step 5: Pull repayment from liquidator
        uint256 balBefore = IERC20(borrowAsset).balanceOf(address(this));
        OZIERC20(borrowAsset).safeTransferFrom(msg.sender, address(this), repayAmount);
        uint256 balAfter = IERC20(borrowAsset).balanceOf(address(this));
        require(balAfter >= balBefore && balAfter - balBefore == repayAmount, "FEE_ON_TRANSFER_UNSUPPORTED");

        // Step 6: Take protocol fee from repayment (before repaying debt)
        uint256 protocolFee = 0;
        if (address(feeCollector) != address(0)) {
            (protocolFee,) = feeCollector.calculateLiquidationFee(repayAmount);
            if (protocolFee > 0) {
                OZIERC20(borrowAsset).forceApprove(address(feeCollector), protocolFee);
                feeCollector.collectFee(borrowAsset, protocolFee, address(this), "liquidation");
            }
        }

        // Step 7: Repay debt via LendingEngine (repayAmount minus protocol fee)
        uint256 debtRepayment = repayAmount - protocolFee;
        OZIERC20(borrowAsset).forceApprove(marketAddr, debtRepayment);
        lendingEngine.repayOnBehalf(positionId, debtRepayment);

        // Step 8: Calculate liquidity to remove proportional to collateral seized
        uint256 positionValue = positionManager.getPositionValue(positionId);
        uint256 totalLiquidity = pos.amount;
        uint256 liquidityToRemove256;
        if (positionValue == 0 || collateralToSeizeNormalized >= positionValue) {
            liquidityToRemove256 = totalLiquidity;
        } else {
            liquidityToRemove256 = (totalLiquidity * collateralToSeizeNormalized) / positionValue;
        }
        require(liquidityToRemove256 > 0, "ZERO_LIQUIDITY");
        require(liquidityToRemove256 <= type(uint128).max, "LIQUIDITY_OVERFLOW");
        uint128 liquidityToRemove = uint128(liquidityToRemove256);

        // Step 9: Unwind LP — reduce position amount BEFORE external call (CEI pattern)
        address adapterAddr = core.adapters(pos.lpType);
        require(adapterAddr != address(0), "ADAPTER_NOT_SET");
        ILPAdapter adapter = ILPAdapter(adapterAddr);

        positionManager.reducePositionAmount(positionId, liquidityToRemove256);
        (uint256 amount0, uint256 amount1) = adapter.unwind(pos.lpToken, pos.tokenId, liquidityToRemove);

        // Step 10: Send underlying tokens directly to liquidator — NO SWAP
        // The liquidator receives the raw tokens from the LP unwind (e.g., ETH + USDC).
        // They decide how/when to sell. This eliminates swap slippage and MEV risk.
        if (amount0 > 0) {
            OZIERC20(pos.token0).safeTransfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            OZIERC20(pos.token1).safeTransfer(msg.sender, amount1);
        }

        // Step 11: Handle full debt repayment — return remaining LP to borrower
        uint256 remainingDebt = lendingEngine.getDebt(positionId);
        if (remainingDebt == 0) {
            PositionManager.Position memory freshPos = positionManager.getPosition(positionId);

            if (freshPos.amount > 0) {
                adapter.unlock(freshPos.lpToken, freshPos.tokenId, freshPos.amount, freshPos.owner);
                positionManager.reducePositionAmount(positionId, freshPos.amount);
            }

            positionManager.markLiquidated(positionId, msg.sender, repayAmount);
        }

        // profit is not directly calculable here since liquidator receives two tokens.
        // The event emits collateralSeized in USD for off-chain profit tracking.
        profit = 0;

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

        if (healthFactor < CRITICAL_HF_THRESHOLD) {
            maxRepay = totalDebt;
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

    // --- Rescue ---

    /// @notice Rescue tokens stuck in this contract (e.g., unexpected transfer)
    /// @dev Only callable by PoolAdmin. Cannot rescue during active liquidation (nonReentrant).
    function rescueTokens(address token, address to, uint256 amount) external onlyPoolAdmin nonReentrant {
        require(token != address(0) && to != address(0), "ZERO_ADDRESS");
        require(amount > 0, "ZERO_AMOUNT");
        OZIERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    // --- Internal ---

    /// @notice Convert borrow asset amount to 18-dec USD value
    /// @dev Uses PriceFeedRegistry if available, falls back to decimal normalization (assumes $1 peg)
    function _getRepayValueUsd(address borrowAsset, uint256 amount, uint8 decimals) internal view returns (uint256) {
        require(decimals <= 36, "INVALID_DECIMALS");
        PriceFeedRegistry registry = positionManager.priceFeedRegistry();
        if (address(registry) != address(0)) {
            return registry.getUsdValue(borrowAsset, amount, decimals);
        }
        if (decimals < 18) {
            return Math.mulDiv(amount, 10 ** (18 - decimals), 1);
        } else if (decimals > 18) {
            return amount / (10 ** (decimals - 18));
        }
        return amount;
    }

    // --- Storage Gap (UUPS upgrade safety) ---
    uint256[50] private __gap;
}
