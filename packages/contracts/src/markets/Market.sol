// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {InterestRateModel} from "./InterestRateModel.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title Market
/// @notice Isolated lending market — single source of truth for interest accrual
/// @dev UUPS upgradeable. Uses ProtocolCore for ownership (DAO controls admin ops).
///      LendingEngine address is updatable so Market isn't bricked if LE is redeployed.
contract Market is IMarket, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    MarketConfig public config;
    MarketState public state;
    InterestRateModel public interestRateModel;

    mapping(address => uint256) public shares;
    uint256 public totalShares;

    /// @notice Reference to ProtocolCore for ownership/admin checks
    ProtocolCore public core;

    /// @notice Authorized address for lending operations (transferOut/transferIn)
    /// @dev Set to LendingEngine proxy address. Updatable by owner if LE is redeployed.
    address public lendingEngine;

    /// @notice Cumulative borrow interest index (RAY = 1e27 precision)
    uint256 public borrowIndex;

    /// @notice Protocol fee passed to IRM for supply rate calc (bps). Default 30 = 0.3%
    uint256 public protocolFeeBps = 30;

    uint256 internal constant RAY = 1e27;

    uint256 public constant DEAD_SHARES = 1000;
    address internal constant DEAD_ADDRESS = address(0xdead);

    event InterestRateModelUpdated(address oldModel, address newModel);
    event MarketConfigUpdated(string field, uint256 oldValue, uint256 newValue);
    event InterestAccrued(uint256 interestAmount, uint256 newBorrowIndex, uint256 timestamp);
    event LendingEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event ProtocolFeeUpdated(uint256 oldValue, uint256 newValue);

    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
        _;
    }

    modifier onlyLendingEngine() {
        require(msg.sender == lendingEngine, "NOT_LENDING_ENGINE");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        MarketConfig memory _config,
        address _interestRateModel,
        address _core,
        address _lendingEngine
    )
        external
        initializer
    {
        require(_core != address(0), "ZERO_CORE");
        require(_interestRateModel != address(0), "ZERO_IRM");
        config = _config;
        interestRateModel = InterestRateModel(_interestRateModel);
        core = ProtocolCore(_core);
        lendingEngine = _lendingEngine;
        state.lastAccrualTimestamp = block.timestamp;
        borrowIndex = RAY;
        protocolFeeBps = 30; // 0.3% default
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // --- Admin (DAO via ProtocolCore.owner()) ---

    /// @notice Set the LendingEngine address (updatable if LE is redeployed)
    function setLendingEngine(address _lendingEngine) external onlyOwner {
        require(_lendingEngine != address(0), "ZERO_ADDRESS");
        emit LendingEngineUpdated(lendingEngine, _lendingEngine);
        lendingEngine = _lendingEngine;
    }

    function setProtocolFee(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 5000, "FEE_TOO_HIGH"); // Max 50%
        emit ProtocolFeeUpdated(protocolFeeBps, _feeBps);
        protocolFeeBps = _feeBps;
    }

    function setInterestRateModel(address _newModel) external onlyOwner {
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
        onlyOwner
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

        state.totalBorrow += interestAccrued;
        state.totalSupply += interestAccrued;
        state.lastAccrualTimestamp = block.timestamp;

        // borrowRatePerSecond is 1e18 scale, borrowIndex is RAY (1e27) scale
        // Must scale rate to RAY before adding: rate * elapsed * 1e9 (= * RAY / 1e18)
        uint256 interestFactor = RAY + ((borrowRatePerSecond * elapsed * RAY) / 1e18);
        borrowIndex = (borrowIndex * interestFactor) / RAY;

        _updateRates();

        emit InterestAccrued(interestAccrued, borrowIndex, block.timestamp);
    }

    // --- Lender Operations ---

    /// @inheritdoc IMarket
    function supply(uint256 amount) external nonReentrant returns (uint256 sharesToMint) {
        require(amount > 0, "ZERO_AMOUNT");
        accrueInterest();

        require(IERC20(config.borrowAsset).transferFrom(msg.sender, address(this), amount), "SUPPLY_TRANSFER_FAILED");

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

        uint256 availableLiquidity = state.totalSupply - state.totalBorrow;
        require(amount <= availableLiquidity, "INSUFFICIENT_LIQUIDITY");

        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        state.totalSupply -= amount;

        require(IERC20(config.borrowAsset).transfer(msg.sender, amount), "WITHDRAW_TRANSFER_FAILED");

        emit Withdraw(msg.sender, amount, sharesToBurn);
    }

    // --- LendingEngine Operations ---

    function transferOut(address to, uint256 amount) external onlyLendingEngine {
        require(to != address(0), "ZERO_RECIPIENT");
        uint256 available = state.totalSupply - state.totalBorrow;
        require(amount <= available, "INSUFFICIENT_LIQUIDITY");

        // Enforce borrow cap (MKT-6)
        if (config.borrowCap > 0) {
            require(state.totalBorrow + amount <= config.borrowCap, "BORROW_CAP_EXCEEDED");
        }

        state.totalBorrow += amount;
        _updateRates();

        require(IERC20(config.borrowAsset).transfer(to, amount), "TRANSFER_OUT_FAILED");
    }

    function transferIn(address from, uint256 amount) external onlyLendingEngine {
        require(from != address(0), "ZERO_SENDER");
        require(amount <= state.totalBorrow, "REPAY_EXCEEDS_BORROW");

        state.totalBorrow -= amount;
        _updateRates();

        require(IERC20(config.borrowAsset).transferFrom(from, address(this), amount), "TRANSFER_IN_FAILED");
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
        state.supplyRate = interestRateModel.getSupplyRate(state.utilization, protocolFeeBps);
    }

    // --- Storage Gap (UUPS upgrade safety) ---
    uint256[50] private __gap;
}
