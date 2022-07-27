// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
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
  uint256 public lastEarningsSP;
  uint256 public lastEarningsTreasury;
  FixedLib.Position public scaledDebt;

  function getDepositYield(
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
        .getDepositYield(amount, backupFeeRate);
  }

  function accrueEarnings(uint256 maturity) external {
    lastEarningsSP = fixedPool.accrueEarnings(maturity);
  }

  function deposit(uint256 amount) external {
    backupDebtReduction = fixedPool.deposit(amount);
  }

  function repay(uint256 amount) external {
    backupDebtReduction = fixedPool.repay(amount);
  }

  function borrow(uint256 amount, uint256 backupAvailableSupply) external {
    backupDebtAddition = fixedPool.borrow(amount, backupAvailableSupply);
  }

  function distributeEarnings(
    uint256 borrowed,
    uint256 supplied,
    uint256 unassignedEarnings,
    uint256 lastAccrual,
    uint256 earnings,
    uint256 borrowAmount
  ) external {
    (lastEarningsSP, lastEarningsTreasury) = FixedLib
      .Pool({
        borrowed: borrowed,
        supplied: supplied,
        unassignedEarnings: unassignedEarnings,
        lastAccrual: lastAccrual
      })
      .distributeEarnings(earnings, borrowAmount);
  }

  function withdraw(uint256 amountToDiscount, uint256 backupAvailableSupply) external {
    backupDebtAddition = fixedPool.withdraw(amountToDiscount, backupAvailableSupply);
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

  function scaleProportionally(
    uint256 scaledDebtPrincipal,
    uint256 scaledDebtFee,
    uint256 amount
  ) external {
    scaledDebt.principal = scaledDebtPrincipal;
    scaledDebt.fee = scaledDebtFee;
    scaledDebt = scaledDebt.scaleProportionally(amount);
  }

  function reduceProportionally(
    uint256 scaledDebtPrincipal,
    uint256 scaledDebtFee,
    uint256 amount
  ) external {
    scaledDebt.principal = scaledDebtPrincipal;
    scaledDebt.fee = scaledDebtFee;
    scaledDebt = scaledDebt.reduceProportionally(amount);
  }
}
