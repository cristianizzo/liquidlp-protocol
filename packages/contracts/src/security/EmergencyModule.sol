// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @title EmergencyModule
/// @notice Guardian-controlled emergency actions with configurable timelock
contract EmergencyModule {
    ProtocolCore public immutable core;

    // --- Configurable Parameters ---
    uint256 public timelockDelay = 48 hours;

    // --- Absolute Bounds ---
    uint256 public constant MIN_TIMELOCK_DELAY = 6 hours;
    uint256 public constant MAX_TIMELOCK_DELAY = 14 days;

    struct TimelockAction {
        bytes32 actionHash;
        uint256 executeAfter;
        bool executed;
    }

    mapping(bytes32 => TimelockAction) public timelockActions;

    event EmergencyPauseAll(address indexed by);
    event ActionQueued(bytes32 indexed actionHash, uint256 executeAfter);
    event ActionExecuted(bytes32 indexed actionHash);
    event ActionCancelled(bytes32 indexed actionHash);
    event TimelockDelayUpdated(uint256 oldDelay, uint256 newDelay);

    modifier onlyGuardian() {
        require(msg.sender == core.guardian() || msg.sender == core.owner(), "NOT_GUARDIAN");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
        _;
    }

    constructor(address _core) {
        core = ProtocolCore(_core);
    }

    // --- Admin ---

    /// @notice Update the timelock delay. This change is itself timelocked.
    /// @dev Must queue via queueAction first, then call this after delay passes.
    function setTimelockDelay(uint256 _delay) external onlyOwner {
        require(_delay >= MIN_TIMELOCK_DELAY, "BELOW_MIN");
        require(_delay <= MAX_TIMELOCK_DELAY, "ABOVE_MAX");

        // Changing timelock delay must itself go through the current timelock
        bytes32 actionHash = keccak256(abi.encode("setTimelockDelay", _delay));
        TimelockAction storage action = timelockActions[actionHash];
        require(action.executeAfter > 0, "NOT_QUEUED");
        require(block.timestamp >= action.executeAfter, "TIMELOCK_NOT_EXPIRED");
        require(!action.executed, "ALREADY_EXECUTED");

        action.executed = true;
        emit TimelockDelayUpdated(timelockDelay, _delay);
        timelockDelay = _delay;
    }

    // --- Emergency ---

    /// @notice Emergency: pause entire protocol immediately (no timelock)
    function emergencyPauseAll() external onlyGuardian {
        core.pause();
        emit EmergencyPauseAll(msg.sender);
    }

    // --- Timelock ---

    /// @notice Queue a timelocked action
    function queueAction(bytes32 actionHash) external onlyOwner {
        timelockActions[actionHash] =
            TimelockAction({actionHash: actionHash, executeAfter: block.timestamp + timelockDelay, executed: false});
        emit ActionQueued(actionHash, block.timestamp + timelockDelay);
    }

    /// @notice Execute a queued action after timelock expires
    function executeAction(bytes32 actionHash) external onlyOwner {
        TimelockAction storage action = timelockActions[actionHash];
        require(action.executeAfter > 0, "NOT_QUEUED");
        require(block.timestamp >= action.executeAfter, "TIMELOCK_NOT_EXPIRED");
        require(!action.executed, "ALREADY_EXECUTED");

        action.executed = true;
        emit ActionExecuted(actionHash);
    }

    /// @notice Cancel a queued action
    function cancelAction(bytes32 actionHash) external onlyOwner {
        delete timelockActions[actionHash];
        emit ActionCancelled(actionHash);
    }
}
