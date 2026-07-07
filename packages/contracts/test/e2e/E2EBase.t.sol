// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../helpers/ForkTestBase.sol";
import {INonfungiblePositionManager, IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3.sol";
import {IUniswapV2Pair, IUniswapV2Router} from "../../src/interfaces/external/IUniswapV2.sol";
import {ILPOracleHub} from "../../src/interfaces/ILPOracleHub.sol";

/// @title E2EBase
/// @notice Base for end-to-end fork tests. Deploys full protocol + creates real LP positions.
/// @dev Inherits ForkTestBase (deploys all contracts). Adds helpers to create real V2/V3 positions.
///
///      Test accounts:
///        alice    — borrower (deposits LP, borrows)
///        bob      — lender (supplies USDC to market)
///        liquidator — liquidates underwater positions
///
///      LP positions are created against real Uniswap on forked mainnet.
abstract contract E2EBase is ForkTestBase {
    // V3 position helpers
    INonfungiblePositionManager public nftManager;

    // Funded test amounts
    uint256 constant ALICE_ETH = 10 ether;
    uint256 constant ALICE_USDC = 50_000e6;
    uint256 constant BOB_USDC = 100_000e6;
    uint256 constant LIQUIDATOR_USDC = 50_000e6;

    function setUp() public virtual override {
        super.setUp();
        nftManager = INonfungiblePositionManager(Constants.UNI_V3_NFT_MANAGER);

        // Fork may have stale Chainlink data — increase oracle staleness tolerance
        vm.startPrank(deployer);
        v3Oracle.setMaxStaleness(86_400); // 24h for fork testing
        v2Oracle.setMaxStaleness(86_400);
        priceFeedRegistry.setMaxStaleness(86_400);
        vm.stopPrank();

        // Fund test accounts
        _fundWeth(alice, ALICE_ETH);
        _fundUsdc(alice, ALICE_USDC);
        _fundUsdc(bob, BOB_USDC);
        _fundUsdc(liquidator, LIQUIDATOR_USDC);

        // Bob supplies USDC to the market (provides borrowable liquidity)
        address marketAddr = core.markets(ethUsdcMarketId);
        vm.startPrank(bob);
        IERC20(Constants.USDC).approve(marketAddr, BOB_USDC);
        IMarket(marketAddr).supply(BOB_USDC);
        vm.stopPrank();
    }

    // ========== V3 Position Helpers ==========

    /// @notice Create a real V3 WETH/USDC position on Uniswap
    /// @param user The user who will own the position
    /// @param wethAmount Amount of WETH to provide
    /// @param usdcAmount Amount of USDC to provide
    /// @return tokenId The V3 NFT position ID
    function _createV3Position(address user, uint256 wethAmount, uint256 usdcAmount)
        internal
        returns (uint256 tokenId)
    {
        vm.startPrank(user);

        IERC20(Constants.WETH).approve(address(nftManager), wethAmount);
        IERC20(Constants.USDC).approve(address(nftManager), usdcAmount);

        // Get current tick to create an in-range position
        IUniswapV3Pool pool = IUniswapV3Pool(Constants.UNI_V3_WETH_USDC_3000);
        (, int24 currentTick,,,,,) = pool.slot0();

        // Round tick to spacing (60 for 0.3% fee tier)
        int24 spacing = 60;
        int24 tickLower = ((currentTick - 1000) / spacing) * spacing;
        int24 tickUpper = ((currentTick + 1000) / spacing) * spacing;

        // Determine token ordering (USDC is token0 in WETH/USDC pool)
        address token0 = Constants.USDC < Constants.WETH ? Constants.USDC : Constants.WETH;
        address token1 = Constants.USDC < Constants.WETH ? Constants.WETH : Constants.USDC;
        uint256 amount0 = token0 == Constants.USDC ? usdcAmount : wethAmount;
        uint256 amount1 = token0 == Constants.USDC ? wethAmount : usdcAmount;

        (tokenId,,,) = nftManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: user,
                deadline: block.timestamp + 300
            })
        );

        vm.stopPrank();
    }

    /// @notice Deposit a V3 position into the protocol
    /// @return positionId The protocol position ID
    function _depositV3(address user, uint256 tokenId) internal returns (uint256 positionId) {
        vm.startPrank(user);

        // Approve NFT transfer to PositionManager (via adapter)
        nftManager.approve(address(v3Adapter), tokenId);

        // Deposit into protocol
        positionId = positionManager.deposit(Constants.UNI_V3_NFT_MANAGER, tokenId, 0, ethUsdcMarketId);

        vm.stopPrank();
    }

    // ========== V2 Position Helpers ==========

    /// @notice Create a real V2 WETH/USDC LP position
    /// @return lpAmount Amount of LP tokens received
    function _createV2Position(
        address user,
        uint256 wethAmount,
        uint256 usdcAmount
    )
        internal
        returns (uint256 lpAmount)
    {
        vm.startPrank(user);

        IUniswapV2Router router = IUniswapV2Router(Constants.UNI_V2_ROUTER);
        IERC20(Constants.WETH).approve(address(router), wethAmount);
        IERC20(Constants.USDC).approve(address(router), usdcAmount);

        (,, lpAmount) = router.addLiquidity(
            Constants.WETH, Constants.USDC, wethAmount, usdcAmount, 0, 0, user, block.timestamp + 300
        );

        vm.stopPrank();
    }

    /// @notice Deposit V2 LP tokens into the protocol
    /// @param marketId The market to deposit into (caller must pass the correct V2 market)
    function _depositV2(address user, uint256 lpAmount, uint256 marketId) internal returns (uint256 positionId) {
        vm.startPrank(user);

        IUniswapV2Pair pair = IUniswapV2Pair(Constants.UNI_V2_WETH_USDC);
        pair.approve(address(v2Adapter), lpAmount);

        positionId = positionManager.deposit(Constants.UNI_V2_WETH_USDC, 0, lpAmount, marketId);

        vm.stopPrank();
    }

    // ========== Price Manipulation Helpers ==========

    /// @notice Mock oracleHub.getPrice to return a specific USD value
    /// @dev Bypasses TWAP/Chainlink deviation checks — use for liquidation tests
    function _mockOraclePrice(
        address lpToken,
        uint256 tokenId,
        uint256 amount,
        ILPAdapter.LPType lpType,
        uint256 valueUsd
    ) internal {
        vm.mockCall(
            address(oracleHub),
            abi.encodeWithSelector(
                ILPOracleHub.getPrice.selector,
                lpToken, tokenId, amount, lpType
            ),
            abi.encode(
                ILPOracleHub.PriceResult({
                    totalValue: valueUsd,
                    principalValue: valueUsd,
                    feeValue: 0,
                    haircut: 700,
                    confidence: 9500,
                    timestamp: block.timestamp
                })
            )
        );
    }

    // ========== View Helpers ==========

    function _getDebt(uint256 positionId) internal view returns (uint256) {
        return lendingEngine.getDebt(positionId);
    }

    function _getPositionValue(uint256 positionId) internal view returns (uint256) {
        return positionManager.getPositionValue(positionId);
    }

    function _getHealthFactor(uint256 positionId) internal view returns (uint256) {
        return positionManager.getHealthFactor(positionId);
    }
}

// V3 pool slot0 is already in IUniswapV3Pool (src/interfaces/external/IUniswapV3.sol)
// V2 router addLiquidity is already in IUniswapV2Router (src/interfaces/external/IUniswapV2.sol)
