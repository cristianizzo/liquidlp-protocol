// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {InterestRateModel} from "./InterestRateModel.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";
import {FeeCollector} from "../core/FeeCollector.sol";

/// @title Market
/// @notice Isolated lending market — single source of truth for interest accrual
/// @dev UUPS upgradeable. Uses ProtocolCore for ownership (DAO controls admin ops).
///      LendingEngine address is updatable so Market isn't bricked if LE is redeployed.
contract Market is IMarket, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for OZIERC20;

    MarketConfig public config;
    MarketState public state;
    InterestRateModel public interestRateModel;

    mapping(address => uint256) public shares;
    uint256 public totalShares;

    /// @notice Reference to ProtocolCore for ownership/admin checks
    ProtocolCore public core;

    /// @dev Deprecated — was `lendingEngine` address. Kept for UUPS storage layout compatibility.
    /// LendingEngine auth now checked via ACLManager.isLendingEngine().
    address private __deprecated_lendingEngine;

    /// @notice Cumulative borrow interest index (RAY = 1e27 precision)
    uint256 public borrowIndex;

    /// @dev Deprecated — supply rate now uses reserveFactorBps. Kept for UUPS storage layout.
    uint256 public protocolFeeBps = 30;

    uint256 internal constant RAY = 1e27;

    uint256 public constant DEAD_SHARES = 1000;
    address internal constant DEAD_ADDRESS = address(0xdead);

    event InterestRateModelUpdated(address oldModel, address newModel);
    event MarketConfigUpdated(string field, uint256 oldValue, uint256 newValue);
    event InterestAccrued(uint256 interestAmount, uint256 protocolShare, uint256 newBorrowIndex, uint256 timestamp);
    event ProtocolFeeUpdated(uint256 oldValue, uint256 newValue);
    event ReserveFactorUpdated(uint256 oldValue, uint256 newValue);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event ReservesDistributed(uint256 amount, address indexed feeCollector);

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
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

    modifier onlyLendingEngine() {
        require(_acl().isLendingEngine(msg.sender), "NOT_LENDING_ENGINE");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(MarketConfig memory _config, address _interestRateModel, address _core) external initializer {
        require(_core != address(0), "ZERO_CORE");
        require(_interestRateModel != address(0), "ZERO_IRM");
        config = _config;
        interestRateModel = InterestRateModel(_interestRateModel);
        core = ProtocolCore(_core);
        state.lastAccrualTimestamp = block.timestamp;
        borrowIndex = RAY;
        protocolFeeBps = 30; // 0.3% default
    }

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

    // --- Admin ---

    function setProtocolFee(uint256 _feeBps) external onlyPoolAdmin {
        require(_feeBps <= 5000, "FEE_TOO_HIGH"); // Max 50%
        emit ProtocolFeeUpdated(protocolFeeBps, _feeBps);
        protocolFeeBps = _feeBps;
    }

    function setReserveFactor(uint256 _bps) external onlyRiskAdmin {
        require(_bps <= 5000, "RESERVE_TOO_HIGH"); // Max 50%
        accrueInterest();
        emit ReserveFactorUpdated(reserveFactorBps, _bps);
        reserveFactorBps = _bps;
    }

    function setFeeCollector(address _feeCollector) external onlyPoolAdmin {
        require(_feeCollector != address(0), "ZERO_ADDRESS");
        require(_feeCollector.code.length > 0, "NOT_CONTRACT");
        emit FeeCollectorUpdated(address(feeCollector), _feeCollector);
        feeCollector = FeeCollector(_feeCollector);
    }

    /// @notice Distribute accumulated protocol reserves to FeeCollector
    /// @dev Permissionless — anyone can trigger (keeper, user, DAO).
    ///      At high utilization, reserves may exceed cash (tokens lent out).
    ///      In that case, only available cash is distributed. Remaining reserves
    ///      stay tracked and can be distributed after repayments bring cash back.
    function distributeReserves() external nonReentrant {
        accrueInterest(); // Ensure reserves are up-to-date
        uint256 amount = protocolReserves;
        require(amount > 0, "NO_RESERVES");
        require(address(feeCollector) != address(0), "NO_FEE_COLLECTOR");

        // Ensure we have enough cash (reserves may exceed balance at high utilization)
        uint256 balance = IERC20(config.borrowAsset).balanceOf(address(this));
        if (amount > balance) amount = balance;
        require(amount > 0, "NO_CASH");

        protocolReserves -= amount; // May leave dust if capped by balance

        // Approve FeeCollector to pull, then call depositReserves
        OZIERC20(config.borrowAsset).forceApprove(address(feeCollector), amount);
        feeCollector.depositReserves(config.borrowAsset, amount);

        emit ReservesDistributed(amount, address(feeCollector));
    }

    function setInterestRateModel(address _newModel) external onlyPoolAdmin {
        require(_newModel != address(0), "ZERO_ADDRESS");
        accrueInterest();
        emit InterestRateModelUpdated(address(interestRateModel), _newModel);
        interestRateModel = InterestRateModel(_newModel);
    }

    function updateConfig(
        uint256 _maxLtv,
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus,
        uint256 _haircut,
        uint256 _borrowCap
    )
        external
        onlyRiskAdmin
    {
        require(_maxLtv <= 9500, "LTV_TOO_HIGH");
        require(_liquidationThreshold <= 9800, "THRESHOLD_TOO_HIGH");
        require(_maxLtv < _liquidationThreshold, "LTV_MUST_BE_BELOW_LIQ_THRESHOLD");
        require(_liquidationBonus <= 2000, "BONUS_TOO_HIGH");
        require(_haircut <= 5000, "HAIRCUT_TOO_HIGH");

        if (_maxLtv != config.maxLtv) emit MarketConfigUpdated("maxLtv", config.maxLtv, _maxLtv);
        if (_liquidationThreshold != config.liquidationThreshold) {
            emit MarketConfigUpdated("liquidationThreshold", config.liquidationThreshold, _liquidationThreshold);
        }
        if (_liquidationBonus != config.liquidationBonus) {
            emit MarketConfigUpdated("liquidationBonus", config.liquidationBonus, _liquidationBonus);
        }
        if (_haircut != config.haircut) emit MarketConfigUpdated("haircut", config.haircut, _haircut);
        if (_borrowCap != config.borrowCap) emit MarketConfigUpdated("borrowCap", config.borrowCap, _borrowCap);

        config.maxLtv = _maxLtv;
        config.liquidationThreshold = _liquidationThreshold;
        config.liquidationBonus = _liquidationBonus;
        config.haircut = _haircut;
        config.borrowCap = _borrowCap;
    }

    // --- Interest Accrual (single source of truth) ---

    function accrueInterest() public {
        if (block.timestamp <= state.lastAccrualTimestamp) return;
        if (state.totalBorrow == 0 || state.totalSupply == 0) {
            state.lastAccrualTimestamp = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - state.lastAccrualTimestamp;
        uint256 currentUtilization = (state.totalBorrow * 10_000) / state.totalSupply;
        uint256 borrowRatePerSecond = interestRateModel.getBorrowRate(currentUtilization);

        uint256 interestAccrued = (state.totalBorrow * borrowRatePerSecond * elapsed) / 1e18;

        // Split interest: protocol keeps reserveFactorBps%, lenders get the rest
        uint256 protocolShare = (interestAccrued * reserveFactorBps) / 10_000;
        uint256 lenderShare = interestAccrued - protocolShare;

        state.totalBorrow += interestAccrued; // Borrowers owe full interest
        state.totalSupply += lenderShare; // Lenders earn less than 100%
        protocolReserves += protocolShare; // Protocol's cut stored separately
        state.lastAccrualTimestamp = block.timestamp;

        // borrowRatePerSecond is 1e18 scale, borrowIndex is RAY (1e27) scale
        uint256 interestFactor = RAY + ((borrowRatePerSecond * elapsed * RAY) / 1e18);
        borrowIndex = (borrowIndex * interestFactor) / RAY;

        _updateRates();

        emit InterestAccrued(interestAccrued, protocolShare, borrowIndex, block.timestamp);
    }

    // --- Lender Operations ---

    /// @inheritdoc IMarket
    function supply(uint256 amount) external nonReentrant returns (uint256 sharesToMint) {
        require(amount > 0, "ZERO_AMOUNT");
        accrueInterest();

        OZIERC20(config.borrowAsset).safeTransferFrom(msg.sender, address(this), amount);

        if (totalShares == 0) {
            require(amount > DEAD_SHARES, "BELOW_MINIMUM_DEPOSIT");
            sharesToMint = amount - DEAD_SHARES;

            shares[DEAD_ADDRESS] += DEAD_SHARES;
            totalShares += DEAD_SHARES;
        } else {
            sharesToMint = (amount * totalShares) / state.totalSupply;
            require(sharesToMint > 0, "DEPOSIT_TOO_SMALL");
        }

        shares[msg.sender] += sharesToMint;
        totalShares += sharesToMint;
        state.totalSupply += amount;

        emit Supply(msg.sender, amount, sharesToMint);
    }

    /// @inheritdoc IMarket
    function withdraw(uint256 sharesToBurn) external nonReentrant returns (uint256 amount) {
        accrueInterest();

        require(shares[msg.sender] >= sharesToBurn, "INSUFFICIENT_SHARES");

        amount = (sharesToBurn * state.totalSupply) / totalShares;

        // Available = actual balance minus protocol reserves (which aren't lender funds)
        uint256 balance = IERC20(config.borrowAsset).balanceOf(address(this));
        uint256 availableLiquidity = balance > protocolReserves ? balance - protocolReserves : 0;
        require(amount <= availableLiquidity, "INSUFFICIENT_LIQUIDITY");

        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        state.totalSupply -= amount;

        OZIERC20(config.borrowAsset).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, sharesToBurn);
    }

    // --- LendingEngine Operations ---

    function transferOut(address to, uint256 amount) external onlyLendingEngine {
        require(to != address(0), "ZERO_RECIPIENT");
        uint256 balance = IERC20(config.borrowAsset).balanceOf(address(this));
        uint256 available = balance > protocolReserves ? balance - protocolReserves : 0;
        require(amount <= available, "INSUFFICIENT_LIQUIDITY");

        // Enforce borrow cap (MKT-6)
        if (config.borrowCap > 0) {
            require(state.totalBorrow + amount <= config.borrowCap, "BORROW_CAP_EXCEEDED");
        }

        state.totalBorrow += amount;
        _updateRates();

        OZIERC20(config.borrowAsset).safeTransfer(to, amount);
    }

    function transferIn(address from, uint256 amount) external onlyLendingEngine {
        require(from != address(0), "ZERO_SENDER");
        require(amount <= state.totalBorrow, "REPAY_EXCEEDS_BORROW");

        state.totalBorrow -= amount;
        _updateRates();

        OZIERC20(config.borrowAsset).safeTransferFrom(from, address(this), amount);
    }

    // --- View ---

    /// @inheritdoc IMarket
    function getMarketState() external view returns (MarketState memory) {
        return state;
    }

    /// @inheritdoc IMarket
    function getConfig() external view returns (MarketConfig memory) {
        return config;
    }

    // --- Internal ---

    function _updateRates() internal {
        if (state.totalSupply == 0) {
            state.utilization = 0;
        } else {
            state.utilization = (state.totalBorrow * 10_000) / state.totalSupply;
        }
        state.borrowRate = interestRateModel.getBorrowRate(state.utilization);
        // Supply rate reflects actual protocol cut from interest
        state.supplyRate = interestRateModel.getSupplyRate(state.utilization, reserveFactorBps);
    }

    // --- New state vars (appended for UUPS upgrade safety) ---
    /// @notice Reserve factor: % of interest kept by protocol (bps). Set via setReserveFactor().
    uint256 public reserveFactorBps;
    /// @notice Accumulated protocol reserves (in borrow asset decimals)
    uint256 public protocolReserves;
    /// @notice FeeCollector address for reserve distribution
    FeeCollector public feeCollector;

    // --- Storage Gap ---
    // Reduced from 50 to 47 after adding 3 new state vars.
    uint256[47] private __gap;
}
