// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { DSTest } from "ds-test/test.sol";
import { FixedPointMathLib } from "@rari-capital/solmate-v6/src/utils/FixedPointMathLib.sol";
import { PoolLib } from "../../contracts/utils/PoolLib.sol";
import { PoolAccounting } from "../../contracts/PoolAccounting.sol";
import { MockInterestRateModel } from "../../contracts/mocks/MockInterestRateModel.sol";

contract PoolAccountingTest is DSTest, PoolAccounting {
  using FixedPointMathLib for uint256;

  uint256 internal constant POOL_ID = 7 days;
  uint256 internal constant FEE_MP = 0.01e18;
  uint256 internal constant FEE_SP = 0.1e18;

  Vm internal vm = Vm(HEVM_ADDRESS);

  constructor() PoolAccounting(new MockInterestRateModel(FEE_SP), 0.02e18 / uint256(1 days), 0) {} // solhint-disable-line no-empty-blocks, max-line-length

  function testAtomicDepositBorrowRepayWithdraw() external {
    depositMP(POOL_ID, address(this), 1 ether, 0 ether);
    borrowMP(POOL_ID, address(this), 1 ether, 1.1 ether, 0);
    repayMP(POOL_ID, address(this), 1 ether, 1.1 ether);
    withdrawMP(POOL_ID, address(this), 0.9 ether, 0.8 ether, 0);
  }

  function testFailTooMuchSlippageDeposit() external {
    depositMP(POOL_ID, address(this), 1 ether, 1.1 ether);
  }

  function testFailTooMuchSlippageBorrow() external {
    depositMP(POOL_ID, address(this), 1 ether, 1 ether);
    borrowMP(POOL_ID, address(this), 1 ether, 1 ether, 0);
  }

  function testFailTooMuchSlippageRepay() external {
    depositMP(POOL_ID, address(this), 1 ether, 1 ether);
    borrowMP(POOL_ID, address(this), 1 ether, 1.1 ether, 0);
    repayMP(POOL_ID, address(this), 1 ether, 0.99 ether);
  }

  function testFailTooMuchSlippageWithdraw() external {
    depositMP(POOL_ID, address(this), 1 ether, 1 ether);
    withdrawMP(POOL_ID, address(this), 1 ether, 1 ether, 0);
  }

  function testBorrowRepayMultiplePools() external {
    uint256 total = 0;
    for (uint256 i = 1; i < 6 + 1; i++) {
      (uint256 borrowed, ) = borrowMP(i * POOL_ID, address(this), 1 ether, 1.1 ether, 100 ether);
      total += borrowed;
    }

    assertEq(getAccountBorrows(address(this), PoolLib.MATURITY_ALL), total);

    for (uint256 i = 1; i < 6 + 1; i++) {
      repayMP(
        i * POOL_ID,
        address(this),
        uint256(1 ether).fmul(1e18 + (FEE_MP * i * POOL_ID) / 365 days, 1e18),
        1.01 ether
      );
    }
  }
}
