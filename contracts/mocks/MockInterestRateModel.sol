// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import { InterestRateModel } from "../InterestRateModel.sol";

contract MockInterestRateModel {
  InterestRateModel public irm;
  uint256 public borrowRate;
  uint128 public floatingFullUtilization = 4e18;

  constructor(uint256 borrowRate_) {
    irm = new InterestRateModel(
      InterestRateModel.Curve({ a: 0.75e18, b: -0.105e18, maxUtilization: 6e18 }),
      4e18,
      InterestRateModel.Curve({ a: 0.75e18, b: -0.105e18, maxUtilization: 6e18 }),
      4e18
    );
    borrowRate = borrowRate_;
  }

  function floatingCurve()
    external
    view
    returns (
      uint128,
      int128,
      uint128,
      uint128
    )
  {
    return (uint128(0), int128(0), uint128(0), floatingFullUtilization);
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
