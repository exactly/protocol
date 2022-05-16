// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { InvalidPrice } from "../ExactlyOracle.sol";

contract MockOracle {
  mapping(string => uint256) public prices;

  function setPrice(string memory symbol, uint256 value) public {
    prices[symbol] = value;
  }

  function getAssetPrice(string memory symbol) public view returns (uint256) {
    if (prices[symbol] > 0) return prices[symbol];
    else revert InvalidPrice();
  }
}
