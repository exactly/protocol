// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { IOracle, InvalidPrice } from "../interfaces/IOracle.sol";

contract MockOracle is IOracle {
  mapping(string => uint256) public prices;

  function setPrice(string memory symbol, uint256 value) public {
    prices[symbol] = value;
  }

  function getAssetPrice(string memory symbol) public view override returns (uint256) {
    if (prices[symbol] > 0) return prices[symbol];
    else revert InvalidPrice();
  }
}
