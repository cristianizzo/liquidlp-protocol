// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ILendingEngine} from "../interfaces/ILendingEngine.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolCore} from "./ProtocolCore.sol";
import {ACLManager} from "./ACLManager.sol";
import {PriceFeedRegistry} from "../oracle/PriceFeedRegistry.sol";
import {PositionManager} from "./PositionManager.sol";
import {Market} from "../markets/Market.sol";
import {RiskManager} from "../security/RiskManager.sol";

/// @title LendingEngine
/// @notice Handles borrowing against LP positions and repayment with interest
/// @dev UUPS upgradeable + reentrancy protected.
///      Interest accrual is delegated to Market (single source of truth).
///      LendingEngine reads Market.borrowIndex() for per-position debt calculation.
///
///      Important for integrators:
///      - getDebt() returns debt as of the last on-chain accrual, NOT real-time.
///        Call accrueInterest(marketId) first for up-to-date values.
///      - repay() is permissionless — anyone can repay any position's debt (payer = msg.sender).
///        This is intentional (same as Aave/Compound — generous repayment).
///      - repayOnBehalf() is restricted to LIQUIDATION_ENGINE role.
///      - borrowCooldownBlocks is chain-dependent: 50 blocks = ~10min on ETH, ~100s on L2s.
contract LendingEngine is ILendingEngine, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    ProtocolCore public core;
    PositionManager public positionManager;

    struct DebtInfo {
        uint256 principal;
        uint256 borrowIndex;
    }

    mapping(uint256 => DebtInfo) public debtInfo;

    uint256 public borrowCooldownBlocks = 1;
    uint256 public constant MIN_COOLDOWN = 1;
    uint256 public constant MAX_COOLDOWN = 50;

    RiskManager public riskManager;

    event BorrowCooldownUpdated(uint256 oldValue, uint256 newValue);
    event RiskManagerUpdated(address indexed oldManager, address indexed newManager);

    // --- ACL Helpers ---
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _core, address _positionManager) external initializer {
        require(_core != address(0) && _positionManager != address(0), "ZERO_ADDRESS");
        core = ProtocolCore(_core);
        positionManager = PositionManager(_positionManager);
        borrowCooldownBlocks = 1;
    }

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

    /// @notice Set borrow cooldown (blocks after deposit before borrowing allowed)
    function setBorrowCooldown(uint256 _blocks) external onlyPoolAdmin {
        require(_blocks >= MIN_COOLDOWN && _blocks <= MAX_COOLDOWN, "OUT_OF_BOUNDS");
        emit BorrowCooldownUpdated(borrowCooldownBlocks, _blocks);
        borrowCooldownBlocks = _blocks;
    }

    function setRiskManager(address _riskManager) external onlyPoolAdmin {
        require(_riskManager == address(0) || _riskManager.code.length > 0, "NOT_CONTRACT");
        emit RiskManagerUpdated(address(riskManager), _riskManager);
        riskManager = RiskManager(_riskManager);
    }

    // --- Core Logic ---

    /// @inheritdoc ILendingEngine
    function borrow(uint256 positionId, uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "ZERO_AMOUNT");

        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        require(pos.owner == msg.sender, "NOT_POSITION_OWNER");
        require(
            pos.status != IPositionManager.PositionStatus.Liquidated
                && pos.status != IPositionManager.PositionStatus.Closed,
            "POSITION_NOT_ACTIVE"
        );

        require(block.number > pos.depositBlock + borrowCooldownBlocks, "BORROW_COOLDOWN");

        address marketAddr = _getMarketAddr(pos.marketId);
        Market market = Market(marketAddr);
        market.accrueInterest();

        uint256 currentDebt = _getCurrentDebt(positionId, market);
        uint256 newTotalDebt = currentDebt + amount;
        uint256 maxBorrow = _getMaxBorrow(positionId, marketAddr);
        require(newTotalDebt <= maxBorrow, "EXCEEDS_MAX_LTV");

        // RiskManager: validate caps (all in 18-dec USD)
        if (address(riskManager) != address(0)) {
            uint256 positionValue = positionManager.getPositionValue(positionId);
            IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();
            uint256 amountUsd = _toUsd(amount, config.borrowAsset);
            (bool valid, string memory reason) = riskManager.validateBorrow(amountUsd, positionValue, pos.lpType);
            require(valid, reason);
            riskManager.recordBorrow(amountUsd, pos.lpType);
        }

        uint256 currentBorrowIndex = market.borrowIndex();
        require(currentBorrowIndex > 0, "MARKET_NOT_INITIALIZED");
        debtInfo[positionId] = DebtInfo({principal: newTotalDebt, borrowIndex: currentBorrowIndex});

        positionManager.updateDebt(positionId, newTotalDebt);

        market.transferOut(msg.sender, amount);

        emit Borrowed(positionId, msg.sender, amount, newTotalDebt);
    }

    /// @inheritdoc ILendingEngine
    function repay(uint256 positionId, uint256 amount) external whenNotPaused nonReentrant {
        _repayInternal(positionId, amount, msg.sender);
    }

    /// @notice Repay debt on behalf of a borrower (used by LiquidationEngine)
    function repayOnBehalf(uint256 positionId, uint256 repayAmount) external whenNotPaused nonReentrant {
        require(_acl().isLiquidationEngine(msg.sender), "NOT_LIQUIDATION_ENGINE");
        _repayInternal(positionId, repayAmount, msg.sender);
    }

    // --- View ---

    /// @inheritdoc ILendingEngine
    function getDebt(uint256 positionId) external view returns (uint256) {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        address marketAddr = _getMarketAddr(pos.marketId);
        return _getCurrentDebt(positionId, Market(marketAddr));
    }

    /// @inheritdoc ILendingEngine
    function getMaxBorrow(uint256 positionId) external view returns (uint256) {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        address marketAddr = _getMarketAddr(pos.marketId);
        return _getMaxBorrow(positionId, marketAddr);
    }

    /// @inheritdoc ILendingEngine
    function accrueInterest(uint256 marketId) public {
        address marketAddr = _getMarketAddr(marketId);
        Market(marketAddr).accrueInterest();
    }

    // --- Internal ---

    function _repayInternal(uint256 positionId, uint256 amount, address payer) internal {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);

        address marketAddr = _getMarketAddr(pos.marketId);
        Market market = Market(marketAddr);
        market.accrueInterest();

        uint256 currentDebt = _getCurrentDebt(positionId, market);
        require(currentDebt > 0, "NO_DEBT");

        uint256 repayAmount = amount == type(uint256).max ? currentDebt : amount;
        require(repayAmount > 0, "ZERO_AMOUNT");
        require(repayAmount <= currentDebt, "REPAY_EXCEEDS_DEBT");

        uint256 remainingDebt = currentDebt - repayAmount;

        debtInfo[positionId] = DebtInfo({principal: remainingDebt, borrowIndex: market.borrowIndex()});

        positionManager.updateDebt(positionId, remainingDebt);

        market.transferIn(payer, repayAmount);

        // RiskManager: track repayment (18-dec USD)
        if (address(riskManager) != address(0)) {
            IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();
            uint256 repayUsd = _toUsd(repayAmount, config.borrowAsset);
            riskManager.recordRepay(repayUsd, pos.lpType);
        }

        emit Repaid(positionId, payer, repayAmount, remainingDebt);
    }

    function _getCurrentDebt(uint256 positionId, Market market) internal view returns (uint256) {
        DebtInfo memory info = debtInfo[positionId];
        if (info.principal == 0) return 0;

        uint256 currentIndex = market.borrowIndex();
        require(currentIndex > 0 && info.borrowIndex > 0, "INDEX_ZERO");

        return (info.principal * currentIndex) / info.borrowIndex;
    }

    /// @notice Calculate max borrow in borrow asset decimals
    function _getMaxBorrow(uint256 positionId, address marketAddr) internal view returns (uint256) {
        uint256 collateralValue = positionManager.getPositionValue(positionId);
        IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();
        uint256 maxBorrowUsd = (collateralValue * config.maxLtv) / 10_000;

        uint8 borrowDecimals = IERC20(config.borrowAsset).decimals();
        require(borrowDecimals <= 36, "INVALID_DECIMALS");

        PriceFeedRegistry registry = positionManager.priceFeedRegistry();
        if (address(registry) != address(0)) {
            uint256 borrowAssetPrice = registry.getPrice(config.borrowAsset);
            require(borrowAssetPrice > 0, "ZERO_PRICE");
            return Math.mulDiv(maxBorrowUsd, 10 ** borrowDecimals, borrowAssetPrice);
        }
        if (borrowDecimals < 18) {
            return maxBorrowUsd / (10 ** (18 - borrowDecimals));
        } else if (borrowDecimals > 18) {
            return Math.mulDiv(maxBorrowUsd, 10 ** (borrowDecimals - 18), 1);
        }
        return maxBorrowUsd;
    }

    /// @notice Convert borrow asset amount to 18-dec USD
    function _toUsd(uint256 amount, address borrowAsset) internal view returns (uint256) {
        uint8 dec = IERC20(borrowAsset).decimals();
        PriceFeedRegistry registry = positionManager.priceFeedRegistry();
        if (address(registry) != address(0)) {
            return registry.getUsdValue(borrowAsset, amount, dec);
        }
        // Fallback: normalize to 18 dec (assumes USD-pegged)
        if (dec < 18) return Math.mulDiv(amount, 10 ** (18 - dec), 1);
        if (dec > 18) return amount / (10 ** (dec - 18));
        return amount;
    }

    function _getMarketAddr(uint256 marketId) internal view returns (address) {
        address marketAddr = core.markets(marketId);
        require(marketAddr != address(0), "MARKET_NOT_FOUND");
        return marketAddr;
    }

    // --- Storage Gap ---
    // Reduced from 50 to 49 after adding riskManager.
    uint256[49] private __gap;
}
