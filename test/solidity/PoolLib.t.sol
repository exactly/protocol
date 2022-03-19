// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { Vm } from "forge-std/Vm.sol";
import { DSTest } from "ds-test/test.sol";
import { InsufficientProtocolLiquidity, MaturityRangeTooWide } from "../../contracts/utils/PoolLib.sol";
import { PoolLib } from "../../contracts/utils/PoolLib.sol";
import "forge-std/console.sol";

contract PoolLibTest is DSTest {
  using PoolLib for PoolLib.MaturityPool;

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
    uint256 packedMaturities;
    packedMaturities = this.addMaturity(packedMaturities, 7 days);
    packedMaturities = this.addMaturity(packedMaturities, 7 days * 224);
    assertTrue(this.checkMaturity(packedMaturities, 7 days));
    assertTrue(this.checkMaturity(packedMaturities, 7 days * 224));

    uint256 packedMaturitiesReverse;
    packedMaturitiesReverse = this.addMaturity(packedMaturitiesReverse, 7 days * 224);
    packedMaturitiesReverse = this.addMaturity(packedMaturitiesReverse, 7 days);
    assertTrue(this.checkMaturity(packedMaturitiesReverse, 7 days * 224));
    assertTrue(this.checkMaturity(packedMaturitiesReverse, 7 days));

    packedMaturitiesReverse = PoolLib.removeMaturity(packedMaturitiesReverse, 7 days * 224);
    assertTrue(this.checkMaturity(packedMaturitiesReverse, 7 days));
  }

  function testMaturityRangeTooWide() external {
    uint256 packedMaturities;
    packedMaturities = this.addMaturity(packedMaturities, 7 days);
    vm.expectRevert(MaturityRangeTooWide.selector);
    this.addMaturity(packedMaturities, 7 days * (224 + 1));

    uint256 packedMaturitiesReverse;
    packedMaturitiesReverse = this.addMaturity(packedMaturitiesReverse, 7 days * (224 + 1));
    vm.expectRevert(MaturityRangeTooWide.selector);
    this.addMaturity(packedMaturitiesReverse, 7 days);
  }

  function addMaturity(uint256 packedMaturities, uint256 maturity) public pure returns (uint256) {
    return PoolLib.addMaturity(packedMaturities, maturity);
  }

  function testAddRemoveMaturity(uint8[12] calldata weekArray) external {
    uint256 packedMaturities;
    uint256 length = weekArray.length;
    for (uint256 i = 0; i < length; i++) {
      // to have values within a range and non zero
      uint256 normalizedTimestamp = ((uint256(weekArray[i]) + 1) * 7 days);
      // avoid having timestamps that are repeated and the packed version doesn't support
      // more than a 223 week range
      if (this.checkMaturity(packedMaturities, normalizedTimestamp) || weekArray[i] > 223) {
        continue;
      }
      packedMaturities = PoolLib.addMaturity(packedMaturities, normalizedTimestamp);
      assertTrue(this.checkMaturity(packedMaturities, normalizedTimestamp));
    }

    for (uint256 i = 0; i < length; i++) {
      uint256 normalizedTimestamp = ((uint256(weekArray[i]) + 1) * 7 days);
      // avoid having timestamps that are repeated and the packed version doesn't support
      // more than a 223 week range
      if (!this.checkMaturity(packedMaturities, normalizedTimestamp) || weekArray[i] > 223) {
        continue;
      }
      packedMaturities = PoolLib.removeMaturity(packedMaturities, normalizedTimestamp);
      assertTrue(!this.checkMaturity(packedMaturities, normalizedTimestamp));
    }
    assertEq(packedMaturities, 0);
  }

  function borrowMoney(uint256 amount, uint256 maxDebt) public returns (uint256) {
    return mp.borrowMoney(amount, maxDebt);
  }

  function checkMaturity(uint256 packedMaturities, uint256 timestamp) public pure returns (bool) {
    uint32 baseTimestamp = uint32(packedMaturities % (2**32));
    uint224 moreMaturities = uint224(packedMaturities >> 32);
    // We calculate all the timestamps using the baseTimestamp
    // and the following bits representing the following weeks
    if (timestamp < baseTimestamp) {
      return false;
    }
    uint256 weekDiff = (timestamp - baseTimestamp) / 7 days;
    if (weekDiff > 223) {
      return false;
    }

    if ((moreMaturities & (1 << weekDiff)) != 0) {
      return true;
    }

    return false;
  }
}
