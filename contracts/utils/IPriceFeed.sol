// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

interface IPriceFeed {
  function decimals() external view returns (uint8);

  function latestAnswer() external view returns (int256);
}
