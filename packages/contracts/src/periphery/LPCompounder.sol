// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {PositionManager} from "../core/PositionManager.sol";
import {FeeCollector} from "../core/FeeCollector.sol";

/// @title LPCompounder
/// @notice Permissionless auto-compound for Uniswap V3 LP positions
/// @dev Anyone can compound any V3 position. Configurable fee split (default 2%):
///      - compoundFeeBps - callerRewardBps → FeeCollector (protocol revenue)
///      - callerRewardBps → caller (reward for gas)
///      - remainder → reinvested as liquidity
///      V2/Curve positions auto-compound natively — no action needed.
contract LPCompounder {
    using SafeERC20 for IERC20;

    ProtocolCore public immutable core;
    PositionManager public immutable positionManager;
    FeeCollector public immutable feeCollector;

    /// @notice Total fee on compounded fees (basis points). Default 200 = 2%.
    uint256 public compoundFeeBps = 200;
    /// @notice Caller reward portion (basis points). Default 30 = 0.3%.
    uint256 public callerRewardBps = 30;
    uint256 public constant MAX_COMPOUND_FEE = 1000; // 10% max total

    /// @notice Minimum fee per token to justify compounding
    uint256 public minCompoundThreshold = 1000;

    event FeesCompounded(
        uint256 indexed positionId, uint256 fees0, uint256 fees1, uint256 addedLiquidity, address indexed compounder
    );
    event CompoundFeeUpdated(uint256 oldTotal, uint256 newTotal, uint256 oldCaller, uint256 newCaller);
    event MinCompoundThresholdUpdated(uint256 oldValue, uint256 newValue);
    event TokensSwept(address indexed token, address indexed to, uint256 amount);

    constructor(address _core, address _positionManager, address _feeCollector) {
        require(_core != address(0) && _positionManager != address(0) && _feeCollector != address(0), "ZERO_ADDRESS");
        core = ProtocolCore(_core);
        positionManager = PositionManager(_positionManager);
        feeCollector = FeeCollector(_feeCollector);
    }

    /// @notice Compound fees for a V3 position — permissionless
    /// @param positionId The position to compound
    /// @param rewardRecipient Where to send the 0.1% caller reward
    function compoundPosition(uint256 positionId, address rewardRecipient) public {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);

        // Only UniswapV3 positions (stub adapters revert, so only check real V3)
        require(pos.lpType == ILPAdapter.LPType.UniswapV3, "NOT_V3_POSITION");

        // Calculate fee split
        uint256 protocolFeeBps = compoundFeeBps > callerRewardBps ? compoundFeeBps - callerRewardBps : 0;

        // Compound via PositionManager (which has adapter access)
        (uint256 fees0, uint256 fees1, uint256 addedLiquidity) = positionManager.compoundFees(
            positionId, address(feeCollector), protocolFeeBps, rewardRecipient, callerRewardBps, pos.owner
        );

        // Skip if no fees collected (no revert — graceful for batch)
        if (fees0 == 0 && fees1 == 0) return;

        // Check threshold after collection
        require(fees0 >= minCompoundThreshold || fees1 >= minCompoundThreshold, "BELOW_THRESHOLD");

        emit FeesCompounded(positionId, fees0, fees1, addedLiquidity, rewardRecipient);
    }

    /// @notice Compound a single position (convenience — reward goes to msg.sender)
    function compoundPosition(uint256 positionId) external {
        compoundPosition(positionId, msg.sender);
    }

    /// @notice Batch compound multiple positions — reward goes to msg.sender
    /// @dev Failures silently skipped — one bad position doesn't block others.
    function batchCompound(uint256[] calldata positionIds) external {
        for (uint256 i = 0; i < positionIds.length; i++) {
            try this.compoundPosition(positionIds[i], msg.sender) {} catch {}
        }
    }

    // --- Admin ---

    /// @notice Set compound fee split (total and caller portion)
    function setCompoundFee(uint256 _totalBps, uint256 _callerBps) external {
        require(
            core.aclManager().isRiskAdmin(msg.sender) || core.aclManager().isPoolAdmin(msg.sender), "NOT_AUTHORIZED"
        );
        require(_totalBps <= MAX_COMPOUND_FEE, "FEE_TOO_HIGH");
        require(_callerBps <= _totalBps, "CALLER_EXCEEDS_TOTAL");
        emit CompoundFeeUpdated(compoundFeeBps, _totalBps, callerRewardBps, _callerBps);
        compoundFeeBps = _totalBps;
        callerRewardBps = _callerBps;
    }

    /// @notice Set minimum fee threshold
    function setMinCompoundThreshold(uint256 _threshold) external {
        require(
            core.aclManager().isRiskAdmin(msg.sender) || core.aclManager().isPoolAdmin(msg.sender), "NOT_AUTHORIZED"
        );
        emit MinCompoundThresholdUpdated(minCompoundThreshold, _threshold);
        minCompoundThreshold = _threshold;
    }

    /// @notice Sweep stuck tokens
    function sweepTokens(address token, address to, uint256 amount) external {
        require(core.aclManager().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        require(token != address(0) && to != address(0), "ZERO_ADDRESS");
        require(amount > 0, "ZERO_AMOUNT");
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 sweepAmount = amount > balance ? balance : amount;
        require(sweepAmount > 0, "NO_BALANCE");
        IERC20(token).safeTransfer(to, sweepAmount);
        emit TokensSwept(token, to, sweepAmount);
    }
}
