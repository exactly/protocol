// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedLib } from "../utils/FixedLib.sol";

contract FixedPoolHarness {
  using FixedLib for FixedLib.Pool;
  using FixedLib for FixedLib.Position;
  using FixedLib for uint256;

  FixedLib.Pool public fixedPool;
  uint256 public backupDebtAddition;
  uint256 public newAccountBorrows;
  uint256 public backupDebtReduction;
  uint256 public nextTimestamp;
  uint256 public lastBackupEarnings;
  uint256 public lastEarningsTreasury;
  FixedLib.Position public scaledDebt;

  function calculateDeposit(
    uint256 borrowed,
    uint256 supplied,
    uint256 unassignedEarnings,
    uint256 lastAccrual,
    uint256 amount,
    uint256 backupFeeRate
  ) external pure returns (uint256, uint256) {
    return
      FixedLib
        .Pool({
          borrowed: borrowed,
          supplied: supplied,
          unassignedEarnings: unassignedEarnings,
          lastAccrual: lastAccrual
        })
        .calculateDeposit(amount, backupFeeRate);
  }

  function accrueEarnings(uint256 maturity) external {
    lastBackupEarnings = fixedPool.accrueEarnings(maturity);
  }

  function deposit(uint256 amount) external {
    backupDebtReduction = fixedPool.deposit(amount);
  }

  function repay(uint256 amount) external {
    backupDebtReduction = fixedPool.repay(amount);
  }

  function borrow(uint256 amount) external {
    backupDebtAddition = fixedPool.borrow(amount);
  }

  function distributeEarnings(
    uint256 borrowed,
    uint256 supplied,
    uint256 unassignedEarnings,
    uint256 lastAccrual,
    uint256 earnings,
    uint256 borrowAmount
  ) external {
    (lastBackupEarnings, lastEarningsTreasury) = FixedLib
      .Pool({
        borrowed: borrowed,
        supplied: supplied,
        unassignedEarnings: unassignedEarnings,
        lastAccrual: lastAccrual
      })
      .distributeEarnings(earnings, borrowAmount);
  }

  function withdraw(uint256 amountToDiscount) external {
    backupDebtAddition = fixedPool.withdraw(amountToDiscount);
  }

  function setMaturity(uint256 encoded, uint256 maturity) external {
    newAccountBorrows = encoded.setMaturity(maturity);
  }

  function clearMaturity(uint256 encoded, uint256 maturity) external {
    newAccountBorrows = encoded.clearMaturity(maturity);
  }

  function addFee(uint256 fee) external {
    fixedPool.unassignedEarnings += fee;
  }

  function removeFee(uint256 fee) external {
    fixedPool.unassignedEarnings -= fee;
  }

  function scaleProportionally(uint256 scaledDebtPrincipal, uint256 scaledDebtFee, uint256 amount) external {
    scaledDebt.principal = scaledDebtPrincipal;
    scaledDebt.fee = scaledDebtFee;
    scaledDebt = scaledDebt.scaleProportionally(amount);
  }

  function reduceProportionally(uint256 scaledDebtPrincipal, uint256 scaledDebtFee, uint256 amount) external {
    scaledDebt.principal = scaledDebtPrincipal;
    scaledDebt.fee = scaledDebtFee;
    scaledDebt = scaledDebt.reduceProportionally(amount);
  }
}
