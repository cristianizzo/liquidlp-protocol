// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title RiskManager
/// @notice Enforces risk parameters: LTV limits, position caps, borrow caps
contract RiskManager {
    ProtocolCore public immutable core;

    // Global limits
    uint256 public maxPositionsPerUser = 20;
    uint256 public maxPositionValue = 10_000_000e18; // $10M max single position
    uint256 public globalBorrowCap = 100_000_000e18; // $100M total borrows
    uint256 public currentGlobalBorrows;

    // Per-LP-type limits
    mapping(ILPAdapter.LPType => uint256) public lpTypeBorrowCap;
    mapping(ILPAdapter.LPType => uint256) public lpTypeCurrentBorrows;

    // Borrow cooldown (prevent same-block deposit+borrow oracle manipulation)
    uint256 public borrowCooldown = 1; // 1 block after deposit
    uint256 public constant MIN_BORROW_COOLDOWN = 1; // At least 1 block
    uint256 public constant MAX_BORROW_COOLDOWN = 50; // Max 50 blocks (~10 min on ETH)

    event BorrowCooldownUpdated(uint256 oldValue, uint256 newValue);

    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
        _;
    }

    modifier onlyAuthorized() {
        require(msg.sender == core.owner() || core.keepers(msg.sender), "NOT_AUTHORIZED");
        _;
    }

    constructor(address _core) {
        core = ProtocolCore(_core);
    }

    /// @notice Validate a borrow request against all risk parameters
    function validateBorrow(
        address borrower,
        uint256 borrowAmount,
        uint256 positionValue,
        uint256 depositBlock,
        uint256 currentDebt,
        uint256 maxLtv,
        ILPAdapter.LPType lpType
    ) external view returns (bool valid, string memory reason) {
        // Check 1: Borrow cooldown
        if (block.number <= depositBlock + borrowCooldown) {
            return (false, "BORROW_COOLDOWN");
        }

        // Check 2: LTV check
        uint256 newDebt = currentDebt + borrowAmount;
        uint256 maxBorrow = (positionValue * maxLtv) / 10_000;
        if (newDebt > maxBorrow) {
            return (false, "EXCEEDS_LTV");
        }

        // Check 3: Position value cap
        if (positionValue > maxPositionValue) {
            return (false, "POSITION_TOO_LARGE");
        }

        // Check 4: Global borrow cap
        if (currentGlobalBorrows + borrowAmount > globalBorrowCap) {
            return (false, "GLOBAL_CAP_REACHED");
        }

        // Check 5: LP type borrow cap
        uint256 typeCap = lpTypeBorrowCap[lpType];
        if (typeCap > 0 && lpTypeCurrentBorrows[lpType] + borrowAmount > typeCap) {
            return (false, "LP_TYPE_CAP_REACHED");
        }

        return (true, "");
    }

    /// @notice Record a borrow for cap tracking
    function recordBorrow(uint256 amount, ILPAdapter.LPType lpType) external onlyAuthorized {
        currentGlobalBorrows += amount;
        lpTypeCurrentBorrows[lpType] += amount;
    }

    /// @notice Record a repayment for cap tracking
    function recordRepay(uint256 amount, ILPAdapter.LPType lpType) external onlyAuthorized {
        currentGlobalBorrows -= amount;
        lpTypeCurrentBorrows[lpType] -= amount;
    }

    // --- Admin ---

    event GlobalBorrowCapUpdated(uint256 oldValue, uint256 newValue);
    event LPTypeBorrowCapUpdated(ILPAdapter.LPType lpType, uint256 cap);
    event MaxPositionValueUpdated(uint256 oldValue, uint256 newValue);
    event MaxPositionsPerUserUpdated(uint256 oldValue, uint256 newValue);

    function setGlobalBorrowCap(uint256 cap) external onlyOwner {
        emit GlobalBorrowCapUpdated(globalBorrowCap, cap);
        globalBorrowCap = cap;
    }

    function setLPTypeBorrowCap(ILPAdapter.LPType lpType, uint256 cap) external onlyOwner {
        lpTypeBorrowCap[lpType] = cap;
        emit LPTypeBorrowCapUpdated(lpType, cap);
    }

    function setMaxPositionValue(uint256 maxValue) external onlyOwner {
        emit MaxPositionValueUpdated(maxPositionValue, maxValue);
        maxPositionValue = maxValue;
    }

    function setMaxPositionsPerUser(uint256 max) external onlyOwner {
        require(max >= 1, "AT_LEAST_ONE");
        emit MaxPositionsPerUserUpdated(maxPositionsPerUser, max);
        maxPositionsPerUser = max;
    }

    function setBorrowCooldown(uint256 _cooldown) external onlyOwner {
        require(_cooldown >= MIN_BORROW_COOLDOWN, "BELOW_MIN");
        require(_cooldown <= MAX_BORROW_COOLDOWN, "ABOVE_MAX");
        emit BorrowCooldownUpdated(borrowCooldown, _cooldown);
        borrowCooldown = _cooldown;
    }
}
