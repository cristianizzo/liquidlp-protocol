// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

/// @title CurveAdapter
/// @notice Handles Curve LP token deposits, withdrawals, and unwinding
contract CurveAdapter is ILPAdapter {
    ProtocolCore public immutable core;
    address public immutable curveRegistry;

    function _acl() internal view returns (ACLManager) {
        return core.aclManager();
    }

    modifier onlyProtocol() {
        ACLManager acl = _acl();
        require(acl.isPositionManager(msg.sender) || acl.isLiquidationEngine(msg.sender), "NOT_AUTHORIZED");
        _;
    }

    constructor(address _curveRegistry, address _core) {
        require(_curveRegistry != address(0) && _core != address(0), "ZERO_ADDRESS");
        curveRegistry = _curveRegistry;
        core = ProtocolCore(_core);
    }

    /// @inheritdoc ILPAdapter
    function validateAndLock(
        address lpToken,
        uint256,
        uint256 amount,
        address from
    )
        external
        onlyProtocol
        returns (LPInfo memory info)
    {
        require(amount > 0, "ZERO_AMOUNT");
        // TODO: Curve implementation
    }

    /// @inheritdoc ILPAdapter
    function unlock(address lpToken, uint256, uint256 amount, address to) external onlyProtocol {
        // TODO: Curve implementation
    }

    /// @inheritdoc ILPAdapter
    function unwind(
        address lpToken,
        uint256,
        uint128 liquidityToRemove
    )
        external
        onlyProtocol
        returns (uint256 amount0, uint256 amount1)
    {
        // TODO: Curve implementation
    }

    /// @inheritdoc ILPAdapter
    function collectFees(address, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    /// @inheritdoc ILPAdapter
    function lpType() external pure returns (LPType) {
        return LPType.Curve;
    }

    /// @inheritdoc ILPAdapter
    function isSupported(address) external pure returns (bool) {
        return false; // TODO: implement
    }
}
