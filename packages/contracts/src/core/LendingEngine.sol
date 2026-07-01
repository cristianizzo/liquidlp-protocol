// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ILendingEngine} from "../interfaces/ILendingEngine.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {ProtocolCore} from "./ProtocolCore.sol";
import {PositionManager} from "./PositionManager.sol";
import {Market} from "../markets/Market.sol";

/// @title LendingEngine
/// @notice Handles borrowing against LP positions and repayment with interest
/// @dev UUPS upgradeable + reentrancy protected.
///      Interest accrual is delegated to Market (single source of truth).
///      LendingEngine reads Market.borrowIndex() for per-position debt calculation.
///      No duplicate interest tracking — eliminates LE-2 divergence bug.
contract LendingEngine is ILendingEngine, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    ProtocolCore public core;
    PositionManager public positionManager;

    struct DebtInfo {
        uint256 principal; // Current debt (rebased at each interaction)
        uint256 borrowIndex; // Market's borrowIndex snapshot at last update
    }

    mapping(uint256 => DebtInfo) public debtInfo;

    /// @notice Blocks after deposit before borrowing is allowed (flash loan defense)
    uint256 public borrowCooldownBlocks = 1;
    uint256 public constant MIN_COOLDOWN = 1;
    uint256 public constant MAX_COOLDOWN = 50;

    event BorrowCooldownUpdated(uint256 oldValue, uint256 newValue);

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

    function initialize(address _core, address _positionManager) external initializer {
        require(_core != address(0) && _positionManager != address(0), "ZERO_ADDRESS");
        core = ProtocolCore(_core);
        positionManager = PositionManager(_positionManager);
        borrowCooldownBlocks = 1;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Set borrow cooldown (blocks after deposit before borrowing allowed)
    function setBorrowCooldown(uint256 _blocks) external onlyOwner {
        require(_blocks >= MIN_COOLDOWN && _blocks <= MAX_COOLDOWN, "OUT_OF_BOUNDS");
        emit BorrowCooldownUpdated(borrowCooldownBlocks, _blocks);
        borrowCooldownBlocks = _blocks;
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

        // Borrow cooldown: prevent same-block deposit+borrow (flash loan defense)
        require(block.number > pos.depositBlock + borrowCooldownBlocks, "BORROW_COOLDOWN");

        // Accrue interest in Market (single source of truth)
        address marketAddr = core.markets(pos.marketId);
        Market market = Market(marketAddr);
        market.accrueInterest();

        // Check borrow doesn't exceed max LTV
        uint256 currentDebt = _getCurrentDebt(positionId, market);
        uint256 newTotalDebt = currentDebt + amount;
        uint256 maxBorrow = _getMaxBorrow(positionId, marketAddr);
        require(newTotalDebt <= maxBorrow, "EXCEEDS_MAX_LTV");

        // Check market borrow cap (LE-3)
        IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();
        IMarket.MarketState memory mState = IMarket(marketAddr).getMarketState();
        if (config.borrowCap > 0) {
            require(mState.totalBorrow + amount <= config.borrowCap, "BORROW_CAP_EXCEEDED");
        }

        // Update debt tracking — snapshot Market's current borrowIndex
        uint256 currentBorrowIndex = market.borrowIndex();
        require(currentBorrowIndex > 0, "MARKET_NOT_INITIALIZED");
        debtInfo[positionId] = DebtInfo({principal: newTotalDebt, borrowIndex: currentBorrowIndex});

        // Update position manager status
        positionManager.updateDebt(positionId, newTotalDebt);

        // Market transfers borrow asset to borrower
        market.transferOut(msg.sender, amount);

        emit Borrowed(positionId, msg.sender, amount, newTotalDebt);
    }

    /// @inheritdoc ILendingEngine
    function repay(uint256 positionId, uint256 amount) external whenNotPaused nonReentrant {
        _repayInternal(positionId, amount, msg.sender);
    }

    /// @notice Repay debt on behalf of a borrower (used by LiquidationEngine)
    /// @dev Payer must be msg.sender itself — prevents draining arbitrary approved addresses.
    ///      The calling contract (e.g., LiquidationEngine) must hold the tokens and be the payer.
    function repayOnBehalf(uint256 positionId, uint256 repayAmount) external whenNotPaused nonReentrant {
        require(positionManager.authorized(msg.sender), "NOT_AUTHORIZED");
        _repayInternal(positionId, repayAmount, msg.sender);
    }

    // --- View ---

    /// @inheritdoc ILendingEngine
    function getDebt(uint256 positionId) external view returns (uint256) {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        address marketAddr = core.markets(pos.marketId);
        return _getCurrentDebt(positionId, Market(marketAddr));
    }

    /// @inheritdoc ILendingEngine
    function getMaxBorrow(uint256 positionId) external view returns (uint256) {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        address marketAddr = core.markets(pos.marketId);
        return _getMaxBorrow(positionId, marketAddr);
    }

    /// @inheritdoc ILendingEngine
    function accrueInterest(uint256 marketId) public {
        address marketAddr = core.markets(marketId);
        Market(marketAddr).accrueInterest();
    }

    // --- Internal ---

    function _repayInternal(uint256 positionId, uint256 amount, address payer) internal {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);

        // Accrue interest in Market
        address marketAddr = core.markets(pos.marketId);
        Market market = Market(marketAddr);
        market.accrueInterest();

        uint256 currentDebt = _getCurrentDebt(positionId, market);
        require(currentDebt > 0, "NO_DEBT");

        uint256 repayAmount = amount == type(uint256).max ? currentDebt : amount;
        require(repayAmount > 0, "ZERO_AMOUNT");
        require(repayAmount <= currentDebt, "REPAY_EXCEEDS_DEBT");

        uint256 remainingDebt = currentDebt - repayAmount;

        // Update debt tracking with current Market borrowIndex
        debtInfo[positionId] = DebtInfo({principal: remainingDebt, borrowIndex: market.borrowIndex()});

        // Update position manager status
        positionManager.updateDebt(positionId, remainingDebt);

        // Market pulls borrow asset from payer
        market.transferIn(payer, repayAmount);

        emit Repaid(positionId, payer, repayAmount, remainingDebt);
    }

    /// @notice Calculate current debt including accrued interest
    /// @dev debt = principal * (currentBorrowIndex / positionBorrowIndex)
    ///      Uses Market.borrowIndex() as the single source of truth
    function _getCurrentDebt(uint256 positionId, Market market) internal view returns (uint256) {
        DebtInfo memory info = debtInfo[positionId];
        if (info.principal == 0) return 0;

        uint256 currentIndex = market.borrowIndex();
        if (currentIndex == 0 || info.borrowIndex == 0) return info.principal;

        return (info.principal * currentIndex) / info.borrowIndex;
    }

    function _getMaxBorrow(uint256 positionId, address marketAddr) internal view returns (uint256) {
        uint256 collateralValue = positionManager.getPositionValue(positionId);
        IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();
        return (collateralValue * config.maxLtv) / 10_000;
    }

    // --- Storage Gap (UUPS upgrade safety) ---
    uint256[50] private __gap;
}
