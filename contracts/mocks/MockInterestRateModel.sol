// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

contract MockInterestRateModel {
  uint256 public borrowRate;

  constructor(uint256 borrowRate_) {
    borrowRate = borrowRate_;
  }

  function floatingBorrowRate(uint256, uint256) external view returns (uint256) {
    return borrowRate;
  }

  function fixedBorrowRate(
    uint256,
    uint256,
    uint256,
    uint256,
    uint256
  ) external view returns (uint256) {
    return borrowRate;
  }

  function setBorrowRate(uint256 newRate) public {
    borrowRate = newRate;
  }
}
