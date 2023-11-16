// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Vm } from "forge-std/Vm.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { FixedLib, MaturityOverflow } from "../contracts/utils/FixedLib.sol";

contract PoolLibTest is Test {
  using FixedLib for FixedLib.Pool;
  using FixedLib for uint256;

  FixedLib.Pool private fp;

  function testAtomicDepositBorrowRepayWithdraw() external {
    uint256 backupDebtReduction = fp.deposit(1 ether);
    assertEq(fp.borrowed, 0);
    assertEq(fp.supplied, 1 ether);
    assertEq(fp.unassignedEarnings, 0);
    assertEq(fp.lastAccrual, 0);
    assertEq(backupDebtReduction, 0);

    uint256 backupDebt = fp.borrow(1 ether);
    assertEq(fp.borrowed, 1 ether);
    assertEq(fp.supplied, 1 ether);
    assertEq(fp.unassignedEarnings, 0);
    assertEq(fp.lastAccrual, 0);
    assertEq(backupDebt, 0);

    backupDebtReduction = fp.repay(1 ether);
    assertEq(fp.borrowed, 0);
    assertEq(fp.supplied, 1 ether);
    assertEq(fp.unassignedEarnings, 0);
    assertEq(fp.lastAccrual, 0);
    assertEq(backupDebtReduction, 0);

    backupDebt = fp.withdraw(1 ether);
    assertEq(fp.borrowed, 0);
    assertEq(fp.supplied, 0);
    assertEq(fp.unassignedEarnings, 0);
    assertEq(fp.lastAccrual, 0);
    assertEq(backupDebt, 0);
  }

  function testBackupBorrow() external {
    uint256 backupDebt = fp.borrow(1 ether);
    assertEq(fp.borrowed, 1 ether);
    assertEq(fp.supplied, 0);
    assertEq(fp.unassignedEarnings, 0);
    assertEq(fp.lastAccrual, 0);
    assertEq(backupDebt, 1 ether);
  }

  function testEarningsAccrual() external {
    fp.unassignedEarnings = 1 ether;
    vm.warp(1 days);
    uint256 earnings = fp.accrueEarnings(1 days);
    assertEq(fp.borrowed, 0);
    assertEq(fp.supplied, 0);
    assertEq(fp.unassignedEarnings, 0);
    assertEq(fp.lastAccrual, 1 days);
    assertEq(earnings, 1 ether);
  }

  function testEarningsDistribution() external {
    fp.borrowed = 1 ether;
    (uint256 backup, uint256 treasury) = fp.distributeEarnings(2 ether, 2 ether);
    assertEq(backup, 1 ether);
    assertEq(treasury, 1 ether);
  }

  function testMaturityRangeLimit() external {
    uint256 maturities;
    maturities = maturities.setMaturity(FixedLib.INTERVAL);
    maturities = maturities.setMaturity(FixedLib.INTERVAL * 224);
    assertTrue(hasMaturity(maturities, FixedLib.INTERVAL));
    assertTrue(hasMaturity(maturities, FixedLib.INTERVAL * 224));

    uint256 maturitiesReverse;
    maturitiesReverse = maturitiesReverse.setMaturity(FixedLib.INTERVAL * 224);
    maturitiesReverse = maturitiesReverse.setMaturity(FixedLib.INTERVAL);
    assertTrue(hasMaturity(maturities, FixedLib.INTERVAL * 224));
    assertTrue(hasMaturity(maturities, FixedLib.INTERVAL));

    maturitiesReverse = maturitiesReverse.clearMaturity(FixedLib.INTERVAL * 224);
    assertTrue(hasMaturity(maturities, FixedLib.INTERVAL));
  }

  function testMaturityRangeTooWide() external {
    uint256 maturities;
    maturities = maturities.setMaturity(FixedLib.INTERVAL);
    vm.expectRevert(MaturityOverflow.selector);
    this.setMaturity(maturities, FixedLib.INTERVAL * (224 + 1));

    uint256 maturitiesReverse;
    maturitiesReverse = maturitiesReverse.setMaturity(FixedLib.INTERVAL * (224 + 1));
    vm.expectRevert(MaturityOverflow.selector);
    this.setMaturity(maturitiesReverse, FixedLib.INTERVAL);
  }

  function testFuzzAddRemoveAll(uint8[12] calldata indexes) external {
    uint256 maturities;

    for (uint256 i = 0; i < indexes.length; i++) {
      if (indexes[i] > 223) continue;

      uint256 maturity = (indexes[i] + 1) * FixedLib.INTERVAL;
      maturities = maturities.setMaturity(maturity);
      assertTrue(hasMaturity(maturities, maturity));
    }

    for (uint256 i = 0; i < indexes.length; i++) {
      if (indexes[i] > 223) continue;

      uint256 maturity = ((uint256(indexes[i]) + 1) * FixedLib.INTERVAL);
      uint256 base = maturities & ((1 << 32) - 1);

      if (maturity < base) vm.expectRevert(stdError.arithmeticError);
      uint256 newMaturities = this.clearMaturity(maturities, maturity);
      if (maturity < base) continue;

      maturities = newMaturities;
      assertTrue(!hasMaturity(maturities, maturity));
    }

    assertEq(maturities, 0);
  }

  function setMaturity(uint256 encoded, uint256 maturity) external pure returns (uint256) {
    return encoded.setMaturity(maturity);
  }

  function clearMaturity(uint256 encoded, uint256 maturity) external pure returns (uint256) {
    return encoded.clearMaturity(maturity);
  }

  function hasMaturity(uint256 encoded, uint256 maturity) internal pure returns (bool) {
    uint256 baseMaturity = encoded & ((1 << 32) - 1);
    if (maturity < baseMaturity) return false;

    uint256 range = (maturity - baseMaturity) / FixedLib.INTERVAL;
    if (range > 223) return false;
    return ((encoded >> 32) & (1 << range)) != 0;
  }
}
