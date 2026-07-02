// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";

/// @title ProtocolCore
/// @notice Central registry and access control for the LiquidLP protocol
/// @dev All core contracts reference this for shared state and permissions.
///      Not proxied — this IS the root of trust. owner = DAO multisig.
///      Adapter/oracle registrations are sparse — maxRegisteredLPType may exceed
///      the number of active adapters. Downstream code handles zero addresses.
contract ProtocolCore {
    // --- Roles ---
    address public owner;
    address public pendingOwner; // Two-step ownership transfer
    address public guardian;
    mapping(address => bool) public keepers;

    // --- Registry ---
    mapping(ILPAdapter.LPType => address) public adapters;
    mapping(ILPAdapter.LPType => address) public oracles;
    mapping(uint256 => address) public markets;
    mapping(address => bool) public registeredMarkets; // duplicate protection
    uint256 public nextMarketId;
    address public marketFactory;

    /// @notice Highest LP type index with a registered adapter
    /// @dev Used by PositionManager._detectLPType to avoid hardcoded loop bounds.
    ///      Only increases — sparse enum slots with no adapter are handled downstream.
    uint8 public maxRegisteredLPType;

    // --- Protocol State ---
    bool public paused;
    mapping(address => bool) public supportedPools;
    mapping(address => uint256) public poolAddedAt;

    // --- Events ---
    event AdapterRegistered(ILPAdapter.LPType indexed lpType, address indexed adapter);
    event OracleRegistered(ILPAdapter.LPType indexed lpType, address indexed oracle);
    event MarketRegistered(uint256 indexed marketId, address indexed market);
    event MarketFactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event PoolWhitelisted(address indexed pool);
    event PoolRemoved(address indexed pool);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferCancelled(address indexed currentOwner, address indexed cancelledPendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event KeeperUpdated(address indexed keeper, bool status);

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian || msg.sender == owner, "NOT_GUARDIAN");
        _;
    }

    constructor(address _owner, address _guardian) {
        require(_owner != address(0), "ZERO_OWNER");
        require(_guardian != address(0), "ZERO_GUARDIAN");
        owner = _owner;
        guardian = _guardian;
    }

    // --- Registry Management ---

    function registerAdapter(ILPAdapter.LPType lpType, address adapter) external onlyOwner {
        require(adapter != address(0), "ZERO_ADDRESS");
        require(adapter.code.length > 0, "NOT_CONTRACT");
        adapters[lpType] = adapter;
        if (uint8(lpType) > maxRegisteredLPType) {
            maxRegisteredLPType = uint8(lpType);
        }
        emit AdapterRegistered(lpType, adapter);
    }

    function registerOracle(ILPAdapter.LPType lpType, address oracle) external onlyOwner {
        require(oracle != address(0), "ZERO_ADDRESS");
        require(oracle.code.length > 0, "NOT_CONTRACT");
        oracles[lpType] = oracle;
        emit OracleRegistered(lpType, oracle);
    }

    function setMarketFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "ZERO_ADDRESS");
        emit MarketFactoryUpdated(marketFactory, _factory);
        marketFactory = _factory;
    }

    function registerMarket(address market) external returns (uint256 marketId) {
        require(msg.sender == owner || msg.sender == marketFactory, "NOT_AUTHORIZED");
        require(market != address(0), "ZERO_ADDRESS");
        require(market.code.length > 0, "NOT_CONTRACT");
        require(!registeredMarkets[market], "MARKET_ALREADY_REGISTERED");
        registeredMarkets[market] = true;
        marketId = nextMarketId++;
        markets[marketId] = market;
        emit MarketRegistered(marketId, market);
    }

    // --- Pool Management ---

    function whitelistPool(address pool) external onlyOwner {
        require(pool != address(0), "ZERO_ADDRESS");
        require(!supportedPools[pool], "ALREADY_WHITELISTED");
        supportedPools[pool] = true;
        poolAddedAt[pool] = block.timestamp;
        emit PoolWhitelisted(pool);
    }

    function removePool(address pool) external onlyOwner {
        require(supportedPools[pool], "NOT_WHITELISTED");
        supportedPools[pool] = false;
        emit PoolRemoved(pool);
    }

    // --- Access Control ---

    function setKeeper(address keeper, bool status) external onlyOwner {
        require(keeper != address(0), "ZERO_ADDRESS");
        keepers[keeper] = status;
        emit KeeperUpdated(keeper, status);
    }

    /// @notice Step 1: Propose new owner (two-step transfer)
    /// @dev Overwrites any existing pending transfer with a cancellation event
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_ADDRESS");
        if (pendingOwner != address(0)) {
            emit OwnershipTransferCancelled(owner, pendingOwner);
        }
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Cancel a pending ownership transfer
    function cancelOwnershipTransfer() external onlyOwner {
        require(pendingOwner != address(0), "NO_PENDING_TRANSFER");
        emit OwnershipTransferCancelled(owner, pendingOwner);
        pendingOwner = address(0);
    }

    /// @notice Step 2: New owner accepts ownership
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "NOT_PENDING_OWNER");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        require(newGuardian != address(0), "ZERO_ADDRESS");
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    // --- Emergency ---

    function pause() external onlyGuardian {
        require(!paused, "ALREADY_PAUSED");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        require(paused, "NOT_PAUSED");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // --- View ---

    function getAdapter(ILPAdapter.LPType lpType) external view returns (address) {
        address adapter = adapters[lpType];
        require(adapter != address(0), "ADAPTER_NOT_FOUND");
        return adapter;
    }

    function getOracle(ILPAdapter.LPType lpType) external view returns (address) {
        address oracle = oracles[lpType];
        require(oracle != address(0), "ORACLE_NOT_FOUND");
        return oracle;
    }

    function isPoolSupported(address pool) external view returns (bool) {
        return supportedPools[pool];
    }

    /// @notice Get pool age in seconds (returns 0 if pool is not currently supported)
    function getPoolAge(address pool) external view returns (uint256) {
        if (!supportedPools[pool]) return 0;
        uint256 addedAt = poolAddedAt[pool];
        if (addedAt == 0) return 0;
        return block.timestamp - addedAt;
    }
}
