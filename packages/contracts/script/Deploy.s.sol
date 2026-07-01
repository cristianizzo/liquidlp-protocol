// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolCore} from "../src/core/ProtocolCore.sol";
import {PositionManager} from "../src/core/PositionManager.sol";
import {LendingEngine} from "../src/core/LendingEngine.sol";
import {LiquidationEngine} from "../src/core/LiquidationEngine.sol";
import {FeeCollector} from "../src/core/FeeCollector.sol";
import {LPOracleHub} from "../src/oracle/LPOracleHub.sol";
import {InterestRateModel} from "../src/markets/InterestRateModel.sol";
import {Market} from "../src/markets/Market.sol";
import {MarketFactory} from "../src/markets/MarketFactory.sol";
import {MarketRegistry} from "../src/markets/MarketRegistry.sol";
import {CircuitBreaker} from "../src/security/CircuitBreaker.sol";
import {RiskManager} from "../src/security/RiskManager.sol";
import {PoolHealthMonitor} from "../src/security/PoolHealthMonitor.sol";
import {EmergencyModule} from "../src/security/EmergencyModule.sol";
import {Router} from "../src/periphery/Router.sol";
import {PositionViewer} from "../src/periphery/PositionViewer.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. ProtocolCore (not proxied — it IS the root of trust)
        ProtocolCore core = new ProtocolCore(deployer, deployer);

        // 2. LPOracleHub (UUPS proxy)
        LPOracleHub oracleHubImpl = new LPOracleHub();
        ERC1967Proxy oracleHubProxy =
            new ERC1967Proxy(address(oracleHubImpl), abi.encodeCall(LPOracleHub.initialize, (address(core))));
        LPOracleHub oracleHub = LPOracleHub(address(oracleHubProxy));

        // 3. PositionManager (UUPS proxy)
        PositionManager positionManagerImpl = new PositionManager();
        ERC1967Proxy positionManagerProxy = new ERC1967Proxy(
            address(positionManagerImpl),
            abi.encodeCall(PositionManager.initialize, (address(core), address(oracleHub)))
        );
        PositionManager positionManager = PositionManager(address(positionManagerProxy));

        // 4. LendingEngine (UUPS proxy)
        LendingEngine lendingEngineImpl = new LendingEngine();
        ERC1967Proxy lendingEngineProxy = new ERC1967Proxy(
            address(lendingEngineImpl),
            abi.encodeCall(LendingEngine.initialize, (address(core), address(positionManager)))
        );
        LendingEngine lendingEngine = LendingEngine(address(lendingEngineProxy));

        // 5. LiquidationEngine (UUPS proxy)
        LiquidationEngine liquidationEngineImpl = new LiquidationEngine();
        ERC1967Proxy liquidationEngineProxy = new ERC1967Proxy(
            address(liquidationEngineImpl),
            abi.encodeCall(
                LiquidationEngine.initialize, (address(core), address(positionManager), address(lendingEngine))
            )
        );
        LiquidationEngine liquidationEngine = LiquidationEngine(address(liquidationEngineProxy));

        // 6. FeeCollector (not proxied — stateless enough to redeploy)
        FeeCollector feeCollector = new FeeCollector(address(core), deployer, deployer);

        // 7. Security (not proxied — replaceable via core references)
        CircuitBreaker circuitBreaker = new CircuitBreaker(address(core));
        RiskManager riskManager = new RiskManager(address(core));
        PoolHealthMonitor poolHealthMonitor = new PoolHealthMonitor(address(core), address(circuitBreaker));
        EmergencyModule emergencyModule = new EmergencyModule(address(core));

        // 8. Interest Rate Models (immutable — deploy new ones to change curves)
        InterestRateModel stableModel = new InterestRateModel(100, 400, 7500, 8500);
        InterestRateModel volatileModel = new InterestRateModel(200, 600, 10_000, 8000);
        InterestRateModel exoticModel = new InterestRateModel(500, 1000, 20_000, 7000);

        // 9. Market implementation + factory
        Market marketImpl = new Market();
        MarketFactory marketFactory = new MarketFactory(address(core), address(marketImpl));
        MarketRegistry marketRegistry = new MarketRegistry(address(core));

        marketFactory.setInterestRateModel("stable", address(stableModel));
        marketFactory.setInterestRateModel("volatile", address(volatileModel));
        marketFactory.setInterestRateModel("exotic", address(exoticModel));

        // 10. Periphery (not proxied — stateless helpers)
        Router router = new Router(address(positionManager), address(lendingEngine));
        PositionViewer positionViewer =
            new PositionViewer(address(core), address(positionManager), address(lendingEngine));

        // 11. Authorize contracts
        positionManager.setAuthorized(address(lendingEngine), true);
        positionManager.setAuthorized(address(liquidationEngine), true);

        vm.stopBroadcast();

        // Log deployed addresses
        console.log("=== LiquidLP Protocol Deployed (UUPS) ===");
        console.log("");
        console.log("--- Core (proxied) ---");
        console.log("ProtocolCore:           ", address(core));
        console.log("LPOracleHub proxy:      ", address(oracleHub));
        console.log("LPOracleHub impl:       ", address(oracleHubImpl));
        console.log("PositionManager proxy:  ", address(positionManager));
        console.log("PositionManager impl:   ", address(positionManagerImpl));
        console.log("LendingEngine proxy:    ", address(lendingEngine));
        console.log("LendingEngine impl:     ", address(lendingEngineImpl));
        console.log("LiquidationEngine proxy:", address(liquidationEngine));
        console.log("LiquidationEngine impl: ", address(liquidationEngineImpl));
        console.log("");
        console.log("--- Not proxied ---");
        console.log("FeeCollector:           ", address(feeCollector));
        console.log("CircuitBreaker:         ", address(circuitBreaker));
        console.log("RiskManager:            ", address(riskManager));
        console.log("PoolHealthMonitor:      ", address(poolHealthMonitor));
        console.log("EmergencyModule:        ", address(emergencyModule));
        console.log("Market impl:            ", address(marketImpl));
        console.log("MarketFactory:          ", address(marketFactory));
        console.log("MarketRegistry:         ", address(marketRegistry));
        console.log("Router:                 ", address(router));
        console.log("PositionViewer:         ", address(positionViewer));
    }
}
