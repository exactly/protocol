// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { PoolLib } from "../utils/PoolLib.sol";

contract FixedPoolHarness {
  using PoolLib for PoolLib.FixedPool;
  using PoolLib for PoolLib.Position;
  using PoolLib for uint256;

  PoolLib.FixedPool public fixedPool;
  uint256 public newDebtSP;
  uint256 public newUserBorrows;
  uint256 public smartPoolDebtReduction;
  uint256 public nextTimestamp;
  uint256 public lastEarningsSP;
  uint256 public lastEarningsTreasury;
  PoolLib.Position public scaledDebt;

  function getDepositYield(
    uint256 unassignedEarnings,
    uint256 amount,
    uint256 spBorrowed,
    uint256 smartPoolFeeRate
  ) external pure returns (uint256, uint256) {
    return unassignedEarnings.getDepositYield(amount, spBorrowed, smartPoolFeeRate);
  }

  function accrueEarnings(uint256 _maturityID) external {
    lastEarningsSP = fixedPool.accrueEarnings(_maturityID, nextTimestamp != 0 ? nextTimestamp : block.timestamp);
  }

  function deposit(uint256 _amount) external {
    smartPoolDebtReduction = fixedPool.deposit(_amount);
  }

  function repay(uint256 _amount) external {
    smartPoolDebtReduction = fixedPool.repay(_amount);
  }

  function borrow(uint256 _amount, uint256 _maxDebt) external {
    newDebtSP = fixedPool.borrow(_amount, _maxDebt);
  }

  function distributeEarningsAccordingly(
    uint256 earnings,
    uint256 suppliedSP,
    uint256 amountFunded
  ) external {
    (lastEarningsSP, lastEarningsTreasury) = PoolLib.distributeEarningsAccordingly(earnings, suppliedSP, amountFunded);
  }

  function withdraw(uint256 _amountToDiscount, uint256 _maxDebt) external {
    newDebtSP = fixedPool.withdraw(_amountToDiscount, _maxDebt);
  }

  function setMaturity(uint256 _userBorrows, uint256 _maturityDate) external {
    newUserBorrows = _userBorrows.setMaturity(_maturityDate);
  }

  function clearMaturity(uint256 _userBorrows, uint256 _maturityDate) external {
    newUserBorrows = _userBorrows.clearMaturity(_maturityDate);
  }

  function addFee(uint256 _fee) external {
    fixedPool.earningsUnassigned += _fee;
  }

  function removeFee(uint256 _fee) external {
    fixedPool.earningsUnassigned -= _fee;
  }

  function scaleProportionally(
    uint256 _scaledDebtPrincipal,
    uint256 _scaledDebtFee,
    uint256 _amount
  ) external {
    scaledDebt.principal = _scaledDebtPrincipal;
    scaledDebt.fee = _scaledDebtFee;
    scaledDebt = scaledDebt.scaleProportionally(_amount);
  }

  function reduceProportionally(
    uint256 _scaledDebtPrincipal,
    uint256 _scaledDebtFee,
    uint256 _amount
  ) external {
    scaledDebt.principal = _scaledDebtPrincipal;
    scaledDebt.fee = _scaledDebtFee;
    scaledDebt = scaledDebt.reduceProportionally(_amount);
  }

  function setNextTimestamp(uint256 _nextTimestamp) external {
    nextTimestamp = _nextTimestamp;
  }
}
