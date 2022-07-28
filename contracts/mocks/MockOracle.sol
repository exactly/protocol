// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { InvalidPrice } from "../ExactlyOracle.sol";
import { Market } from "../Market.sol";

contract MockOracle {
  mapping(Market => uint256) public prices;

  function setPrice(Market market, uint256 value) public {
    prices[market] = value;
  }

  function assetPrice(Market market) public view returns (uint256) {
    return prices[market] > 0 ? prices[market] : 1e18;
  }
}
