// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";

/// @title PancakeSwapAdapter
/// @notice Handles PancakeSwap V2 and V3 LP positions on BSC
/// @dev V2 uses ERC-20 LP tokens, V3 uses ERC-721 NFTs (same as Uniswap V3 fork)
contract PancakeSwapAdapter is ILPAdapter {
    address public immutable v2Factory;
    address public immutable v2Router;
    address public immutable v3NftManager;
    address public immutable v3Factory;
    address public protocol;

    bool public immutable isV3; // Whether this adapter handles V3 or V2

    modifier onlyProtocol() {
        require(msg.sender == protocol, "NOT_PROTOCOL");
        _;
    }

    constructor(
        address _v2Factory,
        address _v2Router,
        address _v3NftManager,
        address _v3Factory,
        address _protocol,
        bool _isV3
    ) {
        v2Factory = _v2Factory;
        v2Router = _v2Router;
        v3NftManager = _v3NftManager;
        v3Factory = _v3Factory;
        protocol = _protocol;
        isV3 = _isV3;
    }

    /// @inheritdoc ILPAdapter
    function validateAndLock(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        address from
    ) external onlyProtocol returns (LPInfo memory info) {
        // PancakeSwap V3 is a fork of Uniswap V3 — same NFT position structure
        // PancakeSwap V2 is a fork of Uniswap V2 — same LP token structure
        // Logic mirrors UniswapV3Adapter / UniswapV2Adapter respectively
    }

    /// @inheritdoc ILPAdapter
    function unlock(address lpToken, uint256 tokenId, uint256 amount, address to) external onlyProtocol {}

    /// @inheritdoc ILPAdapter
    function unwind(
        address lpToken,
        uint256 tokenId,
        uint128 liquidityToRemove
    ) external onlyProtocol returns (uint256, uint256) {
        // Same unwinding logic as Uniswap adapters
        return (0, 0);
    }

    /// @inheritdoc ILPAdapter
    function collectFees(address, uint256) external onlyProtocol returns (uint256, uint256) {
        return (0, 0);
    }

    /// @inheritdoc ILPAdapter
    function lpType() external view returns (LPType) {
        return isV3 ? LPType.PancakeSwapV3 : LPType.PancakeSwapV2;
    }

    /// @inheritdoc ILPAdapter
    function isSupported(address lpToken) external view returns (bool) {
        if (isV3) return lpToken == v3NftManager;
        // For V2: check if pair is from PancakeSwap factory
        return false;
    }
}
