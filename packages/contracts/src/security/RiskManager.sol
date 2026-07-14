// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title RiskManager
/// @notice Enforces risk limits: position caps, borrow caps, supply caps
/// @dev Pure risk limits only — no LTV, no cooldown (those live in LendingEngine).
///      All amounts passed in 18-dec USD. Callers convert before calling.
///      Uses ACLManager: LENDING_ENGINE calls record*, RISK_ADMIN adjusts caps.
contract RiskManager {
    ProtocolCore public immutable core;

    // --- Position Limits ---
    uint256 public maxPositionsPerUser = 20;
    uint256 public maxPositionValue = 10_000_000e18; // $10M max single position

    // --- Borrow Caps (all in 18-dec USD) ---
    uint256 public globalBorrowCap = 100_000_000e18; // $100M total borrows
    uint256 public currentGlobalBorrows;
    mapping(ILPAdapter.LPType => uint256) public lpTypeBorrowCap;
    mapping(ILPAdapter.LPType => uint256) public lpTypeCurrentBorrows;

    // --- Supply Caps (per-market collateral cap, 18-dec USD) ---
    mapping(uint256 => uint256) public marketSupplyCap; // marketId → max collateral value
    mapping(uint256 => uint256) public marketCurrentSupply; // marketId → current collateral value

    // --- Events ---
    event GlobalBorrowCapUpdated(uint256 oldValue, uint256 newValue);
    event LPTypeBorrowCapUpdated(ILPAdapter.LPType indexed lpType, uint256 cap);
    event MaxPositionValueUpdated(uint256 oldValue, uint256 newValue);
    event MaxPositionsPerUserUpdated(uint256 oldValue, uint256 newValue);
    event MarketSupplyCapUpdated(uint256 indexed marketId, uint256 oldValue, uint256 newValue);
    event BorrowTrackingDrift(uint256 tracked, uint256 repaid, bool isGlobal);
    event BorrowRecorded(uint256 amountUsd, uint256 newGlobalBorrows);
    event RepayRecorded(uint256 amountUsd, uint256 newGlobalBorrows);
    event DepositRecorded(uint256 valueUsd, uint256 indexed marketId, uint256 newMarketSupply);
    event WithdrawRecorded(uint256 valueUsd, uint256 indexed marketId, uint256 newMarketSupply);

    // --- ACL ---
    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyRiskAdmin() {
        ACLManager acl = _acl();
        require(acl.isRiskAdmin(msg.sender) || acl.isPoolAdmin(msg.sender), "NOT_RISK_ADMIN");
        _;
    }

    modifier onlyLendingEngine() {
        require(_acl().isLendingEngine(msg.sender), "NOT_LENDING_ENGINE");
        _;
    }

    modifier onlyPositionManager() {
        require(_acl().isPositionManager(msg.sender), "NOT_POSITION_MANAGER");
        _;
    }

    constructor(address _core) {
        require(_core != address(0), "ZERO_ADDRESS");
        core = ProtocolCore(_core);
    }

    // --- Borrow Validation (called by LendingEngine) ---

    /// @notice Validate a borrow request against risk caps
    /// @param borrowAmountUsd Borrow amount in 18-dec USD
    /// @param positionValue Position value in 18-dec USD
    /// @param lpType LP type for per-type cap check
    /// @notice Validate borrow caps AND atomically record the borrow.
    ///         Prevents TOCTOU: two borrows in the same block cannot both pass
    ///         validation before either records, since validation + recording is atomic.
    function validateAndRecordBorrow(
        uint256 borrowAmountUsd,
        uint256 positionValue,
        ILPAdapter.LPType lpType
    )
        external
        onlyLendingEngine
        returns (bool valid, string memory reason)
    {
        // Check 1: Position value cap
        if (positionValue > maxPositionValue) {
            return (false, "POSITION_TOO_LARGE");
        }

        // Check 2: Global borrow cap
        if (currentGlobalBorrows + borrowAmountUsd > globalBorrowCap) {
            return (false, "GLOBAL_CAP_REACHED");
        }

        // Check 3: LP type borrow cap
        uint256 typeCap = lpTypeBorrowCap[lpType];
        if (typeCap > 0 && lpTypeCurrentBorrows[lpType] + borrowAmountUsd > typeCap) {
            return (false, "LP_TYPE_CAP_REACHED");
        }

        // Atomically record the borrow (no gap between validate and record)
        currentGlobalBorrows += borrowAmountUsd;
        lpTypeCurrentBorrows[lpType] += borrowAmountUsd;
        emit BorrowRecorded(borrowAmountUsd, currentGlobalBorrows);

        return (true, "");
    }

    /// @notice Record a repayment for cap tracking (18-dec USD)
    /// @dev Clamped to prevent underflow when repay includes accrued interest
    function recordRepay(uint256 amountUsd, ILPAdapter.LPType lpType) external onlyLendingEngine {
        if (amountUsd > currentGlobalBorrows) {
            emit BorrowTrackingDrift(currentGlobalBorrows, amountUsd, true);
            currentGlobalBorrows = 0;
        } else {
            currentGlobalBorrows -= amountUsd;
        }
        if (amountUsd > lpTypeCurrentBorrows[lpType]) {
            emit BorrowTrackingDrift(lpTypeCurrentBorrows[lpType], amountUsd, false);
            lpTypeCurrentBorrows[lpType] = 0;
        } else {
            lpTypeCurrentBorrows[lpType] -= amountUsd;
        }
        emit RepayRecorded(amountUsd, currentGlobalBorrows);
    }

    // --- Deposit Validation (called by PositionManager) ---

    /// @notice Validate a deposit against risk limits
    /// @param depositor User address
    /// @param positionValue Position value in 18-dec USD
    /// @param marketId Market ID for supply cap
    /// @param userPositionCount Current number of positions the user has
    function validateDeposit(
        address depositor,
        uint256 positionValue,
        uint256 marketId,
        uint256 userPositionCount
    )
        external
        view
        returns (bool valid, string memory reason)
    {
        // Check 1: Max positions per user
        if (userPositionCount >= maxPositionsPerUser) {
            return (false, "MAX_POSITIONS_REACHED");
        }

        // Check 2: Position value cap
        if (positionValue > maxPositionValue) {
            return (false, "POSITION_TOO_LARGE");
        }

        // Check 3: Market supply cap
        uint256 cap = marketSupplyCap[marketId];
        if (cap > 0 && marketCurrentSupply[marketId] + positionValue > cap) {
            return (false, "SUPPLY_CAP_REACHED");
        }

        return (true, "");
    }

    /// @notice Record a deposit for supply cap tracking (18-dec USD)
    function recordDeposit(uint256 valueUsd, uint256 marketId) external onlyPositionManager {
        marketCurrentSupply[marketId] += valueUsd;
        emit DepositRecorded(valueUsd, marketId, marketCurrentSupply[marketId]);
    }

    /// @notice Record a withdrawal for supply cap tracking (18-dec USD)
    function recordWithdraw(uint256 valueUsd, uint256 marketId) external onlyPositionManager {
        marketCurrentSupply[marketId] =
            valueUsd > marketCurrentSupply[marketId] ? 0 : marketCurrentSupply[marketId] - valueUsd;
        emit WithdrawRecorded(valueUsd, marketId, marketCurrentSupply[marketId]);
    }

    // --- Admin (RISK_ADMIN) ---

    function setGlobalBorrowCap(uint256 cap) external onlyRiskAdmin {
        require(cap > 0, "ZERO_CAP");
        emit GlobalBorrowCapUpdated(globalBorrowCap, cap);
        globalBorrowCap = cap;
    }

    function setLPTypeBorrowCap(ILPAdapter.LPType lpType, uint256 cap) external onlyRiskAdmin {
        emit LPTypeBorrowCapUpdated(lpType, cap);
        lpTypeBorrowCap[lpType] = cap;
    }

    function setMaxPositionValue(uint256 maxValue) external onlyRiskAdmin {
        require(maxValue > 0, "ZERO_VALUE");
        emit MaxPositionValueUpdated(maxPositionValue, maxValue);
        maxPositionValue = maxValue;
    }

    function setMaxPositionsPerUser(uint256 max) external onlyRiskAdmin {
        require(max >= 1, "AT_LEAST_ONE");
        emit MaxPositionsPerUserUpdated(maxPositionsPerUser, max);
        maxPositionsPerUser = max;
    }

    function setMarketSupplyCap(uint256 marketId, uint256 cap) external onlyRiskAdmin {
        emit MarketSupplyCapUpdated(marketId, marketSupplyCap[marketId], cap);
        marketSupplyCap[marketId] = cap;
    }
}
