// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { Vm } from "forge-std/Vm.sol";
import { DSTest } from "ds-test/test.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { PoolLib } from "../../contracts/utils/PoolLib.sol";
import { PoolAccounting, IFixedLender } from "../../contracts/PoolAccounting.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";

contract PoolAccountingTest is DSTest {
  using FixedPointMathLib for uint256;

  uint256 internal constant POOL_ID = 7 days;
  uint256 internal constant FEE_MP = 0.01e18;
  uint256 internal constant FEE_SP = 0.1e18;

  Vm internal vm = Vm(HEVM_ADDRESS);
  InterestRateModel internal irm;
  PoolAccounting internal pool;

  function setUp() external {
    vm.label(address(this), "Test");
    irm = new InterestRateModel(0, int256(FEE_MP), type(uint256).max, FEE_SP);
    pool = new PoolAccounting(irm, 0.02e18 / uint256(1 days), 0.028e18);
    pool.initialize(IFixedLender(address(this)));
  }

  function testAtomicDepositBorrowRepayWithdraw() external {
    pool.depositMP(POOL_ID, address(this), 1 ether, 1 ether);
    pool.borrowMP(POOL_ID, address(this), 1 ether, 1.01 ether, 0, 1);
    pool.repayMP(POOL_ID, address(this), 1 ether, 1.01 ether);
    pool.withdrawMP(POOL_ID, address(this), 0.99 ether, 0.98 ether, 0, 12);
  }

  function testFailUnauthorizedDeposit() external {
    vm.prank(address(0));
    pool.depositMP(POOL_ID, address(this), 1 ether, 1 ether);
  }

  function testFailUnauthorizedBorrow() external {
    vm.prank(address(0));
    pool.borrowMP(POOL_ID, address(this), 1 ether, 1 ether, 0, 1);
  }

  function testFailUnauthorizedRepay() external {
    vm.prank(address(0));
    pool.repayMP(POOL_ID, address(this), 1 ether, 1 ether);
  }

  function testFailUnauthorizedWithdraw() external {
    vm.prank(address(0));
    pool.withdrawMP(POOL_ID, address(this), 1 ether, 1 ether, 0, 12);
  }

  function testFailAlreadyInitialized() external {
    pool.initialize(IFixedLender(address(this)));
  }

  function testFailTooMuchSlippageDeposit() external {
    pool.depositMP(POOL_ID, address(this), 1 ether, 1.1 ether);
  }

  function testFailTooMuchSlippageBorrow() external {
    pool.depositMP(POOL_ID, address(this), 1 ether, 1 ether);
    pool.borrowMP(POOL_ID, address(this), 1 ether, 1 ether, 0, 1);
  }

  function testFailTooMuchSlippageRepay() external {
    pool.depositMP(POOL_ID, address(this), 1 ether, 1 ether);
    pool.borrowMP(POOL_ID, address(this), 1 ether, 1.01 ether, 0, 1);
    pool.repayMP(POOL_ID, address(this), 1 ether, 0.99 ether);
  }

  function testFailTooMuchSlippageWithdraw() external {
    pool.depositMP(POOL_ID, address(this), 1 ether, 1 ether);
    pool.withdrawMP(POOL_ID, address(this), 1 ether, 1 ether, 0, 12);
  }

  function testBorrowRepayMultiplePools() external {
    uint256 total = 0;
    for (uint256 i = 1; i < 6 + 1; i++) {
      (uint256 borrowed, , ) = pool.borrowMP(i * POOL_ID, address(this), 1 ether, 1.01 ether, 100 ether, 6);
      total += borrowed;
    }

    assertEq(pool.getAccountBorrows(address(this), PoolLib.MATURITY_ALL), total);

    for (uint256 i = 1; i < 6 + 1; i++) {
      pool.repayMP(
        i * POOL_ID,
        address(this),
        uint256(1 ether).fmul(1e18 + (FEE_MP * i * POOL_ID) / 365 days, 1e18),
        1.01 ether
      );
    }
  }
}
