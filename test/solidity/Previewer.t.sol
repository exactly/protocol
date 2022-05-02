// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { DSTestPlus } from "@rari-capital/solmate/src/test/utils/DSTestPlus.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { Auditor, ExactlyOracle } from "../../contracts/Auditor.sol";
import { MockToken } from "../../contracts/mocks/MockToken.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { FixedLender } from "../../contracts/FixedLender.sol";
import { Previewer } from "../../contracts/periphery/Previewer.sol";

contract PreviewerTest is DSTestPlus {
  address internal constant BOB = address(69);
  address internal constant ALICE = address(70);

  Vm internal vm = Vm(HEVM_ADDRESS);
  FixedLender internal fixedLender;
  Previewer internal previewer;

  function setUp() external {
    MockToken mockToken = new MockToken("DAI", "DAI", 18, 150_000 ether);
    MockOracle mockOracle = new MockOracle();
    mockOracle.setPrice("DAI", 1e18);
    Auditor auditor = new Auditor(ExactlyOracle(address(mockOracle)), 1.1e18);
    InterestRateModel interestRateModel = new InterestRateModel(0.72e18, -0.22e18, 3e18, 2e18, 0.1e18);

    fixedLender = new FixedLender(mockToken, "DAI", 12, 1e18, auditor, interestRateModel, 0.02e18 / uint256(1 days), 0);
    auditor.enableMarket(fixedLender, 0.8e18, "DAI", "DAI", 18);

    vm.label(BOB, "Bob");
    vm.label(ALICE, "Alice");
    mockToken.transfer(BOB, 50_000 ether);
    mockToken.transfer(ALICE, 50_000 ether);
    mockToken.approve(address(fixedLender), 50_000 ether);
    vm.prank(BOB);
    mockToken.approve(address(fixedLender), 50_000 ether);
    vm.prank(ALICE);
    mockToken.approve(address(fixedLender), 50_000 ether);

    previewer = new Previewer();
  }

  function testPreviewYieldAtMaturityReturningAccurateAmount() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 earningsPreviewed = previewer.previewYieldAtMaturity(fixedLender, maturity, 1 ether);
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));
    (, uint256 earningsAfterDeposit) = fixedLender.mpUserSuppliedAmount(maturity, address(this));

    assertEq(earningsPreviewed, earningsAfterDeposit);
  }

  function testPreviewYieldAtMaturityWithZeroAmount() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 earningsPreviewed = previewer.previewYieldAtMaturity(fixedLender, maturity, 0);

    assertEq(earningsPreviewed, 0);
  }

  function testPreviewYieldAtMaturityWithOneUnit() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 earningsPreviewed = previewer.previewYieldAtMaturity(fixedLender, maturity, 1);

    assertEq(earningsPreviewed, 0);
  }

  function testPreviewYieldAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(2 days);
    fixedLender.borrowAtMaturity(maturity, 2.3 ether, 3 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 earningsPreviewed = previewer.previewYieldAtMaturity(fixedLender, maturity, 0.47 ether);
    fixedLender.depositAtMaturity(maturity, 0.47 ether, 0.47 ether, address(this));
    (, uint256 earningsAfterDeposit) = fixedLender.mpUserSuppliedAmount(maturity, address(this));
    assertEq(earningsPreviewed, earningsAfterDeposit);

    vm.warp(5 days);
    earningsPreviewed = previewer.previewYieldAtMaturity(fixedLender, maturity, 1 ether);
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, BOB);
    (, earningsAfterDeposit) = fixedLender.mpUserSuppliedAmount(maturity, BOB);
    assertEq(earningsPreviewed, earningsAfterDeposit);

    vm.warp(6 days);
    earningsPreviewed = previewer.previewYieldAtMaturity(fixedLender, maturity, 20 ether);
    fixedLender.depositAtMaturity(maturity, 20 ether, 20 ether, ALICE);
    (, earningsAfterDeposit) = fixedLender.mpUserSuppliedAmount(maturity, ALICE);
    assertEq(earningsPreviewed, earningsAfterDeposit);
  }

  function testPreviewYieldAtMaturityWithEmptyMaturity() external {
    assertEq(previewer.previewYieldAtMaturity(fixedLender, 7 days, 1 ether), 0);
  }

  function testPreviewYieldAtMaturityWithEmptyMaturityAndZeroAmount() external {
    assertEq(previewer.previewYieldAtMaturity(fixedLender, 7 days, 0), 0);
  }

  function testPreviewYieldAtMaturityWithInvalidMaturity() external {
    assertEq(previewer.previewYieldAtMaturity(fixedLender, 376 seconds, 1 ether), 0);
  }

  function testPreviewYieldAtMaturityWithSameTimestamp() external {
    uint256 maturity = 7 days;
    vm.warp(maturity);
    assertEq(previewer.previewYieldAtMaturity(fixedLender, maturity, 1 ether), 0);
  }

  function testFailPreviewYieldAtMaturityWithMaturedMaturity() external {
    uint256 maturity = 7 days;
    vm.warp(maturity + 1);
    previewer.previewYieldAtMaturity(fixedLender, maturity, 1 ether);
  }

  function testPreviewFeeAtMaturityReturningAccurateAmount() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    uint256 feesPreviewed = previewer.previewFeeAtMaturity(fixedLender, maturity, 1 ether);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));
    (, uint256 feesAfterBorrow) = fixedLender.mpUserBorrowedAmount(maturity, address(this));

    assertEq(feesPreviewed, feesAfterBorrow);
  }

  function testPreviewFeeAtMaturityWithZeroAmount() external {
    fixedLender.deposit(10 ether, address(this));
    assertEq(previewer.previewFeeAtMaturity(fixedLender, 7 days, 0), 0);
  }

  function testPreviewFeeAtMaturityWithOneUnit() external {
    fixedLender.deposit(10 ether, address(this));
    assertEq(previewer.previewFeeAtMaturity(fixedLender, 7 days, 1), 0);
  }

  function testPreviewFeeAtMaturityWithFiveUnits() external {
    fixedLender.deposit(10 ether, address(this));
    assertEq(previewer.previewFeeAtMaturity(fixedLender, 7 days, 5), 0);
  }

  function testPreviewFeeAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.deposit(10 ether, BOB);
    fixedLender.deposit(50 ether, ALICE);

    vm.warp(2 days);
    uint256 feesPreviewed = previewer.previewFeeAtMaturity(fixedLender, maturity, 2.3 ether);
    fixedLender.borrowAtMaturity(maturity, 2.3 ether, 3 ether, address(this), address(this));
    (, uint256 feesAfterBorrow) = fixedLender.mpUserBorrowedAmount(maturity, address(this));
    assertEq(feesPreviewed, feesAfterBorrow);

    vm.warp(3 days);
    fixedLender.depositAtMaturity(maturity, 1.47 ether, 1.47 ether, address(this));

    vm.warp(5 days);
    feesPreviewed = previewer.previewFeeAtMaturity(fixedLender, maturity, 1 ether);
    vm.prank(BOB);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, BOB, BOB);
    (, feesAfterBorrow) = fixedLender.mpUserBorrowedAmount(maturity, BOB);
    assertEq(feesPreviewed, feesAfterBorrow);

    vm.warp(6 days);
    feesPreviewed = previewer.previewFeeAtMaturity(fixedLender, maturity, 20 ether);
    vm.prank(ALICE);
    fixedLender.borrowAtMaturity(maturity, 20 ether, 30 ether, ALICE, ALICE);
    (, feesAfterBorrow) = fixedLender.mpUserBorrowedAmount(maturity, ALICE);
    assertEq(feesPreviewed, feesAfterBorrow);
  }

  function testPreviewFeeAtMaturityWithInvalidMaturity() external {
    fixedLender.deposit(10 ether, address(this));
    previewer.previewFeeAtMaturity(fixedLender, 376 seconds, 1 ether);
  }

  function testFailPreviewFeeAtMaturityWithSameTimestamp() external {
    uint256 maturity = 7 days;
    vm.warp(maturity);
    previewer.previewFeeAtMaturity(fixedLender, maturity, 1 ether);
  }

  function testFailPreviewFeeAtMaturityWithMaturedMaturity() external {
    uint256 maturity = 7 days;
    vm.warp(maturity + 1);
    previewer.previewFeeAtMaturity(fixedLender, maturity, 1 ether);
  }
}
