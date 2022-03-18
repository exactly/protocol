// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FeedRegistryInterface } from "@chainlink/contracts/src/v0.8/interfaces/FeedRegistryInterface.sol";

import { IOracle, InvalidPrice, InvalidSources } from "./interfaces/IOracle.sol";

/// @title ExactlyOracle
/// @notice Proxy to get the price of an asset from a price source, with Chainlink Feed Registry as the primary option.
contract ExactlyOracle is IOracle, AccessControl {
  mapping(string => address) public assetsSources;
  FeedRegistryInterface public chainlinkFeedRegistry;
  address public immutable baseCurrency;
  uint256 public immutable maxDelayTime;

  uint256 public constant TARGET_DECIMALS = 18; // Auditor's target precision
  uint256 public constant ORACLE_DECIMALS = 8; // At date of Exactly launch, Chainlink uses an 8-digit price

  event SymbolSourceUpdated(string indexed symbol, address indexed source);

  /// @notice Constructor.
  /// @param _chainlinkFeedRegistry The address of the Chainlink Feed Registry implementation.
  /// @param _symbols The symbols of the assets.
  /// @param _sources The address of the source of each asset.
  /// @param _baseCurrency The base currency used for the price quotes.
  /// @param _maxDelayTime The max delay time for Chainlink prices to be considered as updated.
  constructor(
    FeedRegistryInterface _chainlinkFeedRegistry,
    string[] memory _symbols,
    address[] memory _sources,
    address _baseCurrency,
    uint256 _maxDelayTime
  ) {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _setAssetsSources(_symbols, _sources);

    chainlinkFeedRegistry = _chainlinkFeedRegistry;
    baseCurrency = _baseCurrency;
    maxDelayTime = _maxDelayTime;
  }

  /// @notice Set or replace the sources of assets.
  /// @param symbols The symbols of the assets.
  /// @param sources The address of the source of each asset.
  function setAssetSources(string[] calldata symbols, address[] calldata sources)
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
  {
    _setAssetsSources(symbols, sources);
  }

  /// @notice Gets an asset price by symbol. If Chainlink Feed Registry price is <= 0 the call is reverted.
  /// @param symbol The symbol of the asset.
  function getAssetPrice(string memory symbol) public view override returns (uint256) {
    (, int256 price, , uint256 updatedAt, ) = chainlinkFeedRegistry.latestRoundData(
      assetsSources[symbol],
      baseCurrency
    );
    if (price > 0 && updatedAt >= block.timestamp - maxDelayTime) return _scaleOraclePriceByDigits(uint256(price));
    else revert InvalidPrice();
  }

  /// @notice Internal function to set the sources for each asset.
  /// @param symbols The symbols of the assets.
  /// @param sources The addresses of the sources of each asset.
  function _setAssetsSources(string[] memory symbols, address[] memory sources) internal {
    if (symbols.length != sources.length) revert InvalidSources();

    for (uint256 i = 0; i < symbols.length; i++) {
      assetsSources[symbols[i]] = sources[i];
      emit SymbolSourceUpdated(symbols[i], sources[i]);
    }
  }

  /// @notice Scale the price returned by the oracle to an 18-digit decimal for use by Auditor.
  /// @param price The price to be scaled.
  function _scaleOraclePriceByDigits(uint256 price) internal pure returns (uint256) {
    return price * 10**(TARGET_DECIMALS - ORACLE_DECIMALS);
  }
}
