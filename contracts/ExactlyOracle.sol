// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import { FixedLender } from "./FixedLender.sol";

/// @title ExactlyOracle
/// @notice Proxy to get the price of an asset from a price source (Chainlink Price Feed Aggregator).
contract ExactlyOracle is AccessControl {
  /// @notice Auditor's target precision.
  uint256 public constant TARGET_DECIMALS = 18;
  /// @notice Chainlink's Price Feed precision when using USD as the base currency.
  uint256 public constant ORACLE_DECIMALS = 8;

  mapping(FixedLender => AggregatorV3Interface) public assetsSources;
  uint256 public immutable maxDelayTime;

  /// @notice Emitted when a FixedLender and source is changed by admin.
  /// @param fixedLender address of the asset used to get the price from this oracle.
  /// @param source address of Chainlink's Price Feed aggregator used to query the asset price in USD.
  event AssetSourceUpdated(FixedLender indexed fixedLender, AggregatorV3Interface indexed source);

  /// @notice Constructor.
  /// @param maxDelayTime_ The max delay time for Chainlink's prices to be considered as updated.
  constructor(uint256 maxDelayTime_) {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    maxDelayTime = maxDelayTime_;
  }

  /// @notice Sets the Chainlink Price Feed Aggregator source for an asset.
  /// @param fixedLender The FixedLender address of the asset.
  /// @param source address of Chainlink's Price Feed aggregator used to query the asset price in USD.
  function setAssetSource(FixedLender fixedLender, AggregatorV3Interface source) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (source.decimals() != ORACLE_DECIMALS) revert InvalidSource();
    assetsSources[fixedLender] = source;
    emit AssetSourceUpdated(fixedLender, source);
  }

  /// @notice Gets an asset price by FixedLender.
  /// @dev If Chainlink's asset price is <= 0 or the updatedAt time is outdated the call is reverted.
  /// @param fixedLender The FixedLender address of the asset.
  /// @return The price of the asset scaled to 18-digit decimals.
  function getAssetPrice(FixedLender fixedLender) public view returns (uint256) {
    (, int256 price, , uint256 updatedAt, ) = assetsSources[fixedLender].latestRoundData();
    if (price > 0 && updatedAt >= block.timestamp - maxDelayTime) return scaleOraclePriceByDigits(uint256(price));
    else revert InvalidPrice();
  }

  /// @notice Scale the price returned by the oracle to an 18-digit decimal to be used by the Auditor.
  /// @param price The price to be scaled.
  /// @return The price of the asset scaled to 18-digit decimals.
  function scaleOraclePriceByDigits(uint256 price) internal pure returns (uint256) {
    return price * 10**(TARGET_DECIMALS - ORACLE_DECIMALS);
  }
}

error InvalidPrice();
error InvalidSource();
