// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { PoolLib, InsufficientProtocolLiquidity, MaturityOverflow } from "../../contracts/utils/PoolLib.sol";
import { TSUtils } from "../../contracts/utils/TSUtils.sol";

contract PoolLibTest is Test {
  using PoolLib for PoolLib.FixedPool;
  using PoolLib for uint256;

  PoolLib.FixedPool private fp;

  function testAtomicDepositBorrowRepayWithdraw() external {
    uint256 smartPoolDebtReduction = fp.deposit(1 ether);
    assertEq(fp.borrowed, 0);
    assertEq(fp.supplied, 1 ether);
    assertEq(fp.earningsUnassigned, 0);
    assertEq(fp.lastAccrual, 0);
    assertEq(smartPoolDebtReduction, 0);

    uint256 smartPoolDebt = fp.borrow(1 ether, 0);
    assertEq(fp.borrowed, 1 ether);
    assertEq(fp.supplied, 1 ether);
    assertEq(fp.earningsUnassigned, 0);
    assertEq(fp.lastAccrual, 0);
    assertEq(smartPoolDebt, 0);

    smartPoolDebtReduction = fp.repay(1 ether);
    assertEq(fp.borrowed, 0);
    assertEq(fp.supplied, 1 ether);
    assertEq(fp.earningsUnassigned, 0);
    assertEq(fp.lastAccrual, 0);
    assertEq(smartPoolDebtReduction, 0);

    smartPoolDebt = fp.withdraw(1 ether, 0);
    assertEq(fp.borrowed, 0);
    assertEq(fp.supplied, 0);
    assertEq(fp.earningsUnassigned, 0);
    assertEq(fp.lastAccrual, 0);
    assertEq(smartPoolDebt, 0);
  }

  function testSmartPoolBorrow() external {
    uint256 smartPoolDebt = fp.borrow(1 ether, 1 ether);
    assertEq(fp.borrowed, 1 ether);
    assertEq(fp.supplied, 0);
    assertEq(fp.earningsUnassigned, 0);
    assertEq(fp.lastAccrual, 0);
    assertEq(smartPoolDebt, 1 ether);
  }

  function testEarningsAccrual() external {
    fp.earningsUnassigned = 1 ether;
    uint256 earnings = fp.accrueEarnings(1 days, 1 days);
    assertEq(fp.borrowed, 0);
    assertEq(fp.supplied, 0);
    assertEq(fp.earningsUnassigned, 0);
    assertEq(fp.lastAccrual, 1 days);
    assertEq(earnings, 1 ether);
  }

  function testEarningsDistribution() external {
    (uint256 smartPool, uint256 treasury) = PoolLib.distributeEarningsAccordingly(2 ether, 1 ether, 2 ether);
    assertEq(smartPool, 1 ether);
    assertEq(treasury, 1 ether);
  }

  function testBorrowInsufficientLiquidity() external {
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    this.borrow(1 ether, 1 ether - 1);
  }

  function testMaturityRangeLimit() external {
    uint256 maturities;
    maturities = maturities.setMaturity(TSUtils.INTERVAL);
    maturities = maturities.setMaturity(TSUtils.INTERVAL * 224);
    assertTrue(maturities.hasMaturity(TSUtils.INTERVAL));
    assertTrue(maturities.hasMaturity(TSUtils.INTERVAL * 224));

    uint256 maturitiesReverse;
    maturitiesReverse = maturitiesReverse.setMaturity(TSUtils.INTERVAL * 224);
    maturitiesReverse = maturitiesReverse.setMaturity(TSUtils.INTERVAL);
    assertTrue(maturities.hasMaturity(TSUtils.INTERVAL * 224));
    assertTrue(maturities.hasMaturity(TSUtils.INTERVAL));

    maturitiesReverse = maturitiesReverse.clearMaturity(TSUtils.INTERVAL * 224);
    assertTrue(maturities.hasMaturity(TSUtils.INTERVAL));
  }

  function testMaturityRangeTooWide() external {
    uint256 maturities;
    maturities = maturities.setMaturity(TSUtils.INTERVAL);
    vm.expectRevert(MaturityOverflow.selector);
    this.setMaturity(maturities, TSUtils.INTERVAL * (224 + 1));

    uint256 maturitiesReverse;
    maturitiesReverse = maturitiesReverse.setMaturity(TSUtils.INTERVAL * (224 + 1));
    vm.expectRevert(MaturityOverflow.selector);
    this.setMaturity(maturitiesReverse, TSUtils.INTERVAL);
  }

  function testFuzzAddRemoveAll(uint8[12] calldata indexes) external {
    uint256 maturities;

    for (uint256 i = 0; i < indexes.length; i++) {
      if (indexes[i] > 223) continue;

      uint32 maturity = ((uint32(indexes[i]) + 1) * TSUtils.INTERVAL);
      maturities = maturities.setMaturity(maturity);
      assertTrue(maturities.hasMaturity(maturity));
    }

    for (uint256 i = 0; i < indexes.length; i++) {
      if (indexes[i] > 223) continue;

      uint256 maturity = ((uint256(indexes[i]) + 1) * TSUtils.INTERVAL);
      uint256 base = maturities % (1 << 32);

      if (maturity < base) vm.expectRevert(stdError.arithmeticError);
      uint256 newMaturities = this.clearMaturity(maturities, maturity);
      if (maturity < base) continue;

      maturities = newMaturities;
      assertTrue(!maturities.hasMaturity(maturity));
    }

    assertEq(maturities, 0);
  }

  function borrow(uint256 amount, uint256 maxDebt) external returns (uint256) {
    return fp.borrow(amount, maxDebt);
  }

  function setMaturity(uint256 encoded, uint256 maturity) external pure returns (uint256) {
    return encoded.setMaturity(maturity);
  }

  function clearMaturity(uint256 encoded, uint256 maturity) external pure returns (uint256) {
    return encoded.clearMaturity(maturity);
  }
}
