// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

contract MockInterestRateModel {
  uint256 public rate;

  constructor(uint256 rate_) {
    rate = rate_;
  }

  function floatingRate(uint256) external view returns (uint256) {
    return rate;
  }

  function floatingRate(uint256, uint256) external view returns (uint256) {
    return rate;
  }

  function fixedRate(uint256, uint256, uint256, uint256, uint256) external view returns (uint256) {
    return rate;
  }

  function fixedBorrowRate(uint256 maturity, uint256, uint256, uint256, uint256) external view returns (uint256) {
    return (rate * (maturity - block.timestamp)) / 365 days;
  }

  function setRate(uint256 newRate) public {
    rate = newRate;
  }
}
