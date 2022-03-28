// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { Vm } from "forge-std/Vm.sol";
import { DSTest } from "ds-test/test.sol";
import { FixedLender } from "../../contracts/FixedLender.sol";
import { PoolAccounting } from "../../contracts/PoolAccounting.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { Auditor } from "../../contracts/Auditor.sol";
import { EToken } from "../../contracts/EToken.sol";
import { MockToken } from "../../contracts/mocks/MockToken.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { MockInterestRateModel } from "../../contracts/mocks/MockInterestRateModel.sol";

contract FixedLenderTest is DSTest {
  Vm internal vm = Vm(HEVM_ADDRESS);
  FixedLender internal fixedLender;
  MockToken internal mockToken;

  uint32 public constant INTERVAL = 7 days;
  uint256 public nextMaturityDate;

  event DepositToSmartPool(address indexed user, uint256 amount);
  event WithdrawFromSmartPool(address indexed user, uint256 amount);
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

    fixedLender = new FixedLender(
      mockToken,
      "DAI",
      "eDAI",
      "eDAI",
      18,
      0.02e18 / uint256(1 days),
      auditor,
      mockInterestRateModel
    );

    auditor.enableMarket(fixedLender, 0.8e18, "DAI", "DAI", 18);
    nextMaturityDate = INTERVAL;

    mockToken.approve(address(fixedLender), 100 ether);
  }

  function testDepositToSmartPool() external {
    vm.expectEmit(true, false, false, true);
    emit DepositToSmartPool(address(this), 1 ether);

    fixedLender.depositToSmartPool(1 ether);
  }

  function testWithdrawFromSmartPool() external {
    fixedLender.depositToSmartPool(1 ether);
    vm.roll(block.number + 1); // we increase block number to avoid same block deposit & withdraw error

    vm.expectEmit(true, false, false, true);
    emit WithdrawFromSmartPool(address(this), 1 ether);
    fixedLender.withdrawFromSmartPool(1 ether);
  }

  function testDepositToMaturityPool() external {
    vm.expectEmit(true, false, false, true);
    emit DepositToMaturityPool(address(this), 1 ether, 0, nextMaturityDate);
    fixedLender.depositToMaturityPool(1 ether, nextMaturityDate, 1 ether);
  }

  function testWithdrawFromMaturityPool() external {
    fixedLender.depositToMaturityPool(1 ether, nextMaturityDate, 1 ether);

    vm.expectEmit(true, false, false, true);
    // TODO: fix wrong hardcoded value
    emit WithdrawFromMaturityPool(address(this), 1 ether, 952380952380952380, nextMaturityDate);
    fixedLender.withdrawFromMaturityPool(1 ether, 0.95 ether, nextMaturityDate);
  }

  function testBorrowFromMaturityPool() external {
    fixedLender.depositToSmartPool(12 ether);

    vm.expectEmit(true, false, false, true);
    emit BorrowFromMaturityPool(address(this), 1 ether, 0.05 ether, nextMaturityDate);
    fixedLender.borrowFromMaturityPool(1 ether, nextMaturityDate, 2 ether);
  }

  function testRepayToMaturityPool() external {
    fixedLender.depositToSmartPool(12 ether);
    fixedLender.borrowFromMaturityPool(1 ether, nextMaturityDate, 1.05 ether);

    vm.expectEmit(true, false, false, true);
    emit RepayToMaturityPool(address(this), address(this), 1 ether, 1.05 ether, nextMaturityDate);
    fixedLender.repayToMaturityPool(address(this), nextMaturityDate, 1.5 ether, 1.5 ether);
  }
}
