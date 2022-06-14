// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "@rari-capital/solmate/src/test/utils/mocks/MockERC20.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { FixedLender } from "../../contracts/FixedLender.sol";
import { Auditor, ExactlyOracle } from "../../contracts/Auditor.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { Previewer } from "../../contracts/periphery/Previewer.sol";
import { TSUtils } from "../../contracts/utils/TSUtils.sol";

contract PreviewerTest is Test {
  using FixedPointMathLib for uint256;
  address internal constant BOB = address(69);
  address internal constant ALICE = address(70);

  FixedLender internal fixedLender;
  Previewer internal previewer;
  MockERC20 internal token;
  Auditor internal auditor;
  MockOracle internal mockOracle;
  InterestRateModel internal interestRateModel;

  function setUp() external {
    token = new MockERC20("DAI", "DAI", 18);
    mockOracle = new MockOracle();
    auditor = new Auditor(ExactlyOracle(address(mockOracle)), 1.1e18);
    interestRateModel = new InterestRateModel(0.72e18, -0.22e18, 3e18, 2e18, 0.1e18);

    fixedLender = new FixedLender(
      token,
      12,
      1e18,
      auditor,
      interestRateModel,
      0.02e18 / uint256(1 days),
      0,
      FixedLender.DampSpeed(0.0046e18, 0.42e18)
    );
    mockOracle.setPrice(fixedLender, 1e18);
    auditor.enableMarket(fixedLender, 0.8e18, 18);

    vm.label(BOB, "Bob");
    vm.label(ALICE, "Alice");
    token.mint(BOB, 50_000 ether);
    token.mint(ALICE, 50_000 ether);
    token.mint(address(this), 50_000 ether);
    token.approve(address(fixedLender), 50_000 ether);
    vm.prank(BOB);
    token.approve(address(fixedLender), 50_000 ether);
    vm.prank(ALICE);
    token.approve(address(fixedLender), 50_000 ether);

    previewer = new Previewer(auditor);
  }

  function testPreviewDepositAtMaturityReturningAccurateAmount() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.deposit(10 ether, address(this));
    vm.warp(200 seconds);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 positionAssetsPreviewed = previewer.previewDepositAtMaturity(fixedLender, maturity, 1 ether);
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));
    (uint256 principalAfterDeposit, uint256 earningsAfterDeposit) = fixedLender.fixedDepositPositions(
      maturity,
      address(this)
    );

    assertEq(positionAssetsPreviewed, principalAfterDeposit + earningsAfterDeposit);
  }

  function testPreviewDepositAtMaturityWithZeroAmount() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.deposit(10 ether, address(this));
    vm.warp(120 seconds);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 earningsPreviewed = previewer.previewDepositAtMaturity(fixedLender, maturity, 0);

    assertEq(earningsPreviewed, 0);
  }

  function testPreviewDepositAtMaturityWithOneUnit() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.deposit(10 ether, address(this));
    vm.warp(120 seconds);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 positionAssetsPreviewed = previewer.previewDepositAtMaturity(fixedLender, maturity, 1);

    assertEq(positionAssetsPreviewed, 1);
  }

  function testPreviewDepositAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.deposit(10 ether, address(this));
    vm.warp(150 seconds);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(2 days);
    fixedLender.borrowAtMaturity(maturity, 2.3 ether, 3 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 positionAssetsPreviewed = previewer.previewDepositAtMaturity(fixedLender, maturity, 0.47 ether);
    fixedLender.depositAtMaturity(maturity, 0.47 ether, 0.47 ether, address(this));
    (uint256 principalAfterDeposit, uint256 earningsAfterDeposit) = fixedLender.fixedDepositPositions(
      maturity,
      address(this)
    );
    assertEq(positionAssetsPreviewed, principalAfterDeposit + earningsAfterDeposit);

    vm.warp(5 days);
    positionAssetsPreviewed = previewer.previewDepositAtMaturity(fixedLender, maturity, 1 ether);
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, BOB);
    (principalAfterDeposit, earningsAfterDeposit) = fixedLender.fixedDepositPositions(maturity, BOB);
    assertEq(positionAssetsPreviewed, principalAfterDeposit + earningsAfterDeposit);

    vm.warp(6 days);
    positionAssetsPreviewed = previewer.previewDepositAtMaturity(fixedLender, maturity, 20 ether);
    fixedLender.depositAtMaturity(maturity, 20 ether, 20 ether, ALICE);
    (principalAfterDeposit, earningsAfterDeposit) = fixedLender.fixedDepositPositions(maturity, ALICE);
    assertEq(positionAssetsPreviewed, principalAfterDeposit + earningsAfterDeposit);
  }

  function testPreviewDepositAtMaturityWithEmptyMaturity() external {
    assertEq(previewer.previewDepositAtMaturity(fixedLender, TSUtils.INTERVAL, 1 ether), 1 ether);
  }

  function testPreviewDepositAtMaturityWithEmptyMaturityAndZeroAmount() external {
    assertEq(previewer.previewDepositAtMaturity(fixedLender, TSUtils.INTERVAL, 0), 0);
  }

  function testPreviewDepositAtMaturityWithInvalidMaturity() external {
    assertEq(previewer.previewDepositAtMaturity(fixedLender, 376 seconds, 1 ether), 1 ether);
  }

  function testPreviewDepositAtMaturityWithSameTimestamp() external {
    uint256 maturity = TSUtils.INTERVAL;
    vm.warp(maturity);
    assertEq(previewer.previewDepositAtMaturity(fixedLender, maturity, 1 ether), 1 ether);
  }

  function testFailPreviewDepositAtMaturityWithMaturedMaturity() external {
    uint256 maturity = TSUtils.INTERVAL;
    vm.warp(maturity + 1);
    previewer.previewDepositAtMaturity(fixedLender, maturity, 1 ether);
  }

  function testPreviewBorrowAtMaturityReturningAccurateAmount() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.deposit(10 ether, address(this));
    vm.warp(180 seconds);
    uint256 positionAssetsPreviewed = previewer.previewBorrowAtMaturity(fixedLender, maturity, 1 ether);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));
    (uint256 principalAfterBorrow, uint256 feesAfterBorrow) = fixedLender.fixedBorrowPositions(maturity, address(this));

    assertEq(positionAssetsPreviewed, principalAfterBorrow + feesAfterBorrow);
  }

  function testPreviewBorrowAtMaturityWithZeroAmount() external {
    fixedLender.deposit(10 ether, address(this));
    vm.warp(5 seconds);
    assertEq(previewer.previewBorrowAtMaturity(fixedLender, TSUtils.INTERVAL, 0), 0);
  }

  function testPreviewBorrowAtMaturityWithOneUnit() external {
    fixedLender.deposit(5 ether, address(this));
    vm.warp(100 seconds);
    fixedLender.deposit(5 ether, address(this));
    assertEq(previewer.previewBorrowAtMaturity(fixedLender, TSUtils.INTERVAL, 1), 1);
  }

  function testPreviewBorrowAtMaturityWithFiveUnits() external {
    fixedLender.deposit(5 ether, address(this));
    vm.warp(100 seconds);
    fixedLender.deposit(5 ether, address(this));
    assertEq(previewer.previewBorrowAtMaturity(fixedLender, TSUtils.INTERVAL, 5), 5);
  }

  function testPreviewBorrowAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.deposit(10 ether, BOB);
    fixedLender.deposit(50 ether, ALICE);

    vm.warp(2 days);
    uint256 positionAssetsPreviewed = previewer.previewBorrowAtMaturity(fixedLender, maturity, 2.3 ether);
    fixedLender.borrowAtMaturity(maturity, 2.3 ether, 3 ether, address(this), address(this));
    (uint256 principalAfterBorrow, uint256 feesAfterBorrow) = fixedLender.fixedBorrowPositions(maturity, address(this));
    assertEq(positionAssetsPreviewed, principalAfterBorrow + feesAfterBorrow);

    vm.warp(3 days);
    fixedLender.depositAtMaturity(maturity, 1.47 ether, 1.47 ether, address(this));

    vm.warp(5 days);
    positionAssetsPreviewed = previewer.previewBorrowAtMaturity(fixedLender, maturity, 1 ether);
    vm.prank(BOB);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, BOB, BOB);
    (principalAfterBorrow, feesAfterBorrow) = fixedLender.fixedBorrowPositions(maturity, BOB);
    assertEq(positionAssetsPreviewed, principalAfterBorrow + feesAfterBorrow);

    vm.warp(6 days);
    positionAssetsPreviewed = previewer.previewBorrowAtMaturity(fixedLender, maturity, 20 ether);
    vm.prank(ALICE);
    fixedLender.borrowAtMaturity(maturity, 20 ether, 30 ether, ALICE, ALICE);
    (principalAfterBorrow, feesAfterBorrow) = fixedLender.fixedBorrowPositions(maturity, ALICE);
    assertEq(positionAssetsPreviewed, principalAfterBorrow + feesAfterBorrow);
  }

  function testPreviewBorrowAtMaturityWithInvalidMaturity() external {
    fixedLender.deposit(10 ether, address(this));
    vm.warp(100 seconds);
    uint256 positionAssetsPreviewed = previewer.previewBorrowAtMaturity(fixedLender, 376 seconds, 1 ether);
    assertGe(positionAssetsPreviewed, 1 ether);
  }

  function testFailPreviewBorrowAtMaturityWithSameTimestamp() external {
    uint256 maturity = TSUtils.INTERVAL;
    vm.warp(maturity);
    previewer.previewBorrowAtMaturity(fixedLender, maturity, 1 ether);
  }

  function testFailPreviewBorrowAtMaturityWithMaturedMaturity() external {
    uint256 maturity = TSUtils.INTERVAL;
    vm.warp(maturity + 1);
    previewer.previewBorrowAtMaturity(fixedLender, maturity, 1 ether);
  }

  function testPreviewRepayAtMaturityReturningAccurateAmount() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.deposit(10 ether, BOB);
    vm.warp(300 seconds);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.prank(BOB);
    fixedLender.borrowAtMaturity(maturity, 2 ether, 3 ether, BOB, BOB);

    vm.warp(3 days);
    uint256 repayAssetsPreviewed = previewer.previewRepayAtMaturity(fixedLender, maturity, 1 ether, address(this));
    uint256 balanceBeforeRepay = token.balanceOf(address(this));
    fixedLender.repayAtMaturity(maturity, 1 ether, 1 ether, address(this));
    uint256 discountAfterRepay = 1 ether - (balanceBeforeRepay - token.balanceOf(address(this)));

    assertEq(repayAssetsPreviewed, 1 ether - discountAfterRepay);
  }

  function testPreviewRepayAtMaturityWithZeroAmount() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.deposit(10 ether, address(this));
    vm.warp(100 seconds);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 repayAssetsPreviewed = previewer.previewRepayAtMaturity(fixedLender, maturity, 0, address(this));

    assertEq(repayAssetsPreviewed, 0);
  }

  function testPreviewRepayAtMaturityWithOneUnit() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.deposit(10 ether, address(this));
    vm.warp(100 seconds);
    fixedLender.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));
    vm.warp(3 days);

    assertEq(previewer.previewRepayAtMaturity(fixedLender, maturity, 1, address(this)), 1);
  }

  function testPreviewRepayAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.deposit(10 ether, BOB);
    vm.warp(200 seconds);
    fixedLender.borrowAtMaturity(maturity, 3 ether, 4 ether, address(this), address(this));

    vm.warp(2 days);
    vm.prank(BOB);
    fixedLender.borrowAtMaturity(maturity, 2.3 ether, 3 ether, BOB, BOB);

    vm.warp(3 days);
    uint256 repayAssetsPreviewed = previewer.previewRepayAtMaturity(fixedLender, maturity, 0.47 ether, address(this));
    uint256 balanceBeforeRepay = token.balanceOf(address(this));
    fixedLender.repayAtMaturity(maturity, 0.47 ether, 0.47 ether, address(this));
    uint256 discountAfterRepay = 0.47 ether - (balanceBeforeRepay - token.balanceOf(address(this)));
    assertEq(repayAssetsPreviewed, 0.47 ether - discountAfterRepay);

    vm.warp(5 days);
    repayAssetsPreviewed = previewer.previewRepayAtMaturity(fixedLender, maturity, 1.1 ether, address(this));
    balanceBeforeRepay = token.balanceOf(address(this));
    fixedLender.repayAtMaturity(maturity, 1.1 ether, 1.1 ether, address(this));
    discountAfterRepay = 1.1 ether - (balanceBeforeRepay - token.balanceOf(address(this)));
    assertEq(repayAssetsPreviewed, 1.1 ether - discountAfterRepay);

    vm.warp(6 days);
    (uint256 bobOwedPrincipal, uint256 bobOwedFee) = fixedLender.fixedBorrowPositions(maturity, BOB);
    uint256 totalOwedBob = bobOwedPrincipal + bobOwedFee;
    repayAssetsPreviewed = previewer.previewRepayAtMaturity(fixedLender, maturity, totalOwedBob, BOB);
    balanceBeforeRepay = token.balanceOf(BOB);
    vm.prank(BOB);
    fixedLender.repayAtMaturity(maturity, totalOwedBob, totalOwedBob, BOB);
    discountAfterRepay = totalOwedBob - (balanceBeforeRepay - token.balanceOf(BOB));
    (bobOwedPrincipal, ) = fixedLender.fixedBorrowPositions(maturity, BOB);
    assertEq(repayAssetsPreviewed, totalOwedBob - discountAfterRepay);
    assertEq(bobOwedPrincipal, 0);
  }

  function testFailPreviewRepayAtMaturityWithEmptyMaturity() external view {
    previewer.previewRepayAtMaturity(fixedLender, TSUtils.INTERVAL, 1 ether, address(this));
  }

  function testFailPreviewRepayAtMaturityWithEmptyMaturityAndZeroAmount() external view {
    previewer.previewRepayAtMaturity(fixedLender, TSUtils.INTERVAL, 0, address(this));
  }

  function testFailPreviewRepayAtMaturityWithInvalidMaturity() external view {
    previewer.previewRepayAtMaturity(fixedLender, 376 seconds, 1 ether, address(this));
  }

  function testPreviewRepayAtMaturityWithSameTimestamp() external {
    uint256 maturity = TSUtils.INTERVAL;
    vm.warp(maturity);

    assertEq(previewer.previewRepayAtMaturity(fixedLender, maturity, 1 ether, address(this)), 1 ether);
  }

  function testPreviewRepayAtMaturityWithMaturedMaturity() external {
    uint256 maturity = TSUtils.INTERVAL;
    vm.warp(maturity + 100);
    uint256 penalties = uint256(1 ether).mulWadDown(100 * fixedLender.penaltyRate());

    assertEq(previewer.previewRepayAtMaturity(fixedLender, maturity, 1 ether, address(this)), 1 ether + penalties);
  }

  function testPreviewWithdrawAtMaturityReturningAccurateAmount() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.depositAtMaturity(maturity, 10 ether, 10 ether, address(this));

    vm.warp(3 days);
    uint256 withdrawAssetsPreviewed = previewer.previewWithdrawAtMaturity(fixedLender, maturity, 10 ether);
    uint256 balanceBeforeWithdraw = token.balanceOf(address(this));
    fixedLender.withdrawAtMaturity(maturity, 10 ether, 0.9 ether, address(this), address(this));
    uint256 feeAfterWithdraw = 10 ether - (token.balanceOf(address(this)) - balanceBeforeWithdraw);

    assertEq(withdrawAssetsPreviewed, 10 ether - feeAfterWithdraw);
  }

  function testPreviewWithdrawAtMaturityWithZeroAmount() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));

    vm.warp(3 days);
    assertEq(previewer.previewWithdrawAtMaturity(fixedLender, maturity, 0), 0);
  }

  function testPreviewWithdrawAtMaturityWithOneUnit() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));

    vm.warp(3 days);
    uint256 feesPreviewed = previewer.previewWithdrawAtMaturity(fixedLender, maturity, 1);

    assertEq(feesPreviewed, 1 - 1);
  }

  function testPreviewWithdrawAtMaturityWithFiveUnits() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));

    vm.warp(3 days);
    uint256 feesPreviewed = previewer.previewWithdrawAtMaturity(fixedLender, maturity, 5);

    assertEq(feesPreviewed, 5 - 1);
  }

  function testPreviewWithdrawAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = TSUtils.INTERVAL;
    fixedLender.deposit(10 ether, address(this));
    fixedLender.deposit(10 ether, BOB);
    fixedLender.depositAtMaturity(maturity, 5 ether, 5 ether, address(this));

    vm.warp(2 days);
    vm.prank(BOB);
    fixedLender.borrowAtMaturity(maturity, 2.3 ether, 3 ether, BOB, BOB);

    vm.warp(3 days);
    uint256 withdrawAssetsPreviewed = previewer.previewWithdrawAtMaturity(fixedLender, maturity, 0.47 ether);
    uint256 balanceBeforeWithdraw = token.balanceOf(address(this));
    fixedLender.withdrawAtMaturity(maturity, 0.47 ether, 0.4 ether, address(this), address(this));
    uint256 feeAfterWithdraw = 0.47 ether - (token.balanceOf(address(this)) - balanceBeforeWithdraw);
    assertEq(withdrawAssetsPreviewed, 0.47 ether - feeAfterWithdraw);

    vm.warp(5 days);
    withdrawAssetsPreviewed = previewer.previewWithdrawAtMaturity(fixedLender, maturity, 1.1 ether);
    balanceBeforeWithdraw = token.balanceOf(address(this));
    fixedLender.withdrawAtMaturity(maturity, 1.1 ether, 1 ether, address(this), address(this));
    feeAfterWithdraw = 1.1 ether - (token.balanceOf(address(this)) - balanceBeforeWithdraw);
    assertEq(withdrawAssetsPreviewed, 1.1 ether - feeAfterWithdraw);

    vm.warp(6 days);
    (uint256 contractPositionPrincipal, uint256 contractPositionEarnings) = fixedLender.fixedDepositPositions(
      maturity,
      address(this)
    );
    uint256 contractPosition = contractPositionPrincipal + contractPositionEarnings;
    withdrawAssetsPreviewed = previewer.previewWithdrawAtMaturity(fixedLender, maturity, contractPosition);
    balanceBeforeWithdraw = token.balanceOf(address(this));
    fixedLender.withdrawAtMaturity(
      maturity,
      contractPosition,
      contractPosition - 1 ether,
      address(this),
      address(this)
    );
    feeAfterWithdraw = contractPosition - (token.balanceOf(address(this)) - balanceBeforeWithdraw);
    (contractPositionPrincipal, ) = fixedLender.fixedDepositPositions(maturity, address(this));

    assertEq(withdrawAssetsPreviewed, contractPosition - feeAfterWithdraw);
  }

  function testFailPreviewWithdrawAtMaturityWithEmptyMaturity() external view {
    previewer.previewWithdrawAtMaturity(fixedLender, TSUtils.INTERVAL, 1 ether);
  }

  function testFailPreviewWithdrawAtMaturityWithEmptyMaturityAndZeroAmount() external view {
    previewer.previewWithdrawAtMaturity(fixedLender, TSUtils.INTERVAL, 0);
  }

  function testFailPreviewWithdrawAtMaturityWithInvalidMaturity() external view {
    previewer.previewWithdrawAtMaturity(fixedLender, 376 seconds, 1 ether);
  }

  function testPreviewWithdrawAtMaturityWithSameTimestamp() external {
    uint256 maturity = TSUtils.INTERVAL;
    vm.warp(maturity);

    assertEq(previewer.previewWithdrawAtMaturity(fixedLender, maturity, 1 ether), 1 ether);
  }

  function testPreviewWithdrawAtMaturityWithMaturedMaturity() external {
    uint256 maturity = TSUtils.INTERVAL;
    vm.warp(maturity + 1);
    assertEq(previewer.previewWithdrawAtMaturity(fixedLender, maturity, 1 ether), 1 ether);
  }

  function testAccountsReturningAccurateAmounts() external {
    fixedLender.deposit(10 ether, address(this));
    vm.warp(100 seconds);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));

    Previewer.MarketAccount[] memory data = previewer.accounts(address(this));

    // We sum all the collateral prices
    uint256 sumCollateral = data[0].smartPoolAssets.mulDivDown(data[0].oraclePrice, 10**data[0].decimals).mulWadDown(
      data[0].adjustFactor
    );

    // We sum all the debt
    uint256 sumDebt = (data[0].fixedBorrowPositions[0].position.principal +
      data[0].fixedBorrowPositions[0].position.fee).mulDivDown(data[0].oraclePrice, 10**data[0].decimals);

    (uint256 realCollateral, uint256 realDebt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);

    assertEq(sumCollateral, realCollateral);
    assertEq(sumDebt, realDebt);
  }

  function testAccountsWithIntermediateOperationsReturningAccurateAmounts() external {
    // we deploy a new token for more liquidity combinations
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    FixedLender fixedLenderWETH = new FixedLender(
      weth,
      12,
      1e18,
      auditor,
      interestRateModel,
      0.02e18 / uint256(1 days),
      0,
      FixedLender.DampSpeed(0.0046e18, 0.42e18)
    );
    mockOracle.setPrice(fixedLenderWETH, 2800e18);
    auditor.enableMarket(fixedLenderWETH, 0.7e18, 18);
    weth.mint(address(this), 50_000 ether);
    weth.approve(address(fixedLenderWETH), 50_000 ether);

    fixedLender.deposit(10 ether, address(this));
    vm.warp(100 seconds);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1.321 ether, 2 ether, address(this), address(this));
    fixedLender.deposit(2 ether, address(this));

    Previewer.MarketAccount[] memory data = previewer.accounts(address(this));

    // We sum all the collateral prices
    uint256 sumCollateral = data[0].smartPoolAssets.mulDivDown(data[0].oraclePrice, 10**data[0].decimals).mulWadDown(
      data[0].adjustFactor
    );

    // We sum all the debt
    uint256 sumDebt = (data[0].fixedBorrowPositions[0].position.principal +
      data[0].fixedBorrowPositions[0].position.fee).mulDivDown(data[0].oraclePrice, 10**data[0].decimals);

    (uint256 realCollateral, uint256 realDebt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    assertEq(sumCollateral - sumDebt, realCollateral - realDebt);
    assertEq(data[0].isCollateral, true);

    fixedLenderWETH.deposit(100 ether, address(this));
    data = previewer.accounts(address(this));
    assertEq(data[1].smartPoolAssets, 100 ether);
    assertEq(data[1].isCollateral, false);
    assertEq(data.length, 2);

    auditor.enterMarket(fixedLenderWETH);
    data = previewer.accounts(address(this));
    sumCollateral += data[1].smartPoolAssets.mulDivDown(data[1].oraclePrice, 10**data[1].decimals).mulWadDown(
      data[1].adjustFactor
    );
    (realCollateral, realDebt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    assertEq(sumCollateral - sumDebt, realCollateral - realDebt);
    assertEq(data[1].isCollateral, true);

    mockOracle.setPrice(fixedLenderWETH, 2800e18);
    vm.warp(200 seconds);
    fixedLenderWETH.borrowAtMaturity(TSUtils.INTERVAL * 2, 33 ether, 40 ether, address(this), address(this));
    data = previewer.accounts(address(this));

    sumCollateral =
      data[0].smartPoolAssets.mulDivDown(data[0].oraclePrice, 10**data[0].decimals).mulWadDown(data[0].adjustFactor) +
      data[1].smartPoolAssets.mulDivDown(data[1].oraclePrice, 10**data[1].decimals).mulWadDown(data[1].adjustFactor);

    sumDebt += (data[1].fixedBorrowPositions[0].position.principal + data[1].fixedBorrowPositions[0].position.fee)
      .mulDivDown(data[1].oraclePrice, 10**data[1].decimals);

    (realCollateral, realDebt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    assertEq(sumCollateral - sumDebt, realCollateral - realDebt);

    mockOracle.setPrice(fixedLenderWETH, 1831e18);
    data = previewer.accounts(address(this));
    assertEq(data[1].oraclePrice, 1831e18);
  }

  function testAccountsWithAccountThatHasBalances() external {
    fixedLender.deposit(10 ether, address(this));
    vm.warp(400 seconds);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    fixedLender.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL * 2, 2.33 ether, 3 ether, address(this), address(this));
    fixedLender.depositAtMaturity(TSUtils.INTERVAL * 2, 1.19 ether, 1.19 ether, address(this));
    (uint256 firstMaturitySupplyPrincipal, uint256 firstMaturitySupplyFee) = fixedLender.fixedDepositPositions(
      TSUtils.INTERVAL,
      address(this)
    );
    (uint256 secondMaturitySupplyPrincipal, uint256 secondMaturitySupplyFee) = fixedLender.fixedDepositPositions(
      TSUtils.INTERVAL * 2,
      address(this)
    );
    (uint256 firstMaturityBorrowPrincipal, uint256 firstMaturityBorrowFee) = fixedLender.fixedBorrowPositions(
      TSUtils.INTERVAL,
      address(this)
    );
    (uint256 secondMaturityBorrowPrincipal, uint256 secondMaturityBorrowFee) = fixedLender.fixedBorrowPositions(
      TSUtils.INTERVAL * 2,
      address(this)
    );

    Previewer.MarketAccount[] memory data = previewer.accounts(address(this));

    assertEq(data[0].assetSymbol, "DAI");
    assertEq(data[0].smartPoolAssets, fixedLender.convertToAssets(fixedLender.balanceOf(address(this))));
    assertEq(data[0].smartPoolShares, fixedLender.balanceOf(address(this)));

    assertEq(data[0].maturitySupplyPositions[0].maturity, TSUtils.INTERVAL);
    assertEq(data[0].maturitySupplyPositions[0].position.principal, firstMaturitySupplyPrincipal);
    assertEq(data[0].maturitySupplyPositions[0].position.fee, firstMaturitySupplyFee);
    assertEq(data[0].maturitySupplyPositions[1].maturity, TSUtils.INTERVAL * 2);
    assertEq(data[0].maturitySupplyPositions[1].position.principal, secondMaturitySupplyPrincipal);
    assertEq(data[0].maturitySupplyPositions[1].position.fee, secondMaturitySupplyFee);
    assertEq(data[0].maturitySupplyPositions.length, 2);
    assertEq(data[0].fixedBorrowPositions[0].maturity, TSUtils.INTERVAL);
    assertEq(data[0].fixedBorrowPositions[0].position.principal, firstMaturityBorrowPrincipal);
    assertEq(data[0].fixedBorrowPositions[0].position.fee, firstMaturityBorrowFee);
    assertEq(data[0].fixedBorrowPositions[1].maturity, TSUtils.INTERVAL * 2);
    assertEq(data[0].fixedBorrowPositions[1].position.principal, secondMaturityBorrowPrincipal);
    assertEq(data[0].fixedBorrowPositions[1].position.fee, secondMaturityBorrowFee);
    assertEq(data[0].fixedBorrowPositions.length, 2);

    assertEq(data[0].oraclePrice, 1e18);
    assertEq(data[0].adjustFactor, 0.8e18);
    assertEq(data[0].penaltyRate, fixedLender.penaltyRate());
    assertEq(data[0].decimals, 18);
    assertEq(data[0].maxFuturePools, 12);
    assertEq(data[0].isCollateral, true);
  }

  function testAccountsWithAccountOnlyDeposit() external {
    fixedLender.deposit(10 ether, address(this));
    Previewer.MarketAccount[] memory data = previewer.accounts(address(this));

    assertEq(data[0].assetSymbol, "DAI");
    assertEq(data[0].smartPoolAssets, 10 ether);
    assertEq(data[0].smartPoolShares, fixedLender.convertToShares(10 ether));
    assertEq(data[0].maturitySupplyPositions.length, 0);
    assertEq(data[0].fixedBorrowPositions.length, 0);
    assertEq(data[0].oraclePrice, 1e18);
    assertEq(data[0].adjustFactor, 0.8e18);
    assertEq(data[0].decimals, 18);
    assertEq(data[0].maxFuturePools, 12);
    assertEq(data[0].isCollateral, false);
  }

  function testAccountsWithEmptyAccount() external {
    Previewer.MarketAccount[] memory data = previewer.accounts(address(this));

    assertEq(data[0].assetSymbol, "DAI");
    assertEq(data[0].smartPoolAssets, 0);
    assertEq(data[0].smartPoolShares, 0);
    assertEq(data[0].maturitySupplyPositions.length, 0);
    assertEq(data[0].fixedBorrowPositions.length, 0);
    assertEq(data[0].oraclePrice, 1e18);
    assertEq(data[0].adjustFactor, 0.8e18);
    assertEq(data[0].decimals, 18);
    assertEq(data[0].maxFuturePools, 12);
    assertEq(data[0].penaltyRate, fixedLender.penaltyRate());
    assertEq(data[0].isCollateral, false);
  }
}
