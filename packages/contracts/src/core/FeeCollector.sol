// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
///   LendingEngine/LiquidationEngine -> collectFee() -> pulls tokens into FeeCollector
///   Keeper/DAO -> distribute() -> splits to treasury + insurance fund
///
/// Safety:
///   - Uses OZ ReentrancyGuard (not manual bool — avoids permanent stuck state)
///   - collectFee measures actual received amount (fee-on-transfer token safe)
///   - distribute verifies balance before sending
contract FeeCollector is ReentrancyGuard {
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
    mapping(address => uint256) public accumulatedFees; // token -> amount

    // --- Authorized Callers ---
    mapping(address => bool) public authorizedCallers;

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
    event AuthorizedCallerUpdated(address indexed caller, bool status);

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

    /// @notice Pull fee tokens from a source into FeeCollector and record actual received amount
    /// @dev Measures balance before/after transfer to handle fee-on-transfer tokens correctly.
    function collectFee(address token, uint256 amount, address from, string calldata feeType) external onlyAuthorized {
        require(amount > 0, "ZERO_AMOUNT");
        require(token != address(0), "ZERO_TOKEN");
        require(from != address(0), "ZERO_FROM");

        // Measure actual received (fee-on-transfer safe)
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        require(IERC20(token).transferFrom(from, address(this), amount), "FEE_TRANSFER_FAILED");
        uint256 actualReceived = IERC20(token).balanceOf(address(this)) - balanceBefore;

        accumulatedFees[token] += actualReceived;
        emit FeesCollected(token, actualReceived, from, feeType);
    }

    /// @notice Distribute accumulated fees to treasury and insurance fund
    /// @dev Uses OZ ReentrancyGuard — cannot get permanently stuck on revert
    function distribute(address token) external onlyAuthorized nonReentrant {
        require(token != address(0), "ZERO_TOKEN");
        require(treasury != address(0), "TREASURY_NOT_SET");
        require(insuranceFund != address(0), "INSURANCE_NOT_SET");

        uint256 total = accumulatedFees[token];
        require(total > 0, "NO_FEES");

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
    }

    // --- View ---

    function getReserveFactor(ILPAdapter.LPType lpType) external view returns (uint256) {
        uint256 rf = reserveFactorBps[lpType];
        return rf > 0 ? rf : defaultReserveFactorBps;
    }

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

    function calculateLiquidationFee(uint256 liquidatorProfit)
        external
        view
        returns (uint256 protocolFee, uint256 liquidatorNet)
    {
        protocolFee = (liquidatorProfit * liquidationFeeBps) / 10_000;
        liquidatorNet = liquidatorProfit - protocolFee;
    }

    // --- Admin (DAO controlled) ---

    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        require(caller != address(0), "ZERO_ADDRESS");
        authorizedCallers[caller] = status;
        emit AuthorizedCallerUpdated(caller, status);
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
