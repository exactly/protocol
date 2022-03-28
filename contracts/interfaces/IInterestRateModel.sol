// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

interface IInterestRateModel {
  function getRateToBorrow(
    uint256 maturityDate,
    uint256 currentDate,
    uint256 amount,
    uint256 borrowedMP,
    uint256 suppliedMP,
    uint256 totalSupplySP
  ) external view returns (uint256);

  function getYieldForDeposit(
    uint256 suppliedSP,
    uint256 unassignedEarnings,
    uint256 amount
  ) external view returns (uint256 earningsShare, uint256 earningsShareSP);
}

error AlreadyMatured();
error InvalidAmount();
error InvalidFullUtilizationRate();
error UtilizationRateExceeded();
