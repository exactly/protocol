// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "@rari-capital/solmate/src/test/utils/mocks/MockERC20.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { Auditor, ExactlyOracle } from "../../contracts/Auditor.sol";
import { FixedLender, InterestRateModel, ERC20 } from "../../contracts/FixedLender.sol";
import { MockInterestRateModel } from "../../contracts/mocks/MockInterestRateModel.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { PoolLib } from "../../contracts/utils/PoolLib.sol";

contract PoolAccountingTest is Test, FixedLender {
  using FixedPointMathLib for uint256;

  uint256 internal constant POOL_ID = 4 weeks;
  uint256 internal constant FEE_MP = 0.01e18;
  uint256 internal constant FEE_SP = 0.1e18;

  constructor()
    FixedLender(
      ERC20(address(new MockERC20("DAI", "DAI", 18))),
      3,
      1e18,
      Auditor(address(new Auditor(ExactlyOracle(address(new MockOracle())), 1.1e18))),
      InterestRateModel(address(new MockInterestRateModel(FEE_SP))),
      0.02e18 / uint256(1 days),
      0,
      FixedLender.DampSpeed(0.0046e18, 0.42e18)
    )
  {} // solhint-disable-line no-empty-blocks, max-line-length

  function testAtomicDepositBorrowRepayWithdraw() external {
    depositMP(POOL_ID, address(this), 1 ether, 0 ether);
    borrowMP(POOL_ID, address(this), 1 ether, 1.1 ether);
    repayMP(POOL_ID, address(this), 1 ether, 1.1 ether);
    withdrawMP(POOL_ID, address(this), 0.9 ether, 0.8 ether);
  }

  function testFailTooMuchSlippageDeposit() external {
    depositMP(POOL_ID, address(this), 1 ether, 1.1 ether);
  }

  function testFailTooMuchSlippageBorrow() external {
    depositMP(POOL_ID, address(this), 1 ether, 1 ether);
    borrowMP(POOL_ID, address(this), 1 ether, 1 ether);
  }

  function testFailTooMuchSlippageRepay() external {
    depositMP(POOL_ID, address(this), 1 ether, 1 ether);
    borrowMP(POOL_ID, address(this), 1 ether, 1.1 ether);
    repayMP(POOL_ID, address(this), 1 ether, 0.99 ether);
  }

  function testFailTooMuchSlippageWithdraw() external {
    depositMP(POOL_ID, address(this), 1 ether, 1 ether);
    withdrawMP(POOL_ID, address(this), 1 ether, 1 ether);
  }

  function testBorrowRepayMultiplePools() external {
    uint256 total = 0;
    smartPoolAssets = 100 ether;
    for (uint256 i = 1; i < 6 + 1; i++) {
      (uint256 borrowed, ) = borrowMP(i * POOL_ID, address(this), 1 ether, 1.1 ether);
      total += borrowed;
    }

    (uint256 position, ) = getAccountBorrows(address(this), PoolLib.MATURITY_ALL);
    assertEq(position, total);

    for (uint256 i = 1; i < 6 + 1; i++) {
      repayMP(
        i * POOL_ID,
        address(this),
        uint256(1 ether).mulWadDown(1e18 + (FEE_MP * i * POOL_ID) / 365 days),
        1.01 ether
      );
    }
  }
}
