// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

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
    emit AnswerUpdated(price_, 0, block.timestamp);
  }

  event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 timestamp);
}
