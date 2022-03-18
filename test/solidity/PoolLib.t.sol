// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { Vm } from "forge-std/Vm.sol";
import { DSTest } from "ds-test/test.sol";
import { InsufficientProtocolLiquidity } from "../../contracts/utils/PoolLib.sol";
import { PoolLib } from "../../contracts/utils/PoolLib.sol";

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

  function borrowMoney(uint256 amount, uint256 maxDebt) public returns (uint256) {
    return mp.borrowMoney(amount, maxDebt);
  }
}
