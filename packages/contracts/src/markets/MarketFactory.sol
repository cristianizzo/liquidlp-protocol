// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {Market} from "./Market.sol";
import {InterestRateModel} from "./InterestRateModel.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title MarketFactory
/// @notice Deploys new isolated lending markets as UUPS proxies
contract MarketFactory {
    ProtocolCore public immutable core;

    /// @notice The Market implementation contract that all proxies point to
    address public marketImplementation;

    /// @notice LendingEngine address set on newly created markets
    address public lendingEngine;

    // Pre-deployed interest rate models
    mapping(string => address) public interestRateModels;

    event MarketCreated(
        uint256 indexed marketId, address proxy, address implementation, ILPAdapter.LPType lpType, address borrowAsset
    );
    event MarketImplementationUpdated(address oldImpl, address newImpl);

    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
        _;
    }

    constructor(address _core, address _marketImplementation) {
        core = ProtocolCore(_core);
        marketImplementation = _marketImplementation;
    }

    /// @notice Deploy a new lending market as a UUPS proxy
    function createMarket(
        ILPAdapter.LPType lpType,
        address borrowAsset,
        uint256 maxLtv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 haircut,
        uint256 borrowCap,
        uint256 minPoolTvl,
        uint256 minPoolAge,
        string calldata rateModelType
    )
        external
        onlyOwner
        returns (uint256 marketId, address marketAddr)
    {
        address rateModel = interestRateModels[rateModelType];
        require(rateModel != address(0), "INVALID_RATE_MODEL");
        require(marketImplementation != address(0), "NO_IMPLEMENTATION");

        IMarket.MarketConfig memory config = IMarket.MarketConfig({
            lpType: lpType,
            borrowAsset: borrowAsset,
            maxLtv: maxLtv,
            liquidationThreshold: liquidationThreshold,
            liquidationBonus: liquidationBonus,
            haircut: haircut,
            borrowCap: borrowCap,
            minPoolTvl: minPoolTvl,
            minPoolAge: minPoolAge
        });

        // Deploy ERC1967 proxy pointing to the Market implementation
        bytes memory initData = abi.encodeCall(Market.initialize, (config, rateModel, address(core), lendingEngine));
        ERC1967Proxy proxy = new ERC1967Proxy(marketImplementation, initData);
        marketAddr = address(proxy);

        // Register in core
        marketId = core.registerMarket(marketAddr);

        emit MarketCreated(marketId, marketAddr, marketImplementation, lpType, borrowAsset);
    }

    /// @notice Update the implementation for future market deployments
    /// @dev Does NOT upgrade existing markets — they keep their current impl
    function setMarketImplementation(address _impl) external onlyOwner {
        require(_impl != address(0), "ZERO_ADDRESS");
        emit MarketImplementationUpdated(marketImplementation, _impl);
        marketImplementation = _impl;
    }

    function setLendingEngine(address _lendingEngine) external onlyOwner {
        lendingEngine = _lendingEngine;
    }

    function setInterestRateModel(string calldata modelType, address model) external onlyOwner {
        interestRateModels[modelType] = model;
    }
}
