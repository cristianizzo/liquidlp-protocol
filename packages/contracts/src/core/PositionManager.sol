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
import {IERC20} from "../interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolCore} from "./ProtocolCore.sol";
import {PriceFeedRegistry} from "../oracle/PriceFeedRegistry.sol";

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
    event LendingEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event PriceFeedRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

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
        emit LendingEngineUpdated(address(lendingEngine), _lendingEngine);
        lendingEngine = ILendingEngine(_lendingEngine);
    }

    /// @notice Set the PriceFeedRegistry (needed for debt → USD conversion in health factor)
    /// @dev Set to address(0) to revert to fallback decimal normalization mode
    function setPriceFeedRegistry(address _registry) external onlyOwner {
        require(_registry == address(0) || _registry.code.length > 0, "NOT_CONTRACT");
        emit PriceFeedRegistryUpdated(address(priceFeedRegistry), _registry);
        priceFeedRegistry = PriceFeedRegistry(_registry);
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
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        uint256 marketId
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 positionId)
    {
        require(lpToken != address(0), "ZERO_LP_TOKEN");
        require(amount > 0 || tokenId > 0, "ZERO_AMOUNT"); // V2: amount > 0, V3: tokenId > 0
        address marketAddr = core.markets(marketId);
        require(marketAddr != address(0), "INVALID_MARKET");

        // Auto-detect LP type by querying each registered adapter
        ILPAdapter.LPType lpType = _detectLPType(lpToken);

        // Validate LP type matches market's configured LP type (prevents risk parameter mismatch)
        IMarket.MarketConfig memory mConfig = IMarket(marketAddr).getConfig();
        require(lpType == mConfig.lpType, "LP_TYPE_MISMATCH");

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

        // Defense-in-depth: also check live debt from LendingEngine
        if (address(lendingEngine) != address(0)) {
            require(lendingEngine.getDebt(positionId) == 0, "HAS_LIVE_DEBT");
        }

        address adapterAddr = core.adapters(pos.lpType);
        require(adapterAddr != address(0), "ADAPTER_NOT_FOUND");

        // CEI: update state BEFORE external call
        pos.status = PositionStatus.Closed;
        emit PositionClosed(positionId, msg.sender);

        // Unlock LP via adapter (external call — reentrancy protected)
        ILPAdapter(adapterAddr).unlock(pos.lpToken, pos.tokenId, pos.amount, msg.sender);
    }

    // --- State Updates (authorized contracts only) ---

    /// @notice Update position debt (called by LendingEngine)
    /// @dev Prevents zombie positions: cannot transition to Active if amount is 0
    function updateDebt(uint256 positionId, uint256 newDebt) external onlyAuthorized positionExists(positionId) {
        Position storage pos = _positions[positionId];
        require(pos.status == PositionStatus.Active || pos.status == PositionStatus.Borrowed, "POSITION_NOT_BORROWABLE");

        positionDebt[positionId] = newDebt;
        if (newDebt > 0 && pos.status == PositionStatus.Active) {
            pos.status = PositionStatus.Borrowed;
        } else if (newDebt == 0 && pos.status == PositionStatus.Borrowed) {
            // Only return to Active if position still has collateral
            if (pos.amount > 0) {
                pos.status = PositionStatus.Active;
            }
        }
    }

    /// @notice Reduce position amount after partial liquidation (called by LiquidationEngine)
    /// @param positionId The position to update
    /// @param amountRemoved How much liquidity was unwound and removed
    function reducePositionAmount(
        uint256 positionId,
        uint256 amountRemoved
    )
        external
        onlyAuthorized
        positionExists(positionId)
    {
        Position storage pos = _positions[positionId];
        require(amountRemoved > 0, "ZERO_AMOUNT");
        require(amountRemoved <= pos.amount, "EXCEEDS_POSITION_AMOUNT");
        pos.amount -= amountRemoved;
        emit PositionAmountReduced(positionId, amountRemoved, pos.amount);
    }

    /// @notice Mark position as liquidated (called by LiquidationEngine)
    /// @dev Terminal state — position cannot re-enter active lifecycle after this
    function markLiquidated(
        uint256 positionId,
        address liquidator,
        uint256 debtRepaid
    )
        external
        onlyAuthorized
        positionExists(positionId)
    {
        require(liquidator != address(0), "ZERO_LIQUIDATOR");
        Position storage pos = _positions[positionId];
        require(pos.status == PositionStatus.Borrowed || pos.status == PositionStatus.Active, "NOT_LIQUIDATABLE_STATUS");
        pos.status = PositionStatus.Liquidated;
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
        ILPOracleHub.PriceResult memory price = oracleHub.getPrice(pos.lpToken, pos.tokenId, pos.amount, pos.lpType);
        return price.totalValue;
    }

    /// @inheritdoc IPositionManager
    function getHealthFactor(uint256 positionId) external view returns (uint256) {
        require(positionId < nextPositionId && _positions[positionId].owner != address(0), "POSITION_NOT_FOUND");
        require(address(lendingEngine) != address(0), "LENDING_ENGINE_NOT_SET");
        uint256 debt = lendingEngine.getDebt(positionId);
        if (debt == 0) return type(uint256).max;

        uint256 collateralValue = getPositionValue(positionId);
        if (collateralValue == 0) return 0;

        Position memory pos = _positions[positionId];
        address marketAddr = core.markets(pos.marketId);
        require(marketAddr != address(0), "MARKET_NOT_FOUND");
        IMarket.MarketConfig memory config = IMarket(marketAddr).getConfig();

        // Convert debt from borrow asset decimals to 18-dec USD value (Aave-style)
        uint256 debtUsd;
        if (address(priceFeedRegistry) != address(0)) {
            uint8 borrowDecimals = IERC20(config.borrowAsset).decimals();
            debtUsd = priceFeedRegistry.getUsdValue(config.borrowAsset, debt, borrowDecimals);
        } else {
            // Fallback: normalize debt to 18 decimals (assumes USD-pegged borrow asset)
            uint8 borrowDecimals = IERC20(config.borrowAsset).decimals();
            require(borrowDecimals <= 36, "INVALID_DECIMALS");
            if (borrowDecimals < 18) {
                debtUsd = Math.mulDiv(debt, 10 ** (18 - borrowDecimals), 1);
            } else if (borrowDecimals > 18) {
                debtUsd = debt / (10 ** (borrowDecimals - 18));
            } else {
                debtUsd = debt;
            }
        }

        // HF = (collateralValue * liquidationThreshold * 1e18) / (debtUsd * 10000)
        // Both collateralValue and debtUsd are in 18-dec USD
        // Scaled by 1e18 (1e18 = health factor of 1.0)
        // Two-step mulDiv to avoid overflow: first scale by threshold, then by 1e18
        if (debtUsd == 0) return type(uint256).max; // Dust debt rounds to 0 USD → treat as no debt
        uint256 numerator = Math.mulDiv(collateralValue, config.liquidationThreshold, 10_000);
        return Math.mulDiv(numerator, 1e18, debtUsd);
    }

    /// @notice Get the block number when a position was deposited (for borrow cooldown)
    function getDepositBlock(uint256 positionId) external view returns (uint256) {
        return _positions[positionId].depositBlock;
    }

    // --- New state vars (appended for UUPS upgrade safety) ---
    PriceFeedRegistry public priceFeedRegistry;

    // --- Storage Gap (UUPS upgrade safety) ---
    // Reserve slots so future upgrades can add state variables
    // without colliding with child contract storage.
    // Reduced from 50 to 49 after adding priceFeedRegistry (1 slot used).
    uint256[49] private __gap;

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
