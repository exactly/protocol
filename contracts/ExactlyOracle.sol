// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { AggregatorV2V3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";
import { Market } from "./Market.sol";

/// @title ExactlyOracle
/// @notice Proxy to get the price of an asset from a price source (Chainlink Price Feed Aggregator).
contract ExactlyOracle is AccessControl {
  /// @notice Auditor's target precision.
  uint256 public constant TARGET_DECIMALS = 18;
  /// @notice Chainlink's Price Feed precision when using USD as the base currency.
  uint256 public constant ORACLE_DECIMALS = 8;

  /// @notice Chainlink's price feed aggregator addresses by market.
  mapping(Market => AggregatorV2V3Interface) public priceFeeds;

  /// @notice Constructor.
  constructor() {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }

  /// @notice Gets an asset price by Market.
  /// @dev If Chainlink's asset price is <= 0 or the updatedAt time is outdated the call is reverted.
  /// @param market address of the asset.
  /// @return The price of the asset scaled to 18-digit decimals.
  function assetPrice(Market market) public view returns (uint256) {
    int256 price = priceFeeds[market].latestAnswer();
    if (price <= 0) revert InvalidPrice();
    // scale price to 18 decimals
    return uint256(price) * 10**(TARGET_DECIMALS - ORACLE_DECIMALS);
  }

  /// @notice Sets the Chainlink Price Feed Aggregator source for an asset.
  /// @param market market address of the asset.
  /// @param source address of Chainlink's Price Feed aggregator used to query the asset price in USD.
  function setPriceFeed(Market market, AggregatorV2V3Interface source) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (source.decimals() != ORACLE_DECIMALS) revert InvalidSource();
    priceFeeds[market] = source;
    emit PriceFeedSet(market, source);
  }

  /// @notice Emitted when a market and source is changed by admin.
  /// @param market address of the asset used to get the price from this oracle.
  /// @param source address of Chainlink's Price Feed aggregator used to query the asset price in USD.
  event PriceFeedSet(Market indexed market, AggregatorV2V3Interface indexed source);
}

error InvalidPrice();
error InvalidSource();
