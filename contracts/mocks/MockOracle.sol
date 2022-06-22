// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { InvalidPrice } from "../ExactlyOracle.sol";
import { FixedLender } from "../FixedLender.sol";

contract MockOracle {
  mapping(FixedLender => uint256) public prices;

  function setPrice(FixedLender market, uint256 value) public {
    prices[market] = value;
  }

  function getAssetPrice(FixedLender market) public view returns (uint256) {
    return prices[market] > 0 ? prices[market] : 1e18;
  }
}
