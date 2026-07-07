// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACLManager} from "../src/core/ACLManager.sol";
import {ProtocolCore} from "../src/core/ProtocolCore.sol";
import {PositionManager} from "../src/core/PositionManager.sol";
import {LendingEngine} from "../src/core/LendingEngine.sol";
import {LiquidationEngine} from "../src/core/LiquidationEngine.sol";
import {FeeCollector} from "../src/core/FeeCollector.sol";
import {LPOracleHub} from "../src/oracle/LPOracleHub.sol";
import {UniswapV3Oracle} from "../src/oracle/UniswapV3Oracle.sol";
import {UniswapV2Oracle} from "../src/oracle/UniswapV2Oracle.sol";
import {PriceFeedRegistry} from "../src/oracle/PriceFeedRegistry.sol";
import {PriceValidator} from "../src/oracle/PriceValidator.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {UniswapV2Adapter} from "../src/adapters/UniswapV2Adapter.sol";
import {InterestRateModel} from "../src/markets/InterestRateModel.sol";
import {Market} from "../src/markets/Market.sol";
import {MarketFactory} from "../src/markets/MarketFactory.sol";
import {MarketRegistry} from "../src/markets/MarketRegistry.sol";
import {CircuitBreaker} from "../src/security/CircuitBreaker.sol";
import {RiskManager} from "../src/security/RiskManager.sol";
import {PoolHealthMonitor} from "../src/security/PoolHealthMonitor.sol";
import {ILPAdapter} from "../src/interfaces/ILPAdapter.sol";

