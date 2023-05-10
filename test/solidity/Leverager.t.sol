// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Test, stdJson } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC20, Market, Leverager, IBalancerVault, Disagreement } from "../../contracts/periphery/Leverager.sol";
import { Auditor, InsufficientAccountLiquidity, MarketNotListed } from "../../contracts/Auditor.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";

contract LeveragerTest is Test {
  using FixedPointMathLib for uint256;
  using stdJson for string;

  Leverager internal leverager;
  Market internal marketUSDC;
  ERC20 internal usdc;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 84_666_000);

    usdc = ERC20(deployment("USDC"));
    marketUSDC = Market(deployment("MarketUSDC"));
    leverager = new Leverager(Auditor(deployment("Auditor")), IBalancerVault(deployment("BalancerVault")));

    deal(address(usdc), address(this), 10_000_000e6);
    marketUSDC.approve(address(leverager), type(uint256).max);
    usdc.approve(address(marketUSDC), type(uint256).max);
    usdc.approve(address(leverager), type(uint256).max);
  }

  function testLeverage() external _checkBalances {
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18, true);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertEq(marketUSDC.maxWithdraw(address(this)), 510153541353);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 410153541355);
  }

  function testLeverageWithAlreadyDepositedAmount() external _checkBalances {
    usdc.approve(address(marketUSDC), type(uint256).max);
    marketUSDC.deposit(100_000e6, address(this));
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18, false);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertEq(marketUSDC.maxWithdraw(address(this)), 510153541352);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 410153541355);
  }

  function testLeverageShouldFailWhenHealthFactorNearOne() external _checkBalances {
    vm.expectRevert();
    leverager.leverage(marketUSDC, 100_000e6, 1.000000000001e18, true);

    leverager.leverage(marketUSDC, 100_000e6, 1.00000000001e18, true);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertEq(marketUSDC.maxWithdraw(address(this)), 581733565996);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 481733565998);
  }

  function testDeleverage() external _checkBalances {
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18, true);
    leverager.deleverage(marketUSDC, 0, 0, 1e18);

    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    // precision loss (2)
    assertEq(marketUSDC.maxWithdraw(address(this)), 100_000e6 - 2);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 0);
  }

  function testDeleverageHalfBorrowPosition() external _checkBalances {
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18, true);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    uint256 leveragedDeposit = 510153541353;
    uint256 leveragedBorrow = 410153541355;
    assertEq(marketUSDC.maxWithdraw(address(this)), leveragedDeposit);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), leveragedBorrow);

    leverager.deleverage(marketUSDC, 0, 0, 0.5e18);
    (, , floatingBorrowShares) = marketUSDC.accounts(address(this));
    uint256 deleveragedDeposit = 305076770676;
    uint256 deleveragedBorrow = 205076770678;
    assertEq(marketUSDC.maxWithdraw(address(this)), deleveragedDeposit);
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), deleveragedBorrow);
    assertEq(leveragedDeposit - deleveragedDeposit, leveragedBorrow - deleveragedBorrow);
  }

  function testFixedDeleverage() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 30_000e6, type(uint256).max, address(this), address(this));

    leverager.deleverage(marketUSDC, maturity, type(uint256).max, 1e18);
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    (uint256 balance, uint256 debt) = marketUSDC.accountSnapshot(address(this));
    assertEq(principal, 0);
    assertEq(debt, 0);
    assertGt(balance, 69_997e6);
    assertLt(balance, 70_000e6);
  }

  function testLateFixedDeleverage() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 30_000e6, type(uint256).max, address(this), address(this));

    vm.warp(maturity + 3 days);
    // we update accumulated earnings, etc...
    marketUSDC.deposit(2, address(this));
    (uint256 balance, uint256 debt) = marketUSDC.accountSnapshot(address(this));
    leverager.deleverage(marketUSDC, maturity, type(uint256).max, 1e18);
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    (uint256 newBalance, ) = marketUSDC.accountSnapshot(address(this));
    assertEq(principal, 0);
    assertEq(newBalance, balance - debt);
  }

  function testPartialFixedDeleverage() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 30_000e6, type(uint256).max, address(this), address(this));

    leverager.deleverage(marketUSDC, maturity, type(uint256).max, 0.1e18);
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    (uint256 balance, uint256 debt) = marketUSDC.accountSnapshot(address(this));
    assertGt(debt, 0);
    assertEq(principal, 27_000e6);
    assertGt(balance, 96_999e6);
    assertLt(balance, 97_000e6);
  }

  function testFlashloanFeeGreaterThanZero() external {
    vm.prank(0xacAaC3e6D6Df918Bf3c809DFC7d42de0e4a72d4C);
    ProtocolFeesCollector(0xce88686553686DA562CE7Cea497CE749DA109f9F).setFlashLoanFeePercentage(1e15);

    vm.expectRevert("BAL#602");
    leverager.leverage(marketUSDC, 100_000e6, 1.03e18, true);
  }

  function testApproveMarket() external {
    vm.expectEmit(true, true, true, true);
    emit Approval(address(leverager), address(marketUSDC), type(uint256).max);
    leverager.approve(marketUSDC);
    assertEq(usdc.allowance(address(leverager), address(marketUSDC)), type(uint256).max);
  }

  function testApproveMaliciousMarket() external {
    vm.expectRevert(MarketNotListed.selector);
    leverager.approve(Market(address(this)));
  }

  function testCallReceiveFlashLoanFromAnyAddress() external _checkBalances {
    uint256[] memory amounts = new uint256[](1);
    uint256[] memory feeAmounts = new uint256[](1);
    ERC20[] memory assets = new ERC20[](1);

    vm.expectRevert();
    leverager.receiveFlashLoan(assets, amounts, feeAmounts, "");
  }

  function testLeverageWithInvalidBalancerVault() external {
    Leverager lev = new Leverager(marketUSDC.auditor(), IBalancerVault(address(this)));
    vm.expectRevert(bytes(""));
    lev.leverage(marketUSDC, 100_000e6, 1.03e18, true);
  }

  function testFloatingToFixedRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrow(50_000e6, address(this), address(this));
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;

    leverager.floatingRoll(marketUSDC, true, maturity, type(uint256).max, 1e18);
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(principal, 50_000e6 + 1);
  }

  function testFloatingToFixedRollHigherThanAvailableLiquidity() external _checkBalances {
    marketUSDC.deposit(2_000_000e6, address(this));
    marketUSDC.borrow(1_000_000e6, address(this), address(this));
    assertLt(usdc.balanceOf(address(leverager.balancerVault())), 1_000_000e6);
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;

    leverager.floatingRoll(marketUSDC, true, maturity, type(uint256).max, 1e18);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(floatingBorrowShares, 0);
    assertEq(principal, 1_000_000e6 + 1);
  }

  function testFloatingToFixedRollHigherThanAvailableLiquidityWithSlippage() external _checkBalances {
    marketUSDC.deposit(2_000_000e6, address(this));
    marketUSDC.borrow(1_000_000e6, address(this), address(this));
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    uint256 initialDebt = marketUSDC.previewRefund(floatingBorrowShares);
    uint256 fee = 8_855_280_712;

    vm.expectRevert(Disagreement.selector);
    leverager.floatingRoll(marketUSDC, true, maturity, 1_000_000e6 + fee, 1e18);

    leverager.floatingRoll(marketUSDC, true, maturity, 1_000_000e6 + ++fee, 1e18);
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    (, , floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertEq(principal, initialDebt);
    assertEq(floatingBorrowShares, 0);
  }

  function testFloatingToFixedRollHigherThanAvailableLiquidityWithSlippageWithThreePools() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.deposit(3_000_000e6, address(this));
    marketUSDC.borrow(2_000_000e6, address(this), address(this));
    vm.warp(block.timestamp + 10_000);
    uint256 fee = 10_504_723_368;

    vm.expectRevert(Disagreement.selector);
    leverager.floatingRoll(marketUSDC, true, maturity, 2_000_000e6 + fee, 1e18);

    leverager.floatingRoll(marketUSDC, true, maturity, 2_000_000e6 + ++fee, 1e18);
  }

  function testFixedToFloatingRollHigherThanAvailableLiquidity() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.deposit(2_000_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 1_000_000e6, type(uint256).max, address(this), address(this));

    leverager.floatingRoll(marketUSDC, false, maturity, type(uint256).max, 1e18);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertGt(marketUSDC.previewRefund(floatingBorrowShares), 1_000_000e6);
    assertEq(principal + fee, 0);
  }

  function testFixedToFloatingRollHigherThanAvailableLiquidityWithSlippage() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.deposit(2_000_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 1_000_000e6, type(uint256).max, address(this), address(this));
    uint256 fee = 893_502_174;

    vm.expectRevert(Disagreement.selector);
    leverager.floatingRoll(marketUSDC, false, maturity, 1_000_000e6 + fee, 1e18);

    leverager.floatingRoll(marketUSDC, false, maturity, 1_000_000e6 + ++fee, 1e18);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 1_000_000e6 + fee);
    assertEq(principal, 0);
  }

  function testFixedToFloatingRollHigherThanAvailableLiquidityWithSlippageWithThreeLoops() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.deposit(3_000_000e6, address(this));
    vm.warp(block.timestamp + 10_000);
    marketUSDC.borrowAtMaturity(maturity, 2_000_000e6, type(uint256).max, address(this), address(this));
    uint256 fee = 1_052_304_919;

    vm.expectRevert(Disagreement.selector);
    leverager.floatingRoll(marketUSDC, false, maturity, 2_000_000e6 + fee, 1e18);

    leverager.floatingRoll(marketUSDC, false, maturity, 2_000_000e6 + ++fee, 1e18);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(marketUSDC.previewRefund(floatingBorrowShares), 2_000_000e6 + fee);
    assertEq(principal, 0);
  }

  function testFloatingToFixedRollWithAccurateSlippage() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrow(50_000e6, address(this), address(this));
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    uint256 maxFee = 41_656_859;

    vm.expectRevert(Disagreement.selector);
    leverager.floatingRoll(marketUSDC, true, maturity, 50_000e6 + maxFee, 1e18);

    leverager.floatingRoll(marketUSDC, true, maturity, 50_000e6 + ++maxFee, 1e18);
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(principal, 50_000e6 + 1);
    assertEq(fee, maxFee - 1);
  }

  function testFloatingToFixedRollWithAccurateSlippageWithPreviousPosition() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrow(50_000e6, address(this), address(this));
    marketUSDC.borrowAtMaturity(maturity, 10_000e6, type(uint256).max, address(this), address(this));
    uint256 maxFee = 46_473_866;

    vm.expectRevert(Disagreement.selector);
    leverager.floatingRoll(marketUSDC, true, maturity, 50_000e6 + maxFee, 1e18);

    leverager.floatingRoll(marketUSDC, true, maturity, 50_000e6 + ++maxFee, 1e18);
  }

  function testFixedToFloatingRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.borrowAtMaturity(maturity, 10_000e6, type(uint256).max, address(this), address(this));
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    leverager.floatingRoll(marketUSDC, false, maturity, type(uint256).max, 1e18);
    (uint256 newPrincipal, uint256 newFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(newPrincipal + newFee, 0);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    uint256 floatingDebt = marketUSDC.previewRefund(floatingBorrowShares);
    assertGt(floatingDebt, 10_000e6);
    assertLt(floatingDebt, principal + fee);
    assertEq(usdc.balanceOf(address(leverager)), 0);
  }

  function testPartialFixedToFloatingRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.borrowAtMaturity(maturity, 10_000e6, type(uint256).max, address(this), address(this));
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    leverager.floatingRoll(marketUSDC, false, maturity, type(uint256).max, 0.5e18);
    (uint256 newPrincipal, uint256 newFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq((newPrincipal + newFee) * 2, principal + fee + 1);
  }

  function testFixedToFloatingRollWithAccurateSlippage() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.borrowAtMaturity(maturity, 10_000e6, type(uint256).max, address(this), address(this));
    uint256 maxAssets = 10_001_221_724;

    vm.expectRevert(Disagreement.selector);
    leverager.floatingRoll(marketUSDC, false, maturity, maxAssets, 1e18);

    leverager.floatingRoll(marketUSDC, false, maturity, ++maxAssets, 1e18);
  }

  function testLateFixedToFloatingRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.borrowAtMaturity(maturity, 10_000e6, type(uint256).max, address(this), address(this));
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    vm.warp(maturity + 1 days);
    uint256 debt = marketUSDC.previewDebt(address(this));
    leverager.floatingRoll(marketUSDC, false, maturity, type(uint256).max, 1e18);
    assertEq(debt, marketUSDC.previewDebt(address(this)) - 1);
    (uint256 newPrincipal, uint256 newFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(newPrincipal + newFee, 0);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertGt(
      marketUSDC.previewRefund(floatingBorrowShares),
      (principal + fee).mulWadDown(1 days * marketUSDC.penaltyRate())
    );
  }

  function testPartialLateFixedToFloatingRoll() external _checkBalances {
    marketUSDC.deposit(100_000e6, address(this));
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    marketUSDC.borrowAtMaturity(maturity, 10_000e6, type(uint256).max, address(this), address(this));
    (uint256 principal, uint256 fee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    vm.warp(maturity + 1 days);
    uint256 debt = marketUSDC.previewDebt(address(this));
    leverager.floatingRoll(marketUSDC, false, maturity, type(uint256).max, 0.5e18);
    assertEq(debt, marketUSDC.previewDebt(address(this)));
    (uint256 newPrincipal, uint256 newFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(newPrincipal + newFee - 1, (principal + fee) / 2);
    (, , uint256 floatingBorrowShares) = marketUSDC.accounts(address(this));
    assertGt(
      marketUSDC.previewRefund(floatingBorrowShares) / 2,
      (principal + fee).mulWadDown(1 days * marketUSDC.penaltyRate()) + 1
    );
  }

  function testFixedRoll() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    uint256 newMaturity = maturity + FixedLib.INTERVAL;
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));

    leverager.fixedRoll(marketUSDC, maturity, newMaturity, type(uint256).max, type(uint256).max, 1e18);
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(principal, 0);
    (principal, ) = marketUSDC.fixedBorrowPositions(newMaturity, address(this));
    assertGt(principal, 50_000e6);
  }

  function testPartialFixedRoll() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    uint256 newMaturity = maturity + FixedLib.INTERVAL;
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));

    leverager.fixedRoll(marketUSDC, maturity, newMaturity, type(uint256).max, type(uint256).max, 0.1e18);
    (uint256 principal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(principal, 45_000e6);
    (principal, ) = marketUSDC.fixedBorrowPositions(newMaturity, address(this));
    assertGt(principal, 5_000e6);
    assertLt(principal, 5_100e6);
  }

  function testFixedRollWithAccurateRepaySlippage() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    uint256 newMaturity = maturity + FixedLib.INTERVAL;
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));
    uint256 maxRepayAssets = 50_004_915_917;

    vm.expectRevert();
    leverager.fixedRoll(marketUSDC, maturity, newMaturity, maxRepayAssets, type(uint256).max, 1e18);

    leverager.fixedRoll(marketUSDC, maturity, newMaturity, ++maxRepayAssets, type(uint256).max, 1e18);
  }

  function testFixedRollWithAccurateBorrowSlippage() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    uint256 newMaturity = maturity + FixedLib.INTERVAL;
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));
    uint256 maxBorrowAssets = 50_128_835_188;

    vm.expectRevert();
    leverager.fixedRoll(marketUSDC, maturity, newMaturity, type(uint256).max, maxBorrowAssets, 1e18);

    leverager.fixedRoll(marketUSDC, maturity, newMaturity, type(uint256).max, ++maxBorrowAssets, 1e18);
  }

  function testLateFixedRoll() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    uint256 newMaturity = maturity + FixedLib.INTERVAL;
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));
    (uint256 repayPrincipal, uint256 repayFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    vm.warp(maturity + 1 days);
    uint256 debt = marketUSDC.previewDebt(address(this));
    leverager.fixedRoll(marketUSDC, maturity, newMaturity, type(uint256).max, type(uint256).max, 1e18);
    assertGt(marketUSDC.previewDebt(address(this)), debt);
    (uint256 newRepayPrincipal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(newRepayPrincipal, 0);
    (uint256 borrowPrincipal, ) = marketUSDC.fixedBorrowPositions(newMaturity, address(this));
    assertGt(borrowPrincipal, (repayPrincipal + repayFee).mulWadDown(1 days * marketUSDC.penaltyRate()));
  }

  // @todo add test where maturity and new maturity is the same

  function testPartialLateFixedRoll() external _checkBalances {
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    uint256 newMaturity = maturity + FixedLib.INTERVAL;
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrowAtMaturity(maturity, 50_000e6, type(uint256).max, address(this), address(this));
    (uint256 repayPrincipal, uint256 repayFee) = marketUSDC.fixedBorrowPositions(maturity, address(this));

    vm.warp(maturity + 1 days);
    uint256 debt = marketUSDC.previewDebt(address(this));
    leverager.fixedRoll(marketUSDC, maturity, newMaturity, type(uint256).max, type(uint256).max, 0.5e18);
    assertGt(marketUSDC.previewDebt(address(this)), debt);
    (uint256 newRepayPrincipal, ) = marketUSDC.fixedBorrowPositions(maturity, address(this));
    assertEq(newRepayPrincipal, 25_000e6);
    (uint256 borrowPrincipal, ) = marketUSDC.fixedBorrowPositions(newMaturity, address(this));
    assertGt(borrowPrincipal, (repayPrincipal + repayFee).mulWadDown(1 days * marketUSDC.penaltyRate()) / 2);
  }

  function testAvailableLiquidity() external {
    Leverager.AvailableAsset[] memory availableAssets = leverager.availableLiquidity();
    Market[] memory markets = marketUSDC.auditor().allMarkets();
    assertEq(availableAssets.length, markets.length);
    assertEq(address(availableAssets[1].asset), address(usdc));
    assertEq(availableAssets[1].liquidity, usdc.balanceOf(address(leverager.balancerVault())));
  }

  modifier _checkBalances() {
    uint256 vault = usdc.balanceOf(address(leverager.balancerVault()));
    _;
    assertLe(usdc.balanceOf(address(leverager)), 1);
    assertEq(usdc.balanceOf(address(leverager.balancerVault())), vault);
  }

  function deployment(string memory name) internal returns (address addr) {
    addr = vm.readFile(string.concat("deployments/optimism/", name, ".json")).readAddress(".address");
    vm.label(addr, name);
  }

  event Approval(address indexed owner, address indexed spender, uint256 amount);
}

interface ProtocolFeesCollector {
  function setFlashLoanFeePercentage(uint256) external;
}
