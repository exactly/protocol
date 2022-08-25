// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.16;

import { InterestRateModel } from "../InterestRateModel.sol";

contract MockInterestRateModel {
  InterestRateModel public irm;
  uint256 public borrowRate;

  constructor(uint256 borrowRate_) {
    irm = new InterestRateModel(
      InterestRateModel.Curve({ a: 0.75e18, b: -0.105e18, maxUtilization: 6e18 }),
      InterestRateModel.Curve({ a: 0.75e18, b: -0.105e18, maxUtilization: 6e18 })
    );
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
