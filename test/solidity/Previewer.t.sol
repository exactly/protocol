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
  MockToken internal mockToken;

  function setUp() external {
    mockToken = new MockToken("DAI", "DAI", 18, 150_000 ether);
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

  function testPreviewDepositAtMaturityReturningAccurateAmount() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 earningsPreviewed = previewer.previewDepositAtMaturity(fixedLender, maturity, 1 ether);
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));
    (, uint256 earningsAfterDeposit) = fixedLender.mpUserSuppliedAmount(maturity, address(this));

    assertEq(earningsPreviewed, earningsAfterDeposit);
  }

  function testPreviewDepositAtMaturityWithZeroAmount() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 earningsPreviewed = previewer.previewDepositAtMaturity(fixedLender, maturity, 0);

    assertEq(earningsPreviewed, 0);
  }

  function testPreviewDepositAtMaturityWithOneUnit() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 earningsPreviewed = previewer.previewDepositAtMaturity(fixedLender, maturity, 1);

    assertEq(earningsPreviewed, 0);
  }

  function testPreviewDepositAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(2 days);
    fixedLender.borrowAtMaturity(maturity, 2.3 ether, 3 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 earningsPreviewed = previewer.previewDepositAtMaturity(fixedLender, maturity, 0.47 ether);
    fixedLender.depositAtMaturity(maturity, 0.47 ether, 0.47 ether, address(this));
    (, uint256 earningsAfterDeposit) = fixedLender.mpUserSuppliedAmount(maturity, address(this));
    assertEq(earningsPreviewed, earningsAfterDeposit);

    vm.warp(5 days);
    earningsPreviewed = previewer.previewDepositAtMaturity(fixedLender, maturity, 1 ether);
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, BOB);
    (, earningsAfterDeposit) = fixedLender.mpUserSuppliedAmount(maturity, BOB);
    assertEq(earningsPreviewed, earningsAfterDeposit);

    vm.warp(6 days);
    earningsPreviewed = previewer.previewDepositAtMaturity(fixedLender, maturity, 20 ether);
    fixedLender.depositAtMaturity(maturity, 20 ether, 20 ether, ALICE);
    (, earningsAfterDeposit) = fixedLender.mpUserSuppliedAmount(maturity, ALICE);
    assertEq(earningsPreviewed, earningsAfterDeposit);
  }

  function testPreviewDepositAtMaturityWithEmptyMaturity() external {
    assertEq(previewer.previewDepositAtMaturity(fixedLender, 7 days, 1 ether), 0);
  }

  function testPreviewDepositAtMaturityWithEmptyMaturityAndZeroAmount() external {
    assertEq(previewer.previewDepositAtMaturity(fixedLender, 7 days, 0), 0);
  }

  function testPreviewDepositAtMaturityWithInvalidMaturity() external {
    assertEq(previewer.previewDepositAtMaturity(fixedLender, 376 seconds, 1 ether), 0);
  }

  function testPreviewDepositAtMaturityWithSameTimestamp() external {
    uint256 maturity = 7 days;
    vm.warp(maturity);
    assertEq(previewer.previewDepositAtMaturity(fixedLender, maturity, 1 ether), 0);
  }

  function testFailPreviewDepositAtMaturityWithMaturedMaturity() external {
    uint256 maturity = 7 days;
    vm.warp(maturity + 1);
    previewer.previewDepositAtMaturity(fixedLender, maturity, 1 ether);
  }

  function testPreviewBorrowAtMaturityReturningAccurateAmount() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    uint256 feesPreviewed = previewer.previewBorrowAtMaturity(fixedLender, maturity, 1 ether);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));
    (, uint256 feesAfterBorrow) = fixedLender.mpUserBorrowedAmount(maturity, address(this));

    assertEq(feesPreviewed, feesAfterBorrow);
  }

  function testPreviewBorrowAtMaturityWithZeroAmount() external {
    fixedLender.deposit(10 ether, address(this));
    assertEq(previewer.previewBorrowAtMaturity(fixedLender, 7 days, 0), 0);
  }

  function testPreviewBorrowAtMaturityWithOneUnit() external {
    fixedLender.deposit(10 ether, address(this));
    assertEq(previewer.previewBorrowAtMaturity(fixedLender, 7 days, 1), 0);
  }

  function testPreviewBorrowAtMaturityWithFiveUnits() external {
    fixedLender.deposit(10 ether, address(this));
    assertEq(previewer.previewBorrowAtMaturity(fixedLender, 7 days, 5), 0);
  }

  function testPreviewBorrowAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.deposit(10 ether, BOB);
    fixedLender.deposit(50 ether, ALICE);

    vm.warp(2 days);
    uint256 feesPreviewed = previewer.previewBorrowAtMaturity(fixedLender, maturity, 2.3 ether);
    fixedLender.borrowAtMaturity(maturity, 2.3 ether, 3 ether, address(this), address(this));
    (, uint256 feesAfterBorrow) = fixedLender.mpUserBorrowedAmount(maturity, address(this));
    assertEq(feesPreviewed, feesAfterBorrow);

    vm.warp(3 days);
    fixedLender.depositAtMaturity(maturity, 1.47 ether, 1.47 ether, address(this));

    vm.warp(5 days);
    feesPreviewed = previewer.previewBorrowAtMaturity(fixedLender, maturity, 1 ether);
    vm.prank(BOB);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, BOB, BOB);
    (, feesAfterBorrow) = fixedLender.mpUserBorrowedAmount(maturity, BOB);
    assertEq(feesPreviewed, feesAfterBorrow);

    vm.warp(6 days);
    feesPreviewed = previewer.previewBorrowAtMaturity(fixedLender, maturity, 20 ether);
    vm.prank(ALICE);
    fixedLender.borrowAtMaturity(maturity, 20 ether, 30 ether, ALICE, ALICE);
    (, feesAfterBorrow) = fixedLender.mpUserBorrowedAmount(maturity, ALICE);
    assertEq(feesPreviewed, feesAfterBorrow);
  }

  function testPreviewBorrowAtMaturityWithInvalidMaturity() external {
    fixedLender.deposit(10 ether, address(this));
    previewer.previewBorrowAtMaturity(fixedLender, 376 seconds, 1 ether);
  }

  function testFailPreviewBorrowAtMaturityWithSameTimestamp() external {
    uint256 maturity = 7 days;
    vm.warp(maturity);
    previewer.previewBorrowAtMaturity(fixedLender, maturity, 1 ether);
  }

  function testFailPreviewBorrowAtMaturityWithMaturedMaturity() external {
    uint256 maturity = 7 days;
    vm.warp(maturity + 1);
    previewer.previewBorrowAtMaturity(fixedLender, maturity, 1 ether);
  }

  function testPreviewRepayAtMaturityReturningAccurateAmount() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.deposit(10 ether, BOB);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.prank(BOB);
    fixedLender.borrowAtMaturity(maturity, 2 ether, 3 ether, BOB, BOB);

    vm.warp(3 days);
    uint256 discountPreviewed = previewer.previewRepayAtMaturity(fixedLender, maturity, 1 ether, address(this));
    uint256 balanceBeforeRepay = mockToken.balanceOf(address(this));
    fixedLender.repayAtMaturity(maturity, 1 ether, 1 ether, address(this));
    uint256 discountAfterRepay = 1 ether - (balanceBeforeRepay - mockToken.balanceOf(address(this)));

    assertEq(discountPreviewed, discountAfterRepay);
  }

  function testPreviewRepayAtMaturityWithZeroAmount() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 discountPreviewed = previewer.previewRepayAtMaturity(fixedLender, maturity, 0, address(this));

    assertEq(discountPreviewed, 0);
  }

  function testPreviewRepayAtMaturityWithOneUnit() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 discountPreviewed = previewer.previewRepayAtMaturity(fixedLender, maturity, 1, address(this));

    assertEq(discountPreviewed, 0);
  }

  function testPreviewRepayAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.deposit(10 ether, BOB);
    fixedLender.borrowAtMaturity(maturity, 3 ether, 4 ether, address(this), address(this));

    vm.warp(2 days);
    vm.prank(BOB);
    fixedLender.borrowAtMaturity(maturity, 2.3 ether, 3 ether, BOB, BOB);

    vm.warp(3 days);
    uint256 discountPreviewed = previewer.previewRepayAtMaturity(fixedLender, maturity, 0.47 ether, address(this));
    uint256 balanceBeforeRepay = mockToken.balanceOf(address(this));
    fixedLender.repayAtMaturity(maturity, 0.47 ether, 0.47 ether, address(this));
    uint256 discountAfterRepay = 0.47 ether - (balanceBeforeRepay - mockToken.balanceOf(address(this)));
    assertEq(discountPreviewed, discountAfterRepay);

    vm.warp(5 days);
    discountPreviewed = previewer.previewRepayAtMaturity(fixedLender, maturity, 1.1 ether, address(this));
    balanceBeforeRepay = mockToken.balanceOf(address(this));
    fixedLender.repayAtMaturity(maturity, 1.1 ether, 1.1 ether, address(this));
    discountAfterRepay = 1.1 ether - (balanceBeforeRepay - mockToken.balanceOf(address(this)));
    assertEq(discountPreviewed, discountAfterRepay);

    vm.warp(6 days);
    (uint256 bobOwedPrincipal, uint256 bobOwedFee) = fixedLender.mpUserBorrowedAmount(maturity, BOB);
    uint256 totalOwedBob = bobOwedPrincipal + bobOwedFee;
    discountPreviewed = previewer.previewRepayAtMaturity(fixedLender, maturity, totalOwedBob, BOB);
    balanceBeforeRepay = mockToken.balanceOf(BOB);
    vm.prank(BOB);
    fixedLender.repayAtMaturity(maturity, totalOwedBob, totalOwedBob, BOB);
    discountAfterRepay = totalOwedBob - (balanceBeforeRepay - mockToken.balanceOf(BOB));
    (bobOwedPrincipal, ) = fixedLender.mpUserBorrowedAmount(maturity, BOB);
    assertEq(discountPreviewed, discountAfterRepay);
    assertEq(bobOwedPrincipal, 0);
  }

  function testPreviewRepayAtMaturityWithEmptyMaturity() external {
    assertEq(previewer.previewRepayAtMaturity(fixedLender, 7 days, 1 ether, address(this)), 0);
  }

  function testPreviewRepayAtMaturityWithEmptyMaturityAndZeroAmount() external {
    assertEq(previewer.previewRepayAtMaturity(fixedLender, 7 days, 0, address(this)), 0);
  }

  function testPreviewRepayAtMaturityWithInvalidMaturity() external {
    assertEq(previewer.previewRepayAtMaturity(fixedLender, 376 seconds, 1 ether, address(this)), 0);
  }

  function testFailPreviewRepayAtMaturityWithSameTimestamp() external {
    uint256 maturity = 7 days;
    vm.warp(maturity);
    previewer.previewRepayAtMaturity(fixedLender, maturity, 1 ether, address(this));
  }

  function testFailPreviewRepayAtMaturityWithMaturedMaturity() external {
    uint256 maturity = 7 days;
    vm.warp(maturity + 1);
    previewer.previewRepayAtMaturity(fixedLender, maturity, 1 ether, address(this));
  }

  function testPreviewWithdrawAtMaturityReturningAccurateAmount() external {
    uint256 maturity = 7 days;
    fixedLender.depositAtMaturity(maturity, 10 ether, 10 ether, address(this));

    vm.warp(3 days);
    uint256 feePreviewed = previewer.previewWithdrawAtMaturity(fixedLender, maturity, 10 ether);
    uint256 balanceBeforeWithdraw = mockToken.balanceOf(address(this));
    fixedLender.withdrawAtMaturity(maturity, 10 ether, 0.9 ether, address(this), address(this));
    uint256 feeAfterWithdraw = 10 ether - (mockToken.balanceOf(address(this)) - balanceBeforeWithdraw);

    assertEq(feePreviewed, feeAfterWithdraw);
  }

  function testPreviewWithdrawAtMaturityWithZeroAmount() external {
    uint256 maturity = 7 days;
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));

    vm.warp(3 days);
    assertEq(previewer.previewWithdrawAtMaturity(fixedLender, maturity, 0), 0);
  }

  function testPreviewWithdrawAtMaturityWithOneUnit() external {
    uint256 maturity = 7 days;
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));

    vm.warp(3 days);
    uint256 feesPreviewed = previewer.previewWithdrawAtMaturity(fixedLender, maturity, 1);

    assertEq(feesPreviewed, 1);
  }

  function testPreviewWithdrawAtMaturityWithFiveUnits() external {
    uint256 maturity = 7 days;
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));

    vm.warp(3 days);
    uint256 feesPreviewed = previewer.previewWithdrawAtMaturity(fixedLender, maturity, 5);

    assertEq(feesPreviewed, 1);
  }

  function testPreviewWithdrawAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = 7 days;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.deposit(10 ether, BOB);
    fixedLender.depositAtMaturity(maturity, 5 ether, 5 ether, address(this));

    vm.warp(2 days);
    vm.prank(BOB);
    fixedLender.borrowAtMaturity(maturity, 2.3 ether, 3 ether, BOB, BOB);

    vm.warp(3 days);
    uint256 feePreviewed = previewer.previewWithdrawAtMaturity(fixedLender, maturity, 0.47 ether);
    uint256 balanceBeforeWithdraw = mockToken.balanceOf(address(this));
    fixedLender.withdrawAtMaturity(maturity, 0.47 ether, 0.4 ether, address(this), address(this));
    uint256 feeAfterWithdraw = 0.47 ether - (mockToken.balanceOf(address(this)) - balanceBeforeWithdraw);
    assertEq(feePreviewed, feeAfterWithdraw);

    vm.warp(5 days);
    feePreviewed = previewer.previewWithdrawAtMaturity(fixedLender, maturity, 1.1 ether);
    balanceBeforeWithdraw = mockToken.balanceOf(address(this));
    fixedLender.withdrawAtMaturity(maturity, 1.1 ether, 1 ether, address(this), address(this));
    feeAfterWithdraw = 1.1 ether - (mockToken.balanceOf(address(this)) - balanceBeforeWithdraw);
    assertEq(feePreviewed, feeAfterWithdraw);

    vm.warp(6 days);
    (uint256 addressDepositedPrincipal, uint256 addressDepositedFee) = fixedLender.mpUserSuppliedAmount(
      maturity,
      address(this)
    );
    uint256 totalDepositedAddress = addressDepositedPrincipal + addressDepositedFee;
    feePreviewed = previewer.previewWithdrawAtMaturity(fixedLender, maturity, totalDepositedAddress);
    balanceBeforeWithdraw = mockToken.balanceOf(address(this));
    fixedLender.withdrawAtMaturity(
      maturity,
      totalDepositedAddress,
      totalDepositedAddress - 1 ether,
      address(this),
      address(this)
    );
    feeAfterWithdraw = totalDepositedAddress - (mockToken.balanceOf(address(this)) - balanceBeforeWithdraw);
    (addressDepositedPrincipal, ) = fixedLender.mpUserSuppliedAmount(maturity, address(this));

    assertEq(feePreviewed, feeAfterWithdraw);
    assertEq(addressDepositedPrincipal, 0);
  }

  function testFailPreviewWithdrawAtMaturityWithEmptyMaturity() external view {
    previewer.previewWithdrawAtMaturity(fixedLender, 7 days, 1 ether);
  }

  function testFailPreviewWithdrawAtMaturityWithEmptyMaturityAndZeroAmount() external view {
    previewer.previewWithdrawAtMaturity(fixedLender, 7 days, 0);
  }

  function testFailPreviewWithdrawAtMaturityWithInvalidMaturity() external view {
    previewer.previewWithdrawAtMaturity(fixedLender, 376 seconds, 1 ether);
  }

  function testFailPreviewWithdrawAtMaturityWithSameTimestamp() external {
    uint256 maturity = 7 days;
    vm.warp(maturity);
    previewer.previewWithdrawAtMaturity(fixedLender, maturity, 1 ether);
  }

  function testFailPreviewWithdrawAtMaturityWithMaturedMaturity() external {
    uint256 maturity = 7 days;
    vm.warp(maturity + 1);
    previewer.previewWithdrawAtMaturity(fixedLender, maturity, 1 ether);
  }
}
