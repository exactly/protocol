// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { DSTestPlus } from "@rari-capital/solmate/src/test/utils/DSTestPlus.sol";
import { FixedPointMathLib } from "@rari-capital/solmate-v6/src/utils/FixedPointMathLib.sol";
import { MockInterestRateModel } from "../../contracts/mocks/MockInterestRateModel.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { Auditor } from "../../contracts/Auditor.sol";
import { MockToken } from "../../contracts/mocks/MockToken.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { FixedLender } from "../../contracts/FixedLender.sol";

contract FixedLenderTest is DSTestPlus {
  address internal constant BOB = address(69);

  Vm internal vm = Vm(HEVM_ADDRESS);
  FixedLender internal fixedLender;
  MockToken internal mockToken;

  event Transfer(address indexed from, address indexed to, uint256 amount);
  event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
  event Withdraw(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
  event DepositAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed owner,
    uint256 assets,
    uint256 fee
  );
  event WithdrawAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed owner,
    uint256 assets,
    uint256 assetsDiscounted
  );
  event BorrowAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 fee
  );
  event RepayAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed borrower,
    uint256 assets,
    uint256 debtCovered
  );

  function setUp() external {
    mockToken = new MockToken("DAI", "DAI", 18, 100_000 ether);
    MockOracle mockOracle = new MockOracle();
    mockOracle.setPrice("DAI", 1e8);
    Auditor auditor = new Auditor(mockOracle);
    InterestRateModel interestRateModel = new InterestRateModel(0.0495e18, -0.025e18, 1.1e18, 1e18, 0);
    MockInterestRateModel mockInterestRateModel = new MockInterestRateModel(address(interestRateModel));
    mockInterestRateModel.setBorrowRate(0.1e18);

    fixedLender = new FixedLender(mockToken, "DAI", auditor, mockInterestRateModel, 0.02e18 / uint256(1 days), 0);

    auditor.enableMarket(fixedLender, 0.8e18, "DAI", "DAI", 18);

    vm.label(BOB, "Bob");
    mockToken.transfer(BOB, 50_000 ether);
    mockToken.approve(address(fixedLender), 50_000 ether);
    vm.prank(BOB);
    mockToken.approve(address(fixedLender), 50_000 ether);
  }

  function testDepositToSmartPool() external {
    vm.expectEmit(true, true, true, true);
    emit Deposit(address(this), address(this), 1 ether, 1 ether);

    fixedLender.deposit(1 ether, address(this));
  }

  function testWithdrawFromSmartPool() external {
    fixedLender.deposit(1 ether, address(this));
    vm.roll(block.number + 1); // we increase block number to avoid same block deposit & withdraw error

    vm.expectEmit(true, true, true, true);
    emit Transfer(address(fixedLender), address(this), 1 ether);
    fixedLender.withdraw(1 ether, address(this), address(this));
  }

  function testDepositAtMaturity() external {
    vm.expectEmit(true, true, true, true);
    emit DepositAtMaturity(7 days, address(this), address(this), 1 ether, 0);
    fixedLender.depositAtMaturity(7 days, 1 ether, 1 ether, address(this));
  }

  function testWithdrawAtMaturity() external {
    fixedLender.depositAtMaturity(7 days, 1 ether, 1 ether, address(this));

    vm.expectEmit(true, true, true, true);
    // TODO: fix wrong hardcoded value
    emit WithdrawAtMaturity(7 days, address(this), address(this), address(this), 1 ether, 909090909090909090);
    fixedLender.withdrawAtMaturity(7 days, 1 ether, 0.9 ether, address(this), address(this));
  }

  function testBorrowAtMaturity() external {
    fixedLender.deposit(12 ether, address(this));

    vm.expectEmit(true, true, true, true);
    emit BorrowAtMaturity(7 days, address(this), address(this), address(this), 1 ether, 0.1 ether);
    fixedLender.borrowAtMaturity(7 days, 1 ether, 2 ether, address(this), address(this));
  }

  function testRepayAtMaturity() external {
    fixedLender.deposit(12 ether, address(this));
    fixedLender.borrowAtMaturity(7 days, 1 ether, 1.1 ether, address(this), address(this));

    vm.expectEmit(true, true, true, true);
    emit RepayAtMaturity(7 days, address(this), address(this), 1 ether, 1.1 ether);
    fixedLender.repayAtMaturity(7 days, 1.5 ether, 1.5 ether, address(this));
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

  function testSmartPoolEarningsDistribution() external {
    vm.prank(BOB);
    fixedLender.deposit(10_000 ether, BOB);

    vm.warp(7 days);

    vm.prank(BOB);
    fixedLender.borrowAtMaturity(7 days * 2, 1_000 ether, 1_100 ether, BOB, BOB);

    vm.warp(7 days + 3.5 days);
    fixedLender.deposit(10_000 ether, address(this));
    assertEq(fixedLender.balanceOf(BOB), 10_000 ether);
    assertEq(fixedLender.maxWithdraw(address(this)), 10_000 ether - 1);
    assertRelApproxEq(fixedLender.balanceOf(address(this)), 9950 ether, 2.5e13);

    vm.warp(7 days + 5 days);
    fixedLender.deposit(1_000 ether, address(this));
    assertRelApproxEq(fixedLender.balanceOf(address(this)), 10944 ether, 2.5e13);
  }
}
