// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../interfaces/IChainlinkFeedRegistry.sol";

contract SomeChainlinkFeedRegistry is IChainlinkFeedRegistry {
    mapping(address => mapping(address => int256)) public assetsPricesByCurrency;
    
    function latestRoundData(address base, address quote) override external view returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) {
        int256 _price = assetsPricesByCurrency[base][quote];
        return (0, _price, 0, 0, 0);
    }

    function setPrice(address _asset, address _baseCurrency, int256 _price) public {
        assetsPricesByCurrency[_asset][_baseCurrency] = _price;
    }

}
