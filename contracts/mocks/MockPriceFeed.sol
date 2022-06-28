// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { MockERC20 } from "@rari-capital/solmate/src/test/utils/mocks/MockERC20.sol";

contract MockPriceFeed {
  event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

  uint8 public constant decimals = 8; // solhint-disable-line const-name-snakecase
  int256 public price;
  uint256 public updatedAt;

  constructor(int256 price_) {
    setPrice(price_);
  }

  function latestRoundData()
    external
    view
    returns (
      uint80,
      int256,
      uint256,
      uint256,
      uint80
    )
  {
    return (0, price, 0, updatedAt, 0);
  }

  function setPrice(int256 price_) public {
    price = price_;
    updatedAt = block.timestamp;
    emit AnswerUpdated(price_, 0, block.timestamp);
  }

  function setUpdatedAt(uint256 timestamp) public {
    updatedAt = timestamp;
  }
}
