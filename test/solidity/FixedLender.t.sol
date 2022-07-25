// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "@rari-capital/solmate/src/test/utils/mocks/MockERC20.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { MockInterestRateModel } from "../../contracts/mocks/MockInterestRateModel.sol";
import { Auditor, ExactlyOracle, InsufficientLiquidity } from "../../contracts/Auditor.sol";
import {
  FixedLender,
  ERC20,
  PoolLib,
  TooMuchSlippage,
  ZeroRepay,
  SmartPoolReserveExceeded,
  InsufficientProtocolLiquidity
} from "../../contracts/FixedLender.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { TSUtils } from "../../contracts/utils/TSUtils.sol";

contract FixedLenderTest is Test {
  using FixedPointMathLib for uint256;

  address internal constant BOB = address(0x69);
  address internal constant ALICE = address(0x420);

  Auditor internal auditor;
  MockOracle internal mockOracle;
  FixedLender internal fixedLender;
  FixedLender internal fixedLenderWETH;
  MockERC20 internal weth;
  MockInterestRateModel internal mockInterestRateModel;
  string[] private tokens = ["DAI", "USDC", "WETH", "WBTC"];

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
  event LiquidateBorrow(
    address indexed receiver,
    address indexed borrower,
    uint256 repaidAssets,
    uint256 lendersAssets,
    FixedLender indexed collateralFixedLender,
    uint256 seizedAssets
  );

  function setUp() external {
    MockERC20 token = new MockERC20("DAI", "DAI", 18);
    mockOracle = new MockOracle();
    auditor = new Auditor(ExactlyOracle(address(mockOracle)), Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    mockInterestRateModel = new MockInterestRateModel(0.1e18);

    fixedLender = new FixedLender(
      token,
      3,
      1e18,
      auditor,
      InterestRateModel(address(mockInterestRateModel)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      FixedLender.DampSpeed(0.0046e18, 0.42e18)
    );

    weth = new MockERC20("WETH", "WETH", 18);
    fixedLenderWETH = new FixedLender(
      weth,
      12,
      1e18,
      auditor,
      InterestRateModel(address(mockInterestRateModel)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      FixedLender.DampSpeed(0.0046e18, 0.42e18)
    );

    auditor.enableMarket(fixedLender, 0.8e18, 18);
    auditor.enableMarket(fixedLenderWETH, 0.9e18, 18);
    auditor.enterMarket(fixedLenderWETH);

    vm.label(BOB, "Bob");
    vm.label(ALICE, "Alice");
    token.mint(BOB, 50_000 ether);
    token.mint(ALICE, 50_000 ether);
    token.mint(address(this), 50_000 ether);
    weth.mint(address(this), 50_000 ether);

    weth.approve(address(fixedLenderWETH), 50_000 ether);
    token.approve(address(fixedLender), type(uint256).max);
    vm.prank(BOB);
    token.approve(address(fixedLender), type(uint256).max);
    vm.prank(ALICE);
    token.approve(address(fixedLender), type(uint256).max);
  }

  function testDepositToSmartPool() external {
    vm.expectEmit(true, true, true, true, address(fixedLender));
    emit Deposit(address(this), address(this), 1 ether, 1 ether);

    fixedLender.deposit(1 ether, address(this));
  }

  function testWithdrawFromSmartPool() external {
    fixedLender.deposit(1 ether, address(this));

    vm.expectEmit(true, true, true, true, address(fixedLender.asset()));
    emit Transfer(address(fixedLender), address(this), 1 ether);
    fixedLender.withdraw(1 ether, address(this), address(this));
  }

  function testDepositAtMaturity() external {
    vm.expectEmit(true, true, true, true, address(fixedLender));
    emit DepositAtMaturity(TSUtils.INTERVAL, address(this), address(this), 1 ether, 0);
    fixedLender.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
  }

  function testWithdrawAtMaturity() external {
    fixedLender.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));

    vm.expectEmit(true, true, true, true, address(fixedLender));
    emit WithdrawAtMaturity(TSUtils.INTERVAL, address(this), address(this), address(this), 1 ether, 909090909090909090);
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1 ether, 0.9 ether, address(this), address(this));
  }

  function testBorrowAtMaturity() external {
    fixedLender.deposit(12 ether, address(this));

    vm.expectEmit(true, true, true, true, address(fixedLender));
    emit BorrowAtMaturity(TSUtils.INTERVAL, address(this), address(this), address(this), 1 ether, 0.1 ether);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));
  }

  function testRepayAtMaturity() external {
    fixedLender.deposit(12 ether, address(this));
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));

    vm.expectEmit(true, true, true, true, address(fixedLender));
    emit RepayAtMaturity(TSUtils.INTERVAL, address(this), address(this), 1.01 ether, 1.1 ether);
    fixedLender.repayAtMaturity(TSUtils.INTERVAL, 1.5 ether, 1.5 ether, address(this));
  }

  function testDepositTooMuchSlippage() external {
    vm.expectRevert(TooMuchSlippage.selector);
    fixedLender.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1.1 ether, address(this));
  }

  function testBorrowTooMuchSlippage() external {
    fixedLender.deposit(12 ether, address(this));
    vm.expectRevert(TooMuchSlippage.selector);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this), address(this));
  }

  function testRepayTooMuchSlippage() external {
    fixedLender.deposit(12 ether, address(this));
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));
    vm.expectRevert(TooMuchSlippage.selector);
    fixedLender.repayAtMaturity(TSUtils.INTERVAL, 1 ether, 0.9 ether, address(this));
  }

  function testMultipleFixedBorrowsRepays() external {
    uint256 total = 0;
    fixedLender.deposit(100 ether, address(this));
    for (uint256 i = 1; i < 3 + 1; i++) {
      total += fixedLender.borrowAtMaturity(i * TSUtils.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));
    }

    assertEq(fixedLender.getDebt(address(this)), total);

    for (uint256 i = 1; i < 3 + 1; i++) {
      fixedLender.repayAtMaturity(
        i * TSUtils.INTERVAL,
        uint256(1 ether).mulWadDown(1e18 + (0.1e18 * i * TSUtils.INTERVAL) / 365 days),
        1.01 ether,
        address(this)
      );
    }
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

    vm.warp(TSUtils.INTERVAL);

    vm.prank(BOB);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL * 2, 1_000 ether, 1_100 ether, BOB, BOB);

    vm.warp(TSUtils.INTERVAL + TSUtils.INTERVAL / 2);
    fixedLender.deposit(10_000 ether, address(this));
    assertEq(fixedLender.balanceOf(BOB), 10_000 ether);
    assertEq(fixedLender.maxWithdraw(address(this)), 10_000 ether - 1);
    assertApproxEqRel(fixedLender.balanceOf(address(this)), 9950 ether, 2.6e13);

    vm.warp(TSUtils.INTERVAL + (TSUtils.INTERVAL / 3) * 2);
    fixedLender.deposit(1_000 ether, address(this));
    assertApproxEqRel(fixedLender.balanceOf(address(this)), 10944 ether, 5e13);
  }

  function testSmartPoolSharesDoNotAccountUnassignedEarningsFromMoreThanOneIntervalPastMaturities() external {
    uint256 maturity = TSUtils.INTERVAL * 2;
    fixedLender.deposit(10_000 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    // we move to the last second before an interval goes by after the maturity passed
    vm.warp(TSUtils.INTERVAL * 2 + TSUtils.INTERVAL - 1 seconds);
    assertLt(fixedLender.previewDeposit(10_000 ether), fixedLender.balanceOf(address(this)));

    // we move to the instant where an interval went by after the maturity passed
    vm.warp(TSUtils.INTERVAL * 3);
    // the unassigned earnings of the maturity that the contract borrowed from are not accounted anymore
    assertEq(fixedLender.previewDeposit(10_000 ether), fixedLender.balanceOf(address(this)));
  }

  function testPreviewOperationsWithSmartPoolCorrectlyAccountingEarnings() external {
    uint256 assets = 10_000 ether;
    uint256 maturity = TSUtils.INTERVAL * 2;
    uint256 anotherMaturity = TSUtils.INTERVAL * 3;
    fixedLender.deposit(assets, address(this));

    vm.warp(TSUtils.INTERVAL);
    fixedLender.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    vm.prank(BOB);
    fixedLender.deposit(10_000 ether, BOB);
    vm.prank(BOB); // we have unassigned earnings
    fixedLender.borrowAtMaturity(anotherMaturity, 1_000 ether, 1_100 ether, BOB, BOB);

    vm.warp(maturity + 1 days); // and we have penalties -> delayed a day
    fixedLender.repayAtMaturity(maturity, 1_100 ether, 1_200 ether, address(this));

    assertEq(
      fixedLender.previewRedeem(fixedLender.balanceOf(address(this))),
      fixedLender.redeem(fixedLender.balanceOf(address(this)), address(this), address(this))
    );

    vm.warp(maturity + 2 days);
    fixedLender.deposit(assets, address(this));
    vm.warp(maturity + 2 weeks); // a more relevant portion of the accumulator is distributed after 2 weeks
    assertEq(fixedLender.previewWithdraw(assets), fixedLender.withdraw(assets, address(this), address(this)));

    vm.warp(maturity + 3 weeks);
    assertEq(fixedLender.previewDeposit(assets), fixedLender.deposit(assets, address(this)));
    vm.warp(maturity + 4 weeks);
    assertEq(fixedLender.previewMint(10_000 ether), fixedLender.mint(10_000 ether, address(this)));
  }

  function testFrontRunSmartPoolEarningsDistributionWithBigPenaltyRepayment() external {
    uint256 maturity = TSUtils.INTERVAL * 2;
    fixedLender.deposit(10_000 ether, address(this));

    vm.warp(TSUtils.INTERVAL);
    fixedLender.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    vm.warp(maturity);
    fixedLender.repayAtMaturity(maturity, 1, 1, address(this)); // we send tx to accrue earnings

    vm.warp(maturity + 7 days * 2 - 1 seconds);
    vm.prank(BOB);
    fixedLender.deposit(10_100 ether, BOB); // bob deposits more assets to have same shares as previous user
    assertEq(fixedLender.balanceOf(BOB), 10_000 ether);
    uint256 assetsBobBefore = fixedLender.convertToAssets(fixedLender.balanceOf(address(this)));
    assertEq(assetsBobBefore, fixedLender.convertToAssets(fixedLender.balanceOf(address(this))));

    vm.warp(maturity + 7 days * 2); // 2 weeks delayed (2% daily = 28% in penalties), 1100 * 1.28 = 1408
    fixedLender.repayAtMaturity(maturity, 1_408 ether, 1_408 ether, address(this));
    // no penalties are accrued (accumulator accounts them)

    // 1 second passed since bob's deposit -> he now has 21219132878712 more if he withdraws
    assertEq(fixedLender.convertToAssets(fixedLender.balanceOf(BOB)), assetsBobBefore + 21219132878712);
    assertApproxEqRel(fixedLender.smartPoolEarningsAccumulator(), 308 ether, 1e7);

    vm.warp(maturity + 7 days * 5);
    // then the accumulator will distribute 20% of the accumulated earnings
    // 308e18 * 0.20 = 616e17
    vm.prank(ALICE);
    fixedLender.deposit(10_100 ether, ALICE); // alice deposits same assets amount as previous users
    assertApproxEqRel(fixedLender.smartPoolEarningsAccumulator(), 308 ether - 616e17, 1e14);
    // bob earns half the earnings distributed
    assertApproxEqRel(fixedLender.convertToAssets(fixedLender.balanceOf(BOB)), assetsBobBefore + 616e17 / 2, 1e14);
  }

  function testDistributeMultipleAccumulatedEarnings() external {
    vm.warp(0);
    uint256 maturity = TSUtils.INTERVAL * 2;
    fixedLender.deposit(10_000 ether, address(this));
    fixedLender.depositAtMaturity(maturity, 1_000 ether, 1_000 ether, address(this));

    vm.warp(maturity - 1 weeks);
    fixedLender.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    vm.warp(maturity + 2 weeks); // 2 weeks delayed (2% daily = 28% in penalties), 1100 * 1.28 = 1408
    fixedLender.repayAtMaturity(maturity, 1_408 ether, 1_408 ether, address(this));
    // no penalties are accrued (accumulator accounts all of them since borrow uses mp deposits)
    assertApproxEqRel(fixedLender.smartPoolEarningsAccumulator(), 408 ether, 1e7);

    vm.warp(maturity + 3 weeks);
    vm.prank(BOB);
    fixedLender.deposit(10_000 ether, BOB);

    uint256 balanceBobAfterFirstDistribution = fixedLender.convertToAssets(fixedLender.balanceOf(BOB));
    uint256 balanceContractAfterFirstDistribution = fixedLender.convertToAssets(fixedLender.balanceOf(address(this)));
    uint256 accumulatedEarningsAfterFirstDistribution = fixedLender.smartPoolEarningsAccumulator();

    // 196 ether are distributed from the accumulator
    assertApproxEqRel(balanceContractAfterFirstDistribution, 10_196 ether, 1e14);
    assertApproxEqAbs(balanceBobAfterFirstDistribution, 10_000 ether, 1);
    assertApproxEqRel(accumulatedEarningsAfterFirstDistribution, 408 ether - 196 ether, 1e16);
    assertEq(fixedLender.lastAccumulatedEarningsAccrual(), maturity + 3 weeks);

    vm.warp(maturity * 2 + 1 weeks);
    fixedLender.deposit(1_000 ether, address(this));

    uint256 balanceBobAfterSecondDistribution = fixedLender.convertToAssets(fixedLender.balanceOf(BOB));
    uint256 balanceContractAfterSecondDistribution = fixedLender.convertToAssets(fixedLender.balanceOf(address(this)));
    uint256 accumulatedEarningsAfterSecondDistribution = fixedLender.smartPoolEarningsAccumulator();

    uint256 earningsDistributed = balanceBobAfterSecondDistribution -
      balanceBobAfterFirstDistribution +
      balanceContractAfterSecondDistribution -
      balanceContractAfterFirstDistribution -
      1_000 ether; // new deposited eth
    uint256 earningsToBob = 35135460980638083225;
    uint256 earningsToContract = 35821060758380935905;

    assertEq(
      accumulatedEarningsAfterFirstDistribution - accumulatedEarningsAfterSecondDistribution,
      earningsDistributed
    );
    assertEq(earningsToBob + earningsToContract, earningsDistributed);
    assertEq(balanceBobAfterSecondDistribution, balanceBobAfterFirstDistribution + earningsToBob);
    assertEq(
      balanceContractAfterSecondDistribution,
      balanceContractAfterFirstDistribution + earningsToContract + 1_000 ether
    );
    assertEq(fixedLender.lastAccumulatedEarningsAccrual(), maturity * 2 + 1 weeks);
  }

  function testUpdateAccumulatedEarningsFactorToZero() external {
    vm.warp(0);
    uint256 maturity = TSUtils.INTERVAL * 2;
    fixedLender.deposit(10_000 ether, address(this));

    vm.warp(TSUtils.INTERVAL / 2);
    fixedLender.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    // accumulator accounts 10% of the fees, smartPoolFeeRate -> 0.1
    fixedLender.depositAtMaturity(maturity, 1_000 ether, 1_000 ether, address(this));
    assertEq(fixedLender.smartPoolEarningsAccumulator(), 10 ether);

    vm.warp(TSUtils.INTERVAL);
    fixedLender.deposit(1_000 ether, address(this));
    // 25% was distributed
    assertEq(fixedLender.convertToAssets(fixedLender.balanceOf(address(this))), 11_002.5 ether);
    assertEq(fixedLender.smartPoolEarningsAccumulator(), 7.5 ether);

    // we set the factor to 0 and all is distributed in the following tx
    fixedLender.setAccumulatedEarningsSmoothFactor(0);
    vm.warp(TSUtils.INTERVAL + 1 seconds);
    fixedLender.deposit(1 ether, address(this));
    assertEq(fixedLender.convertToAssets(fixedLender.balanceOf(address(this))), 11_011 ether);
    assertEq(fixedLender.smartPoolEarningsAccumulator(), 0);

    // accumulator has 0 earnings so nothing is distributed
    vm.warp(TSUtils.INTERVAL * 2);
    fixedLender.deposit(1 ether, address(this));
    assertEq(fixedLender.convertToAssets(fixedLender.balanceOf(address(this))), 11_012 ether);
    assertEq(fixedLender.smartPoolEarningsAccumulator(), 0);
  }

  function testFailAnotherUserRedeemWhenOwnerHasShortfall() external {
    fixedLender.deposit(10_000 ether, address(this));
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_100 ether, address(this), address(this));

    uint256 assets = fixedLender.previewWithdraw(10_000 ether);
    fixedLender.approve(BOB, assets);
    fixedLender.deposit(1_000 ether, address(this));
    vm.prank(BOB);
    fixedLender.redeem(assets, address(this), address(this));
  }

  function testFailAnotherUserWithdrawWhenOwnerHasShortfall() external {
    fixedLender.deposit(10_000 ether, address(this));
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_100 ether, address(this), address(this));

    fixedLender.approve(BOB, 10_000 ether);
    fixedLender.deposit(1_000 ether, address(this));
    vm.prank(BOB);
    fixedLender.withdraw(10_000 ether, address(this), address(this));
  }

  function testFailRoundingUpAllowanceWhenBorrowingAtMaturity() external {
    uint256 maturity = TSUtils.INTERVAL * 2;

    fixedLender.deposit(10_000 ether, address(this));
    fixedLender.borrowAtMaturity(maturity, 1 ether, 1.1 ether, address(this), address(this));
    vm.warp(TSUtils.INTERVAL);
    // we accrue earnings with this tx so we break proportion of 1 to 1 assets and shares
    fixedLender.borrowAtMaturity(maturity, 1 ether, 1.1 ether, address(this), address(this));

    vm.warp(TSUtils.INTERVAL + 3 days);
    vm.prank(BOB);
    // we try to borrow 1 unit on behalf of this contract as bob being msg.sender without allowance
    // if it correctly rounds up, it should fail
    fixedLender.borrowAtMaturity(maturity, 1, 2, BOB, address(this));
  }

  function testFailRoundingUpAllowanceWhenWithdrawingAtMaturity() external {
    uint256 maturity = TSUtils.INTERVAL * 2;

    fixedLender.deposit(10_000 ether, address(this));
    fixedLender.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));
    vm.warp(TSUtils.INTERVAL);
    // we accrue earnings with this tx so we break proportion of 1 to 1 assets and shares
    fixedLender.borrowAtMaturity(maturity, 1 ether, 1.1 ether, address(this), address(this));

    vm.warp(maturity);
    vm.prank(BOB);
    // we try to withdraw 1 unit on behalf of this contract as bob being msg.sender without allowance
    // if it correctly rounds up, it should fail
    fixedLender.withdrawAtMaturity(maturity, 1, 0, BOB, address(this));
  }

  function testFailRoundingUpAssetsToValidateShortfallWhenTransferringFrom() external {
    MockERC20 token = new MockERC20("DAI", "DAI", 18);

    // we deploy a harness fixedlender to be able to set different supply and smartPoolAssets
    FixedLenderHarness fixedLenderHarness = new FixedLenderHarness(
      token,
      12,
      1e18,
      auditor,
      InterestRateModel(address(mockInterestRateModel)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      FixedLender.DampSpeed(0.0046e18, 0.42e18)
    );
    uint256 maturity = TSUtils.INTERVAL * 2;
    token.mint(address(this), 50_000 ether);
    token.approve(address(fixedLenderHarness), 50_000 ether);
    fixedLenderHarness.approve(BOB, 50_000 ether);
    auditor.enableMarket(fixedLenderHarness, 0.8e18, 18);

    fixedLenderHarness.setSmartPoolAssets(500 ether);
    fixedLenderHarness.setSupply(2000 ether);

    fixedLenderHarness.deposit(1000 ether, address(this));
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderHarness.borrowAtMaturity(maturity, 800 ether, 800 ether, address(this), address(this));

    // we try to transfer 5 shares, if it correctly rounds up to 2 withdraw amount then it should fail
    // if it rounds down to 1, it will pass
    vm.prank(BOB);
    fixedLenderHarness.transferFrom(address(this), BOB, 5);
  }

  function testFailRoundingUpAssetsToValidateShortfallWhenTransferring() external {
    MockERC20 token = new MockERC20("DAI", "DAI", 18);

    // we deploy a harness fixedlender to be able to set different supply and smartPoolAssets
    FixedLenderHarness fixedLenderHarness = new FixedLenderHarness(
      token,
      12,
      1e18,
      auditor,
      InterestRateModel(address(mockInterestRateModel)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      FixedLender.DampSpeed(0.0046e18, 0.42e18)
    );
    uint256 maturity = TSUtils.INTERVAL * 2;
    token.mint(address(this), 50_000 ether);
    token.approve(address(fixedLenderHarness), 50_000 ether);
    auditor.enableMarket(fixedLenderHarness, 0.8e18, 18);

    fixedLenderHarness.setSmartPoolAssets(500 ether);
    fixedLenderHarness.setSupply(2000 ether);

    fixedLenderHarness.deposit(1000 ether, address(this));
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderHarness.borrowAtMaturity(maturity, 800 ether, 800 ether, address(this), address(this));

    // we try to transfer 5 shares, if it correctly rounds up to 2 withdraw amount then it should fail
    // if it rounds down to 1, it will pass
    fixedLenderHarness.transfer(BOB, 5);
  }

  function testAccountLiquidityAdjustedDebt() external {
    // we deposit 1000 as collateral
    fixedLender.deposit(1_000 ether, address(this));

    mockInterestRateModel.setBorrowRate(0);
    // we borrow 100 as debt
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 100 ether, 100 ether, address(this), address(this));

    (uint256 collateral, uint256 debt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    (uint256 adjustFactor, , , ) = auditor.markets(fixedLender);

    assertEq(collateral, uint256(1_000 ether).mulDivDown(1e18, 10**18).mulWadDown(adjustFactor));
    assertEq(collateral, 800 ether);
    assertEq(debt, uint256(100 ether).mulDivUp(1e18, 10**18).divWadUp(adjustFactor));
    assertEq(debt, 125 ether);
  }

  function testCrossMaturityLiquidation() external {
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderWETH.deposit(1.15 ether, address(this));
    fixedLender.deposit(50_000 ether, ALICE);
    fixedLender.setMaxFuturePools(12);
    fixedLender.setPenaltyRate(2e11);

    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    for (uint256 i = 1; i <= 4; i++) {
      fixedLender.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }

    mockOracle.setPrice(fixedLenderWETH, 10e18);
    vm.warp(2 * TSUtils.INTERVAL + 1);

    vm.prank(BOB);
    vm.expectEmit(true, true, true, true, address(fixedLender));
    emit LiquidateBorrow(BOB, address(this), 10454545454545454545, 104545454545454545, fixedLenderWETH, 1.15 ether);
    fixedLender.liquidate(address(this), type(uint256).max, fixedLenderWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      FixedLender(address(0)),
      0
    );
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
    assertEq(fixedLenderWETH.balanceOf(address(this)), 0);
    assertEq(weth.balanceOf(address(BOB)), 1.15 ether);
  }

  function testMultipleLiquidationSameUser() external {
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderWETH.deposit(1.15 ether, address(this));
    fixedLender.deposit(5_000 ether, ALICE);
    fixedLender.setPenaltyRate(2e11);
    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    auditor.setLiquidationIncentive(Auditor.LiquidationIncentive(0.1e18, 0));

    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 4_000 ether, 4_000 ether, address(this), address(this));
    mockOracle.setPrice(fixedLenderWETH, 1_000e18);

    vm.warp(TSUtils.INTERVAL * 2 + 1);
    vm.prank(BOB);
    fixedLender.liquidate(address(this), 500 ether, fixedLenderWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      FixedLender(address(0)),
      0
    );
    assertEq(remainingCollateral, 540 ether);
    assertEq(remainingDebt, 6794.201 ether);
    assertEq(fixedLenderWETH.balanceOf(address(this)), 0.6 ether);
    assertEq(weth.balanceOf(address(BOB)), 0.55 ether);

    vm.prank(BOB);
    fixedLender.liquidate(address(this), 100 ether, fixedLenderWETH);
    (remainingCollateral, remainingDebt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    assertEq(remainingCollateral, 441 ether);
    assertEq(remainingDebt, 6669.201 ether);
    assertEq(fixedLenderWETH.balanceOf(address(this)), 0.49 ether);
    assertEq(weth.balanceOf(address(BOB)), 0.66 ether);

    vm.prank(BOB);
    fixedLender.liquidate(address(this), 500 ether, fixedLenderWETH);
    (remainingCollateral, remainingDebt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
    assertEq(fixedLenderWETH.balanceOf(address(this)), 0);
    assertEq(weth.balanceOf(address(BOB)), 1.15 ether);
  }

  function testLiquidateWithZeroAsMaxAssets() external {
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderWETH.deposit(1.15 ether, address(this));
    fixedLender.deposit(5_000 ether, ALICE);
    fixedLender.setPenaltyRate(2e11);
    mockOracle.setPrice(fixedLenderWETH, 5_000e18);

    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 4_000 ether, 4_000 ether, address(this), address(this));
    mockOracle.setPrice(fixedLenderWETH, 100e18);

    vm.expectRevert(ZeroRepay.selector);
    vm.prank(BOB);
    fixedLender.liquidate(address(this), 0, fixedLender);
  }

  function testLiquidateAndSeizeFromEmptyCollateral() external {
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderWETH.deposit(1.15 ether, address(this));
    fixedLender.deposit(5_000 ether, ALICE);
    fixedLender.setPenaltyRate(2e11);
    mockOracle.setPrice(fixedLenderWETH, 5_000e18);

    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));
    mockOracle.setPrice(fixedLenderWETH, 100e18);

    vm.expectRevert(ZeroRepay.selector);
    vm.prank(BOB);
    fixedLender.liquidate(address(this), 3000 ether, fixedLender);
  }

  function testLiquidateLeavingDustAsCollateral() external {
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderWETH.deposit(1.15 ether, address(this));
    fixedLender.deposit(5_000 ether, ALICE);
    fixedLender.setPenaltyRate(2e11);
    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    auditor.setLiquidationIncentive(Auditor.LiquidationIncentive(0.1e18, 0));

    for (uint256 i = 1; i <= 3; i++) {
      fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));
    }
    mockOracle.setPrice(fixedLenderWETH, 99e18);

    vm.warp(TSUtils.INTERVAL * 3 + 182 days + 123 minutes + 10 seconds);

    vm.prank(BOB);
    fixedLender.liquidate(address(this), 103499999999999999800, fixedLenderWETH);
    assertEq(fixedLenderWETH.maxWithdraw(address(this)), 1);

    vm.prank(BOB);
    fixedLender.liquidate(address(this), type(uint256).max, fixedLenderWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      FixedLender(address(0)),
      0
    );

    assertEq(fixedLenderWETH.maxWithdraw(address(this)), 0);
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
  }

  function testLiquidateAndSeizeExactAmountWithDustAsCollateral() external {
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderWETH.deposit(1.15 ether + 5, address(this));
    fixedLender.deposit(5_000 ether, ALICE);
    fixedLender.setPenaltyRate(2e11);
    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    auditor.setLiquidationIncentive(Auditor.LiquidationIncentive(0.1e18, 0));

    for (uint256 i = 1; i <= 3; i++) {
      fixedLender.borrowAtMaturity(
        TSUtils.INTERVAL,
        1_000 ether + 100,
        1_000 ether + 100,
        address(this),
        address(this)
      );
    }
    mockOracle.setPrice(fixedLenderWETH, 100e18);

    vm.warp(TSUtils.INTERVAL * 3 + 182 days + 123 minutes + 10 seconds);

    vm.prank(BOB);
    fixedLender.liquidate(address(this), type(uint256).max, fixedLenderWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      FixedLender(address(0)),
      0
    );
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
  }

  function testLiquidateWithTwoUnitsAsMaxAssets() external {
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderWETH.deposit(1.15 ether, address(this));
    fixedLender.deposit(5_000 ether, ALICE);
    fixedLender.setPenaltyRate(2e11);
    mockOracle.setPrice(fixedLenderWETH, 5_000e18);

    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL * 2, 1_000 ether, 1_000 ether, address(this), address(this));
    mockOracle.setPrice(fixedLenderWETH, 100e18);

    vm.prank(BOB);
    fixedLender.liquidate(address(this), 2, fixedLenderWETH);

    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      FixedLender(address(0)),
      0
    );
    assertGt(remainingCollateral, 0);
    assertGt(remainingDebt, 0);
  }

  function testLiquidateFlexibleBorrow() external {
    fixedLenderWETH.deposit(1.15 ether, address(this));
    fixedLender.deposit(50_000 ether, ALICE);

    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    fixedLender.borrow(4_000 ether, address(this), address(this));
    mockOracle.setPrice(fixedLenderWETH, 4_000e18);

    assertEq(fixedLender.flexibleBorrowPositions(address(this)), 4_000 ether);

    // partial liquidation
    vm.prank(BOB);
    fixedLender.liquidate(address(this), type(uint256).max, fixedLenderWETH);
    uint256 assetsRepaid = 3685589519650655024000;

    (, uint256 remainingDebt) = fixedLender.getAccountSnapshot(address(this));
    (uint256 remainingCollateral, ) = fixedLenderWETH.getAccountSnapshot(address(this));
    assertEq(weth.balanceOf(address(BOB)), assetsRepaid.divWadDown(4_000 ether).mulWadUp(1.1e18));
    assertEq(remainingCollateral, 1.15 ether - assetsRepaid.divWadDown(4_000 ether).mulWadUp(1.1e18));
    assertEq(fixedLender.flexibleBorrowPositions(address(this)), 4_000 ether - assetsRepaid);
    assertEq(fixedLender.flexibleBorrowPositions(address(this)), remainingDebt);

    (uint256 usdCollateral, uint256 usdDebt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    assertEq(usdCollateral, remainingCollateral.mulWadDown(4_000 ether).mulWadDown(0.9e18));
    assertEq(usdDebt, remainingDebt.divWadUp(0.8e18));

    mockOracle.setPrice(fixedLenderWETH, 1_000e18);
    // full liquidation
    vm.prank(BOB);
    fixedLender.liquidate(address(this), type(uint256).max, fixedLenderWETH);

    (, remainingDebt) = fixedLender.getAccountSnapshot(address(this));
    (remainingCollateral, ) = fixedLenderWETH.getAccountSnapshot(address(this));
    (usdCollateral, usdDebt) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
    assertEq(usdCollateral, 0);
    assertEq(usdDebt, 0);
    assertEq(fixedLender.flexibleBorrowPositions(address(this)), 0);
    assertEq(weth.balanceOf(address(BOB)), 1.15 ether);
  }

  function testLiquidateFlexibleBorrowChargeLendersAssetsToLiquidator() external {
    fixedLenderWETH.deposit(1.15 ether, address(this));
    fixedLender.deposit(50_000 ether, ALICE);

    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    fixedLender.borrow(4_000 ether, address(this), address(this));
    mockOracle.setPrice(fixedLenderWETH, 3_000e18);

    uint256 bobDAIBalanceBefore = ERC20(fixedLender.asset()).balanceOf(BOB);
    vm.prank(BOB);
    fixedLender.liquidate(address(this), 100 ether, fixedLenderWETH);
    uint256 assetsRepaid = uint256(100 ether).divWadDown(1.01e18);
    uint256 lendersIncentiveRepaid = assetsRepaid.mulWadDown(0.01e18);
    uint256 assetsSeized = assetsRepaid.mulDivUp(10**18, 3_000 ether).mulWadUp(1.1e18);
    assertEq(ERC20(fixedLender.asset()).balanceOf(BOB), bobDAIBalanceBefore - assetsRepaid - lendersIncentiveRepaid);
    assertEq(weth.balanceOf(address(BOB)), assetsSeized);
  }

  function testLiquidateFlexibleAndFixedBorrowPositionsInSingleCall() external {
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderWETH.deposit(1.15 ether, address(this));
    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    fixedLender.deposit(50_000 ether, ALICE);

    for (uint256 i = 1; i <= 2; i++) {
      fixedLender.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }

    fixedLender.borrow(2_000 ether, address(this), address(this));
    mockOracle.setPrice(fixedLenderWETH, 4_000e18);

    vm.prank(BOB);
    fixedLender.liquidate(address(this), 1000 ether, fixedLenderWETH);
    uint256 assetsRepaid = uint256(1000 ether).divWadDown(1.01e18);
    // only repaid in the first maturity
    (uint256 principal, uint256 fee) = fixedLender.fixedBorrowPositions(TSUtils.INTERVAL, address(this));
    assertEq(principal + fee, 1_000 ether - assetsRepaid);
    (principal, fee) = fixedLender.fixedBorrowPositions(TSUtils.INTERVAL * 2, address(this));
    assertEq(principal + fee, 1_000 ether);
    assertEq(fixedLender.flexibleBorrowPositions(address(this)), 2_000 ether);

    vm.prank(BOB);
    fixedLender.liquidate(address(this), 1500 ether, fixedLenderWETH);
    assetsRepaid += uint256(1500 ether).divWadDown(1.01e18);
    (principal, fee) = fixedLender.fixedBorrowPositions(TSUtils.INTERVAL, address(this));
    assertEq(principal + fee, 0);
    (principal, fee) = fixedLender.fixedBorrowPositions(TSUtils.INTERVAL * 2, address(this));
    assertEq(principal + fee, 0);
    assertEq(fixedLender.flexibleBorrowPositions(address(this)), 2_000 ether - (assetsRepaid - 2_000 ether));

    vm.prank(BOB);
    fixedLender.liquidate(address(this), 1500 ether, fixedLenderWETH);
  }

  function testLiquidateAndChargeIncentiveForLenders() external {
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderWETH.deposit(1.15 ether, address(this));
    fixedLender.deposit(50_000 ether, ALICE);
    fixedLender.setMaxFuturePools(12);

    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    for (uint256 i = 1; i <= 4; i++) {
      fixedLender.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }
    mockOracle.setPrice(fixedLenderWETH, 3_000e18);

    uint256 bobDAIBalanceBefore = ERC20(fixedLender.asset()).balanceOf(BOB);
    vm.prank(BOB);
    fixedLender.liquidate(address(this), type(uint256).max, fixedLenderWETH);
    uint256 bobDAIBalanceAfter = ERC20(fixedLender.asset()).balanceOf(BOB);
    // if 110% is 1.15 ether then 100% is 1.0454545455 ether * 3_000 (eth price) = 3136363636363636363637
    // bob will repay 1% of that amount
    uint256 totalBobRepayment = uint256(3136363636363636363637).mulWadDown(1.01e18);

    // BOB STILL SEIZES ALL USER COLLATERAL
    assertEq(weth.balanceOf(address(BOB)), 1.15 ether);
    assertEq(bobDAIBalanceBefore - bobDAIBalanceAfter, totalBobRepayment);
  }

  function testLiquidateFlexibleBorrowConsideringDebtOverTime() external {
    vm.warp(0);
    fixedLenderWETH.deposit(1.15 ether, address(this));
    fixedLender.deposit(50_000 ether, ALICE);

    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    fixedLender.borrow(4_000 ether, address(this), address(this));

    // 10% yearly interest
    vm.warp(365 days);
    assertEq(fixedLender.getDebt(address(this)), 4_000 ether + 400 ether);

    // bob is allowed to repay 2970
    vm.prank(BOB);
    fixedLender.liquidate(address(this), type(uint256).max, fixedLenderWETH);

    assertApproxEqRel(fixedLender.getDebt(address(this)), 1_430 ether, 1e18);
    assertApproxEqRel(fixedLender.smartPoolFlexibleBorrows(), 1_430 ether, 1e18);
    assertEq(fixedLender.smartPoolAssets(), 50_400 ether);
    assertEq(fixedLender.lastUpdatedSmartPoolRate(), 365 days);
  }

  function testLiquidateAndDistributeLosses() external {
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderWETH.deposit(1.15 ether, address(this));
    fixedLender.deposit(50_000 ether, ALICE);
    fixedLender.setMaxFuturePools(12);

    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    for (uint256 i = 1; i <= 4; i++) {
      fixedLender.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }
    mockOracle.setPrice(fixedLenderWETH, 3_000e18);

    uint256 bobDAIBalanceBefore = ERC20(fixedLender.asset()).balanceOf(BOB);
    uint256 smartPoolAssetsBefore = fixedLender.smartPoolAssets();
    vm.prank(BOB);
    fixedLender.liquidate(address(this), type(uint256).max, fixedLenderWETH);
    uint256 bobDAIBalanceAfter = ERC20(fixedLender.asset()).balanceOf(BOB);
    uint256 smartPoolAssetsAfter = fixedLender.smartPoolAssets();
    uint256 totalUsdDebt = 1_000 ether * 4;
    // if 110% is 1.15 ether then 100% is 1.0454545455 ether * 3_000 (eth price) = 3136363636363636363637
    uint256 totalBobRepayment = 3136363636363636363637;
    uint256 lendersIncentive = uint256(3136363636363636363637).mulWadDown(0.01e18);

    // BOB SEIZES ALL USER COLLATERAL
    assertEq(weth.balanceOf(address(BOB)), 1.15 ether);
    assertEq(bobDAIBalanceBefore - bobDAIBalanceAfter, totalBobRepayment + lendersIncentive);
    assertEq(smartPoolAssetsBefore - smartPoolAssetsAfter, totalUsdDebt - totalBobRepayment);
    assertEq(fixedLender.fixedBorrows(address(this)), 0);
    for (uint256 i = 1; i <= 4; i++) {
      (uint256 principal, uint256 fee) = fixedLender.fixedBorrowPositions(TSUtils.INTERVAL * i, address(this));
      assertEq(principal + fee, 0);
    }
  }

  function testLiquidateAndSubtractLossesFromAccumulator() external {
    mockInterestRateModel.setBorrowRate(0.1e18);
    fixedLender.setSmartPoolFeeRate(0);
    fixedLenderWETH.deposit(1.3 ether, address(this));
    fixedLender.deposit(50_000 ether, ALICE);
    fixedLender.setMaxFuturePools(12);
    fixedLender.setPenaltyRate(2e11);

    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    for (uint256 i = 3; i <= 6; i++) {
      fixedLender.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_100 ether, address(this), address(this));
    }
    vm.prank(ALICE);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 5_000 ether, 5_500 ether, address(ALICE), address(ALICE));
    mockOracle.setPrice(fixedLenderWETH, 100e18);

    vm.warp(TSUtils.INTERVAL * 2);

    (uint256 principal, uint256 fee) = fixedLender.fixedBorrowPositions(TSUtils.INTERVAL, ALICE);
    (, uint256 debt) = fixedLender.getAccountSnapshot(ALICE);
    vm.prank(ALICE);
    fixedLender.repayAtMaturity(TSUtils.INTERVAL, principal + fee, debt, address(ALICE));
    uint256 smartPoolEarningsAccumulator = fixedLender.smartPoolEarningsAccumulator();
    uint256 smartPoolAssets = fixedLender.smartPoolAssets();

    assertEq(smartPoolEarningsAccumulator, debt - principal - fee);

    vm.prank(BOB);
    fixedLender.liquidate(address(this), type(uint256).max, fixedLenderWETH);

    uint256 badDebt = 981818181818181818181 + 1100000000000000000000 + 1100000000000000000000 + 1100000000000000000000;
    uint256 earningsSPDistributedInRepayment = 66666662073779496497;

    assertEq(fixedLender.smartPoolEarningsAccumulator(), 0);
    assertEq(
      badDebt,
      smartPoolEarningsAccumulator + smartPoolAssets - fixedLender.smartPoolAssets() + earningsSPDistributedInRepayment
    );
    assertEq(fixedLender.fixedBorrows(address(this)), 0);
  }

  function testDistributionOfLossesShouldReduceFromSmartPoolFixedBorrowsAccordingly() external {
    mockInterestRateModel.setBorrowRate(0);
    fixedLenderWETH.deposit(1.15 ether, address(this));
    fixedLender.deposit(50_000 ether, ALICE);
    fixedLender.setMaxFuturePools(12);

    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    for (uint256 i = 1; i <= 4; i++) {
      fixedLender.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));

      // we deposit so smartPoolFixedBorrows is 0
      fixedLender.depositAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this));
    }
    mockOracle.setPrice(fixedLenderWETH, 3_000e18);

    assertEq(fixedLender.smartPoolFixedBorrows(), 0);
    vm.prank(BOB);
    // distribution of losses should not reduce more of smartPoolFixedBorrows
    fixedLender.liquidate(address(this), type(uint256).max, fixedLenderWETH);
    assertEq(fixedLender.smartPoolFixedBorrows(), 0);

    fixedLenderWETH.deposit(1.15 ether, address(this));
    mockOracle.setPrice(fixedLenderWETH, 5_000e18);
    for (uint256 i = 1; i <= 4; i++) {
      fixedLender.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));

      // we withdraw 500 so smartPoolFixedBorrows is half
      fixedLender.withdrawAtMaturity(TSUtils.INTERVAL * i, 500 ether, 500 ether, address(this), address(this));
    }
    mockOracle.setPrice(fixedLenderWETH, 3_000e18);

    assertEq(fixedLender.smartPoolFixedBorrows(), (1_000 ether * 4) / 2);
    vm.prank(BOB);
    // distribution of losses should reduce the remaining from smartPoolFixedBorrows
    fixedLender.liquidate(address(this), type(uint256).max, fixedLenderWETH);
    assertEq(fixedLender.smartPoolFixedBorrows(), 0);
  }

  function testCappedLiquidation() external {
    mockInterestRateModel.setBorrowRate(0);
    mockOracle.setPrice(fixedLenderWETH, 2_000e18);

    fixedLender.deposit(50_000 ether, ALICE);
    fixedLenderWETH.deposit(1 ether, address(this));
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));

    mockOracle.setPrice(fixedLenderWETH, 900e18);

    vm.prank(BOB);
    // vm.expectEmit(true, true, true, true, address(fixedLender));
    // emit LiquidateBorrow(BOB, address(this), 818181818181818181819, 8181818181818181818, fixedLenderWETH, 1 ether);
    // we expect the liquidation to cap the max amount of possible assets to repay
    fixedLender.liquidate(address(this), type(uint256).max, fixedLenderWETH);
    (uint256 remainingCollateral, ) = auditor.accountLiquidity(address(this), FixedLender(address(0)), 0);
    assertEq(remainingCollateral, 0);
  }

  function testLiquidationResultingInZeroCollateralAndZeroDebt() external {
    mockInterestRateModel.setBorrowRate(0);
    mockOracle.setPrice(fixedLenderWETH, 2_000e18);

    fixedLender.deposit(50_000 ether, ALICE);
    fixedLenderWETH.deposit(1 ether, address(this));
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));

    mockOracle.setPrice(fixedLenderWETH, 900e18);

    vm.prank(BOB);
    vm.expectEmit(true, true, true, true, address(fixedLender));
    emit LiquidateBorrow(BOB, address(this), 818181818181818181819, 8181818181818181818, fixedLenderWETH, 1 ether);
    fixedLender.liquidate(address(this), 1_000 ether, fixedLenderWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      FixedLender(address(0)),
      0
    );
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
  }

  function testUpdateSmartPoolAssetsAverageWithDampSpeedUp() external {
    vm.warp(0);
    fixedLender.deposit(100 ether, address(this));

    vm.warp(217);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertLt(fixedLender.smartPoolAssetsAverage(), fixedLender.smartPoolAssets());

    vm.warp(435);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertLt(fixedLender.smartPoolAssetsAverage(), fixedLender.smartPoolAssets());

    // with a damp speed up of 0.0046, the smartPoolAssetsAverage is equal to the smartPoolAssets
    // when 9011 seconds went by
    vm.warp(9446);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), fixedLender.smartPoolAssets());

    vm.warp(300000);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), fixedLender.smartPoolAssets());
  }

  function testUpdateSmartPoolAssetsAverageWithDampSpeedDown() external {
    vm.warp(0);
    fixedLender.deposit(100 ether, address(this));

    vm.warp(218);
    fixedLender.withdraw(50 ether, address(this), address(this));

    vm.warp(220);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertLt(fixedLender.smartPoolAssets(), fixedLender.smartPoolAssetsAverage());

    vm.warp(300);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertApproxEqRel(fixedLender.smartPoolAssetsAverage(), fixedLender.smartPoolAssets(), 1e6);

    // with a damp speed down of 0.42, the smartPoolAssetsAverage is equal to the smartPoolAssets
    // when 23 seconds went by
    vm.warp(323);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), fixedLender.smartPoolAssets());
  }

  function testUpdateSmartPoolAssetsAverageWhenDepositingRightBeforeEarlyWithdraw() external {
    uint256 initialBalance = 10 ether;
    uint256 amount = 1 ether;

    vm.warp(0);
    fixedLender.deposit(initialBalance, address(this));
    fixedLender.depositAtMaturity(TSUtils.INTERVAL, amount, amount, address(this));

    vm.warp(2000);
    fixedLender.deposit(100 ether, address(this));
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, amount, 0.9 ether, address(this), address(this));
    assertApproxEqRel(fixedLender.smartPoolAssetsAverage(), initialBalance, 1e15);
    assertEq(fixedLender.smartPoolAssets(), 100 ether + initialBalance);
  }

  function testUpdateSmartPoolAssetsAverageWhenDepositingRightBeforeBorrow() external {
    uint256 initialBalance = 10 ether;
    vm.warp(0);
    fixedLender.deposit(initialBalance, address(this));

    vm.warp(2000);
    fixedLender.deposit(100 ether, address(this));
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertApproxEqRel(fixedLender.smartPoolAssetsAverage(), initialBalance, 1e15);
    assertEq(fixedLender.smartPoolAssets(), 100 ether + initialBalance);
  }

  function testUpdateSmartPoolAssetsAverageWhenDepositingSomeSecondsBeforeBorrow() external {
    vm.warp(0);
    fixedLender.deposit(10 ether, address(this));

    vm.warp(218);
    fixedLender.deposit(100 ether, address(this));
    uint256 lastSmartPoolAssetsAverage = fixedLender.smartPoolAssetsAverage();

    vm.warp(250);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    uint256 supplyAverageFactor = uint256(
      1e18 - FixedPointMathLib.expWad(-int256(fixedLender.dampSpeedUp() * (250 - 218)))
    );
    assertEq(
      fixedLender.smartPoolAssetsAverage(),
      lastSmartPoolAssetsAverage.mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(fixedLender.smartPoolAssets())
    );
    assertEq(fixedLender.smartPoolAssetsAverage(), 20.521498717652997528 ether);

    vm.warp(9541);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), fixedLender.smartPoolAssets());
  }

  function testUpdateSmartPoolAssetsAverageWhenDepositingAndBorrowingContinuously() external {
    vm.warp(0);
    fixedLender.deposit(10 ether, address(this));

    vm.warp(218);
    fixedLender.deposit(100 ether, address(this));

    vm.warp(219);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), 6.807271809941046233 ether);

    vm.warp(220);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), 7.280868252688897889 ether);

    vm.warp(221);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), 7.752291154776303799 ether);

    vm.warp(222);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), 8.221550491529461938 ether);
  }

  function testUpdateSmartPoolAssetsAverageWhenDepositingAndWithdrawingEarlyContinuously() external {
    vm.warp(0);
    fixedLender.deposit(10 ether, address(this));
    fixedLender.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));

    vm.warp(218);
    fixedLender.deposit(100 ether, address(this));

    vm.warp(219);
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), 6.807271809941046233 ether);

    vm.warp(220);
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), 7.280868252688897889 ether);

    vm.warp(221);
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), 7.752291154776303799 ether);

    vm.warp(222);
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), 8.221550491529461938 ether);
  }

  function testUpdateSmartPoolAssetsAverageWhenWithdrawingRightBeforeBorrow() external {
    uint256 initialBalance = 10 ether;
    vm.warp(0);
    fixedLender.deposit(initialBalance, address(this));

    vm.warp(2000);
    fixedLender.withdraw(5 ether, address(this), address(this));
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertApproxEqRel(fixedLender.smartPoolAssetsAverage(), initialBalance, 1e15);
    assertEq(fixedLender.smartPoolAssets(), initialBalance - 5 ether);
  }

  function testUpdateSmartPoolAssetsAverageWhenWithdrawingRightBeforeEarlyWithdraw() external {
    uint256 initialBalance = 10 ether;
    uint256 amount = 1 ether;
    vm.warp(0);
    fixedLender.deposit(initialBalance, address(this));
    fixedLender.depositAtMaturity(TSUtils.INTERVAL, amount, amount, address(this));

    vm.warp(2000);
    fixedLender.withdraw(5 ether, address(this), address(this));
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, amount, 0.9 ether, address(this), address(this));
    assertApproxEqRel(fixedLender.smartPoolAssetsAverage(), initialBalance, 1e15);
    assertEq(fixedLender.smartPoolAssets(), initialBalance - 5 ether);
  }

  function testUpdateSmartPoolAssetsAverageWhenWithdrawingSomeSecondsBeforeBorrow() external {
    vm.warp(0);
    fixedLender.deposit(10 ether, address(this));

    vm.warp(218);
    fixedLender.withdraw(5 ether, address(this), address(this));
    uint256 lastSmartPoolAssetsAverage = fixedLender.smartPoolAssetsAverage();

    vm.warp(219);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    uint256 supplyAverageFactor = uint256(
      1e18 - FixedPointMathLib.expWad(-int256(fixedLender.dampSpeedDown() * (219 - 218)))
    );
    assertEq(
      fixedLender.smartPoolAssetsAverage(),
      uint256(lastSmartPoolAssetsAverage).mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(fixedLender.smartPoolAssets())
    );
    assertEq(fixedLender.smartPoolAssetsAverage(), 5.874852456225897297 ether);

    vm.warp(221);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    supplyAverageFactor = uint256(1e18 - FixedPointMathLib.expWad(-int256(fixedLender.dampSpeedDown() * (221 - 219))));
    assertEq(
      fixedLender.smartPoolAssetsAverage(),
      uint256(5.874852456225897297 ether).mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(fixedLender.smartPoolAssets())
    );
    assertEq(fixedLender.smartPoolAssetsAverage(), 5.377683011800498150 ether);

    vm.warp(444);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), fixedLender.smartPoolAssets());
  }

  function testUpdateSmartPoolAssetsAverageWhenWithdrawingSomeSecondsBeforeEarlyWithdraw() external {
    vm.warp(0);
    fixedLender.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
    fixedLender.deposit(10 ether, address(this));

    vm.warp(218);
    fixedLender.withdraw(5 ether, address(this), address(this));
    uint256 lastSmartPoolAssetsAverage = fixedLender.smartPoolAssetsAverage();

    vm.warp(219);
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    uint256 supplyAverageFactor = uint256(
      1e18 - FixedPointMathLib.expWad(-int256(fixedLender.dampSpeedDown() * (219 - 218)))
    );
    assertEq(
      fixedLender.smartPoolAssetsAverage(),
      lastSmartPoolAssetsAverage.mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(fixedLender.smartPoolAssets())
    );
    assertEq(fixedLender.smartPoolAssetsAverage(), 5.874852456225897297 ether);

    vm.warp(221);
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    supplyAverageFactor = uint256(1e18 - FixedPointMathLib.expWad(-int256(fixedLender.dampSpeedDown() * (221 - 219))));
    assertEq(
      fixedLender.smartPoolAssetsAverage(),
      uint256(5.874852456225897297 ether).mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(fixedLender.smartPoolAssets())
    );
    assertEq(fixedLender.smartPoolAssetsAverage(), 5.377683011800498150 ether);

    vm.warp(226);
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertApproxEqRel(fixedLender.smartPoolAssetsAverage(), fixedLender.smartPoolAssets(), 1e17);
  }

  function testUpdateSmartPoolAssetsAverageWhenWithdrawingBeforeEarlyWithdrawsAndBorrows() external {
    vm.warp(0);
    fixedLender.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
    fixedLender.deposit(10 ether, address(this));

    vm.warp(218);
    fixedLender.withdraw(5 ether, address(this), address(this));
    uint256 lastSmartPoolAssetsAverage = fixedLender.smartPoolAssetsAverage();

    vm.warp(219);
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    uint256 supplyAverageFactor = uint256(
      1e18 - FixedPointMathLib.expWad(-int256(fixedLender.dampSpeedDown() * (219 - 218)))
    );
    assertEq(
      fixedLender.smartPoolAssetsAverage(),
      uint256(lastSmartPoolAssetsAverage).mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(fixedLender.smartPoolAssets())
    );
    assertEq(fixedLender.smartPoolAssetsAverage(), 5.874852456225897297 ether);

    vm.warp(221);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    supplyAverageFactor = uint256(1e18 - FixedPointMathLib.expWad(-int256(fixedLender.dampSpeedDown() * (221 - 219))));
    assertEq(
      fixedLender.smartPoolAssetsAverage(),
      uint256(5.874852456225897297 ether).mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(fixedLender.smartPoolAssets())
    );
    assertEq(fixedLender.smartPoolAssetsAverage(), 5.377683011800498150 ether);

    vm.warp(223);
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    supplyAverageFactor = uint256(1e18 - FixedPointMathLib.expWad(-int256(fixedLender.dampSpeedDown() * (223 - 221))));
    assertEq(
      fixedLender.smartPoolAssetsAverage(),
      uint256(5.377683011800498150 ether).mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(fixedLender.smartPoolAssets())
    );
    assertEq(fixedLender.smartPoolAssetsAverage(), 5.163049730714664338 ether);

    vm.warp(226);
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertApproxEqRel(fixedLender.smartPoolAssetsAverage(), fixedLender.smartPoolAssets(), 1e16);

    vm.warp(500);
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertEq(fixedLender.smartPoolAssetsAverage(), fixedLender.smartPoolAssets());
  }

  function testFixedBorrowFailingWhenFlexibleBorrowAccruesDebt() external {
    fixedLender.deposit(100 ether, address(this));

    fixedLender.borrow(50 ether, address(this), address(this));

    vm.warp(365 days);
    vm.expectRevert(InsufficientLiquidity.selector);
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL * 14, 10 ether, 15 ether, address(this), address(this));

    vm.expectRevert(InsufficientLiquidity.selector);
    fixedLender.transfer(address(BOB), 15 ether);

    vm.expectRevert(InsufficientLiquidity.selector);
    fixedLender.withdraw(15 ether, address(this), address(this));

    vm.expectRevert(InsufficientLiquidity.selector);
    fixedLender.withdraw(15 ether, address(this), address(this));

    fixedLender.approve(address(BOB), 15 ether);

    vm.prank(BOB);
    vm.expectRevert(InsufficientLiquidity.selector);
    fixedLender.transferFrom(address(this), address(BOB), 15 ether);
  }

  function testDepositShouldUpdateFlexibleBorrowVariables() external {
    vm.warp(0);
    fixedLender.deposit(100 ether, address(this));
    fixedLender.borrow(10 ether, address(this), address(this));
    uint256 spPreviousUtilization = fixedLender.spPreviousUtilization();

    vm.warp(365 days);
    fixedLender.deposit(1, address(this));

    assertEq(fixedLender.smartPoolFlexibleBorrows(), 11 ether);
    assertEq(fixedLender.smartPoolAssets(), 101 ether + 1);
    assertEq(fixedLender.lastUpdatedSmartPoolRate(), 365 days);
    assertGt(fixedLender.spPreviousUtilization(), spPreviousUtilization);
    spPreviousUtilization = fixedLender.spPreviousUtilization();

    vm.warp(730 days);
    fixedLender.mint(1, address(this));
    assertEq(fixedLender.smartPoolFlexibleBorrows(), 12.1 ether);
    assertEq(fixedLender.smartPoolAssets(), 102.1 ether + 3);
    assertEq(fixedLender.lastUpdatedSmartPoolRate(), 730 days);
    assertGt(fixedLender.spPreviousUtilization(), spPreviousUtilization);
  }

  function testWithdrawShouldUpdateFlexibleBorrowVariables() external {
    vm.warp(0);
    fixedLender.deposit(100 ether, address(this));
    fixedLender.borrow(10 ether, address(this), address(this));
    uint256 spPreviousUtilization = fixedLender.spPreviousUtilization();

    vm.warp(365 days);
    fixedLender.withdraw(1, address(this), address(this));

    assertEq(fixedLender.smartPoolFlexibleBorrows(), 11 ether);
    assertEq(fixedLender.smartPoolAssets(), 101 ether - 1);
    assertEq(fixedLender.lastUpdatedSmartPoolRate(), 365 days);
    assertGt(fixedLender.spPreviousUtilization(), spPreviousUtilization);
    spPreviousUtilization = fixedLender.spPreviousUtilization();

    vm.warp(730 days);
    fixedLender.redeem(1, address(this), address(this));

    assertEq(fixedLender.smartPoolFlexibleBorrows(), 12.1 ether);
    assertEq(fixedLender.smartPoolAssets(), 102.1 ether - 2);
    assertEq(fixedLender.lastUpdatedSmartPoolRate(), 730 days);
    assertGt(fixedLender.spPreviousUtilization(), spPreviousUtilization);
  }

  function testFlexibleBorrow() external {
    fixedLender.deposit(10 ether, address(this));
    uint256 balanceBefore = fixedLender.asset().balanceOf(address(this));
    fixedLender.borrow(1 ether, address(this), address(this));
    uint256 balanceAfter = fixedLender.asset().balanceOf(address(this));
    uint256 borrowedShares = fixedLender.flexibleBorrowPositions(address(this));

    assertEq(borrowedShares, 1 ether);
    assertEq(balanceAfter, balanceBefore + 1 ether);
  }

  function testFlexibleBorrowFromAnotherUserWithAllowance() external {
    fixedLender.deposit(10 ether, address(this));
    vm.prank(BOB);
    fixedLender.approve(address(this), type(uint256).max);
    fixedLender.borrow(1 ether, address(this), address(BOB));
  }

  function testFlexibleBorrowFromAnotherUserSubtractsAllowance() external {
    fixedLender.deposit(10 ether, address(this));
    vm.prank(BOB);
    fixedLender.approve(address(this), 2 ether);
    fixedLender.borrow(1 ether, address(this), address(BOB));

    assertEq(fixedLender.allowance(address(BOB), address(this)), 2 ether - 1 ether);
  }

  function testFailFlexibleBorrowFromAnotherUserWithoutAllowance() external {
    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrow(1 ether, address(this), address(BOB));
  }

  function testFlexibleBorrowAccountingDebt() external {
    vm.warp(0);
    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrow(1 ether, address(this), address(this));
    assertEq(fixedLender.smartPoolFlexibleBorrows(), 1 ether);
    assertEq(fixedLender.totalFlexibleBorrowsShares(), fixedLender.flexibleBorrowPositions(address(this)));

    // after 1 year 10% is the accumulated debt (using a mock interest rate model)
    vm.warp(365 days);
    assertEq(fixedLender.getDebt(address(this)), 1.1 ether);
    fixedLender.repay(0.5 ether, address(this));
    assertEq(fixedLender.smartPoolFlexibleBorrows(), 0.55 ether);
    assertEq(fixedLender.totalFlexibleBorrowsShares(), fixedLender.flexibleBorrowPositions(address(this)));

    assertEq(fixedLender.flexibleBorrowPositions(address(this)), 0.5 ether);
    fixedLender.repay(0.5 ether, address(this));
    assertEq(fixedLender.flexibleBorrowPositions(address(this)), 0);
  }

  function testFlexibleBorrowAccountingDebtMultipleAccounts() internal { // TODO refactor
    vm.warp(0);

    mockOracle.setPrice(fixedLenderWETH, 1_000e18);
    weth.mint(BOB, 1 ether);
    vm.prank(BOB);
    weth.approve(address(fixedLenderWETH), 1 ether);
    vm.prank(BOB);
    fixedLenderWETH.deposit(1 ether, BOB);
    vm.prank(BOB);
    auditor.enterMarket(fixedLenderWETH);

    weth.mint(ALICE, 1 ether);
    vm.prank(ALICE);
    weth.approve(address(fixedLenderWETH), 1 ether);
    vm.prank(ALICE);
    fixedLenderWETH.deposit(1 ether, ALICE);
    vm.prank(ALICE);
    auditor.enterMarket(fixedLenderWETH);

    fixedLender.deposit(10 ether, address(this));
    fixedLender.borrow(1 ether, address(this), address(this));

    mockInterestRateModel.setBorrowRate(0.05e18);
    // after 1/2 year 2.5% is the accumulated debt (using a mock interest rate model)
    vm.warp(182.5 days);
    assertEq(fixedLender.previewRepay(1 ether), 1.025 ether);
    assertEq(fixedLender.getDebt(address(this)), 1.025 ether);

    vm.prank(BOB);
    fixedLender.borrow(1 ether, address(BOB), address(BOB));
    assertEq(fixedLender.previewRepay(1 ether), fixedLender.getDebt(address(BOB)));
    assertEq(fixedLender.previewRepay(1.025 ether), fixedLender.flexibleBorrowPositions(address(this)));

    // after 1/4 year 1.25% is the accumulated debt
    // contract now owes 1.025 * 1.0125 = 1.0378125 ether
    // bob now owes      1 * 1.0125     = 1.0125 ether
    vm.warp(273.75 days);
    vm.prank(ALICE);
    fixedLender.borrow(1 ether, address(ALICE), address(ALICE));
    // TODO: check rounding
    assertEq(fixedLender.previewRepay(1 ether), fixedLender.flexibleBorrowPositions(address(ALICE)) + 1);
    assertEq(fixedLender.previewRepay(1.0125 ether), fixedLender.flexibleBorrowPositions(address(BOB)));
    assertEq(fixedLender.previewRepay(1.0378125 ether), fixedLender.flexibleBorrowPositions(address(this)));

    // after another 1/4 year 1.25% is the accumulated debt
    // contract now owes 1.0378125 * 1.0125 = 1.0507851525 ether
    // bob now owes      1.0125 * 1.0125    = 1.02515625 ether
    // alice now owes    1 * 1.0125         = 1.0125 ether
    vm.warp(365 days);
    vm.prank(ALICE);
    fixedLender.repay(1.05078515625 ether, address(this));
    vm.prank(BOB);
    fixedLender.repay(1.02515625 ether, address(BOB));
    vm.prank(ALICE);
    fixedLender.repay(1.0125 ether, address(ALICE));

    assertEq(fixedLender.flexibleBorrowPositions(address(this)), 0);
    assertEq(fixedLender.flexibleBorrowPositions(address(BOB)), 0);
    assertEq(fixedLender.flexibleBorrowPositions(address(ALICE)), 0);

    uint256 flexibleDebtAccrued = 0.05078515625 ether + 0.02515625 ether + 0.0125 ether;
    assertEq(fixedLender.smartPoolAssets(), 10 ether + flexibleDebtAccrued);
  }

  function testFlexibleBorrowExceedingSmartPoolReserve() external {
    fixedLenderWETH.deposit(1 ether, address(this));
    mockOracle.setPrice(fixedLenderWETH, 1_000e18);

    fixedLender.deposit(10 ether, address(this));
    fixedLender.setSmartPoolReserveFactor(0.1e18);

    fixedLender.borrow(9 ether, address(this), address(this));
    fixedLender.repay(9 ether, address(this));

    vm.expectRevert(SmartPoolReserveExceeded.selector);
    fixedLender.borrow(9.01 ether, address(this), address(this));
  }

  function testFlexibleBorrowExceedingSmartPoolReserveIncludingFixedBorrow() external {
    fixedLenderWETH.deposit(1 ether, address(this));
    mockOracle.setPrice(fixedLenderWETH, 1_000e18);

    fixedLender.deposit(10 ether, address(this));
    fixedLender.setSmartPoolReserveFactor(0.1e18);

    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));

    fixedLender.borrow(8 ether, address(this), address(this));
    fixedLender.repay(8 ether, address(this));

    vm.expectRevert(SmartPoolReserveExceeded.selector);
    fixedLender.borrow(8.01 ether, address(this), address(this));
  }

  function testFlexibleBorrowExceedingSmartPoolReserveWithNewDebt() external {
    fixedLenderWETH.deposit(1 ether, address(this));
    mockOracle.setPrice(fixedLenderWETH, 1_000e18);

    fixedLender.deposit(10 ether, address(this));
    fixedLender.setSmartPoolReserveFactor(0.1e18);
    fixedLender.borrow(8.8 ether, address(this), address(this));
    vm.warp(365 days);

    // it doesn't revert because the flexible debt also increases the smart pool assets
    fixedLender.borrow(0.1 ether, address(this), address(this));
  }

  function testOperationsShouldUpdateSmartPoolAssetsAverage() external {
    fixedLender.deposit(100 ether, address(this));
    uint256 currentSmartPoolAssets = fixedLender.smartPoolAssetsAverage();
    assertEq(fixedLender.smartPoolAssetsAverage(), 0);
    uint256 previousSmartPoolAssets = currentSmartPoolAssets;

    // SMART POOL WITHDRAW
    vm.warp(1000);
    fixedLender.withdraw(1, address(this), address(this));
    currentSmartPoolAssets = fixedLender.smartPoolAssetsAverage();
    assertGt(currentSmartPoolAssets, previousSmartPoolAssets);
    previousSmartPoolAssets = currentSmartPoolAssets;

    vm.warp(2000);
    // SMART POOL DEPOSIT (LIQUIDATE SHOULD ALSO UPDATE SP ASSETS AVERAGE)
    fixedLender.deposit(1, address(this));
    currentSmartPoolAssets = fixedLender.smartPoolAssetsAverage();
    assertGt(currentSmartPoolAssets, previousSmartPoolAssets);
    previousSmartPoolAssets = currentSmartPoolAssets;

    vm.warp(3000);
    // FIXED BORROW
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 1, 2, address(this), address(this));
    currentSmartPoolAssets = fixedLender.smartPoolAssetsAverage();
    assertGt(currentSmartPoolAssets, previousSmartPoolAssets);
    previousSmartPoolAssets = currentSmartPoolAssets;

    vm.warp(4000);
    // EARLY WITHDRAW
    fixedLender.depositAtMaturity(TSUtils.INTERVAL, 10, 1, address(this));
    fixedLender.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    currentSmartPoolAssets = fixedLender.smartPoolAssetsAverage();
    assertGt(currentSmartPoolAssets, previousSmartPoolAssets);
    previousSmartPoolAssets = currentSmartPoolAssets;

    vm.warp(5000);
    // FLEXIBLE BORROW DOESN'T UPDATE
    fixedLender.borrow(1 ether, address(this), address(this));
    currentSmartPoolAssets = fixedLender.smartPoolAssetsAverage();
    assertEq(currentSmartPoolAssets, previousSmartPoolAssets);
    previousSmartPoolAssets = currentSmartPoolAssets;

    vm.warp(6000);
    // FLEXIBLE REPAY DOESN'T UPDATE
    fixedLender.repay(1 ether, address(this));
    currentSmartPoolAssets = fixedLender.smartPoolAssetsAverage();
    assertEq(currentSmartPoolAssets, previousSmartPoolAssets);
  }

  function testInsufficientProtocolLiquidity() external {
    mockOracle.setPrice(fixedLenderWETH, 1_000e18);

    fixedLenderWETH.deposit(50 ether, address(this));
    // SMART POOL ASSETS = 100
    fixedLender.deposit(100 ether, address(this));
    vm.warp(2);

    // FIXED BORROWS = 51
    fixedLender.borrowAtMaturity(TSUtils.INTERVAL, 51 ether, 60 ether, address(this), address(this));

    // WITHDRAWING 50 SHOULD REVERT (LIQUIDITY = 49)
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    fixedLender.withdraw(50 ether, address(this), address(this));

    // SMART POOL ASSETS = 151 & FIXED BORROWS = 51 (LIQUIDITY = 100)
    fixedLender.deposit(51 ether, address(this));

    // FLEXIBLE BORROWS = 51 ETHER
    fixedLender.borrow(51 ether, address(this), address(this));

    // WITHDRAWING 50 SHOULD REVERT (LIQUIDITY = 49)
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    fixedLender.withdraw(50 ether, address(this), address(this));

    // WITHDRAWING 49 SHOULD NOT REVERT
    fixedLender.withdraw(49 ether, address(this), address(this));
  }

  function testMultipleBorrowsForMultipleAssets() external {
    mockInterestRateModel.setBorrowRate(0);
    vm.warp(0);
    FixedLender[4] memory fixedLenders;
    for (uint256 i = 0; i < tokens.length; i++) {
      MockERC20 token = new MockERC20(tokens[i], tokens[i], 18);
      fixedLenders[i] = new FixedLender(
        token,
        3,
        1e18,
        auditor,
        InterestRateModel(address(mockInterestRateModel)),
        0.02e18 / uint256(1 days),
        1e17,
        0,
        FixedLender.DampSpeed(0.0046e18, 0.42e18)
      );

      auditor.enableMarket(fixedLenders[i], 0.8e18, 18);
      token.mint(BOB, 50_000 ether);
      token.mint(address(this), 50_000 ether);
      vm.prank(BOB);
      token.approve(address(fixedLenders[i]), type(uint256).max);
      token.approve(address(fixedLenders[i]), type(uint256).max);
      fixedLenders[i].deposit(30_000 ether, address(this));
    }

    // since 224 is the max amount of consecutive maturities where a user can borrow
    // 221 is the last valid cycle (the last maturity where it borrows is 224)
    for (uint256 m = 0; m < 221; m += 3) {
      vm.warp(TSUtils.INTERVAL * m);
      for (uint256 i = 0; i < fixedLenders.length; ++i) {
        for (uint256 j = m + 1; j <= m + 3; ++j) {
          fixedLenders[i].borrowAtMaturity(TSUtils.INTERVAL * j, 1 ether, 1.2 ether, address(this), address(this));
        }
      }
    }

    // repay does not increase in cost
    fixedLenders[0].repayAtMaturity(TSUtils.INTERVAL, 1 ether, 1000 ether, address(this));
    // withdraw DOES increase in cost
    fixedLenders[0].withdraw(1 ether, address(this), address(this));

    // normal operations of another user are not impacted
    vm.prank(BOB);
    fixedLenders[0].deposit(100 ether, address(BOB));
    vm.prank(BOB);
    fixedLenders[0].withdraw(1 ether, address(BOB), address(BOB));
    vm.prank(BOB);
    vm.warp(TSUtils.INTERVAL * 400);
    fixedLenders[0].borrowAtMaturity(TSUtils.INTERVAL * 401, 1 ether, 1.2 ether, address(BOB), address(BOB));

    // liquidate function to user's borrows DOES increase in cost
    vm.prank(BOB);
    fixedLenders[0].liquidate(address(this), 1_000 ether, fixedLenders[0]);
  }
}

contract FixedLenderHarness is FixedLender {
  constructor(
    ERC20 asset_,
    uint8 maxFuturePools_,
    uint128 accumulatedEarningsSmoothFactor_,
    Auditor auditor_,
    InterestRateModel interestRateModel_,
    uint256 penaltyRate_,
    uint256 smartPoolFeeRate_,
    uint128 smartPoolReserveFactor_,
    DampSpeed memory dampSpeed_
  )
    FixedLender(
      asset_,
      maxFuturePools_,
      accumulatedEarningsSmoothFactor_,
      auditor_,
      interestRateModel_,
      penaltyRate_,
      smartPoolFeeRate_,
      smartPoolReserveFactor_,
      dampSpeed_
    )
  {}

  function setSupply(uint256 supply) external {
    totalSupply = supply;
  }

  function setSmartPoolAssets(uint256 balance) external {
    smartPoolAssets = balance;
  }
}
