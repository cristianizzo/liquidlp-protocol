// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolCore} from "../core/ProtocolCore.sol";
import {ACLManager} from "../core/ACLManager.sol";

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
    mapping(address => uint8) public feedDecimals; // feed → cached decimals
    uint256 public maxStaleness = 3600; // 1 hour

    event PriceFeedUpdated(address indexed token, address indexed feed);
    event MaxStalenessUpdated(uint256 oldValue, uint256 newValue);

    modifier onlyPoolAdmin() {
        require(core.aclManager().isPoolAdmin(msg.sender), "NOT_POOL_ADMIN");
        _;
    }

    constructor(address _core) {
        require(_core != address(0), "ZERO_CORE");
        require(_core.code.length > 0, "NOT_CONTRACT");
        core = ProtocolCore(_core);
    }

    /// @notice Set Chainlink price feed for a token
    /// @dev Validates the feed is callable and returns sane data before registering
    function setPriceFeed(address token, address feed) external onlyPoolAdmin {
        require(token != address(0) && feed != address(0), "ZERO_ADDRESS");
        require(feed.code.length > 0, "NOT_CONTRACT");

        // Validate feed works and has valid decimals
        uint8 dec = IAggregatorV3(feed).decimals();
        require(dec <= 36, "INVALID_FEED_DECIMALS");

        // Validate feed returns a positive price (catch misconfigured feeds early)
        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        require(answer > 0, "INVALID_FEED_PRICE");

        priceFeeds[token] = feed;
        feedDecimals[feed] = dec;
        emit PriceFeedUpdated(token, feed);
    }

    /// @notice Set max staleness for price feeds
    function setMaxStaleness(uint256 _maxStaleness) external onlyPoolAdmin {
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

        uint8 dec = feedDecimals[feed];
        if (dec < 18) {
            price = Math.mulDiv(uint256(answer), 10 ** (18 - dec), 1);
        } else if (dec > 18) {
            price = Math.mulDiv(uint256(answer), 1, 10 ** (dec - 18));
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
