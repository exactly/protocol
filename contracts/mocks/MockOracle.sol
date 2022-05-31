// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { InvalidPrice } from "../ExactlyOracle.sol";
import { FixedLender } from "../FixedLender.sol";

contract MockOracle {
  mapping(FixedLender => uint256) public prices;

  function setPrice(FixedLender fixedLender, uint256 value) public {
    prices[fixedLender] = value;
  }

  function getAssetPrice(FixedLender fixedLender) public view returns (uint256) {
    if (prices[fixedLender] > 0) return prices[fixedLender];
    else revert InvalidPrice();
  }
}
