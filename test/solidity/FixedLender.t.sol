// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { DSTest } from "ds-test/test.sol";
import { FixedPointMathLib } from "@rari-capital/solmate-v6/src/utils/FixedPointMathLib.sol";
import { MockInterestRateModel } from "../../contracts/mocks/MockInterestRateModel.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { Auditor } from "../../contracts/Auditor.sol";
import { MockToken } from "../../contracts/mocks/MockToken.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { FixedLender } from "../../contracts/FixedLender.sol";

contract FixedLenderTest is DSTest {
  Vm internal vm = Vm(HEVM_ADDRESS);
  FixedLender internal fixedLender;
  MockToken internal mockToken;

  event Transfer(address indexed from, address indexed to, uint256 amount);
  event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
  event Withdraw(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
  event DepositToMaturityPool(address indexed from, uint256 amount, uint256 fee, uint256 maturityDate);
  event BorrowFromMaturityPool(address indexed to, uint256 amount, uint256 fee, uint256 maturityDate);
  event WithdrawFromMaturityPool(address indexed from, uint256 amount, uint256 amountDiscounted, uint256 maturityDate);
  event RepayToMaturityPool(
    address indexed payer,
    address indexed borrower,
    uint256 repayAmount,
    uint256 debtCovered,
    uint256 maturityDate
  );

  function setUp() external {
    mockToken = new MockToken("DAI", "DAI", 18, 100 ether);
    MockOracle mockOracle = new MockOracle();
    mockOracle.setPrice("DAI", 1e8);
    Auditor auditor = new Auditor(mockOracle);
    InterestRateModel interestRateModel = new InterestRateModel(0.0495e18, -0.025e18, 1.1e18, 1e18, 0);
    MockInterestRateModel mockInterestRateModel = new MockInterestRateModel(address(interestRateModel));
    mockInterestRateModel.setBorrowRate(0.05e18);

    fixedLender = new FixedLender(mockToken, "DAI", auditor, mockInterestRateModel, 0.02e18 / uint256(1 days), 0);

    auditor.enableMarket(fixedLender, 0.8e18, "DAI", "DAI", 18);

    mockToken.approve(address(fixedLender), 100 ether);
  }

  function testDepositToSmartPool() external {
    vm.expectEmit(true, true, false, true);
    emit Deposit(address(this), address(this), 1 ether, 1 ether);

    fixedLender.deposit(1 ether, address(this));
  }

  function testWithdrawFromSmartPool() external {
    fixedLender.deposit(1 ether, address(this));
    vm.roll(block.number + 1); // we increase block number to avoid same block deposit & withdraw error

    vm.expectEmit(true, true, false, true);
    emit Transfer(address(fixedLender), address(this), 1 ether);
    fixedLender.withdraw(1 ether, address(this), address(this));
  }

  function testDepositToMaturityPool() external {
    vm.expectEmit(true, false, false, true);
    emit DepositToMaturityPool(address(this), 1 ether, 0, 7 days);
    fixedLender.depositToMaturityPool(1 ether, 7 days, 1 ether);
  }

  function testWithdrawFromMaturityPool() external {
    fixedLender.depositToMaturityPool(1 ether, 7 days, 1 ether);

    vm.expectEmit(true, false, false, true);
    // TODO: fix wrong hardcoded value
    emit WithdrawFromMaturityPool(address(this), 1 ether, 952380952380952380, 7 days);
    fixedLender.withdrawFromMaturityPool(1 ether, 0.95 ether, 7 days);
  }

  function testBorrowFromMaturityPool() external {
    fixedLender.deposit(12 ether, address(this));

    vm.expectEmit(true, false, false, true);
    emit BorrowFromMaturityPool(address(this), 1 ether, 0.05 ether, 7 days);
    fixedLender.borrowFromMaturityPool(1 ether, 7 days, 2 ether);
  }

  function testRepayToMaturityPool() external {
    fixedLender.deposit(12 ether, address(this));
    fixedLender.borrowFromMaturityPool(1 ether, 7 days, 1.05 ether);

    vm.expectEmit(true, false, false, true);
    emit RepayToMaturityPool(address(this), address(this), 1 ether, 1.05 ether, 7 days);
    fixedLender.repayToMaturityPool(address(this), 7 days, 1.5 ether, 1.5 ether);
  }

  function testMultipleDepositsToSmartPool() external {
    fixedLender.deposit(1 ether, address(this));
    fixedLender.deposit(1 ether, address(this));
    fixedLender.deposit(1 ether, address(this));
    fixedLender.deposit(1 ether, address(this));
    fixedLender.deposit(1 ether, address(this));
    fixedLender.deposit(1 ether, address(this));
    fixedLender.deposit(1 ether, address(this));
  }
}
