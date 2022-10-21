// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { IPriceFeed } from "../utils/IPriceFeed.sol";

contract MockPriceFeed is IPriceFeed {
  uint8 public immutable decimals;
  int256 public price;

  constructor(uint8 decimals_, int256 price_) {
    decimals = decimals_;
    setPrice(price_);
  }

  function latestAnswer() external view returns (int256) {
    return price;
  }

  function setPrice(int256 price_) public {
    price = price_;
  }
}
