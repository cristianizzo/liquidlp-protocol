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
import {IERC20 as OZIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolCore} from "./ProtocolCore.sol";
import {ACLManager} from "./ACLManager.sol";
import {PriceFeedRegistry} from "../oracle/PriceFeedRegistry.sol";
import {RiskManager} from "../security/RiskManager.sol";
import {CircuitBreaker} from "../security/CircuitBreaker.sol";
import {FeeCollector} from "./FeeCollector.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

/// @title PositionManager
/// @notice Manages LP position deposits, withdrawals, and position state tracking
/// @dev UUPS upgradeable + reentrancy protected (external calls to adapters/oracles)
///      Uses ACLManager for role-based access control (Aave V3 pattern).
contract PositionManager is IPositionManager, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for OZIERC20;

    ProtocolCore public core;
    ILPOracleHub public oracleHub;
    ILendingEngine public lendingEngine;

    mapping(uint256 => Position) internal _positions;
    mapping(address => uint256[]) internal _ownerPositions;
    uint256 public nextPositionId;
    mapping(uint256 => uint256) public positionDebt;
    /// @dev Deprecated — was `authorized` mapping. Kept for UUPS storage layout compatibility.
    mapping(address => bool) private __deprecated_authorized;

    // --- Events ---
    event CollateralAdded(uint256 indexed positionId, uint256 addedLiquidity, uint256 used0, uint256 used1);
    event CircuitBreakerNotConfigured(uint256 indexed marketId, address pool);
    event PositionAmountReduced(uint256 indexed positionId, uint256 amountRemoved, uint256 newAmount);
    event LendingEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event PriceFeedRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event RiskManagerUpdated(address indexed oldManager, address indexed newManager);
    event CircuitBreakerUpdated(address indexed oldBreaker, address indexed newBreaker);

    // --- ACL Helpers ---
    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    // --- Modifiers ---
    modifier onlyPoolAdmin() {
        require(_acl().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    modifier onlyLendingEngine() {
        require(_acl().isLendingEngine(msg.sender), "NOT_LENDING_ENGINE");
        _;
    }

    modifier onlyLiquidationEngine() {
        require(_acl().isLiquidationEngine(msg.sender), "NOT_LIQUIDATION_ENGINE");
        _;
    }

    modifier onlyLendingOrLiquidation() {
        ACLManager acl = _acl();
        require(acl.isLendingEngine(msg.sender) || acl.isLiquidationEngine(msg.sender), "NOT_AUTHORIZED");
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

    function _authorizeUpgrade(address) internal override onlyPoolAdmin {}

    /// @notice Set the LendingEngine reference (needed for accurate health factor)
    function setLendingEngine(address _lendingEngine) external onlyPoolAdmin {
        require(_lendingEngine != address(0), "ZERO_ADDRESS");
        require(_lendingEngine.code.length > 0, "NOT_CONTRACT");
        emit LendingEngineUpdated(address(lendingEngine), _lendingEngine);
        lendingEngine = ILendingEngine(_lendingEngine);
    }

    /// @notice Set the PriceFeedRegistry (needed for debt → USD conversion in health factor)
    /// @dev Set to address(0) to revert to fallback decimal normalization mode
    function setPriceFeedRegistry(address _registry) external onlyPoolAdmin {
        require(_registry == address(0) || _registry.code.length > 0, "NOT_CONTRACT");
        emit PriceFeedRegistryUpdated(address(priceFeedRegistry), _registry);
        priceFeedRegistry = PriceFeedRegistry(_registry);
    }

    /// @notice Set RiskManager for position/borrow cap enforcement
    function setRiskManager(address _riskManager) external onlyPoolAdmin {
        require(_riskManager == address(0) || _riskManager.code.length > 0, "NOT_CONTRACT");
        emit RiskManagerUpdated(address(riskManager), _riskManager);
        riskManager = RiskManager(_riskManager);
    }

    /// @notice Set CircuitBreaker for pool-level pause enforcement
    function setCircuitBreaker(address _circuitBreaker) external onlyPoolAdmin {
        require(_circuitBreaker == address(0) || _circuitBreaker.code.length > 0, "NOT_CONTRACT");
        emit CircuitBreakerUpdated(address(circuitBreaker), _circuitBreaker);
        circuitBreaker = CircuitBreaker(_circuitBreaker);
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
        require(amount > 0 || tokenId > 0, "ZERO_AMOUNT");
        address marketAddr = core.markets(marketId);
        require(marketAddr != address(0), "INVALID_MARKET");

        // Auto-detect LP type by querying each registered adapter
        ILPAdapter.LPType lpType = _detectLPType(lpToken);

        // Validate LP type matches market's configured LP type
        IMarket.MarketConfig memory mConfig = IMarket(marketAddr).getConfig();
        require(lpType == mConfig.lpType, "LP_TYPE_MISMATCH");

        // Validate oracle is healthy before accepting deposit
        require(oracleHub.isOracleHealthy(lpType), "ORACLE_UNHEALTHY");

        address adapterAddr = core.adapters(lpType);
        require(adapterAddr != address(0), "NO_ADAPTER");

        ILPAdapter adapter = ILPAdapter(adapterAddr);

        // Validate and lock the LP position
        ILPAdapter.LPInfo memory info = adapter.validateAndLock(lpToken, tokenId, amount, msg.sender);

        // Verify pool is whitelisted and not circuit-broken
        require(core.isPoolSupported(info.pool), "POOL_NOT_SUPPORTED");
        if (address(circuitBreaker) != address(0)) {
            require(!circuitBreaker.poolPaused(info.pool), "POOL_CIRCUIT_BREAKER");
            require(!circuitBreaker.marketFrozen(marketId), "MARKET_FROZEN");
        } else {
            emit CircuitBreakerNotConfigured(marketId, info.pool);
        }

        // Get oracle price to validate position has value
        ILPOracleHub.PriceResult memory price = oracleHub.getPrice(lpToken, tokenId, amount, lpType);
        require(price.totalValue > 0, "ZERO_VALUE");

        // RiskManager: validate deposit caps
        if (address(riskManager) != address(0)) {
            (bool valid, string memory reason) =
                riskManager.validateDeposit(msg.sender, price.totalValue, marketId, activePositionCount[msg.sender]);
            require(valid, reason);
            riskManager.recordDeposit(price.totalValue, marketId);
        }

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
        activePositionCount[msg.sender]++;

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

        // RiskManager: track withdrawal for supply cap
        if (address(riskManager) != address(0)) {
            uint256 posValue = getPositionValue(positionId);
            riskManager.recordWithdraw(posValue, pos.marketId);
        }

        // CEI: update state BEFORE external call
        pos.status = PositionStatus.Closed;
        if (activePositionCount[msg.sender] > 0) activePositionCount[msg.sender]--;
        emit PositionClosed(positionId, msg.sender);

        // Unlock LP via adapter
        ILPAdapter(adapterAddr).unlock(pos.lpToken, pos.tokenId, pos.amount, msg.sender);
    }

    /// @inheritdoc IPositionManager
    /// @dev Pulls token0/token1 from user, forwards to adapter which adds liquidity.
    ///      For V2: new LP tokens are minted → pos.amount increases.
    ///      For V3: NFT liquidity increases in same tick range → pos.amount unchanged (liquidity in NFT).
    ///      Unused tokens (dust from price ratio mismatch) are refunded to the user.
    function addCollateral(
        uint256 positionId,
        uint256 amount0,
        uint256 amount1
    )
        external
        whenNotPaused
        nonReentrant
        positionExists(positionId)
    {
        Position storage pos = _positions[positionId];
        require(pos.owner == msg.sender, "NOT_POSITION_OWNER");
        require(pos.status == PositionStatus.Active || pos.status == PositionStatus.Borrowed, "POSITION_NOT_BORROWABLE");
        require(amount0 > 0 || amount1 > 0, "ZERO_AMOUNTS");

        // Frozen markets block new collateral (risk-taking)
        if (address(circuitBreaker) != address(0)) {
            require(!circuitBreaker.marketFrozen(pos.marketId), "MARKET_FROZEN");
        }

        address adapterAddr = core.adapters(pos.lpType);
        require(adapterAddr != address(0), "ADAPTER_NOT_FOUND");

        // Snapshot pre-change value for RiskManager delta tracking
        uint256 valueBefore = getPositionValue(positionId);

        // Pull tokens from user to adapter (balance-delta to measure actual received)
        uint256 adapterBal0Before = IERC20(pos.token0).balanceOf(adapterAddr);
        uint256 adapterBal1Before = IERC20(pos.token1).balanceOf(adapterAddr);

        if (amount0 > 0) {
            OZIERC20(pos.token0).safeTransferFrom(msg.sender, adapterAddr, amount0);
        }
        if (amount1 > 0) {
            OZIERC20(pos.token1).safeTransferFrom(msg.sender, adapterAddr, amount1);
        }

        uint256 received0 = IERC20(pos.token0).balanceOf(adapterAddr) - adapterBal0Before;
        uint256 received1 = IERC20(pos.token1).balanceOf(adapterAddr) - adapterBal1Before;

        // Adapter adds liquidity to the position (unused tokens refunded to user)
        (uint256 addedLiquidity, uint256 used0, uint256 used1) = ILPAdapter(adapterAddr)
            .addLiquidity(pos.lpToken, pos.tokenId, pos.token0, pos.token1, received0, received1, msg.sender);

        require(addedLiquidity > 0, "ZERO_LIQUIDITY_ADDED");

        // For V2: LP tokens were minted → increase stored amount
        if (pos.lpType == ILPAdapter.LPType.UniswapV2 || pos.lpType == ILPAdapter.LPType.PancakeSwapV2) {
            pos.amount += addedLiquidity;
            require(pos.amount <= type(uint128).max, "AMOUNT_OVERFLOW");
        }
        // For V3: liquidity is inside the NFT — oracle reads it directly, no amount update

        // RiskManager: enforce position value cap and track supply delta
        // Note: skip maxPositionsPerUser check (not creating a new position)
        if (address(riskManager) != address(0)) {
            uint256 valueAfter = getPositionValue(positionId);
            require(valueAfter <= riskManager.maxPositionValue(), "POSITION_TOO_LARGE");
            uint256 delta = valueAfter > valueBefore ? valueAfter - valueBefore : 0;
            if (delta > 0) {
                riskManager.recordDeposit(delta, pos.marketId);
            }
        }

        emit CollateralAdded(positionId, addedLiquidity, used0, used1);
    }

    // --- State Updates (role-based access) ---

    /// @notice Update position debt (called by LendingEngine)
    function updateDebt(uint256 positionId, uint256 newDebt) external onlyLendingEngine positionExists(positionId) {
        Position storage pos = _positions[positionId];
        require(pos.status == PositionStatus.Active || pos.status == PositionStatus.Borrowed, "POSITION_NOT_BORROWABLE");

        positionDebt[positionId] = newDebt;
        if (newDebt > 0 && pos.status == PositionStatus.Active) {
            pos.status = PositionStatus.Borrowed;
        } else if (newDebt == 0 && pos.status == PositionStatus.Borrowed) {
            if (pos.amount > 0 || pos.tokenId > 0) {
                // Position still has collateral (amount for V2, tokenId for V3)
                pos.status = PositionStatus.Active;
            } else {
                // Fully consumed (no LP, no debt) → mark as closed
                pos.status = PositionStatus.Closed;
                if (activePositionCount[pos.owner] > 0) activePositionCount[pos.owner]--;
            }
        }
    }

    /// @notice Reduce position amount after partial liquidation (called by LiquidationEngine)
    function reducePositionAmount(
        uint256 positionId,
        uint256 amountRemoved
    )
        external
        onlyLiquidationEngine
        positionExists(positionId)
    {
        Position storage pos = _positions[positionId];
        require(amountRemoved > 0, "ZERO_AMOUNT");
        require(amountRemoved <= pos.amount, "EXCEEDS_POSITION_AMOUNT");
        pos.amount -= amountRemoved;
        emit PositionAmountReduced(positionId, amountRemoved, pos.amount);
    }

    /// @notice Mark position as liquidated (called by LiquidationEngine)
    function markLiquidated(
        uint256 positionId,
        address liquidator,
        uint256 debtRepaid
    )
        external
        onlyLiquidationEngine
        positionExists(positionId)
    {
        require(liquidator != address(0), "ZERO_LIQUIDATOR");
        Position storage pos = _positions[positionId];
        require(pos.status == PositionStatus.Borrowed || pos.status == PositionStatus.Active, "NOT_LIQUIDATABLE_STATUS");
        pos.status = PositionStatus.Liquidated;
        positionDebt[positionId] = 0;
        if (activePositionCount[pos.owner] > 0) activePositionCount[pos.owner]--;
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
        uint8 borrowDecimals = TokenUtils.safeDecimals(config.borrowAsset);
        if (address(priceFeedRegistry) != address(0)) {
            debtUsd = priceFeedRegistry.getUsdValue(config.borrowAsset, debt, borrowDecimals);
        } else {
            if (borrowDecimals < 18) {
                debtUsd = Math.mulDiv(debt, 10 ** (18 - borrowDecimals), 1);
            } else if (borrowDecimals > 18) {
                debtUsd = debt / (10 ** (borrowDecimals - 18));
            } else {
                debtUsd = debt;
            }
        }

        if (debtUsd == 0) return type(uint256).max;
        uint256 numerator = Math.mulDiv(collateralValue, config.liquidationThreshold, 10_000);
        return Math.mulDiv(numerator, 1e18, debtUsd);
    }

    /// @notice Get the block number at which a position was deposited (used for borrow cooldown)
    /// @param positionId The position to query
    /// @return The block number of the deposit
    function getDepositBlock(uint256 positionId) external view returns (uint256) {
        return _positions[positionId].depositBlock;
    }

    /// @notice Collect fees and reinvest as liquidity (called by LPCompounder)
    /// @dev Permissionless via LPCompounder. PositionManager mediates adapter access.
    /// @param positionId The position to compound
    /// @param protocolFeeRecipient Where to send protocol fee (FeeCollector)
    /// @param protocolFeeBps Protocol fee in basis points (e.g., 190 = 1.9%)
    /// @param callerRewardRecipient Where to send caller reward (msg.sender of LPCompounder)
    /// @param callerRewardBps Caller reward in basis points (e.g., 10 = 0.1%)
    /// @param dustRefundTo Where to send unused tokens (position owner)
    /// @return fees0 Total fees collected in token0
    /// @return fees1 Total fees collected in token1
    /// @return addedLiquidity Liquidity added back to position
    function compoundFees(
        uint256 positionId,
        address protocolFeeRecipient,
        uint256 protocolFeeBps,
        address callerRewardRecipient,
        uint256 callerRewardBps,
        address dustRefundTo
    )
        external
        whenNotPaused
        nonReentrant
        positionExists(positionId)
        returns (uint256 fees0, uint256 fees1, uint256 addedLiquidity)
    {
        // Access: only keeper or pool admin (LPCompounder has KEEPER role)
        require(_acl().isKeeper(msg.sender) || _acl().isPoolAdmin(msg.sender), "NOT_KEEPER");

        // Validate fee bps — prevent misconfiguration/abuse
        require(protocolFeeBps + callerRewardBps <= 5000, "FEES_TOO_HIGH"); // max 50% total

        Position storage pos = _positions[positionId];
        require(pos.status == PositionStatus.Active || pos.status == PositionStatus.Borrowed, "POSITION_NOT_ACTIVE");

        address adapterAddr = core.adapters(pos.lpType);
        require(adapterAddr != address(0), "NO_ADAPTER");
        ILPAdapter adapter = ILPAdapter(adapterAddr);

        // Step 1: Collect fees from NFT → tokens to this contract
        (fees0, fees1) = adapter.collectFees(pos.lpToken, pos.tokenId);
        if (fees0 == 0 && fees1 == 0) return (0, 0, 0);

        uint256 totalDeducted0;
        uint256 totalDeducted1;

        // Step 2: Protocol fee → FeeCollector (via collectFee so accumulatedFees is tracked)
        if (protocolFeeBps > 0 && protocolFeeRecipient != address(0)) {
            uint256 pFee0 = (fees0 * protocolFeeBps) / 10_000;
            uint256 pFee1 = (fees1 * protocolFeeBps) / 10_000;
            if (pFee0 > 0) {
                OZIERC20(pos.token0).forceApprove(protocolFeeRecipient, pFee0);
                FeeCollector(protocolFeeRecipient).collectFee(pos.token0, pFee0, address(this), "compound");
            }
            if (pFee1 > 0) {
                OZIERC20(pos.token1).forceApprove(protocolFeeRecipient, pFee1);
                FeeCollector(protocolFeeRecipient).collectFee(pos.token1, pFee1, address(this), "compound");
            }
            totalDeducted0 += pFee0;
            totalDeducted1 += pFee1;
        }

        // Step 3: Caller reward → whoever triggered the compound
        if (callerRewardBps > 0 && callerRewardRecipient != address(0)) {
            uint256 cReward0 = (fees0 * callerRewardBps) / 10_000;
            uint256 cReward1 = (fees1 * callerRewardBps) / 10_000;
            if (cReward0 > 0) OZIERC20(pos.token0).safeTransfer(callerRewardRecipient, cReward0);
            if (cReward1 > 0) OZIERC20(pos.token1).safeTransfer(callerRewardRecipient, cReward1);
            totalDeducted0 += cReward0;
            totalDeducted1 += cReward1;
        }

        // Step 4: Reinvest remainder as liquidity
        uint256 reinvest0 = fees0 - totalDeducted0;
        uint256 reinvest1 = fees1 - totalDeducted1;

        if (reinvest0 > 0) OZIERC20(pos.token0).safeTransfer(adapterAddr, reinvest0);
        if (reinvest1 > 0) OZIERC20(pos.token1).safeTransfer(adapterAddr, reinvest1);

        (addedLiquidity,,) =
            adapter.addLiquidity(pos.lpToken, pos.tokenId, pos.token0, pos.token1, reinvest0, reinvest1, dustRefundTo);
    }

    // --- New state vars (appended for UUPS upgrade safety) ---
    PriceFeedRegistry public priceFeedRegistry;
    RiskManager public riskManager;
    mapping(address => uint256) public activePositionCount;
    CircuitBreaker public circuitBreaker;

    // --- Storage Gap ---
    // Reduced from 50 to 46 after adding priceFeedRegistry + riskManager + activePositionCount + circuitBreaker.
    uint256[46] private __gap;

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
