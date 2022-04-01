// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { InterestRateModel, IInterestRateModel } from "../InterestRateModel.sol";

contract MockInterestRateModel is IInterestRateModel {
  InterestRateModel public irm;
  uint256 public borrowRate;

  constructor(uint256 borrowRate_) {
    irm = new InterestRateModel(0.72e18, -0.22e18, 3e18, 2e18, 0.1e18);
    borrowRate = borrowRate_;
  }

  function getRateToBorrow(
    uint256,
    uint256,
    uint256,
    uint256,
    uint256,
    uint256
  ) external view override returns (uint256) {
    return borrowRate;
  }

  function getYieldForDeposit(
    uint256 suppliedSP,
    uint256 unassignedEarnings,
    uint256 amount
  ) external view override returns (uint256 earningsShare, uint256 earningsShareSP) {
    return irm.getYieldForDeposit(suppliedSP, unassignedEarnings, amount);
  }

  function setBorrowRate(uint256 newRate) public {
    borrowRate = newRate;
  }
}
