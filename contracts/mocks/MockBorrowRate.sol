// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

contract MockBorrowRate {
  using FixedPointMathLib for uint256;
  uint256 public borrowRate;

  constructor(uint256 borrowRate_) {
    borrowRate = borrowRate_;
  }

  function floatingRate(uint256, uint256) external view returns (uint256) {
    return borrowRate;
  }

  function floatingRate(uint256) external view returns (uint256) {
    return borrowRate;
  }

  function fixedRate(
    uint256 maturity,
    uint256,
    uint256,
    uint256,
    uint256,
    uint256,
    uint256
  ) external view returns (uint256) {
    return borrowRate.mulDivUp(365 days, maturity - block.timestamp);
  }

  function maturityAllocation(uint256, uint256) external pure returns (uint256) {
    return 1e18;
  }

  function fixedBorrowThreshold() external pure returns (uint256) {
    return 1e18;
  }

  function canBorrowAtMaturity(uint256, uint256, uint256, uint256, uint256) external pure returns (bool) {
    return true;
  }

  function setRate(uint256 newRate) public {
    borrowRate = newRate;
  }
}
