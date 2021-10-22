// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

interface IChainlinkFeedRegistry {
  
  function latestRoundData(address base, address quote)
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );

}