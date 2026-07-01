// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ILPOracleHub} from "../interfaces/ILPOracleHub.sol";
import {ILPOracle} from "../interfaces/ILPOracle.sol";
import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title LPOracleHub
/// @notice Central oracle router that delegates pricing to type-specific oracles
/// @dev UUPS upgradeable — referenced by PositionManager, address must stay stable
contract LPOracleHub is ILPOracleHub, Initializable, UUPSUpgradeable {
    ProtocolCore public core;

    mapping(ILPAdapter.LPType => address) public oracles;

    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _core) external initializer {
        core = ProtocolCore(_core);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @inheritdoc ILPOracleHub
    function registerOracle(ILPAdapter.LPType lpType, address oracle) external onlyOwner {
        require(oracle != address(0), "ZERO_ADDRESS");
        oracles[lpType] = oracle;
    }

    /// @inheritdoc ILPOracleHub
    function getPrice(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        ILPAdapter.LPType lpType
    )
        external
        view
        returns (PriceResult memory result)
    {
        address oracle = oracles[lpType];
        require(oracle != address(0), "NO_ORACLE");
        result = ILPOracle(oracle).getPrice(lpToken, tokenId, amount);
    }

    /// @inheritdoc ILPOracleHub
    function getRawPrice(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        ILPAdapter.LPType lpType
    )
        external
        view
        returns (uint256)
    {
        address oracle = oracles[lpType];
        require(oracle != address(0), "NO_ORACLE");
        return ILPOracle(oracle).getRawPrice(lpToken, tokenId, amount);
    }

    /// @inheritdoc ILPOracleHub
    function isOracleHealthy(ILPAdapter.LPType lpType) external view returns (bool) {
        address oracle = oracles[lpType];
        if (oracle == address(0)) return false;
        return ILPOracle(oracle).isHealthy();
    }

    // --- Storage Gap (UUPS upgrade safety) ---
    uint256[50] private __gap;
}
