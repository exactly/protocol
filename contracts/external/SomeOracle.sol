// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../interfaces/IOracle.sol";

contract SomeOracle is IOracle {

  mapping(string => uint) public prices;
    
  function getAssetPrice(string memory symbol) override public view returns (uint) {
      return prices[symbol];
  }

  function setPrice(string memory symbol, uint value) public {
      prices[symbol] = value;
  }

}