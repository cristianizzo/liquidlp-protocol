// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILPAdapter} from "../../src/interfaces/ILPAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @notice Mock adapter for testing PositionManager
contract MockLPAdapter is ILPAdapter {
    ILPAdapter.LPType public immutable _lpType;
    mapping(address => bool) public supportedTokens;
    bool public shouldRevert;

    // Configurable return values
    address public token0Return = address(0x1111);
    address public token1Return = address(0x2222);
    uint256 public unwindAmount0 = 1 ether;
    uint256 public unwindAmount1 = 2000e6;

    // Track calls for verification
    uint256 public lockCallCount;
    uint256 public unlockCallCount;

    constructor(ILPAdapter.LPType lpType_) {
        _lpType = lpType_;
    }

    function setTokenReturns(address _token0, address _token1) external {
        token0Return = _token0;
        token1Return = _token1;
    }

    function setUnwindAmounts(uint256 _amount0, uint256 _amount1) external {
        unwindAmount0 = _amount0;
        unwindAmount1 = _amount1;
    }

    function setSupportedToken(address token, bool supported) external {
        supportedTokens[token] = supported;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function validateAndLock(address lpToken, uint256, uint256, address)
        external
        override
        returns (LPInfo memory info)
    {
        require(!shouldRevert, "MOCK_REVERT");
        lockCallCount++;
        info = LPInfo({
            lpType: _lpType,
            token0: token0Return,
            token1: token1Return,
            feeTier: 3000,
            tickLower: -887_220,
            tickUpper: 887_220,
            liquidity: 1_000_000,
            pool: lpToken
        });
    }

    function unlock(address, uint256, uint256, address) external override {
        require(!shouldRevert, "MOCK_REVERT");
        unlockCallCount++;
    }

    /// @notice Total liquidity the position has (set to match deposit amount for scaling)
    uint256 public totalLiquidity = 100e18;

    function setTotalLiquidity(uint256 _total) external {
        totalLiquidity = _total;
    }

    function unwind(address, uint256, uint128 liquidityToRemove)
        external
        override
        returns (uint256 out0, uint256 out1)
    {
        // Scale output proportionally to liquidity removed (realistic behavior)
        if (totalLiquidity > 0) {
            out0 = (unwindAmount0 * uint256(liquidityToRemove)) / totalLiquidity;
            out1 = (unwindAmount1 * uint256(liquidityToRemove)) / totalLiquidity;
        } else {
            out0 = unwindAmount0;
            out1 = unwindAmount1;
        }

        // Transfer tokens to caller
        if (out0 > 0 && token0Return != address(0)) {
            IERC20(token0Return).transfer(msg.sender, out0);
        }
        if (out1 > 0 && token1Return != address(0)) {
            IERC20(token1Return).transfer(msg.sender, out1);
        }
    }

    function collectFees(address, uint256) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function lpType() external view override returns (LPType) {
        return _lpType;
    }

    function isSupported(address lpToken) external view override returns (bool) {
        return supportedTokens[lpToken];
    }
}
