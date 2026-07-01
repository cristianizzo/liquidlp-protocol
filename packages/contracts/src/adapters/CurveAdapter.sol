// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";

/// @title CurveAdapter
/// @notice Handles Curve LP token deposits, withdrawals, and unwinding
contract CurveAdapter is ILPAdapter {
    address public protocol;

    // Curve pool registry for validation
    address public immutable curveRegistry;

    modifier onlyProtocol() {
        require(msg.sender == protocol, "NOT_PROTOCOL");
        _;
    }

    constructor(address _curveRegistry, address _protocol) {
        curveRegistry = _curveRegistry;
        protocol = _protocol;
    }

    /// @inheritdoc ILPAdapter
    function validateAndLock(
        address lpToken,
        uint256, /* tokenId */
        uint256 amount,
        address from
    )
        external
        onlyProtocol
        returns (LPInfo memory info)
    {
        require(amount > 0, "ZERO_AMOUNT");

        // Verify LP token is from a registered Curve pool
        // address pool = ICurveRegistry(curveRegistry).get_pool_from_lp_token(lpToken);
        // require(pool != address(0), "INVALID_CURVE_LP");

        // Get underlying tokens
        // address[8] memory coins = ICurveRegistry(curveRegistry).get_coins(pool);

        // Transfer LP tokens from user
        // IERC20(lpToken).transferFrom(from, address(this), amount);

        // info = LPInfo({
        //     lpType: LPType.Curve,
        //     token0: coins[0],
        //     token1: coins[1],
        //     feeTier: 400, // Curve typically 0.04%
        //     tickLower: 0,
        //     tickUpper: 0,
        //     liquidity: uint128(amount),
        //     pool: pool
        // });
    }

    /// @inheritdoc ILPAdapter
    function unlock(address lpToken, uint256, uint256 amount, address to) external onlyProtocol {
        // IERC20(lpToken).transfer(to, amount);
    }

    /// @inheritdoc ILPAdapter
    function unwind(
        address lpToken,
        uint256, /* tokenId */
        uint128 liquidityToRemove
    )
        external
        onlyProtocol
        returns (uint256 amount0, uint256 amount1)
    {
        // Get pool from LP token
        // address pool = ICurveRegistry(curveRegistry).get_pool_from_lp_token(lpToken);

        // Remove liquidity — Curve uses remove_liquidity or remove_liquidity_one_coin
        // For liquidation, remove proportionally:
        // uint256[2] memory minAmounts = [uint256(0), uint256(0)];
        // ICurvePool(pool).remove_liquidity(uint256(liquidityToRemove), minAmounts);

        // Or remove as single coin (e.g., USDC) for simpler liquidation:
        // amount0 = ICurvePool(pool).remove_liquidity_one_coin(
        //     uint256(liquidityToRemove), 0, 0
        // );
    }

    /// @inheritdoc ILPAdapter
    function collectFees(address, uint256) external pure returns (uint256, uint256) {
        // Curve LP auto-compounds fees via virtual price increase
        return (0, 0);
    }

    /// @inheritdoc ILPAdapter
    function lpType() external pure returns (LPType) {
        return LPType.Curve;
    }

    /// @inheritdoc ILPAdapter
    function isSupported(address lpToken) external view returns (bool) {
        // try ICurveRegistry(curveRegistry).get_pool_from_lp_token(lpToken) returns (address pool) {
        //     return pool != address(0);
        // } catch {
        //     return false;
        // }
        return false;
    }
}
