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
import {InterestRateModel} from "../src/markets/InterestRateModel.sol";
import {Market} from "../src/markets/Market.sol";
import {MarketFactory} from "../src/markets/MarketFactory.sol";
import {MarketRegistry} from "../src/markets/MarketRegistry.sol";
import {CircuitBreaker} from "../src/security/CircuitBreaker.sol";
import {RiskManager} from "../src/security/RiskManager.sol";
import {PoolHealthMonitor} from "../src/security/PoolHealthMonitor.sol";
import {PositionViewer} from "../src/periphery/PositionViewer.sol";

/// @dev DEPRECATED — use chain-specific scripts in script/deploy/ instead.
///      Those scripts deploy TimelockController and transfer admin roles.
///      This script is kept for local development only (no timelock, no role transfer).
contract Deploy is Script {
    // Deployed contract addresses stored as state to avoid stack-too-deep
    ACLManager public aclManager;
    ProtocolCore public core;
    LPOracleHub public oracleHub;
    PositionManager public positionManager;
    LendingEngine public lendingEngine;
    LiquidationEngine public liquidationEngine;
    FeeCollector public feeCollector;
    MarketFactory public marketFactory;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        _deployCore(deployer);
        _deployProxies();
        _deploySupportContracts(deployer);
        _configureRoles();

        vm.stopBroadcast();

        _logAddresses();
    }

    function _deployCore(address deployer) internal {
        aclManager = new ACLManager(deployer);
        core = new ProtocolCore(deployer, address(aclManager));

        LPOracleHub oracleHubImpl = new LPOracleHub();
        oracleHub = LPOracleHub(
            address(new ERC1967Proxy(address(oracleHubImpl), abi.encodeCall(LPOracleHub.initialize, (address(core)))))
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

    function _deploySupportContracts(address deployer) internal {
        feeCollector = new FeeCollector(address(core), deployer, deployer);

        // Security
        CircuitBreaker cb = new CircuitBreaker(address(core));
        new RiskManager(address(core));
        new PoolHealthMonitor(address(core), address(cb));

        // Interest Rate Models
        InterestRateModel stableModel = new InterestRateModel(100, 400, 7500, 8500);
        InterestRateModel volatileModel = new InterestRateModel(200, 600, 10_000, 8000);
        InterestRateModel exoticModel = new InterestRateModel(500, 1000, 20_000, 7000);

        // Market implementation + factory
        Market marketImpl = new Market();
        marketFactory = new MarketFactory(address(core), address(marketImpl));
        new MarketRegistry(address(core));

        marketFactory.setInterestRateModel("stable", address(stableModel));
        marketFactory.setInterestRateModel("volatile", address(volatileModel));
        marketFactory.setInterestRateModel("exotic", address(exoticModel));

        // Periphery (no Router — users call contracts directly, frontend uses Multicall3)
        new PositionViewer(address(core), address(positionManager), address(lendingEngine));
    }

    function _configureRoles() internal {
        aclManager.grantRole(aclManager.LENDING_ENGINE(), address(lendingEngine));
        aclManager.grantRole(aclManager.LIQUIDATION_ENGINE(), address(liquidationEngine));
        aclManager.grantRole(aclManager.POSITION_MANAGER(), address(positionManager));
        positionManager.setLendingEngine(address(lendingEngine));
        core.setMarketFactory(address(marketFactory));
    }

    function _logAddresses() internal view {
        console.log("=== LiquidLP Protocol Deployed (UUPS + ACLManager) ===");
        console.log("");
        console.log("--- ACL ---");
        console.log("ACLManager:             ", address(aclManager));
        console.log("");
        console.log("--- Core (not proxied) ---");
        console.log("ProtocolCore:           ", address(core));
        console.log("");
        console.log("--- Proxied (UUPS) ---");
        console.log("LPOracleHub proxy:      ", address(oracleHub));
        console.log("PositionManager proxy:  ", address(positionManager));
        console.log("LendingEngine proxy:    ", address(lendingEngine));
        console.log("LiquidationEngine proxy:", address(liquidationEngine));
        console.log("");
        console.log("--- Not proxied ---");
        console.log("FeeCollector:           ", address(feeCollector));
        console.log("MarketFactory:          ", address(marketFactory));
    }
}
