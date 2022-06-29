// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { InterestRateModel } from "../InterestRateModel.sol";

contract MockInterestRateModel {
  InterestRateModel public irm;
  uint256 public borrowRate;
  uint256 public flexibleFullUtilization = 4e18;

  constructor(uint256 borrowRate_) {
    irm = new InterestRateModel(0.75e18, -0.105e18, 6e18, 4e18, 0.75e18, -0.105e18, 6e18, 4e18);
    borrowRate = borrowRate_;
  }

  function getFlexibleBorrowRate(uint256, uint256) external view returns (uint256) {
    return borrowRate;
  }

  function getRateToBorrow(
    uint256,
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
