// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { Vm } from "forge-std/Vm.sol";
import { DSTest } from "ds-test/test.sol";
import { stdError } from "forge-std/stdlib.sol";
import { PoolLib, InsufficientProtocolLiquidity, MaturityOverflow } from "../../contracts/utils/PoolLib.sol";

contract PoolLibTest is DSTest {
  using PoolLib for PoolLib.MaturityPool;
  using PoolLib for uint256;

  Vm internal vm = Vm(HEVM_ADDRESS);
  PoolLib.MaturityPool private mp;

  function testAtomicDepositBorrowRepayWithdraw() external {
    uint256 smartPoolDebtReduction = mp.depositMoney(1 ether);
    assertEq(mp.borrowed, 0);
    assertEq(mp.supplied, 1 ether);
    assertEq(mp.suppliedSP, 0);
    assertEq(mp.earningsUnassigned, 0);
    assertEq(mp.lastAccrue, 0);
    assertEq(smartPoolDebtReduction, 0);

    uint256 smartPoolDebt = mp.borrowMoney(1 ether, 0);
    assertEq(mp.borrowed, 1 ether);
    assertEq(mp.supplied, 1 ether);
    assertEq(mp.suppliedSP, 0);
    assertEq(mp.earningsUnassigned, 0);
    assertEq(mp.lastAccrue, 0);
    assertEq(smartPoolDebt, 0);

    smartPoolDebtReduction = mp.repayMoney(1 ether);
    assertEq(mp.borrowed, 0);
    assertEq(mp.supplied, 1 ether);
    assertEq(mp.suppliedSP, 0);
    assertEq(mp.earningsUnassigned, 0);
    assertEq(mp.lastAccrue, 0);
    assertEq(smartPoolDebtReduction, 0);

    smartPoolDebt = mp.withdrawMoney(1 ether, 0);
    assertEq(mp.borrowed, 0);
    assertEq(mp.supplied, 0);
    assertEq(mp.suppliedSP, 0);
    assertEq(mp.earningsUnassigned, 0);
    assertEq(mp.lastAccrue, 0);
    assertEq(smartPoolDebt, 0);
  }

  function testSmartPoolBorrow() external {
    uint256 smartPoolDebt = mp.borrowMoney(1 ether, 1 ether);
    assertEq(mp.borrowed, 1 ether);
    assertEq(mp.supplied, 0);
    assertEq(mp.suppliedSP, 1 ether);
    assertEq(mp.earningsUnassigned, 0);
    assertEq(mp.lastAccrue, 0);
    assertEq(smartPoolDebt, 1 ether);
  }

  function testEarningsAccrual() external {
    mp.earningsUnassigned = 1 ether;
    uint256 earnings = mp.accrueEarnings(1 days, 1 days);
    assertEq(mp.borrowed, 0);
    assertEq(mp.supplied, 0);
    assertEq(mp.suppliedSP, 0);
    assertEq(mp.earningsUnassigned, 0);
    assertEq(mp.lastAccrue, 1 days);
    assertEq(earnings, 1 ether);
  }

  function testEarningsDistribution() external {
    (uint256 smartPool, uint256 treasury) = PoolLib.distributeEarningsAccordingly(2 ether, 1 ether, 2 ether);
    assertEq(smartPool, 1 ether);
    assertEq(treasury, 1 ether);
  }

  function testBorrowInsufficientLiquidity() external {
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    this.borrowMoney(1 ether, 1 ether - 1);
  }

  function testMaturityRangeLimit() external {
    uint256 maturities;
    maturities = maturities.setMaturity(7 days);
    maturities = maturities.setMaturity(7 days * 224);
    assertTrue(maturities.hasMaturity(7 days));
    assertTrue(maturities.hasMaturity(7 days * 224));

    uint256 maturitiesReverse;
    maturitiesReverse = maturitiesReverse.setMaturity(7 days * 224);
    maturitiesReverse = maturitiesReverse.setMaturity(7 days);
    assertTrue(maturities.hasMaturity(7 days * 224));
    assertTrue(maturities.hasMaturity(7 days));

    maturitiesReverse = maturitiesReverse.clearMaturity(7 days * 224);
    assertTrue(maturities.hasMaturity(7 days));
  }

  function testMaturityRangeTooWide() external {
    uint256 maturities;
    maturities = maturities.setMaturity(7 days);
    vm.expectRevert(MaturityOverflow.selector);
    this.setMaturity(maturities, 7 days * (224 + 1));

    uint256 maturitiesReverse;
    maturitiesReverse = maturitiesReverse.setMaturity(7 days * (224 + 1));
    vm.expectRevert(MaturityOverflow.selector);
    this.setMaturity(maturitiesReverse, 7 days);
  }

  function testFuzzAddRemoveAll(uint8[12] calldata indexes) external {
    uint256 maturities;

    for (uint256 i = 0; i < indexes.length; i++) {
      if (indexes[i] > 223) continue;

      uint32 maturity = ((uint32(indexes[i]) + 1) * 7 days);
      maturities = maturities.setMaturity(maturity);
      assertTrue(maturities.hasMaturity(maturity));
    }

    for (uint256 i = 0; i < indexes.length; i++) {
      if (indexes[i] > 223) continue;

      uint256 maturity = ((uint256(indexes[i]) + 1) * 7 days);
      uint256 base = maturities % (1 << 32);

      if (maturity < base) vm.expectRevert(stdError.arithmeticError);
      uint256 newMaturities = this.clearMaturity(maturities, maturity);
      if (maturity < base) continue;

      maturities = newMaturities;
      assertTrue(!maturities.hasMaturity(maturity));
    }

    assertEq(maturities, 0);
  }

  function borrowMoney(uint256 amount, uint256 maxDebt) external returns (uint256) {
    return mp.borrowMoney(amount, maxDebt);
  }

  function setMaturity(uint256 encoded, uint256 maturity) external pure returns (uint256) {
    return encoded.setMaturity(maturity);
  }

  function clearMaturity(uint256 encoded, uint256 maturity) external pure returns (uint256) {
    return encoded.clearMaturity(maturity);
  }
}
