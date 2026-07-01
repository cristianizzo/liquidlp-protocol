// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";

/// @title AerodromeAdapter
/// @notice Handles Aerodrome/Velodrome LP deposits, withdrawals, and unwinding
/// @dev Supports both V2-style (stable/volatile) and concentrated liquidity
contract AerodromeAdapter is ILPAdapter {
    address public immutable aerodromeRouter;
    address public immutable aerodromeFactory;
    address public protocol;

    modifier onlyProtocol() {
        require(msg.sender == protocol, "NOT_PROTOCOL");
        _;
    }

    constructor(address _router, address _factory, address _protocol) {
        aerodromeRouter = _router;
        aerodromeFactory = _factory;
        protocol = _protocol;
    }

    /// @inheritdoc ILPAdapter
    function validateAndLock(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        address from
    ) external onlyProtocol returns (LPInfo memory info) {
        // Aerodrome has two types:
        // 1. V2-style pools: ERC-20 LP tokens (amount > 0, tokenId == 0)
        // 2. Concentrated liquidity: ERC-721 NFTs (tokenId > 0, amount == 0)

        // Validate pool is from Aerodrome factory
        // Transfer LP token/NFT from user
        // Parse pool info (stable vs volatile, tokens, etc.)

        // Note: Do NOT include gauge-staked positions
        // User must unstake from gauge before depositing into LiquidLP
    }

    /// @inheritdoc ILPAdapter
    function unlock(address lpToken, uint256 tokenId, uint256 amount, address to) external onlyProtocol {
        // Return LP token/NFT to user
    }

    /// @inheritdoc ILPAdapter
    function unwind(
        address lpToken,
        uint256 tokenId,
        uint128 liquidityToRemove
    ) external onlyProtocol returns (uint256 amount0, uint256 amount1) {
        // For V2-style: use router.removeLiquidity()
        // For concentrated: use nftManager.decreaseLiquidity() + collect()
    }

    /// @inheritdoc ILPAdapter
    function collectFees(address lpToken, uint256 tokenId) external onlyProtocol returns (uint256, uint256) {
        // V2-style: fees auto-compound (return 0,0)
        // Concentrated: collect via NFT manager
        return (0, 0);
    }

    /// @inheritdoc ILPAdapter
    function lpType() external pure returns (LPType) {
        return LPType.Aerodrome;
    }

    /// @inheritdoc ILPAdapter
    function isSupported(address lpToken) external view returns (bool) {
        // Check if lpToken is a pool created by the Aerodrome factory
        // In production, query: IAerodromeFactory(aerodromeFactory).isPool(lpToken)
        // For now, return false until wired to mainnet factory
        return false;
    }
}
