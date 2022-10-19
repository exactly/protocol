// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

contract MockPriceFeed {
  uint8 public constant decimals = 8; // solhint-disable-line const-name-snakecase
  int256 public price;

  constructor(int256 price_) {
    setPrice(price_);
  }

  function latestAnswer() external view returns (int256) {
    return price;
  }

  function setPrice(int256 price_) public {
    price = price_;
  }
}
