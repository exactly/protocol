// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";

import "../interfaces/IOracle.sol";
import "../interfaces/IChainlinkFeedRegistry.sol";
import "../utils/Errors.sol";

/// @title ExactlyOracle
/// @notice Proxy smart contract to get the price of an asset from a price source, with Chainlink Feed Registry
///         smart contract as the primary option
/// - If the returned price by the Chainlink Feed Registry is <= 0, the call is reverted
contract ExactlyOracle is IOracle, AccessControl {

  bytes32 public constant TEAM_ROLE = keccak256("TEAM_ROLE");

  event SymbolSourceUpdated(string indexed symbol, address indexed source);

  mapping(string => address) private assetsSources;
  IChainlinkFeedRegistry public chainlinkFeedRegistry;
  address public immutable baseCurrency;

  /// @notice Constructor
  /// @param _chainlinkFeedRegistry The address of the Chainlink Feed Registry implementation
  /// @param _symbols The symbols of the assets
  /// @param _sources The address of the source of each asset
  /// @param _baseCurrency The base currency used for the price quotes
  constructor(address _chainlinkFeedRegistry, string[] memory _symbols, address[] memory _sources, address _baseCurrency) {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _setupRole(TEAM_ROLE, msg.sender);
    _setAssetsSources(_symbols, _sources);

    chainlinkFeedRegistry = IChainlinkFeedRegistry(_chainlinkFeedRegistry);
    baseCurrency = _baseCurrency;
  }

  /// @notice External function called by the Exactly governance to set or replace sources of assets
  /// @param symbols The symbols of the assets
  /// @param sources The address of the source of each asset
  function setAssetSources(string[] calldata symbols, address[] calldata sources)
    external
    onlyRole(TEAM_ROLE)
  {
    _setAssetsSources(symbols, sources);
  }

  /// @notice Internal function to set the sources for each asset
  /// @param symbols The symbols of the assets
  /// @param sources The addresses of the sources of each asset
  function _setAssetsSources(string[] memory symbols, address[] memory sources) internal {
    if (symbols.length != sources.length) {
      revert GenericError(ErrorCode.INCONSISTENT_PARAMS_LENGTH);
    }
    
    for (uint256 i = 0; i < symbols.length; i++) {
      assetsSources[symbols[i]] = sources[i];
      emit SymbolSourceUpdated(symbols[i], sources[i]);
    }
  }

  /// @notice Gets an asset price by symbol
  /// @param symbol The symbol of the asset
  function getAssetPrice(string memory symbol) public view override returns (uint256) {
      (,int256 price,,,) = chainlinkFeedRegistry.latestRoundData(assetsSources[symbol], baseCurrency);
      if (price > 0) {
        return uint256(price);
      } else {
        revert GenericError(ErrorCode.PRICE_ERROR);
      }
  }

  /// @notice Gets a list of prices from a list of assets symbols
  /// @param symbols The list of assets symbols
  function getAssetsPrices(string[] calldata symbols) external view returns (uint256[] memory) {
    uint256[] memory prices = new uint256[](symbols.length);
    for (uint256 i = 0; i < symbols.length; i++) {
      prices[i] = getAssetPrice(symbols[i]);
    }
    return prices;
  }

  /// @notice Gets the address of the source for an asset symbol
  /// @param symbol The symbol of the asset
  /// @return address The address of the source
  function getSourceOfAssetBySymbol(string memory symbol) external view returns (address) {
    return address(assetsSources[symbol]);
  }

}
