// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { ISequencerFeed } from "../utils/ISequencerFeed.sol";

contract MockSequencerFeed is ISequencerFeed {
  uint256 public startedAt;
  int256 public answer;

  function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
    return (0, answer, startedAt, 0, 0);
  }

  function setStartedAt(uint256 startedAt_) external {
    startedAt = startedAt_;
  }

  function setAnswer(int256 answer_) external {
    answer = answer_;
  }
}
