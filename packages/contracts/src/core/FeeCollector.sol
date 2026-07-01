// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "./ProtocolCore.sol";

/// @title FeeCollector
/// @notice Collects and distributes protocol fees using Aave-style reserve factor model
/// @dev Revenue sources:
///   1. Reserve factor: % of borrow interest kept by protocol (per LP type)
///   2. Liquidation fee: % of liquidation penalty goes to protocol
///   3. Management fee: small annual fee on deposited LP collateral
///
/// Fee flow:
///   LendingEngine/LiquidationEngine → collectFee(token, amount, from) → pulls tokens into FeeCollector
///   Keeper/DAO → distribute(token) → splits to treasury + insurance fund
contract FeeCollector {
    ProtocolCore public immutable core;

    // --- Reserve Factor (Aave-style, per LP type) ---
    mapping(ILPAdapter.LPType => uint256) public reserveFactorBps;
    uint256 public defaultReserveFactorBps = 2000; // 20%

    // --- Other Fee Rates ---
    uint256 public liquidationFeeBps = 1000; // 10% of liquidation penalty
    uint256 public managementFeeBps = 10; // 0.1% annual on collateral value

    // --- Absolute Bounds ---
    uint256 public constant MIN_RESERVE_FACTOR = 500; // 5%
    uint256 public constant MAX_RESERVE_FACTOR = 5000; // 50%
    uint256 public constant MAX_LIQUIDATION_FEE = 2000; // 20%
    uint256 public constant MAX_MANAGEMENT_FEE = 100; // 1%
    uint256 public constant MAX_INSURANCE_SHARE = 5000; // 50%

    // --- Fee Recipients ---
    address public treasury;
    address public insuranceFund;
    uint256 public insuranceFundShareBps = 1000; // 10%

    // --- Accumulated Fees ---
    mapping(address => uint256) public accumulatedFees; // token → amount

    // --- Authorized Callers ---
    /// @notice Protocol contracts authorized to call collectFee (LiquidationEngine, LendingEngine, etc.)
    mapping(address => bool) public authorizedCallers;

    // --- State ---
    bool private _distributing;

    // --- Events ---
    event FeesCollected(address indexed token, uint256 amount, address indexed from, string feeType);
    event FeesDistributed(address indexed token, uint256 toTreasury, uint256 toInsurance);
    event ReserveFactorUpdated(ILPAdapter.LPType indexed lpType, uint256 oldValue, uint256 newValue);
    event DefaultReserveFactorUpdated(uint256 oldValue, uint256 newValue);
    event LiquidationFeeUpdated(uint256 oldValue, uint256 newValue);
    event ManagementFeeUpdated(uint256 oldValue, uint256 newValue);
    event InsuranceFundShareUpdated(uint256 oldValue, uint256 newValue);
    event TreasuryUpdated(address indexed oldAddr, address indexed newAddr);
    event InsuranceFundUpdated(address indexed oldAddr, address indexed newAddr);

    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
        _;
    }

    modifier onlyAuthorized() {
        require(
            msg.sender == core.owner() || core.keepers(msg.sender) || authorizedCallers[msg.sender], "NOT_AUTHORIZED"
        );
        _;
    }

    constructor(address _core, address _treasury, address _insuranceFund) {
        require(_core != address(0), "ZERO_CORE");
        require(_treasury != address(0), "ZERO_TREASURY");
        require(_insuranceFund != address(0), "ZERO_INSURANCE");
        core = ProtocolCore(_core);
        treasury = _treasury;
        insuranceFund = _insuranceFund;

        reserveFactorBps[ILPAdapter.LPType.Curve] = 1000;
        reserveFactorBps[ILPAdapter.LPType.UniswapV2] = 2000;
        reserveFactorBps[ILPAdapter.LPType.UniswapV3] = 2000;
        reserveFactorBps[ILPAdapter.LPType.Aerodrome] = 2500;
        reserveFactorBps[ILPAdapter.LPType.PancakeSwapV2] = 2000;
        reserveFactorBps[ILPAdapter.LPType.PancakeSwapV3] = 2500;
    }

    // --- Fee Collection ---

    /// @notice Pull fee tokens from a source into FeeCollector and record them
    /// @dev Called by LendingEngine (interest fees) and LiquidationEngine (liquidation fees).
    ///      Caller must have already approved FeeCollector for the token amount.
    /// @param token The fee token (e.g., USDC)
    /// @param amount Amount of fees to collect
    /// @param from Address to pull tokens from (Market, LiquidationEngine, etc.)
    /// @param feeType Label for event ("interest", "liquidation", "management")
    function collectFee(address token, uint256 amount, address from, string calldata feeType) external onlyAuthorized {
        require(amount > 0, "ZERO_AMOUNT");
        require(token != address(0), "ZERO_TOKEN");
        require(from != address(0), "ZERO_FROM");

        // Pull tokens into FeeCollector
        require(IERC20(token).transferFrom(from, address(this), amount), "FEE_TRANSFER_FAILED");

        accumulatedFees[token] += amount;
        emit FeesCollected(token, amount, from, feeType);
    }

    /// @notice Record fees that are already held by FeeCollector (e.g., sent directly)
    /// @dev Use when tokens are transferred to FeeCollector before calling this
    function recordFee(address token, uint256 amount, string calldata feeType) external onlyAuthorized {
        require(amount > 0, "ZERO_AMOUNT");
        require(token != address(0), "ZERO_TOKEN");
        accumulatedFees[token] += amount;
        emit FeesCollected(token, amount, address(this), feeType);
    }

    /// @notice Distribute accumulated fees to treasury and insurance fund
    function distribute(address token) external onlyAuthorized {
        require(!_distributing, "REENTRANCY");
        _distributing = true;

        require(token != address(0), "ZERO_TOKEN");
        require(treasury != address(0), "TREASURY_NOT_SET");
        require(insuranceFund != address(0), "INSURANCE_NOT_SET");

        uint256 total = accumulatedFees[token];
        require(total > 0, "NO_FEES");

        // Verify FeeCollector actually holds the tokens
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= total, "INSUFFICIENT_BALANCE");

        // Clear before transfers (CEI pattern)
        accumulatedFees[token] = 0;

        uint256 toInsurance = (total * insuranceFundShareBps) / 10_000;
        uint256 toTreasury = total - toInsurance;

        if (toTreasury > 0) {
            require(IERC20(token).transfer(treasury, toTreasury), "TREASURY_TRANSFER_FAILED");
        }
        if (toInsurance > 0) {
            require(IERC20(token).transfer(insuranceFund, toInsurance), "INSURANCE_TRANSFER_FAILED");
        }

        emit FeesDistributed(token, toTreasury, toInsurance);
        _distributing = false;
    }

    // --- View ---

    /// @notice Get the reserve factor for an LP type
    function getReserveFactor(ILPAdapter.LPType lpType) external view returns (uint256) {
        uint256 rf = reserveFactorBps[lpType];
        return rf > 0 ? rf : defaultReserveFactorBps;
    }

    /// @notice Calculate protocol's share of interest for a given LP type
    /// @param totalInterest Total interest accrued
    /// @param lpType LP type (determines reserve factor)
    /// @return protocolShare Amount that goes to protocol
    /// @return lenderShare Amount that goes to lenders
    function calculateInterestSplit(
        uint256 totalInterest,
        ILPAdapter.LPType lpType
    )
        external
        view
        returns (uint256 protocolShare, uint256 lenderShare)
    {
        uint256 rf = reserveFactorBps[lpType];
        if (rf == 0) rf = defaultReserveFactorBps;

        protocolShare = (totalInterest * rf) / 10_000;
        lenderShare = totalInterest - protocolShare;
    }

    /// @notice Calculate liquidation fee from liquidator profit
    /// @param liquidatorProfit Total profit the liquidator made
    /// @return protocolFee Amount that goes to protocol
    /// @return liquidatorNet Amount liquidator keeps
    function calculateLiquidationFee(uint256 liquidatorProfit)
        external
        view
        returns (uint256 protocolFee, uint256 liquidatorNet)
    {
        protocolFee = (liquidatorProfit * liquidationFeeBps) / 10_000;
        liquidatorNet = liquidatorProfit - protocolFee;
    }

    // --- Admin (DAO controlled) ---

    /// @notice Authorize a contract to call collectFee (e.g., LiquidationEngine)
    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        require(caller != address(0), "ZERO_ADDRESS");
        authorizedCallers[caller] = status;
    }

    function setReserveFactor(ILPAdapter.LPType lpType, uint256 _bps) external onlyOwner {
        require(_bps >= MIN_RESERVE_FACTOR && _bps <= MAX_RESERVE_FACTOR, "OUT_OF_BOUNDS");
        emit ReserveFactorUpdated(lpType, reserveFactorBps[lpType], _bps);
        reserveFactorBps[lpType] = _bps;
    }

    function setDefaultReserveFactor(uint256 _bps) external onlyOwner {
        require(_bps >= MIN_RESERVE_FACTOR && _bps <= MAX_RESERVE_FACTOR, "OUT_OF_BOUNDS");
        emit DefaultReserveFactorUpdated(defaultReserveFactorBps, _bps);
        defaultReserveFactorBps = _bps;
    }

    function setLiquidationFee(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_LIQUIDATION_FEE, "TOO_HIGH");
        emit LiquidationFeeUpdated(liquidationFeeBps, _bps);
        liquidationFeeBps = _bps;
    }

    function setManagementFee(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_MANAGEMENT_FEE, "TOO_HIGH");
        emit ManagementFeeUpdated(managementFeeBps, _bps);
        managementFeeBps = _bps;
    }

    function setInsuranceFundShare(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_INSURANCE_SHARE, "TOO_HIGH");
        emit InsuranceFundShareUpdated(insuranceFundShareBps, _bps);
        insuranceFundShareBps = _bps;
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "ZERO_ADDRESS");
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setInsuranceFund(address _insuranceFund) external onlyOwner {
        require(_insuranceFund != address(0), "ZERO_ADDRESS");
        emit InsuranceFundUpdated(insuranceFund, _insuranceFund);
        insuranceFund = _insuranceFund;
    }
}
