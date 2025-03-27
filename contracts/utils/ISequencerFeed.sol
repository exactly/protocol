// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

interface ISequencerFeed {
  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

error SequencerDown();
error GracePeriodNotOver();