/// @title DeployBase
/// @notice Shared deployment logic for all chains. Subclass sets chain-specific config.
/// @dev Usage: forge script script/deploy/Sepolia.s.sol --rpc-url $RPC --broadcast --verify
abstract contract DeployBase is Script {
    // --- Chain Config (set by subclass) ---

    struct ChainConfig {
        // Roles
        address deployer;
        address guardian;
        address riskAdmin;
        // V2 DEX (address(0) = skip)
        address v2Factory;
        address v2Router;
        // V3 DEX (address(0) = skip)
        address v3Factory;
        address v3NftManager;
        // Tokens
        address weth; // native wrapped token (WETH, WBNB, etc.)
        address stablecoin; // primary borrow asset (USDC, BUSD, etc.)
        // Chainlink feeds
        address clNativeUsd; // ETH/USD, BNB/USD, etc.
        address clStablecoinUsd; // USDC/USD, BUSD/USD, etc.
        // Pools to whitelist
        address v2Pool; // V2 pair to whitelist (address(0) = skip)
        address v3Pool; // V3 pool to whitelist (address(0) = skip)
        // Market params
        uint256 maxLtv; // bps (e.g., 6500 = 65%)
        uint256 liquidationThreshold; // bps
        uint256 liquidationBonus; // bps
        uint256 haircut; // bps
        uint256 borrowCap; // in stablecoin decimals
    }

    // --- Deployed Contracts ---
    ACLManager public aclManager;
    ProtocolCore public core;
    LPOracleHub public oracleHub;
    PositionManager public positionManager;
    LendingEngine public lendingEngine;
    LiquidationEngine public liquidationEngine;
    FeeCollector public feeCollector;
    CircuitBreaker public circuitBreaker;
    RiskManager public riskManager;
    PriceFeedRegistry public priceFeedRegistry;
    PriceValidator public priceValidator;
    PoolHealthMonitor public poolHealthMonitor;
    MarketFactory public marketFactory;
    MarketRegistry public marketRegistry;

    // --- Abstract: subclass provides config ---
    function _config() internal virtual returns (ChainConfig memory);

    // --- Entry Point ---
    function run() external {
        ChainConfig memory cfg = _config();

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(vm.addr(deployerKey) == cfg.deployer, "DEPLOYER_KEY_MISMATCH");

        vm.startBroadcast(deployerKey);

        _deployCore(cfg);
        _deployProxies();
        _deploySecurity(cfg);
        _deployOracles(cfg);
        _deployAdapters(cfg);
        _deployMarkets(cfg);
        _configureRoles(cfg);
        _createMarket(cfg);

        vm.stopBroadcast();

        _logAddresses(cfg);
    }

    // --- Deploy Steps ---

    function _deployCore(ChainConfig memory cfg) internal {
        // TODO: Post-deploy, transfer ACLManager and ProtocolCore ownership from the
        // deployer EOA to a multisig. The deployer should not retain admin privileges.
        aclManager = new ACLManager(cfg.deployer);
        core = new ProtocolCore(cfg.deployer, address(aclManager));

        LPOracleHub ohImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(ohImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
        );
    }

    function _deployProxies() internal {
        PositionManager pmImpl = new PositionManager();
        positionManager = PositionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl), abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
                )
            )
        );

        LendingEngine leImpl = new LendingEngine();
        lendingEngine = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(leImpl), abi.encodeCall(LendingEngine.initialize, (address(core), address(positionManager)))
                )
            )
        );

        LiquidationEngine liqImpl = new LiquidationEngine();
        liquidationEngine = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(liqImpl),
                    abi.encodeCall(
                        LiquidationEngine.initialize, (address(core), address(positionManager), address(lendingEngine))
                    )
                )
            )
        );
    }

    function _deploySecurity(ChainConfig memory cfg) internal {
        feeCollector = new FeeCollector(address(core), cfg.deployer, cfg.deployer);
        circuitBreaker = new CircuitBreaker(address(core));
        riskManager = new RiskManager(address(core));
        poolHealthMonitor = new PoolHealthMonitor(address(core), address(circuitBreaker));
        priceFeedRegistry = new PriceFeedRegistry(address(core));
        priceValidator = new PriceValidator(address(core), address(circuitBreaker));
    }

    function _deployOracles(ChainConfig memory cfg) internal {
        // V3 Oracle
        if (cfg.v3NftManager != address(0)) {
            UniswapV3Oracle v3Oracle = new UniswapV3Oracle(address(core), cfg.v3NftManager);
            v3Oracle.setPriceFeed(cfg.weth, cfg.clNativeUsd);
            v3Oracle.setPriceFeed(cfg.stablecoin, cfg.clStablecoinUsd);
            v3Oracle.setMaxStaleness(3600);
            oracleHub.registerOracle(ILPAdapter.LPType.UniswapV3, address(v3Oracle));
        }

        // V2 Oracle
        if (cfg.v2Factory != address(0)) {
            UniswapV2Oracle v2Oracle = new UniswapV2Oracle(address(core));
            v2Oracle.setPriceFeed(cfg.weth, cfg.clNativeUsd);
            v2Oracle.setPriceFeed(cfg.stablecoin, cfg.clStablecoinUsd);
            v2Oracle.setMaxStaleness(3600);
            oracleHub.registerOracle(ILPAdapter.LPType.UniswapV2, address(v2Oracle));
        }

        // PriceFeedRegistry (for cross-decimal HF/LTV)
        priceFeedRegistry.setPriceFeed(cfg.stablecoin, cfg.clStablecoinUsd);
        priceFeedRegistry.setPriceFeed(cfg.weth, cfg.clNativeUsd);
    }

    function _deployAdapters(ChainConfig memory cfg) internal {
        if (cfg.v3NftManager != address(0)) {
            UniswapV3Adapter v3Adapter = new UniswapV3Adapter(cfg.v3NftManager, cfg.v3Factory, address(core));
            core.registerAdapter(ILPAdapter.LPType.UniswapV3, address(v3Adapter));
        }

        if (cfg.v2Factory != address(0)) {
            UniswapV2Adapter v2Adapter = new UniswapV2Adapter(cfg.v2Factory, cfg.v2Router, address(core));
            core.registerAdapter(ILPAdapter.LPType.UniswapV2, address(v2Adapter));
        }
    }

    function _deployMarkets(ChainConfig memory cfg) internal {
        InterestRateModel stableModel = new InterestRateModel(100, 400, 7500, 8500);
        InterestRateModel volatileModel = new InterestRateModel(200, 600, 10_000, 8000);

        Market marketImpl = new Market();
        marketFactory = new MarketFactory(address(core), address(marketImpl));
        marketRegistry = new MarketRegistry(address(core));

        marketFactory.setInterestRateModel("stable", address(stableModel));
        marketFactory.setInterestRateModel("volatile", address(volatileModel));

        core.setMarketFactory(address(marketFactory));
    }

    function _configureRoles(ChainConfig memory cfg) internal {
        // Contract roles
        aclManager.grantRole(aclManager.LENDING_ENGINE(), address(lendingEngine));
        aclManager.grantRole(aclManager.LIQUIDATION_ENGINE(), address(liquidationEngine));
        aclManager.grantRole(aclManager.POSITION_MANAGER(), address(positionManager));

        // Human roles
        if (cfg.guardian != address(0)) {
            aclManager.addEmergencyAdmin(cfg.guardian);
        }
        if (cfg.riskAdmin != address(0)) {
            aclManager.addRiskAdmin(cfg.riskAdmin);
        }

        // Wire references
        positionManager.setLendingEngine(address(lendingEngine));
        positionManager.setPriceFeedRegistry(address(priceFeedRegistry));
        positionManager.setRiskManager(address(riskManager));
        positionManager.setCircuitBreaker(address(circuitBreaker));
        lendingEngine.setRiskManager(address(riskManager));

        // Wire swap router for liquidation collateral swaps
        // Uses V2 router if available, otherwise requires manual config post-deploy
        if (cfg.v2Router != address(0)) {
            liquidationEngine.setSwapRouter(cfg.v2Router);
        }

        // Grant KEEPER to security contracts so they can trigger CircuitBreaker.pausePool()
        aclManager.grantRole(aclManager.KEEPER(), address(priceValidator));
        aclManager.grantRole(aclManager.KEEPER(), address(poolHealthMonitor));
    }

    function _createMarket(ChainConfig memory cfg) internal {
        // Whitelist pools
        if (cfg.v3Pool != address(0)) core.whitelistPool(cfg.v3Pool);
        if (cfg.v2Pool != address(0)) core.whitelistPool(cfg.v2Pool);

        // Create V3 market if V3 is configured
        if (cfg.v3NftManager != address(0)) {
            _createAndWireMarket(ILPAdapter.LPType.UniswapV3, cfg);
        }

        // Create V2 market if V2 is configured
        if (cfg.v2Factory != address(0)) {
            _createAndWireMarket(ILPAdapter.LPType.UniswapV2, cfg);
        }
    }

    function _createAndWireMarket(ILPAdapter.LPType lpType, ChainConfig memory cfg) internal {
        (uint256 marketId,) = marketFactory.createMarket(
            lpType,
            cfg.stablecoin,
            cfg.maxLtv,
            cfg.liquidationThreshold,
            cfg.liquidationBonus,
            cfg.haircut,
            cfg.borrowCap,
            0, // minPoolTvl (0 for testnet)
            0, // minPoolAge (0 for testnet)
            "volatile"
        );

        // Wire FeeCollector into the newly created market
        address marketAddr = core.markets(marketId);
        Market(marketAddr).setFeeCollector(address(feeCollector));
    }

    function _logAddresses(ChainConfig memory) internal view {
        console.log("=== Aurelia Protocol Deployed ===");
        console.log("");
        console.log("ACLManager:             ", address(aclManager));
        console.log("ProtocolCore:           ", address(core));
        console.log("PositionManager:        ", address(positionManager));
        console.log("LendingEngine:          ", address(lendingEngine));
        console.log("LiquidationEngine:      ", address(liquidationEngine));
        console.log("LPOracleHub:            ", address(oracleHub));
        console.log("FeeCollector:           ", address(feeCollector));
        console.log("CircuitBreaker:         ", address(circuitBreaker));
        console.log("RiskManager:            ", address(riskManager));
        console.log("PriceFeedRegistry:      ", address(priceFeedRegistry));
        console.log("PriceValidator:         ", address(priceValidator));
        console.log("PoolHealthMonitor:      ", address(poolHealthMonitor));
        console.log("MarketFactory:          ", address(marketFactory));
        console.log("MarketRegistry:         ", address(marketRegistry));
    }
}
