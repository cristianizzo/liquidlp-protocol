// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";

/// @notice Chainlink AggregatorV3 minimal interface
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @title PriceFeedRegistry
/// @notice Chainlink price feed registry for any token → USD price
/// @dev Used by PositionManager and LendingEngine to convert debt amounts to USD.
///      Returns prices normalized to 18 decimals.
///      Same pattern as Aave's AaveOracle: token → Chainlink feed → USD price.
contract PriceFeedRegistry {
    ProtocolCore public immutable core;

    mapping(address => address) public priceFeeds; // token → Chainlink feed
    uint256 public maxStaleness = 3600; // 1 hour

    event PriceFeedUpdated(address indexed token, address indexed feed);
    event MaxStalenessUpdated(uint256 oldValue, uint256 newValue);

    modifier onlyOwner() {
        require(msg.sender == core.owner(), "NOT_OWNER");
        _;
    }

    constructor(address _core) {
        require(_core != address(0), "ZERO_CORE");
        core = ProtocolCore(_core);
    }

    /// @notice Set Chainlink price feed for a token
    function setPriceFeed(address token, address feed) external onlyOwner {
        require(token != address(0) && feed != address(0), "ZERO_ADDRESS");
        require(feed.code.length > 0, "NOT_CONTRACT");
        priceFeeds[token] = feed;
        emit PriceFeedUpdated(token, feed);
    }

    /// @notice Set max staleness for price feeds
    function setMaxStaleness(uint256 _maxStaleness) external onlyOwner {
        require(_maxStaleness >= 300 && _maxStaleness <= 86_400, "OUT_OF_BOUNDS");
        emit MaxStalenessUpdated(maxStaleness, _maxStaleness);
        maxStaleness = _maxStaleness;
    }

    /// @notice Get token price in USD (18 decimals)
    /// @param token Token address
    /// @return price USD price normalized to 18 decimals
    function getPrice(address token) public view returns (uint256 price) {
        address feed = priceFeeds[token];
        require(feed != address(0), "NO_PRICE_FEED");

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(feed).latestRoundData();
        require(answer > 0, "INVALID_PRICE");
        require(updatedAt > 0 && answeredInRound >= roundId, "STALE_ROUND");
        require(block.timestamp >= updatedAt && block.timestamp - updatedAt <= maxStaleness, "STALE_PRICE");

        uint8 feedDecimals = IAggregatorV3(feed).decimals();
        require(feedDecimals <= 36, "INVALID_FEED_DECIMALS");
        if (feedDecimals < 18) {
            price = Math.mulDiv(uint256(answer), 10 ** (18 - feedDecimals), 1);
        } else if (feedDecimals > 18) {
            price = uint256(answer) / (10 ** (feedDecimals - 18));
        } else {
            price = uint256(answer);
        }
    }

    /// @notice Convert a token amount to USD value (18 decimals)
    /// @param token Token address
    /// @param amount Token amount in native decimals
    /// @param tokenDecimals Token's decimal count (must be <= 36)
    /// @return usdValue USD value in 18 decimals
    function getUsdValue(address token, uint256 amount, uint8 tokenDecimals) external view returns (uint256 usdValue) {
        require(tokenDecimals <= 36, "INVALID_DECIMALS");
        uint256 price = getPrice(token);
        usdValue = Math.mulDiv(amount, price, 10 ** tokenDecimals);
    }
}
