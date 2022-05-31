// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FeedRegistryInterface } from "@chainlink/contracts/src/v0.8/interfaces/FeedRegistryInterface.sol";
import { FixedLender } from "./FixedLender.sol";

/// @title ExactlyOracle
/// @notice Proxy to get the price of an asset from a price source, with Chainlink Feed Registry as the primary option.
contract ExactlyOracle is AccessControl {
  /// @notice Auditor's target precision.
  uint256 public constant TARGET_DECIMALS = 18;
  /// @notice Chainlink's Feed Registry price precision when using USD as the base currency.
  uint256 public constant ORACLE_DECIMALS = 8;
  /// @notice USD base currency to be used when fetching prices from Chainlink's Feed Registry.
  address public constant BASE_CURRENCY = 0x0000000000000000000000000000000000000348;

  mapping(FixedLender => address) public assetsSources;
  FeedRegistryInterface public chainlinkFeedRegistry;
  uint256 public immutable maxDelayTime;

  /// @notice Emitted when a FixedLender and source is changed by admin.
  /// @param fixedLender address of the asset used to get the price from this oracle.
  /// @param source address of the asset used to query the price from Chainlink's Feed Registry.
  event AssetSourceUpdated(FixedLender indexed fixedLender, address indexed source);

  /// @notice Constructor.
  /// @param chainlinkFeedRegistry_ The address of Chainlink's Feed Registry implementation.
  /// @param maxDelayTime_ The max delay time for Chainlink's prices to be considered as updated.
  constructor(FeedRegistryInterface chainlinkFeedRegistry_, uint256 maxDelayTime_) {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    chainlinkFeedRegistry = chainlinkFeedRegistry_;
    maxDelayTime = maxDelayTime_;
  }

  /// @notice Sets the Chainlink Feed Registry source for an asset.
  /// @param fixedLender The FixedLender address of the asset.
  /// @param source The address of the sources of each asset.
  function setAssetSource(FixedLender fixedLender, address source) external onlyRole(DEFAULT_ADMIN_ROLE) {
    assetsSources[fixedLender] = source;
    emit AssetSourceUpdated(fixedLender, source);
  }

  /// @notice Gets an asset price by FixedLender.
  /// @dev If Chainlink's Feed Registry price is <= 0 or the updatedAt time is outdated the call is reverted.
  /// @param fixedLender The FixedLender address of the asset.
  /// @return The price of the asset scaled to 18-digit decimals.
  function getAssetPrice(FixedLender fixedLender) public view returns (uint256) {
    (, int256 price, , uint256 updatedAt, ) = chainlinkFeedRegistry.latestRoundData(
      assetsSources[fixedLender],
      BASE_CURRENCY
    );
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
error InvalidSources();
