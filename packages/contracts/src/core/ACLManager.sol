// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ACLManager
/// @notice Role-based access control for the LiquidLP protocol (Aave V3 pattern)
/// @dev Extends OZ AccessControl. Single source of truth for all permissions.
///      Deployed once, referenced by all contracts via ProtocolCore.aclManager().
///      DEFAULT_ADMIN_ROLE holder (owner multisig, later timelock) can grant/revoke all roles.
contract ACLManager is AccessControl {
    // --- Admin Roles (humans / multisigs / governance) ---
    bytes32 public constant POOL_ADMIN = keccak256("POOL_ADMIN");
    bytes32 public constant EMERGENCY_ADMIN = keccak256("EMERGENCY_ADMIN");
    bytes32 public constant RISK_ADMIN = keccak256("RISK_ADMIN");

    // --- Contract Roles (protocol contracts only) ---
    bytes32 public constant LENDING_ENGINE = keccak256("LENDING_ENGINE");
    bytes32 public constant LIQUIDATION_ENGINE = keccak256("LIQUIDATION_ENGINE");
    bytes32 public constant POSITION_MANAGER = keccak256("POSITION_MANAGER");
    bytes32 public constant KEEPER = keccak256("KEEPER");

    constructor(address admin) {
        require(admin != address(0), "ZERO_ADMIN");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POOL_ADMIN, admin);
    }

    // --- Pool Admin ---
    function addPoolAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "ZERO_ADDRESS");
        grantRole(POOL_ADMIN, admin);
    }

    function removePoolAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(POOL_ADMIN, admin);
    }

    function isPoolAdmin(address admin) external view returns (bool) {
        return hasRole(POOL_ADMIN, admin);
    }

    // --- Emergency Admin ---
    function addEmergencyAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "ZERO_ADDRESS");
        grantRole(EMERGENCY_ADMIN, admin);
    }

    function removeEmergencyAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(EMERGENCY_ADMIN, admin);
    }

    function isEmergencyAdmin(address admin) external view returns (bool) {
        return hasRole(EMERGENCY_ADMIN, admin);
    }

    // --- Risk Admin ---
    function addRiskAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "ZERO_ADDRESS");
        grantRole(RISK_ADMIN, admin);
    }

    function removeRiskAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(RISK_ADMIN, admin);
    }

    function isRiskAdmin(address admin) external view returns (bool) {
        return hasRole(RISK_ADMIN, admin);
    }

    // --- Contract Roles (granted during deployment) ---
    function isLendingEngine(address addr) external view returns (bool) {
        return hasRole(LENDING_ENGINE, addr);
    }

    function isLiquidationEngine(address addr) external view returns (bool) {
        return hasRole(LIQUIDATION_ENGINE, addr);
    }

    function isPositionManager(address addr) external view returns (bool) {
        return hasRole(POSITION_MANAGER, addr);
    }

    function isKeeper(address addr) external view returns (bool) {
        return hasRole(KEEPER, addr);
    }

    /// @notice Override renounceRole to prevent bricking — cannot renounce DEFAULT_ADMIN_ROLE
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        require(role != DEFAULT_ADMIN_ROLE, "CANNOT_RENOUNCE_ADMIN");
        super.renounceRole(role, callerConfirmation);
    }

    /// @notice Override revokeRole to prevent bricking — cannot revoke last DEFAULT_ADMIN_ROLE
    /// @dev An admin revoking their own admin role would also brick the protocol
    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (role == DEFAULT_ADMIN_ROLE) {
            // If revoking from self, ensure at least one other admin exists
            // We can't easily count role members without AccessControlEnumerable,
            // so we block self-revoke of DEFAULT_ADMIN_ROLE entirely
            require(account != msg.sender, "CANNOT_SELF_REVOKE_ADMIN");
        }
        super.revokeRole(role, account);
    }
}
