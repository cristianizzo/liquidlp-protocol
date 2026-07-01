// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ILPOracleHub} from "../interfaces/ILPOracleHub.sol";
import {ILendingEngine} from "../interfaces/ILendingEngine.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {ProtocolCore} from "./ProtocolCore.sol";

/// @title PositionManager
/// @notice Manages LP position deposits, withdrawals, and position state tracking
/// @dev UUPS upgradeable + reentrancy protected (external calls to adapters/oracles)
contract PositionManager is IPositionManager, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    ProtocolCore public core;
    ILPOracleHub public oracleHub;
    ILendingEngine public lendingEngine;

    mapping(uint256 => Position) internal _positions;
    mapping(address => uint256[]) internal _ownerPositions;
    uint256 public nextPositionId;
    mapping(uint256 => uint256) public positionDebt;
    mapping(address => bool) public authorized;

    // --- Events ---
    event AuthorizationUpdated(address indexed addr, bool status);
    event PositionAmountReduced(uint256 indexed positionId, uint256 amountRemoved, uint256 newAmount);

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
        _;
    }

    modifier onlyAuthorized() {
        require(authorized[msg.sender] || msg.sender == core.owner(), "NOT_AUTHORIZED");
        _;
    }

    modifier whenNotPaused() {
        require(!core.paused(), "PAUSED");
        _;
    }

    modifier positionExists(uint256 positionId) {
        require(positionId < nextPositionId, "POSITION_NOT_FOUND");
        require(_positions[positionId].owner != address(0), "POSITION_NOT_FOUND");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _core, address _oracleHub) external initializer {
        require(_core != address(0) && _oracleHub != address(0), "ZERO_ADDRESS");
        core = ProtocolCore(_core);
        oracleHub = ILPOracleHub(_oracleHub);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Set the LendingEngine reference (needed for accurate health factor)
    function setLendingEngine(address _lendingEngine) external onlyOwner {
        require(_lendingEngine != address(0), "ZERO_ADDRESS");
        lendingEngine = ILendingEngine(_lendingEngine);
    }

    // --- Admin ---

    function setAuthorized(address addr, bool status) external onlyOwner {
        require(addr != address(0), "ZERO_ADDRESS");
        authorized[addr] = status;
        emit AuthorizationUpdated(addr, status);
    }

    // --- Core Logic ---

    /// @inheritdoc IPositionManager
    function deposit(
        address lpToken, uint256 tokenId, uint256 amount, uint256 marketId
    ) external whenNotPaused nonReentrant returns (uint256 positionId) {
        require(lpToken != address(0), "ZERO_LP_TOKEN");
        require(core.markets(marketId) != address(0), "INVALID_MARKET");

        // Auto-detect LP type by querying each registered adapter
        ILPAdapter.LPType lpType = _detectLPType(lpToken);
        address adapterAddr = core.adapters(lpType);
        require(adapterAddr != address(0), "NO_ADAPTER");

        ILPAdapter adapter = ILPAdapter(adapterAddr);

        // Validate and lock the LP position (external call — reentrancy protected)
        ILPAdapter.LPInfo memory info = adapter.validateAndLock(lpToken, tokenId, amount, msg.sender);

        // Verify pool is whitelisted
        require(core.isPoolSupported(info.pool), "POOL_NOT_SUPPORTED");

        // Get oracle price to validate position has value
        ILPOracleHub.PriceResult memory price = oracleHub.getPrice(lpToken, tokenId, amount, lpType);
        require(price.totalValue > 0, "ZERO_VALUE");

        // Create position
        positionId = nextPositionId++;
        _positions[positionId] = Position({
            id: positionId,
            owner: msg.sender,
            lpToken: lpToken,
            tokenId: tokenId,
            amount: amount,
            lpType: lpType,
            pool: info.pool,
            token0: info.token0,
            token1: info.token1,
            marketId: marketId,
            status: PositionStatus.Active,
            depositTimestamp: block.timestamp,
            depositBlock: block.number
        });

        _ownerPositions[msg.sender].push(positionId);

        emit PositionCreated(positionId, msg.sender, lpToken, tokenId, lpType, price.totalValue);
    }

    /// @inheritdoc IPositionManager
    function withdraw(uint256 positionId) external whenNotPaused nonReentrant positionExists(positionId) {
        Position storage pos = _positions[positionId];
        require(pos.owner == msg.sender, "NOT_POSITION_OWNER");
        require(positionDebt[positionId] == 0, "HAS_DEBT");
        require(pos.status == PositionStatus.Active, "NOT_ACTIVE");

        // Unlock LP via adapter (external call — reentrancy protected)
        address adapterAddr = core.adapters(pos.lpType);
        ILPAdapter(adapterAddr).unlock(pos.lpToken, pos.tokenId, pos.amount, msg.sender);

        pos.status = PositionStatus.Closed;
        emit PositionClosed(positionId, msg.sender);
    }

    // --- State Updates (authorized contracts only) ---

    /// @notice Update position debt (called by LendingEngine)
    function updateDebt(uint256 positionId, uint256 newDebt) external onlyAuthorized positionExists(positionId) {
        Position storage pos = _positions[positionId];
        require(
            pos.status == PositionStatus.Active || pos.status == PositionStatus.Borrowed,
            "POSITION_NOT_BORROWABLE"
        );

        positionDebt[positionId] = newDebt;
        if (newDebt > 0 && pos.status == PositionStatus.Active) {
            pos.status = PositionStatus.Borrowed;
        } else if (newDebt == 0 && pos.status == PositionStatus.Borrowed) {
            pos.status = PositionStatus.Active;
        }
    }

    /// @notice Reduce position amount after partial liquidation (called by LiquidationEngine)
    /// @param positionId The position to update
    /// @param amountRemoved How much liquidity was unwound and removed
    function reducePositionAmount(
        uint256 positionId, uint256 amountRemoved
    ) external onlyAuthorized positionExists(positionId) {
        Position storage pos = _positions[positionId];
        require(amountRemoved > 0, "ZERO_AMOUNT");
        require(amountRemoved <= pos.amount, "EXCEEDS_POSITION_AMOUNT");
        pos.amount -= amountRemoved;
        emit PositionAmountReduced(positionId, amountRemoved, pos.amount);
    }

    /// @notice Mark position as liquidated (called by LiquidationEngine)
    function markLiquidated(
        uint256 positionId, address liquidator, uint256 debtRepaid
    ) external onlyAuthorized positionExists(positionId) {
        require(liquidator != address(0), "ZERO_LIQUIDATOR");
        _positions[positionId].status = PositionStatus.Liquidated;
        positionDebt[positionId] = 0;
        emit PositionLiquidated(positionId, liquidator, debtRepaid);
    }

    // --- View Functions ---

    /// @inheritdoc IPositionManager
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return _positions[positionId];
    }

    /// @inheritdoc IPositionManager
    function getPositionsByOwner(address posOwner) external view returns (uint256[] memory) {
        return _ownerPositions[posOwner];
    }

    /// @inheritdoc IPositionManager
    function getPositionValue(uint256 positionId) public view returns (uint256) {
        Position memory pos = _positions[positionId];
        if (pos.owner == address(0)) return 0;
        ILPOracleHub.PriceResult memory price = oracleHub.getPrice(
            pos.lpToken, pos.tokenId, pos.amount, pos.lpType
        );
        return price.totalValue;
    }

    /// @inheritdoc IPositionManager
    function getHealthFactor(uint256 positionId) external view returns (uint256) {
        // Use interest-accrued debt from LendingEngine (not stale positionDebt)
        uint256 debt;
        if (address(lendingEngine) != address(0)) {
            debt = lendingEngine.getDebt(positionId);
        } else {
            debt = positionDebt[positionId]; // Fallback if LE not set yet
        }
        if (debt == 0) return type(uint256).max;

        uint256 collateralValue = getPositionValue(positionId);
        if (collateralValue == 0) return 0;

        Position memory pos = _positions[positionId];
        address marketAddr = core.markets(pos.marketId);
        IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();

        // HF = (collateralValue * liquidationThreshold) / (debt * 10000)
        // Scaled by 1e18 (1e18 = health factor of 1.0)
        return (collateralValue * config.liquidationThreshold * 1e18) / (debt * 10_000);
    }

    /// @notice Get the block number when a position was deposited (for borrow cooldown)
    function getDepositBlock(uint256 positionId) external view returns (uint256) {
        return _positions[positionId].depositBlock;
    }

    // --- Storage Gap (UUPS upgrade safety) ---
    // Reserve 50 slots so future upgrades can add state variables
    // without colliding with child contract storage.
    uint256[50] private __gap;

    // --- Internal ---

    function _detectLPType(address lpToken) internal view returns (ILPAdapter.LPType) {
        uint8 maxType = core.maxRegisteredLPType();
        for (uint8 i = 0; i <= maxType; i++) {
            ILPAdapter.LPType lt = ILPAdapter.LPType(i);
            address adapterAddr = core.adapters(lt);
            if (adapterAddr != address(0) && ILPAdapter(adapterAddr).isSupported(lpToken)) {
                return lt;
            }
        }
        revert("UNSUPPORTED_LP");
    }
}
