// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionManager} from "../core/PositionManager.sol";
import {LendingEngine} from "../core/LendingEngine.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title PositionViewer
/// @notice Read-only view functions for the frontend — batch queries for gas efficiency
contract PositionViewer {
    ProtocolCore public immutable core;
    PositionManager public immutable positionManager;
    LendingEngine public immutable lendingEngine;

    struct PositionView {
        uint256 id;
        address owner;
        address lpToken;
        uint256 tokenId;
        uint256 amount;
        uint8 lpType;
        uint8 status;
        uint256 collateralValue;
        uint256 debt;
        uint256 healthFactor;
        uint256 maxBorrow;
        uint256 availableToBorrow;
    }

    struct MarketView {
        uint256 id;
        uint8 lpType;
        address borrowAsset;
        uint256 totalSupply;
        uint256 totalBorrow;
        uint256 utilization;
        uint256 supplyRateAPR;
        uint256 borrowRateAPR;
        uint256 maxLtv;
    }

    constructor(address _core, address _positionManager, address _lendingEngine) {
        core = ProtocolCore(_core);
        positionManager = PositionManager(_positionManager);
        lendingEngine = LendingEngine(_lendingEngine);
    }

    /// @notice Get all positions for a user with full details
    function getUserPositions(address user) external view returns (PositionView[] memory) {
        uint256[] memory ids = positionManager.getPositionsByOwner(user);
        PositionView[] memory views = new PositionView[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            views[i] = getPositionView(ids[i]);
        }

        return views;
    }

    /// @notice Get detailed view of a single position
    function getPositionView(uint256 positionId) public view returns (PositionView memory view_) {
        PositionManager.Position memory pos = positionManager.getPosition(positionId);
        uint256 collateralValue = positionManager.getPositionValue(positionId);
        uint256 debt = lendingEngine.getDebt(positionId);
        uint256 healthFactor = positionManager.getHealthFactor(positionId);
        uint256 maxBorrow = lendingEngine.getMaxBorrow(positionId);

        view_ = PositionView({
            id: pos.id,
            owner: pos.owner,
            lpToken: pos.lpToken,
            tokenId: pos.tokenId,
            amount: pos.amount,
            lpType: uint8(pos.lpType),
            status: uint8(pos.status),
            collateralValue: collateralValue,
            debt: debt,
            healthFactor: healthFactor,
            maxBorrow: maxBorrow,
            availableToBorrow: maxBorrow > debt ? maxBorrow - debt : 0
        });
    }

    /// @notice Get market overview data
    function getMarketView(uint256 marketId) external view returns (MarketView memory) {
        address marketAddr = core.markets(marketId);
        IMarket market = IMarket(marketAddr);
        IMarket.MarketConfig memory config = market.getConfig();
        IMarket.MarketState memory state = market.getMarketState();

        return MarketView({
            id: marketId,
            lpType: uint8(config.lpType),
            borrowAsset: config.borrowAsset,
            totalSupply: state.totalSupply,
            totalBorrow: state.totalBorrow,
            utilization: state.utilization,
            supplyRateAPR: state.supplyRate,
            borrowRateAPR: state.borrowRate,
            maxLtv: config.maxLtv
        });
    }
}
