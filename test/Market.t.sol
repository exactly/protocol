// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17; // solhint-disable-line one-contract-per-file

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MockInterestRateModel } from "../contracts/mocks/MockInterestRateModel.sol";
import { MockBorrowRate } from "../contracts/mocks/MockBorrowRate.sol";
import {
  Auditor,
  IPriceFeed,
  InsufficientAccountLiquidity,
  SequencerDown,
  GracePeriodNotOver
} from "../contracts/Auditor.sol";
import { InterestRateModel, Parameters } from "../contracts/InterestRateModel.sol";
import { PriceFeedWrapper } from "../contracts/PriceFeedWrapper.sol";
import { PriceFeedDouble } from "../contracts/PriceFeedDouble.sol";
import { MockSequencerFeed } from "../contracts/mocks/MockSequencerFeed.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import { MockStETH } from "../contracts/mocks/MockStETH.sol";
import { FixedLib } from "../contracts/utils/FixedLib.sol";
import {
  ERC20,
  Market,
  FixedLib,
  ZeroRepay,
  NotAuditor,
  ZeroBorrow,
  ZeroDeposit,
  ZeroWithdraw,
  Disagreement,
  MarketFrozen,
  NotPausingRole,
  Parameters as MarketParams,
  InsufficientProtocolLiquidity
} from "../contracts/Market.sol";

contract MarketTest is Test {
  using FixedPointMathLib for int256;
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;

  address internal constant BOB = address(0x69);
  address internal constant ALICE = address(0x420);

  Market internal market;
  Market internal marketWETH;
  Auditor internal auditor;
  MockERC20 internal weth;
  MockPriceFeed internal daiPriceFeed;
  MockInterestRateModel internal irm;

  function setUp() external {
    vm.warp(0);

    MockERC20 asset = new MockERC20("DAI", "DAI", 18);
    weth = new MockERC20("WETH", "WETH", 18);

    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18, 0)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18), new MockSequencerFeed());
    vm.label(address(auditor), "Auditor");

    irm = new MockInterestRateModel(0.1e18);

    market = Market(address(new ERC1967Proxy(address(new Market(asset, auditor)), "")));
    market.initialize(
      MarketParams({
        maxFuturePools: 3,
        earningsAccumulatorSmoothFactor: 1e18,
        interestRateModel: InterestRateModel(address(irm)),
        penaltyRate: 0.02e18 / uint256(1 days),
        backupFeeRate: 1e17,
        reserveFactor: 0,
        floatingAssetsDampSpeedUp: 0.0046e18,
        floatingAssetsDampSpeedDown: 0.42e18,
        uDampSpeedUp: 0.23e18,
        uDampSpeedDown: 0.000053e18,
        fixedBorrowThreshold: 1e18,
        curveFactor: 0.1e18,
        minThresholdFactor: 1e18
      })
    );
    vm.label(address(market), "MarketDAI");
    daiPriceFeed = new MockPriceFeed(18, 1e18);

    marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      MarketParams({
        maxFuturePools: 12,
        earningsAccumulatorSmoothFactor: 1e18,
        interestRateModel: InterestRateModel(address(irm)),
        penaltyRate: 0.02e18 / uint256(1 days),
        backupFeeRate: 1e17,
        reserveFactor: 0,
        floatingAssetsDampSpeedUp: 0.0046e18,
        floatingAssetsDampSpeedDown: 0.42e18,
        uDampSpeedUp: 0.23e18,
        uDampSpeedDown: 0.000053e18,
        fixedBorrowThreshold: 1e18,
        curveFactor: 0.1e18,
        minThresholdFactor: 1e18
      })
    );
    vm.label(address(marketWETH), "MarketWETH");

    auditor.enableMarket(market, daiPriceFeed, 0.8e18);
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.9e18);
    auditor.enterMarket(marketWETH);

    vm.label(BOB, "Bob");
    vm.label(ALICE, "Alice");
    asset.mint(BOB, 50_000 ether);
    asset.mint(ALICE, 50_000 ether);
    asset.mint(address(this), 1_000_000 ether);
    weth.mint(address(this), 1_000_000 ether);

    asset.approve(address(market), type(uint256).max);
    weth.approve(address(marketWETH), type(uint256).max);
    vm.prank(BOB);
    asset.approve(address(market), type(uint256).max);
    vm.prank(BOB);
    weth.approve(address(marketWETH), type(uint256).max);
    vm.prank(ALICE);
    asset.approve(address(market), type(uint256).max);
  }

  function testDepositToSmartPool() external {
    vm.expectEmit(true, true, true, true, address(market));
    emit Deposit(address(this), address(this), 1 ether, 1 ether);

    market.deposit(1 ether, address(this));
  }

  function testWithdrawFromSmartPool() external {
    market.deposit(1 ether, address(this));

    vm.expectEmit(true, true, true, true, address(market.asset()));
    emit Transfer(address(market), address(this), 1 ether);
    market.withdraw(1 ether, address(this), address(this));
  }

  function testDepositAtMaturity() external {
    vm.expectEmit(true, true, true, true, address(market));
    emit DepositAtMaturity(FixedLib.INTERVAL, address(this), address(this), 1 ether, 0);
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
  }

  function testWithdrawAtMaturity() external {
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));

    vm.expectEmit(true, true, true, true, address(market));
    emit WithdrawAtMaturity(
      FixedLib.INTERVAL,
      address(this),
      address(this),
      address(this),
      1 ether,
      992387166938553562
    );
    market.withdrawAtMaturity(FixedLib.INTERVAL, 1 ether, 0.9 ether, address(this), address(this));
  }

  function testBorrowAtMaturity() external {
    market.deposit(12 ether, address(this));

    vm.expectEmit(true, true, true, true, address(market));
    emit BorrowAtMaturity(FixedLib.INTERVAL, address(this), address(this), address(this), 1 ether, 7671232876712328);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));
  }

  function testSingleFloatingBorrow() external {
    market.deposit(12 ether, address(this));

    vm.expectEmit(true, true, true, true, address(market));
    emit Borrow(address(this), address(this), address(this), 1 ether, 1 ether);
    market.borrow(1 ether, address(this), address(this));
  }

  function testRepayAtMaturity() external {
    market.deposit(12 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));

    vm.expectEmit(true, true, true, true, address(market));
    emit RepayAtMaturity(FixedLib.INTERVAL, address(this), address(this), 1000767123287671232, 1007671232876712328);
    market.repayAtMaturity(FixedLib.INTERVAL, 1.5 ether, 1.5 ether, address(this));
  }

  function testSingleFloatingRepay() external {
    market.deposit(12 ether, address(this));
    market.borrow(1 ether, address(this), address(this));

    vm.expectEmit(true, true, true, true, address(market));
    emit Repay(address(this), address(this), 1 ether, 1 ether);
    market.refund(1 ether, address(this));
  }

  function testDepositDisagreement() external {
    vm.expectRevert(Disagreement.selector);
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1.1 ether, address(this));
  }

  function testBorrowDisagreement() external {
    market.deposit(12 ether, address(this));
    vm.expectRevert(Disagreement.selector);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this), address(this));
  }

  function testRepayDisagreement() external {
    market.deposit(12 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));
    vm.expectRevert(Disagreement.selector);
    market.repayAtMaturity(FixedLib.INTERVAL, 1 ether, 0.9 ether, address(this));
  }

  function testMultipleFixedBorrowsRepays() external {
    uint256 total = 0;
    market.deposit(100 ether, address(this));
    for (uint256 i = 1; i < 3 + 1; i++) {
      total += market.borrowAtMaturity(i * FixedLib.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));
    }

    assertEq(market.previewDebt(address(this)), total);

    for (uint256 i = 1; i < 3 + 1; i++) {
      market.repayAtMaturity(
        i * FixedLib.INTERVAL,
        uint256(1 ether).mulWadDown(1e18 + (0.1e18 * i * FixedLib.INTERVAL) / 365 days),
        1.01 ether,
        address(this)
      );
    }
  }

  function testMultipleDepositsToSmartPool() external {
    market.deposit(1 ether, address(this));
    market.deposit(1 ether, address(this));
    market.deposit(1 ether, address(this));
    market.deposit(1 ether, address(this));
    market.deposit(1 ether, address(this));
    market.deposit(1 ether, address(this));
    market.deposit(1 ether, address(this));
  }

  function testBorrowAtMaturityWithZeroAssets() external {
    vm.expectRevert(ZeroBorrow.selector);
    market.borrowAtMaturity(FixedLib.INTERVAL, 0, 0, address(this), address(this));
  }

  function testBorrowWithZeroAssets() external {
    vm.expectRevert(ZeroBorrow.selector);
    market.borrow(0, address(this), BOB);
  }

  function testDepositAtMaturityWithZeroAssets() external {
    vm.expectRevert(ZeroDeposit.selector);
    market.depositAtMaturity(FixedLib.INTERVAL, 0, 0, address(this));
  }

  function testSmartPoolEarningsDistribution() external {
    vm.prank(BOB);
    market.deposit(10_000 ether, BOB);

    irm = MockInterestRateModel(address(new MockBorrowRate(0.1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));

    vm.warp(FixedLib.INTERVAL);
    vm.prank(BOB);
    market.borrowAtMaturity(FixedLib.INTERVAL * 2, 1_000 ether, 1_100 ether, BOB, BOB);

    vm.warp(FixedLib.INTERVAL + FixedLib.INTERVAL / 2);
    market.deposit(10_000 ether, address(this));
    assertEq(market.balanceOf(BOB), 10_000 ether);
    assertEq(market.maxWithdraw(address(this)), 10_000 ether - 1);
    assertApproxEqRel(market.balanceOf(address(this)), 9950 ether, 2.6e13);

    vm.warp(FixedLib.INTERVAL + (FixedLib.INTERVAL / 3) * 2);
    market.deposit(1_000 ether, address(this));
    assertApproxEqRel(market.balanceOf(address(this)), 10944 ether, 5e13);
  }

  function testSmartPoolSharesDoNotAccountUnassignedEarningsFromMoreThanOneIntervalPastMaturities() external {
    uint256 maturity = FixedLib.INTERVAL * 2;
    market.deposit(10_000 ether, address(this));
    market.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    // move to the last second before an interval goes by after the maturity passed
    vm.warp(FixedLib.INTERVAL * 2 + FixedLib.INTERVAL - 1 seconds);
    assertLt(market.previewDeposit(10_000 ether), market.balanceOf(address(this)));

    // move to the instant where an interval went by after the maturity passed
    vm.warp(FixedLib.INTERVAL * 3);
    // the unassigned earnings of the maturity that the contract borrowed from are not accounted anymore
    assertEq(market.previewDeposit(10_000 ether), market.balanceOf(address(this)));
  }

  function testPreviewOperationsWithSmartPoolCorrectlyAccountingEarnings() external {
    uint256 assets = 10_000 ether;
    uint256 maturity = FixedLib.INTERVAL * 2;
    uint256 anotherMaturity = FixedLib.INTERVAL * 3;
    market.deposit(assets, address(this));

    vm.warp(FixedLib.INTERVAL);
    market.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    vm.prank(BOB);
    market.deposit(10_000 ether, BOB);
    vm.prank(BOB); // unassigned earnings
    market.borrowAtMaturity(anotherMaturity, 1_000 ether, 1_100 ether, BOB, BOB);

    vm.warp(maturity + 1 days); // and penalties -> delayed a day
    market.repayAtMaturity(maturity, 1_100 ether, 1_200 ether, address(this));

    assertEq(
      market.previewRedeem(market.balanceOf(address(this))),
      market.redeem(market.balanceOf(address(this)), address(this), address(this))
    );

    vm.warp(maturity + 2 days);
    market.deposit(assets, address(this));
    vm.warp(maturity + 2 weeks); // a more relevant portion of the accumulator is distributed after 2 weeks
    assertEq(market.previewWithdraw(assets), market.withdraw(assets, address(this), address(this)));

    vm.warp(maturity + 3 weeks);
    assertEq(market.previewDeposit(assets), market.deposit(assets, address(this)));
    vm.warp(maturity + 4 weeks);
    assertEq(market.previewMint(10_000 ether), market.mint(10_000 ether, address(this)));
  }

  function testFrontRunSmartPoolEarningsDistributionWithBigPenaltyRepayment() external {
    irm = MockInterestRateModel(address(new MockBorrowRate(0.1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));

    uint256 maturity = FixedLib.INTERVAL * 2;
    market.deposit(10_000 ether, address(this));

    vm.warp(FixedLib.INTERVAL);
    market.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    vm.warp(maturity);
    market.repayAtMaturity(maturity, 1, 1, address(this)); // send tx to accrue earnings

    vm.warp(maturity + 7 days * 2 - 1 seconds);
    vm.prank(BOB);
    market.deposit(10_100 ether, BOB); // bob deposits more assets to have same shares as previous account
    assertEq(market.balanceOf(BOB), 10_000 ether);
    uint256 assetsBobBefore = market.convertToAssets(market.balanceOf(address(this)));
    assertEq(assetsBobBefore, market.convertToAssets(market.balanceOf(address(this))));

    vm.warp(maturity + 7 days * 2); // 2 weeks delayed (2% daily = 28% in penalties), 1100 * 1.28 = 1408
    market.repayAtMaturity(maturity, 1_408 ether, 1_408 ether, address(this));
    // no penalties are accrued (accumulator accounts them)

    // 1 second passed since bob's deposit -> he now has 21219132878712 more if he withdraws
    assertEq(market.convertToAssets(market.balanceOf(BOB)), assetsBobBefore + 21219132878712);
    assertApproxEqRel(market.earningsAccumulator(), 308 ether, 1e7);

    vm.warp(maturity + 7 days * 5);
    // then the accumulator will distribute 20% of the accumulated earnings
    // 308e18 * 0.20 = 616e17
    vm.prank(ALICE);
    market.deposit(10_100 ether, ALICE); // alice deposits same assets amount as previous accounts
    assertApproxEqRel(market.earningsAccumulator(), 308 ether - 616e17, 1e14);
    // bob earns half the earnings distributed
    assertApproxEqRel(market.convertToAssets(market.balanceOf(BOB)), assetsBobBefore + 616e17 / 2, 1e14);
  }

  function testDistributeMultipleAccumulatedEarnings() external {
    irm = MockInterestRateModel(address(new MockBorrowRate(0.1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));

    vm.warp(0);
    uint256 maturity = FixedLib.INTERVAL * 2;
    market.deposit(10_000 ether, address(this));
    market.depositAtMaturity(maturity, 1_000 ether, 1_000 ether, address(this));

    vm.warp(maturity - 1 weeks);
    market.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    vm.warp(maturity + 2 weeks); // 2 weeks delayed (2% daily = 28% in penalties), 1100 * 1.28 = 1408
    market.repayAtMaturity(maturity, 1_408 ether, 1_408 ether, address(this));
    // no penalties are accrued (accumulator accounts all of them since borrow uses mp deposits)
    assertApproxEqRel(market.earningsAccumulator(), 408 ether, 1e7);

    vm.warp(maturity + 3 weeks);
    vm.prank(BOB);
    market.deposit(10_000 ether, BOB);

    uint256 balanceBobAfterFirstDistribution = market.convertToAssets(market.balanceOf(BOB));
    uint256 balanceContractAfterFirstDistribution = market.convertToAssets(market.balanceOf(address(this)));
    uint256 accumulatedEarningsAfterFirstDistribution = market.earningsAccumulator();

    // 196 ether are distributed from the accumulator
    assertApproxEqRel(balanceContractAfterFirstDistribution, 10_196 ether, 1e14);
    assertApproxEqAbs(balanceBobAfterFirstDistribution, 10_000 ether, 1);
    assertApproxEqRel(accumulatedEarningsAfterFirstDistribution, 408 ether - 196 ether, 1e16);
    assertEq(market.lastAccumulatorAccrual(), maturity + 3 weeks);

    vm.warp(maturity * 2 + 1 weeks);
    market.deposit(1_000 ether, address(this));

    uint256 balanceBobAfterSecondDistribution = market.convertToAssets(market.balanceOf(BOB));
    uint256 balanceContractAfterSecondDistribution = market.convertToAssets(market.balanceOf(address(this)));
    uint256 accumulatedEarningsAfterSecondDistribution = market.earningsAccumulator();

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
    assertEq(market.lastAccumulatorAccrual(), maturity * 2 + 1 weeks);
  }

  function testUpdateAccumulatedEarningsFactorToZero() external {
    vm.warp(0);
    uint256 maturity = FixedLib.INTERVAL * 2;
    market.deposit(10_000 ether, address(this));

    irm = MockInterestRateModel(address(new MockBorrowRate(0.1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));

    vm.warp(FixedLib.INTERVAL / 2);
    market.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    // accumulator accounts 10% of the fees, backupFeeRate -> 0.1
    market.depositAtMaturity(maturity, 1_000 ether, 1_000 ether, address(this));
    assertEq(market.earningsAccumulator(), 10 ether);

    vm.warp(FixedLib.INTERVAL);
    market.deposit(1_000 ether, address(this));
    // 25% was distributed
    assertEq(market.convertToAssets(market.balanceOf(address(this))), 11_002.5 ether);
    assertEq(market.earningsAccumulator(), 7.5 ether);

    // set the factor to 0 and all is distributed in the following tx
    market.setEarningsAccumulatorSmoothFactor(0);
    vm.warp(FixedLib.INTERVAL + 1 seconds);
    market.deposit(1 ether, address(this));
    assertEq(market.convertToAssets(market.balanceOf(address(this))), 11_011 ether);
    assertEq(market.earningsAccumulator(), 0);

    // accumulator has 0 earnings so nothing is distributed
    vm.warp(FixedLib.INTERVAL * 2);
    market.deposit(1 ether, address(this));
    assertEq(market.convertToAssets(market.balanceOf(address(this))), 11_012 ether);
    assertEq(market.earningsAccumulator(), 0);
  }

  function testAnotherUserRedeemWhenOwnerHasShortfall() external {
    market.deposit(10_000 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1_000 ether, 1_100 ether, address(this), address(this));

    uint256 assets = market.previewWithdraw(10_000 ether);
    market.approve(BOB, assets);
    market.deposit(1_000 ether, address(this));

    vm.expectRevert(InsufficientAccountLiquidity.selector);
    vm.prank(BOB);
    market.redeem(assets, address(this), address(this));
  }

  function testAnotherUserWithdrawWhenOwnerHasShortfall() external {
    market.deposit(10_000 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1_000 ether, 1_100 ether, address(this), address(this));

    market.approve(BOB, 10_000 ether);
    market.deposit(1_000 ether, address(this));

    vm.expectRevert(InsufficientAccountLiquidity.selector);
    vm.prank(BOB);
    market.withdraw(10_000 ether, address(this), address(this));
  }

  function testRoundingUpAllowanceWhenBorrowingAtMaturity() external {
    uint256 maturity = FixedLib.INTERVAL * 2;

    market.deposit(10_000 ether, address(this));
    market.borrowAtMaturity(maturity, 1 ether, 1.1 ether, address(this), address(this));
    vm.warp(FixedLib.INTERVAL);
    // accrue earnings with this tx so it breaks proportion of 1 to 1 assets and shares
    market.borrowAtMaturity(maturity, 1 ether, 1.1 ether, address(this), address(this));

    vm.expectRevert(stdError.arithmeticError);
    vm.warp(FixedLib.INTERVAL + 3 days);
    vm.prank(BOB);
    // try to borrow 1 unit on behalf of this contract as bob being msg.sender without allowance
    // if it correctly rounds up, it should fail
    market.borrowAtMaturity(maturity, 1, 2, BOB, address(this));
  }

  function testRoundingUpAllowanceWhenWithdrawingAtMaturity() external {
    uint256 maturity = FixedLib.INTERVAL * 2;

    market.deposit(10_000 ether, address(this));
    market.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));
    vm.warp(FixedLib.INTERVAL);
    // accrue earnings with this tx so it breaks proportion of 1 to 1 assets and shares
    market.borrowAtMaturity(maturity, 1 ether, 1.1 ether, address(this), address(this));

    vm.expectRevert(stdError.arithmeticError);
    vm.warp(maturity);
    vm.prank(BOB);
    // try to withdraw 1 unit on behalf of this contract as bob being msg.sender without allowance
    // if it correctly rounds up, it should fail
    market.withdrawAtMaturity(maturity, 1, 0, BOB, address(this));
  }

  function testRoundingDownAssetsWhenTransferingWithAnAccountWithoutShortfall() external {
    market.deposit(10_000 ether, address(this));
    auditor.enterMarket(market);
    market.deposit(33_333 ether, BOB);

    vm.prank(BOB);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 1.1 ether, BOB, BOB);
    vm.warp(FixedLib.INTERVAL / 2);
    market.deposit(3_000 ether, ALICE);

    // previewMint(shares) = previewRedeem(shares) + 1
    market.transfer(ALICE, ERC20(market).balanceOf(address(this)));
  }

  function testSumDebtPlusEffectsShouldntRoundUpWhenWithdrawing() external {
    market.deposit(10_000 ether, address(this));
    auditor.enterMarket(market);
    market.deposit(33_333 ether, BOB);

    vm.prank(BOB);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 1.1 ether, BOB, BOB);
    vm.warp(FixedLib.INTERVAL / 2);
    market.deposit(3_000 ether, ALICE);

    daiPriceFeed.setPrice(0.0002e18);
    // if sumDebtPlusEffects rounds up this will revert
    market.transfer(ALICE, ERC20(market).balanceOf(address(this)));
  }

  function testRoundingDownAssetsWhenTransferingFromAnAccountWithoutShortfall() external {
    market.deposit(10_000 ether, address(this));
    auditor.enterMarket(market);
    market.deposit(33_333 ether, BOB);

    vm.prank(BOB);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 1.1 ether, BOB, BOB);
    vm.warp(FixedLib.INTERVAL / 2);
    market.deposit(3_000 ether, ALICE);

    market.approve(BOB, type(uint256).max);
    vm.startPrank(BOB);
    // previewMint(shares) = previewRedeem(shares) + 1
    market.transferFrom(address(this), BOB, ERC20(market).balanceOf(address(this)));
    vm.stopPrank();
  }

  function testRoundingDownAssetsToValidateShortfallWhenTransferringFrom() external {
    MockERC20 asset = new MockERC20("DAI", "DAI", 18);

    // deploy a harness market to be able to set different supply and floatingAssets
    MarketHarness marketHarness = new MarketHarness(
      asset,
      auditor,
      MarketParams({
        maxFuturePools: 12,
        earningsAccumulatorSmoothFactor: 1e18,
        interestRateModel: InterestRateModel(address(irm)),
        penaltyRate: 0.02e18 / uint256(1 days),
        backupFeeRate: 1e17,
        reserveFactor: 0,
        floatingAssetsDampSpeedUp: 0.0046e18,
        floatingAssetsDampSpeedDown: 0.42e18,
        uDampSpeedUp: 0.23e18,
        uDampSpeedDown: 0.000053e18,
        fixedBorrowThreshold: 1e18,
        curveFactor: 0.1e18,
        minThresholdFactor: 1e18
      })
    );
    uint256 maturity = FixedLib.INTERVAL * 2;
    asset.mint(address(this), 50_000 ether);
    asset.approve(address(marketHarness), 50_000 ether);
    marketHarness.approve(BOB, 50_000 ether);
    auditor.enableMarket(marketHarness, daiPriceFeed, 0.8e18);

    marketHarness.setFloatingAssets(500 ether);
    marketHarness.setSupply(2000 ether);

    marketHarness.deposit(1000 ether, address(this));
    irm.setRate(0);
    marketHarness.borrowAtMaturity(maturity, 640 ether, 640 ether, address(this), address(this));

    // try to transfer 5 shares, if it correctly rounds up to 2 withdraw amount then it should fail
    // if it rounds down to 1, it will pass
    vm.prank(BOB);
    marketHarness.transferFrom(address(this), BOB, 5);
  }

  function testRoundingDownAssetsToValidateShortfallWhenTransferring() external {
    MockERC20 asset = new MockERC20("DAI", "DAI", 18);

    // deploy a harness market to be able to set different supply and floatingAssets
    MarketHarness marketHarness = new MarketHarness(
      asset,
      auditor,
      MarketParams({
        maxFuturePools: 12,
        earningsAccumulatorSmoothFactor: 1e18,
        interestRateModel: InterestRateModel(address(irm)),
        penaltyRate: 0.02e18 / uint256(1 days),
        backupFeeRate: 1e17,
        reserveFactor: 0,
        floatingAssetsDampSpeedUp: 0.0046e18,
        floatingAssetsDampSpeedDown: 0.42e18,
        uDampSpeedUp: 0.23e18,
        uDampSpeedDown: 0.000053e18,
        fixedBorrowThreshold: 1e18,
        curveFactor: 0.1e18,
        minThresholdFactor: 1e18
      })
    );
    uint256 maturity = FixedLib.INTERVAL * 2;
    asset.mint(address(this), 50_000 ether);
    asset.approve(address(marketHarness), 50_000 ether);
    auditor.enableMarket(marketHarness, daiPriceFeed, 0.8e18);

    marketHarness.setFloatingAssets(500 ether);
    marketHarness.setSupply(2000 ether);

    marketHarness.deposit(1000 ether, address(this));
    irm.setRate(0);
    marketHarness.borrowAtMaturity(maturity, 640 ether, 640 ether, address(this), address(this));

    // try to transfer 5 shares, if it correctly rounds up to 2 withdraw amount then it should fail
    // if it rounds down to 1, it will pass
    marketHarness.transfer(BOB, 5);
  }

  function testAccountLiquidityAdjustedDebt() external {
    // deposit 1000 as collateral
    market.deposit(1_000 ether, address(this));

    irm.setRate(0);
    // borrow 100 as debt
    market.borrowAtMaturity(FixedLib.INTERVAL, 100 ether, 100 ether, address(this), address(this));

    (uint256 collateral, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    (uint256 adjustFactor, , , , ) = auditor.markets(market);

    assertEq(collateral, uint256(1_000 ether).mulDivDown(1e18, 10 ** 18).mulWadDown(adjustFactor));
    assertEq(collateral, 800 ether);
    assertEq(debt, uint256(100 ether).mulDivUp(1e18, 10 ** 18).divWadUp(adjustFactor));
    assertEq(debt, 125 ether);
  }

  function testCrossMaturityLiquidation() external {
    irm.setRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);
    market.setMaxFuturePools(12);
    market.setPenaltyRate(2e11);

    daiPriceFeed.setPrice(0.0002e18);
    for (uint256 i = 1; i <= 4; i++) {
      market.borrowAtMaturity(FixedLib.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }

    daiPriceFeed.setPrice(0.1e18);
    vm.warp(2 * FixedLib.INTERVAL + 1);

    vm.prank(BOB);
    vm.expectEmit(true, true, true, true, address(market));
    emit Liquidate(BOB, address(this), 10454545454545454550, 104545454545454545, marketWETH, 1.15 ether);
    market.liquidate(address(this), type(uint256).max, marketWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      Market(address(0)),
      0
    );
    assertEq(remainingCollateral, 0);
    // accumulator can't afford covering bad debt
    assertEq((remainingDebt * 1e18) / 0.1e18, 5591732318181818181820);
    assertEq(marketWETH.balanceOf(address(this)), 0);
    assertEq(weth.balanceOf(BOB), 1.15 ether);
  }

  function testMultipleLiquidationSameUser() external {
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(40_000 ether, ALICE);
    market.setPenaltyRate(2e11);
    daiPriceFeed.setPrice(0.0002e18);
    auditor.setLiquidationIncentive(Auditor.LiquidationIncentive(0.1e18, 0));

    // distribute earnings to accumulator
    market.setBackupFeeRate(1e18);
    irm = MockInterestRateModel(address(new MockBorrowRate(1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));
    vm.prank(ALICE);
    market.borrowAtMaturity(FixedLib.INTERVAL, 10_000 ether, 20_000 ether, ALICE, ALICE);
    market.depositAtMaturity(FixedLib.INTERVAL, 10_000 ether, 10_000 ether, ALICE);

    irm.setRate(0);
    market.borrowAtMaturity(FixedLib.INTERVAL, 4_000 ether, 4_000 ether, address(this), address(this));
    daiPriceFeed.setPrice(0.001e18);

    vm.warp(FixedLib.INTERVAL * 2 + 1);
    vm.prank(BOB);
    market.liquidate(address(this), 500 ether, marketWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      Market(address(0)),
      0
    );
    assertEq((remainingCollateral * 1e18) / 0.001e18, 540 ether);
    assertEq((remainingDebt * 1e18) / 0.001e18, 6794.201 ether);
    assertEq(marketWETH.balanceOf(address(this)), 0.6 ether);
    assertEq(weth.balanceOf(BOB), 0.55 ether);

    vm.prank(BOB);
    market.liquidate(address(this), 100 ether, marketWETH);
    (remainingCollateral, remainingDebt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq((remainingCollateral * 1e18) / 0.001e18, 441 ether);
    assertEq((remainingDebt * 1e18) / 0.001e18, 6669.201 ether);
    assertEq(marketWETH.balanceOf(address(this)), 0.49 ether);
    assertEq(weth.balanceOf(BOB), 0.66 ether);

    vm.prank(BOB);
    market.liquidate(address(this), 500 ether, marketWETH);
    (remainingCollateral, remainingDebt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
    assertEq(marketWETH.balanceOf(address(this)), 0);
    assertEq(weth.balanceOf(BOB), 1.15 ether);
  }

  function testLiquidateWithZeroAsMaxAssets() external {
    irm.setRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(5_000 ether, ALICE);
    market.setPenaltyRate(2e11);
    daiPriceFeed.setPrice(0.0002e18);

    market.borrowAtMaturity(FixedLib.INTERVAL, 4_000 ether, 4_000 ether, address(this), address(this));
    daiPriceFeed.setPrice(0.01e18);

    vm.expectRevert(ZeroRepay.selector);
    vm.prank(BOB);
    market.liquidate(address(this), 0, market);
  }

  function testLiquidateAndSeizeFromEmptyCollateral() external {
    irm.setRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(5_000 ether, ALICE);
    market.setPenaltyRate(2e11);
    daiPriceFeed.setPrice(0.0002e18);

    market.borrowAtMaturity(FixedLib.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));
    daiPriceFeed.setPrice(0.01e18);

    vm.expectRevert(ZeroRepay.selector);
    vm.prank(BOB);
    market.liquidate(address(this), 3000 ether, market);
  }

  function testNotEnteredMarketShouldNotBeSeized() external {
    // set up new market that account will not enter
    MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
    Market marketUSDC = Market(address(new ERC1967Proxy(address(new Market(usdc, auditor)), "")));
    marketUSDC.initialize(
      MarketParams({
        maxFuturePools: 3,
        earningsAccumulatorSmoothFactor: 1e18,
        interestRateModel: InterestRateModel(address(irm)),
        penaltyRate: 0.02e18 / uint256(1 days),
        backupFeeRate: 1e17,
        reserveFactor: 0,
        floatingAssetsDampSpeedUp: 0.0046e18,
        floatingAssetsDampSpeedDown: 0.42e18,
        uDampSpeedUp: 0.23e18,
        uDampSpeedDown: 0.000053e18,
        fixedBorrowThreshold: 1e18,
        curveFactor: 0.1e18,
        minThresholdFactor: 1e18
      })
    );
    vm.label(address(marketUSDC), "MarketUSDC");
    MockPriceFeed usdcPriceFeed = new MockPriceFeed(18, 1e18);
    auditor.enableMarket(marketUSDC, usdcPriceFeed, 0.8e18);
    usdc.mint(address(this), 1_000_000e6);
    usdc.approve(address(marketUSDC), type(uint256).max);
    marketUSDC.deposit(10_000e6, address(this));
    // deposit 1 ether to use as collateral
    marketWETH.deposit(1 ether, address(this));
    auditor.enterMarket(marketWETH);

    // BOB adds liquidity to dai market
    vm.prank(BOB);
    market.deposit(10_000 ether, BOB);

    daiPriceFeed.setPrice(0.0001e18);
    market.borrow(5_000 ether, address(this), address(this));
    // pump borrowed asset
    daiPriceFeed.setPrice(0.0002e18);

    vm.expectRevert(ZeroRepay.selector);
    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketUSDC);

    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);
  }

  function testLiquidateLeavingDustAsCollateral() external {
    vm.prank(ALICE);
    marketWETH.approve(address(this), type(uint256).max);

    market.deposit(1.15 ether, address(this));
    auditor.enterMarket(market);
    marketWETH.deposit(50_000 ether, ALICE);
    marketWETH.setPenaltyRate(2e11);
    daiPriceFeed.setPrice(5_000e18);
    auditor.setLiquidationIncentive(Auditor.LiquidationIncentive(0.1e18, 0));

    // distribute earnings to accumulator
    marketWETH.setBackupFeeRate(1e18);
    irm = MockInterestRateModel(address(new MockBorrowRate(1e18)));
    marketWETH.setInterestRateModel(InterestRateModel(address(irm)));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 15_000 ether, 30_000 ether, ALICE, ALICE);
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 15_000 ether, 15_000 ether, ALICE);

    irm.setRate(0);
    for (uint256 i = 1; i <= 3; i++) {
      marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));
    }
    daiPriceFeed.setPrice(99e18);

    vm.warp(FixedLib.INTERVAL * 3 + 182 days + 123 minutes + 10 seconds);

    weth.mint(BOB, 1_000_000 ether);
    vm.prank(BOB);
    marketWETH.liquidate(address(this), 103499999999999999800, market);
    assertEq(market.maxWithdraw(address(this)), 1);

    daiPriceFeed.setPrice(5e18);
    vm.expectRevert(ZeroWithdraw.selector);
    vm.prank(BOB);
    marketWETH.liquidate(address(this), type(uint256).max, market);

    daiPriceFeed.setPrice(0.1e18);
    vm.expectRevert(bytes(""));
    vm.prank(BOB);
    marketWETH.liquidate(address(this), type(uint256).max, market);

    auditor.handleBadDebt(address(this));
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      Market(address(0)),
      0
    );

    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
  }

  function testEarlyRepayLiquidationUnassignedEarnings() public {
    uint256 maturity = FixedLib.INTERVAL;
    uint256 assets = 10_000 ether;
    ERC20 asset = market.asset();
    deal(address(asset), ALICE, assets);

    vm.startPrank(ALICE);

    // ALICE deposits
    market.deposit(assets, ALICE);

    // ALICE borrows at maturity, using backup from the deposit
    market.borrowAtMaturity(maturity, assets / 10, type(uint256).max, ALICE, ALICE);

    // ALICE borrows the maximum possible using floating rate
    (uint256 collateral, uint256 debt) = auditor.accountLiquidity(address(ALICE), Market(address(0)), 0);
    uint256 borrow = ((collateral - debt) * 8) / 10; // max borrow capacity
    market.borrow(borrow, ALICE, ALICE);

    vm.stopPrank();

    skip(1 days);

    // LIQUIDATOR liquidates ALICE, wiping ALICE'S maturity borrow
    // and ignores its unassigned rewards
    address liquidator = makeAddr("liquidator");
    vm.startPrank(liquidator);
    deal(address(asset), liquidator, assets);
    asset.approve(address(market), assets);
    market.liquidate(ALICE, type(uint256).max, market);
    vm.stopPrank();

    // ATTACKER deposits to borrow at maturity
    address attacker = makeAddr("attacker");
    deal(address(asset), attacker, 20);
    vm.startPrank(attacker);
    asset.approve(address(market), 20);
    market.deposit(10, attacker);

    // ATTACKER borrows at maturity, making floatingBackupBorrowed = 1 > supply = 0
    market.borrowAtMaturity(maturity, 1, type(uint256).max, attacker, attacker);

    // ATTACKER deposits just 1 at maturity, claiming all the unassigned earnings
    // by only providing 1 principal
    uint256 positionAssets = market.depositAtMaturity(maturity, 1, 0, attacker);
    assertEq(positionAssets, 2);
  }

  function testBorrowFromFreeLunchShouldNotRevertWithFloatingFullUtilization() external {
    marketWETH.deposit(1.15 ether, address(this));
    daiPriceFeed.setPrice(0.0002e18);
    auditor.enterMarket(marketWETH);

    market.deposit(10 ether, address(this));
    market.borrow(10 ether, address(this), address(this));

    market.setReserveFactor(0.1e18);

    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
    // borrow only using fixed pool money should not revert
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, type(uint256).max, address(this), address(this));
  }

  function testEarlyWithdrawFromFreeLunchShouldNotRevertWithFloatingFullUtilization() external {
    marketWETH.deposit(1.15 ether, address(this));
    daiPriceFeed.setPrice(0.0002e18);
    auditor.enterMarket(marketWETH);

    market.deposit(10 ether, address(this));
    market.borrow(10 ether, address(this), address(this));

    market.setReserveFactor(0.1e18);

    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
    // borrow only using fixed pool money should not revert
    market.withdrawAtMaturity(FixedLib.INTERVAL, 1 ether, 0, address(this), address(this));
  }

  function testFixedOperationsUpdateFloatingDebt() external {
    market.deposit(100 ether, address(this));

    vm.warp(1 days);
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
    assertEq(market.lastFloatingDebtUpdate(), 1 days);

    vm.warp(2 days);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));
    assertEq(market.lastFloatingDebtUpdate(), 2 days);

    vm.warp(3 days);
    market.repayAtMaturity(FixedLib.INTERVAL, 1.5 ether, 1.5 ether, address(this));
    assertEq(market.lastFloatingDebtUpdate(), 3 days);

    vm.warp(4 days);
    market.withdrawAtMaturity(FixedLib.INTERVAL, 1 ether, 0.9 ether, address(this), address(this));
    assertEq(market.lastFloatingDebtUpdate(), 4 days);
  }

  function testAccrueEarningsBeforeLiquidation() external {
    uint256 maturity = FixedLib.INTERVAL * 2;
    uint256 assets = 10_000 ether;

    // BOB adds liquidity for liquidation
    vm.prank(BOB);
    market.deposit(assets, BOB);

    // ALICE deposits and borrows
    ERC20 asset = market.asset();
    deal(address(asset), ALICE, assets);
    vm.startPrank(ALICE);
    market.deposit(assets, ALICE);
    market.borrowAtMaturity(maturity, (assets * 78 * 78) / 100 / 100, type(uint256).max, ALICE, ALICE);
    vm.stopPrank();

    // Maturity is over and some time has passed, accruing extra debt fees
    skip(maturity + (FixedLib.INTERVAL * 90) / 100);

    // ALICE has a health factor below 1 and should be liquidated and end up with 0 assets
    (uint256 collateral, uint256 debt) = market.accountSnapshot(address(ALICE));
    assertEq(collateral, 10046671780821917806594); // 10046e18
    assertEq(debt, 9290724716705852929432); // 9290e18

    // Liquidator liquidates
    address liquidator = makeAddr("liquidator");
    deal(address(asset), liquidator, assets);
    vm.startPrank(liquidator);
    asset.approve(address(market), type(uint256).max);
    market.liquidate(ALICE, type(uint256).max, market);
    vm.stopPrank();

    (collateral, debt) = market.accountSnapshot(address(ALICE));

    assertEq(collateral, 0);
    assertEq(debt, 0);
  }

  function testLiquidateUpdateFloatingDebt() external {
    irm.setRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    daiPriceFeed.setPrice(0.0002e18);
    market.deposit(50_000 ether, ALICE);

    for (uint256 i = 1; i <= 2; i++) {
      market.borrowAtMaturity(FixedLib.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }

    market.borrow(2_000 ether, address(this), address(this));
    daiPriceFeed.setPrice(0.00025e18);

    vm.warp(1 days);
    vm.prank(BOB);
    market.liquidate(address(this), 1000 ether, marketWETH);
    assertEq(market.lastFloatingDebtUpdate(), 1 days);
  }

  function testBorrowAtMaturityUpdatesFloatingDebtAndFloatingAssets() external {
    marketWETH.deposit(1.15 ether, address(this));
    daiPriceFeed.setPrice(0.0002e18);
    auditor.enterMarket(marketWETH);

    market.setReserveFactor(0.09e18);
    market.deposit(10 ether, address(this));
    market.borrow(9 ether, address(this), address(this));
    vm.warp(3 days);
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.borrowAtMaturity(FixedLib.INTERVAL, 0.0999 ether, 1_000 ether, address(this), address(this));
  }

  function testShareValueNotDecreasingWhenMintingToTreasury() external {
    market.setTreasury(BOB, 0.1e18);
    market.deposit(10 ether, address(this));
    market.borrow(3 ether, address(this), address(this));
    vm.warp(100 days);
    uint256 shareValueBefore = market.previewMint(1e18);
    market.borrow(1, address(this), address(this));
    uint256 shareValueAfter = market.previewMint(1e18);
    assertGe(shareValueAfter, shareValueBefore);
  }

  function testShareValueNotDecreasingAfterDeposit() external {
    market.setTreasury(BOB, 0.1e18);
    market.deposit(10 ether, address(this));
    market.borrow(1 ether, address(this), address(this));
    vm.warp(10 days);
    uint256 shareValue = market.previewMint(1e18);
    market.deposit(1 ether, address(this));
    assertGe(market.previewMint(1e18), shareValue);
  }

  function testTotalAssetsProjectingFloatingDebtCorrectly() external {
    market.setTreasury(BOB, 0.1e18);
    market.deposit(10 ether, address(this));
    market.borrow(1 ether, address(this), address(this));
    vm.warp(1 days);
    uint256 totalAssets = market.totalAssets();
    uint256 newDebt = market.totalFloatingBorrowAssets() - market.floatingDebt();
    market.deposit(2, address(this));
    assertEq(market.totalAssets() - totalAssets, 2 + newDebt.mulWadUp(market.treasuryFeeRate()));
  }

  function testTotalAssetsProjectingBackupEarningsCorrectly() external {
    market.deposit(10 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    vm.warp(FixedLib.INTERVAL + 10 days);
    assertEq(market.totalAssets(), 10007671232876712328);
  }

  function testSetEarningsAccumulatorSmoothFactorShouldDistributeEarnings() external {
    market.deposit(100 ether, address(this));
    market.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, 15 ether, address(this), address(this));
    vm.warp(1 days);
    uint256 totalAssetsBefore = market.totalAssets();

    vm.expectEmit(true, true, true, false, address(market));
    emit MarketUpdate(block.timestamp, market.totalSupply(), 0, 0, 0, 0);
    market.setEarningsAccumulatorSmoothFactor(2e18);
    assertEq(totalAssetsBefore, market.totalAssets());
  }

  function testSetFloatingAssetsDampSpeedFactorShouldUpdateFloatingAssetsAverage() external {
    market.deposit(100 ether, address(this));
    vm.warp(30 seconds);
    market.deposit(5, address(this));
    vm.warp(100 seconds);
    uint256 floatingAssetsAverageBefore = market.floatingAssetsAverage();

    market.setDampSpeed(0.0083e18, 0.0083e18, 0.35e18, 0.35e18);
    assertGt(market.floatingAssetsAverage(), floatingAssetsAverageBefore);
  }

  function testSetFloatingAssetsDampSpeedFactorShouldUpdateGlobalUtilizationAverage() external {
    market.deposit(100 ether, address(this));
    market.borrow(10 ether, address(this), address(this));
    uint256 globalUtilizationAverageBefore = market.globalUtilizationAverage();

    vm.warp(1_000 seconds);
    market.setDampSpeed(0.0083e18, 0.0083e18, 0.35e18, 0.35e18);
    assertGt(market.globalUtilizationAverage(), globalUtilizationAverageBefore);
  }

  function testGlobalUtilizationAverageWithSignificantAmountOperations() external {
    MockERC20 asset = new MockERC20("USDC", "USDC", 18);
    Market newMarket = Market(address(new ERC1967Proxy(address(new Market(asset, auditor)), "")));
    newMarket.initialize(
      MarketParams({
        maxFuturePools: 7,
        earningsAccumulatorSmoothFactor: 2e18,
        interestRateModel: new InterestRateModel(
          Parameters({
            minRate: 0.05e18,
            naturalRate: 0.11e18,
            maxUtilization: 1.3e18,
            naturalUtilization: 0.88e18,
            growthSpeed: 1.3e18,
            sigmoidSpeed: 2.5e18,
            spreadFactor: 0.3e18,
            maturitySpeed: 0.5e18,
            timePreference: 0.2e18,
            fixedAllocation: 0.6e18,
            maxRate: 18.25e18
          }),
          newMarket
        ),
        penaltyRate: 0.02e18 / uint256(1 days),
        backupFeeRate: 1e17,
        reserveFactor: 0.05e18,
        floatingAssetsDampSpeedUp: 0.000053e18,
        floatingAssetsDampSpeedDown: 0.23e18,
        uDampSpeedUp: 0.23e18,
        uDampSpeedDown: 0.000053e18,
        fixedBorrowThreshold: 1e18,
        curveFactor: 0.1e18,
        minThresholdFactor: 1e18
      })
    );
    auditor.enableMarket(newMarket, IPriceFeed(auditor.BASE_FEED()), 0.91e18);
    asset.mint(address(this), 10_000_000 ether);
    asset.approve(address(newMarket), type(uint256).max);
    market.deposit(500_000 ether, address(this));
    auditor.enterMarket(market);

    newMarket.deposit(1_350_000 ether, address(this));
    vm.warp(block.timestamp + 3 days);
    newMarket.borrow(1_160_000 ether, address(this), address(this));

    vm.warp(block.timestamp + 25);

    uint256 floatingAssets = newMarket.floatingAssets();
    uint256 floatingDebt = newMarket.floatingDebt();
    uint256 uGlobal = (floatingDebt + newMarket.floatingBackupBorrowed()).divWadUp(floatingAssets);
    uint256 globalUtilizationAverage = newMarket.previewGlobalUtilizationAverage();
    assertEq(globalUtilizationAverage, uGlobal);

    newMarket.deposit(600_000 ether, address(this));

    floatingAssets = newMarket.floatingAssets();
    floatingDebt = newMarket.floatingDebt();
    uGlobal = (floatingDebt + newMarket.floatingBackupBorrowed()).divWadUp(floatingAssets);
    globalUtilizationAverage = newMarket.previewGlobalUtilizationAverage();
    assertGt(globalUtilizationAverage, uGlobal.mulWadDown(1.3e18));

    for (uint256 i = 0; i < 3; ++i) {
      vm.warp(block.timestamp + 30 minutes);
      newMarket.borrowAtMaturity(FixedLib.INTERVAL, 50_000 ether, 150_000 ether, address(this), address(this));
      uGlobal = (newMarket.floatingDebt() + newMarket.floatingBackupBorrowed()).divWadUp(newMarket.floatingAssets());
      globalUtilizationAverage = newMarket.previewGlobalUtilizationAverage();
      assertGt(globalUtilizationAverage, uGlobal.mulWadDown(1.2e18));
    }

    vm.warp(block.timestamp + 30 minutes);
    newMarket.withdraw(600_000 ether, address(this), address(this));
    uGlobal = (newMarket.floatingDebt() + newMarket.floatingBackupBorrowed()).divWadUp(newMarket.floatingAssets());
    globalUtilizationAverage = newMarket.previewGlobalUtilizationAverage();
    assertGt(uGlobal, globalUtilizationAverage.mulWadDown(1.2e18));

    vm.warp(block.timestamp + 45 seconds);
    uGlobal = (newMarket.floatingDebt() + newMarket.floatingBackupBorrowed()).divWadUp(newMarket.floatingAssets());
    globalUtilizationAverage = newMarket.previewGlobalUtilizationAverage();
    assertApproxEqRel(globalUtilizationAverage, uGlobal, 0.0001e18);
  }

  function testGlobalUtilizationAverageWithLeverageOperations() external {
    MockERC20 asset = new MockERC20("USDC", "USDC", 18);
    Market newMarket = Market(address(new ERC1967Proxy(address(new Market(asset, auditor)), "")));
    newMarket.initialize(
      MarketParams({
        maxFuturePools: 7,
        earningsAccumulatorSmoothFactor: 2e18,
        interestRateModel: new InterestRateModel(
          Parameters({
            minRate: 0.05e18,
            naturalRate: 0.11e18,
            maxUtilization: 1.3e18,
            naturalUtilization: 0.88e18,
            growthSpeed: 1.3e18,
            sigmoidSpeed: 2.5e18,
            spreadFactor: 0.3e18,
            maturitySpeed: 0.5e18,
            timePreference: 0.2e18,
            fixedAllocation: 0.6e18,
            maxRate: 18.25e18
          }),
          newMarket
        ),
        penaltyRate: 0.02e18 / uint256(1 days),
        backupFeeRate: 1e17,
        reserveFactor: 0.05e18,
        floatingAssetsDampSpeedUp: 0.000053e18,
        floatingAssetsDampSpeedDown: 0.23e18,
        uDampSpeedUp: 0.23e18,
        uDampSpeedDown: 0.000053e18,
        fixedBorrowThreshold: 1e18,
        curveFactor: 0.1e18,
        minThresholdFactor: 1e18
      })
    );
    auditor.enableMarket(newMarket, IPriceFeed(auditor.BASE_FEED()), 0.91e18);
    asset.mint(address(this), 10_000_000 ether);
    asset.approve(address(newMarket), type(uint256).max);
    market.deposit(500_000 ether, address(this));
    auditor.enterMarket(market);

    newMarket.deposit(1_350_000 ether, address(this));
    vm.warp(block.timestamp + 3 days);
    newMarket.borrow(1_160_000 ether, address(this), address(this));

    vm.warp(block.timestamp + 25 seconds);

    uint256 floatingAssets = newMarket.floatingAssets();
    uint256 floatingDebt = newMarket.floatingDebt();
    uint256 uGlobal = (floatingDebt + newMarket.floatingBackupBorrowed()).divWadUp(floatingAssets);
    uint256 globalUtilizationAverage = newMarket.previewGlobalUtilizationAverage();
    assertEq(uGlobal, globalUtilizationAverage);

    newMarket.deposit(120_000 ether, address(this));

    floatingAssets = newMarket.floatingAssets();
    floatingDebt = newMarket.floatingDebt();
    uGlobal = (floatingDebt + newMarket.floatingBackupBorrowed()).divWadUp(floatingAssets);
    globalUtilizationAverage = newMarket.previewGlobalUtilizationAverage();
    assertGt(globalUtilizationAverage, uGlobal.mulWadDown(1.05e18));

    for (uint256 i = 0; i < 10; i++) {
      vm.warp(block.timestamp + 3);
      newMarket.borrow(45_000 ether, address(this), address(this));
      floatingAssets = newMarket.floatingAssets();
      floatingDebt = newMarket.floatingDebt();
      uGlobal = (floatingDebt + newMarket.floatingBackupBorrowed()).divWadUp(floatingAssets);
      globalUtilizationAverage = newMarket.previewGlobalUtilizationAverage();
      assertGt(globalUtilizationAverage, uGlobal);

      vm.warp(block.timestamp + 3);
      newMarket.deposit(45_000 ether, address(this));
      floatingAssets = newMarket.floatingAssets();
      floatingDebt = newMarket.floatingDebt();
      uGlobal = (floatingDebt + newMarket.floatingBackupBorrowed()).divWadUp(floatingAssets);
      globalUtilizationAverage = newMarket.previewGlobalUtilizationAverage();
      assertGt(globalUtilizationAverage, uGlobal);

      // fixed rate should not fluctuate and stay below ~9%
      assertLt(
        newMarket.interestRateModel().fixedRate(
          FixedLib.INTERVAL,
          newMarket.maxFuturePools(),
          0,
          floatingDebt.divWadUp(floatingAssets),
          floatingDebt.divWadUp(floatingAssets),
          newMarket.previewGlobalUtilizationAverage()
        ),
        0.086e18
      );
    }
  }

  function testSetInterestRateModelShouldUpdateFloatingDebt() external {
    market.setInterestRateModel(InterestRateModel(address(new MockInterestRateModel(0.1e18))));
    market.deposit(100 ether, address(this));
    market.borrow(30 ether, address(this), address(this));
    vm.warp(1 days);
    // uint256 floatingDebtBefore = market.floatingDebt();

    vm.expectEmit(true, true, true, false, address(market));
    emit MarketUpdate(block.timestamp, market.totalSupply(), 0, 0, 0, 0);
    market.setInterestRateModel(
      new InterestRateModel(
        Parameters({
          minRate: 3.5e16,
          naturalRate: 8e16,
          maxUtilization: 1.1e18,
          naturalUtilization: 0.75e18,
          growthSpeed: 1.1e18,
          sigmoidSpeed: 2.5e18,
          spreadFactor: 0.2e18,
          maturitySpeed: 0.5e18,
          timePreference: 0.01e18,
          fixedAllocation: 0.6e18,
          maxRate: 15_000e16
        }),
        Market(address(0))
      )
    );
    // assertGt(market.floatingDebt(), floatingDebtBefore);
    // // if floatingDebt is updated with these last new irm values, then floatingDebt would be lower than 30.003 ether
    // assertGt(market.floatingDebt(), 30.003 ether);
  }

  function testSetInterestRateModelWithAddressZeroShouldNotUpdateFloatingDebt() external {
    market.deposit(100 ether, address(this));
    market.borrow(30 ether, address(this), address(this));
    market.setInterestRateModel(InterestRateModel(address(0)));
    vm.warp(1 days);
    uint256 floatingDebtBefore = market.floatingDebt();

    vm.expectEmit(true, true, true, false, address(market));
    emit MarketUpdate(block.timestamp, market.totalSupply(), 0, 0, 0, 0);
    market.setInterestRateModel(
      new InterestRateModel(
        Parameters({
          minRate: 3.5e16,
          naturalRate: 8e16,
          maxUtilization: 1.1e18,
          naturalUtilization: 0.75e18,
          growthSpeed: 1.1e18,
          sigmoidSpeed: 2.5e18,
          spreadFactor: 0.2e18,
          maturitySpeed: 0.5e18,
          timePreference: 0.01e18,
          fixedAllocation: 0.6e18,
          maxRate: 15_000e16
        }),
        Market(address(0))
      )
    );
    assertEq(market.floatingDebt(), floatingDebtBefore);
  }

  function testClearBadDebtEmptiesUnassignedEarnings() external {
    uint256 maxVal = type(uint256).max;

    marketWETH.deposit(100000 ether, address(this));
    marketWETH.borrowAtMaturity(4 weeks, 10000e18, maxVal, address(this), address(this));
    marketWETH.repayAtMaturity(4 weeks, maxVal, maxVal, address(this));

    vm.startPrank(BOB);
    market.deposit(100 ether, BOB);
    auditor.enterMarket(market);
    marketWETH.borrowAtMaturity(4 weeks, 60e18, maxVal, BOB, BOB);
    vm.stopPrank();

    vm.startPrank(ALICE);
    weth.mint(ALICE, 1_000_000 ether);
    weth.approve(address(marketWETH), type(uint256).max);
    marketWETH.deposit(10, ALICE);
    marketWETH.borrowAtMaturity(4 weeks, 1, maxVal, ALICE, ALICE);
    vm.stopPrank();

    daiPriceFeed.setPrice(0.6e18);

    vm.startPrank(ALICE);
    marketWETH.liquidate(BOB, 100_000 ether, market);
    vm.stopPrank();

    (, , uint256 unassignedEarningsAfter, ) = marketWETH.fixedPools(4 weeks);
    assertEq(unassignedEarningsAfter, 0);

    address account = makeAddr("account");
    vm.startPrank(account);
    deal(address(weth), account, 10);
    weth.approve(address(marketWETH), 10);
    marketWETH.depositAtMaturity(4 weeks, 10, 0, account);
    vm.stopPrank();

    (, , unassignedEarningsAfter, ) = marketWETH.fixedPools(4 weeks);
    assertEq(unassignedEarningsAfter, 0);

    // account should not get unassigned earnings
    (uint256 principal, uint256 fee) = marketWETH.fixedDepositPositions(4 weeks, account);
    assertEq(principal, 10);
    assertEq(fee, 0);
  }

  function testClearBadDebtCalledByAccount() external {
    vm.expectRevert(NotAuditor.selector);
    market.clearBadDebt(address(this));
  }

  function testClearBadDebtWithEmptyAccumulatorShouldNotRevert() external {
    daiPriceFeed.setPrice(2e4);
    marketWETH.deposit(0.0000000001 ether, address(this));
    auditor.enterMarket(marketWETH);
    market.deposit(1_000 ether, BOB);
    market.borrow(500 ether, address(this), address(this));
    daiPriceFeed.setPrice(1);
    (uint256 adjustFactor, uint8 decimals, , , IPriceFeed priceFeed) = auditor.markets(market);
    uint256 floatingAssetsBefore = market.floatingAssets();
    assertEq(
      market.maxWithdraw(address(this)).mulDivDown(auditor.assetPrice(priceFeed), 10 ** decimals).mulWadDown(
        adjustFactor
      ),
      0
    );
    assertEq(market.earningsAccumulator(), 0);

    auditor.handleBadDebt(address(this));
    assertEq(market.earningsAccumulator(), 0);
    assertEq(market.floatingAssets(), floatingAssetsBefore);
    // user still has debt
    assertGt(market.previewDebt(address(this)), 0);
  }

  function testClearBadDebtPartiallyRepaysEachFixedBorrow() external {
    irm = MockInterestRateModel(address(new MockBorrowRate(1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));
    marketWETH.setInterestRateModel(InterestRateModel(address(irm)));
    daiPriceFeed.setPrice(50_000_000_000_000e18);
    market.deposit(0.0000000001 ether, address(this));
    auditor.enterMarket(market);

    marketWETH.deposit(1_000 ether, BOB);
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 5 ether, type(uint256).max, address(this), address(this));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL * 2, 200 ether, type(uint256).max, address(this), address(this));
    // with a 100% borrow rate the accumulator keeps 10% of the fees
    marketWETH.depositAtMaturity(FixedLib.INTERVAL * 2, 200 ether, 100 ether, address(this));
    assertEq(marketWETH.earningsAccumulator(), 20 ether);

    daiPriceFeed.setPrice(1);
    // clear the first fixed borrow debt with accumulator's earnings
    vm.expectEmit(true, true, true, true, address(marketWETH));
    emit RepayAtMaturity(FixedLib.INTERVAL, address(auditor), address(this), 10 ether, 10 ether);
    auditor.handleBadDebt(address(this));

    // only first fixed borrow is covered
    (uint256 principal, uint256 fee) = marketWETH.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    (, , uint256 unassignedEarningsAfter, ) = market.fixedPools(FixedLib.INTERVAL);
    assertEq(unassignedEarningsAfter, 0);
    assertEq(principal + fee, 0);
    (principal, fee) = marketWETH.fixedBorrowPositions(FixedLib.INTERVAL * 2, address(this));
    assertEq(principal + fee, 400 ether);
    assertEq(marketWETH.earningsAccumulator(), 15 ether);
  }

  function testClearBadDebtExactlyRepaysFixedBorrowWithAccumulatorAmount() external {
    irm = MockInterestRateModel(address(new MockBorrowRate(10e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));
    marketWETH.setInterestRateModel(InterestRateModel(address(irm)));

    daiPriceFeed.setPrice(50_000_000_000_000e18);
    market.deposit(0.0000000001 ether, address(this));
    auditor.enterMarket(market);

    marketWETH.deposit(1_000 ether, BOB);
    marketWETH.borrow(50 ether, address(this), address(this));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 5 ether, type(uint256).max, address(this), address(this));
    // with a 1000% borrow rate the accumulator keeps 100% of the fees
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 5 ether, 5 ether, address(this));
    marketWETH.repayAtMaturity(FixedLib.INTERVAL, 50 ether, 50 ether, address(this));
    assertEq(marketWETH.earningsAccumulator(), 5 ether);

    daiPriceFeed.setPrice(1);
    vm.expectEmit(true, true, true, true, address(marketWETH));
    emit RepayAtMaturity(FixedLib.INTERVAL, address(auditor), address(this), 5 ether, 5 ether);
    auditor.handleBadDebt(address(this));

    (uint256 principal, uint256 fee) = marketWETH.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    (, uint256 fixedBorrows, uint256 floatingBorrowShares) = marketWETH.accounts(address(this));
    assertEq(principal + fee, 0);
    assertEq(fixedBorrows, 0);
    assertEq(marketWETH.earningsAccumulator(), 0);
    // floating debt remains untouched
    assertEq(marketWETH.previewRefund(floatingBorrowShares), 50 ether);
  }

  function testClearBadDebtPartiallyRepaysFloatingDebt() external {
    irm = MockInterestRateModel(address(new MockBorrowRate(1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));
    marketWETH.setInterestRateModel(InterestRateModel(address(irm)));
    daiPriceFeed.setPrice(50_000_000_000_000e18);
    market.deposit(0.0000000001 ether, address(this));
    auditor.enterMarket(market);

    marketWETH.deposit(1_000 ether, BOB);
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 5 ether, type(uint256).max, address(this), address(this));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL * 2, 200 ether, type(uint256).max, address(this), address(this));
    marketWETH.borrow(50 ether, address(this), address(this));
    // with a 100% borrow rate the accumulator keeps 10% of the fees
    marketWETH.depositAtMaturity(FixedLib.INTERVAL * 2, 200 ether, 100 ether, address(this));
    assertEq(marketWETH.earningsAccumulator(), 20 ether);

    daiPriceFeed.setPrice(1);
    // clear the first fixed borrow debt and more than 1/5 of the floating debt with accumulator's earnings
    vm.expectEmit(true, true, true, true, address(marketWETH));
    emit Repay(address(auditor), address(this), 15 ether, 15 ether);
    auditor.handleBadDebt(address(this));

    // only first fixed borrow is covered
    (uint256 principal, uint256 fee) = marketWETH.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal + fee, 0);
    (principal, fee) = marketWETH.fixedBorrowPositions(FixedLib.INTERVAL * 2, address(this));
    (, , uint256 floatingBorrowShares) = marketWETH.accounts(address(this));
    (, , uint256 unassignedEarningsAfter, ) = market.fixedPools(FixedLib.INTERVAL);
    assertEq(unassignedEarningsAfter, 0);
    assertEq(principal + fee, 400 ether);
    assertEq(marketWETH.previewRefund(floatingBorrowShares), 35 ether);
    assertEq(marketWETH.earningsAccumulator(), 0);
  }

  function testClearBadDebtAvoidingFixedBorrowsIfAccumulatorLower() external {
    irm = MockInterestRateModel(address(new MockBorrowRate(1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));
    marketWETH.setInterestRateModel(InterestRateModel(address(irm)));

    daiPriceFeed.setPrice(50_000_000_000_000e18);
    market.deposit(0.0000000001 ether, address(this));
    auditor.enterMarket(market);

    marketWETH.deposit(1_000 ether, BOB);
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 11 ether, type(uint256).max, address(this), address(this));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL * 2, 100 ether, type(uint256).max, address(this), address(this));
    marketWETH.borrow(5 ether, address(this), address(this));
    marketWETH.depositAtMaturity(FixedLib.INTERVAL * 2, 200 ether, 100 ether, address(this));

    daiPriceFeed.setPrice(1);
    vm.expectEmit(true, true, true, true, address(marketWETH));
    emit Repay(address(auditor), address(this), 5 ether, 5 ether);
    auditor.handleBadDebt(address(this));

    // only first fixed borrow is covered
    (uint256 principal, uint256 fee) = marketWETH.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal + fee, 22 ether);
    (principal, fee) = marketWETH.fixedBorrowPositions(FixedLib.INTERVAL * 2, address(this));
    (, , uint256 floatingBorrowShares) = marketWETH.accounts(address(this));
    assertEq(principal + fee, 200 ether);
    assertEq(marketWETH.previewRefund(floatingBorrowShares), 0);
    assertEq(marketWETH.earningsAccumulator(), 5 ether);
  }

  function testClearBadDebtShouldAccrueAccumulatedEarningsBeforeSpreadingLosses() external {
    marketWETH.setMaxFuturePools(3);

    irm = MockInterestRateModel(address(new MockBorrowRate(1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));
    marketWETH.setInterestRateModel(InterestRateModel(address(irm)));
    daiPriceFeed.setPrice(50_000_000_000_000e18);
    market.deposit(0.0000000001 ether, address(this));
    auditor.enterMarket(market);

    marketWETH.deposit(1_000 ether, BOB);
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, type(uint256).max, address(this), address(this));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL * 2, 200 ether, type(uint256).max, address(this), address(this));
    // with a 100% borrow rate the accumulator keeps 10% of the fees
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 10 ether, 10 ether, address(this));
    marketWETH.depositAtMaturity(FixedLib.INTERVAL * 2, 200 ether, 100 ether, address(this));
    assertEq(marketWETH.earningsAccumulator(), 21 ether);

    vm.warp(4 weeks);
    uint256 totalAssetsBefore = marketWETH.totalAssets();
    daiPriceFeed.setPrice(1);
    vm.expectEmit(true, true, true, true, address(marketWETH));
    emit MarketUpdate(4 weeks, marketWETH.totalSupply(), marketWETH.floatingAssets() + 5.25 ether, 0, 0, 15.75 ether);
    auditor.handleBadDebt(address(this));
    assertEq(marketWETH.floatingAssets(), totalAssetsBefore);

    // no borrow is covered
    (uint256 principal, uint256 fee) = marketWETH.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal + fee, 20 ether);
    (principal, fee) = marketWETH.fixedBorrowPositions(FixedLib.INTERVAL * 2, address(this));
    assertEq(principal + fee, 400 ether);
    assertEq(marketWETH.earningsAccumulator(), 15.75 ether);
  }

  function testLiquidateAndSeizeExactAmountWithDustAsCollateral() external {
    vm.prank(ALICE);
    marketWETH.approve(address(this), type(uint256).max);

    market.deposit(1.15 ether + 5, address(this));
    marketWETH.deposit(100_000 ether, ALICE);
    marketWETH.setPenaltyRate(2e11);
    daiPriceFeed.setPrice(5_000e18);
    auditor.setLiquidationIncentive(Auditor.LiquidationIncentive(0.1e18, 0));
    auditor.enterMarket(market);

    // distribute earnings to accumulator
    marketWETH.setBackupFeeRate(1e18);
    irm = MockInterestRateModel(address(new MockBorrowRate(1e18)));
    marketWETH.setInterestRateModel(InterestRateModel(address(irm)));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 20_000 ether, 40_000 ether, ALICE, ALICE);
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 20_000 ether, 20_000 ether, ALICE);

    irm.setRate(0);
    for (uint256 i = 1; i <= 3; i++) {
      marketWETH.borrowAtMaturity(
        FixedLib.INTERVAL,
        1_000 ether + 100,
        1_000 ether + 100,
        address(this),
        address(this)
      );
    }
    daiPriceFeed.setPrice(100e18);

    vm.warp(FixedLib.INTERVAL * 3 + 182 days + 123 minutes + 10 seconds);

    weth.mint(BOB, 1_000_000 ether);
    vm.prank(BOB);
    marketWETH.liquidate(address(this), type(uint256).max, market);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      Market(address(0)),
      0
    );
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
  }

  function testLiquidateWithTwoUnitsAsMaxAssets() external {
    irm.setRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(5_000 ether, ALICE);
    market.setPenaltyRate(2e11);
    daiPriceFeed.setPrice(0.0002e18);

    market.borrowAtMaturity(FixedLib.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL * 2, 1_000 ether, 1_000 ether, address(this), address(this));
    daiPriceFeed.setPrice(0.01e18);

    vm.prank(BOB);
    market.liquidate(address(this), 2, marketWETH);

    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      Market(address(0)),
      0
    );
    assertGt(remainingCollateral, 0);
    assertGt(remainingDebt, 0);
  }

  function testLiquidateFlexibleBorrow() external {
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);

    // distribute earnings to accumulator
    market.setBackupFeeRate(1e18);
    irm.setRate(1e18);
    vm.prank(ALICE);
    market.borrowAtMaturity(FixedLib.INTERVAL, 15_000 ether, 30_000 ether, ALICE, ALICE);
    market.depositAtMaturity(FixedLib.INTERVAL, 15_000 ether, 15_000 ether, ALICE);

    market.setBackupFeeRate(1e17);
    daiPriceFeed.setPrice(0.0002e18);
    market.borrow(4_000 ether, address(this), address(this));
    daiPriceFeed.setPrice(0.00025e18);

    (, , uint256 floatingBorrowShares) = market.accounts(address(this));
    assertEq(floatingBorrowShares, 4_000 ether);

    // partial liquidation
    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);
    uint256 assetsRepaid = 3685589519650655024000;

    (, uint256 remainingDebt) = market.accountSnapshot(address(this));
    (uint256 remainingCollateral, ) = marketWETH.accountSnapshot(address(this));
    (, , floatingBorrowShares) = market.accounts(address(this));
    assertEq(weth.balanceOf(BOB), assetsRepaid.divWadDown(4_000 ether).mulWadUp(1.1e18));
    assertEq(remainingCollateral, 1.15 ether - assetsRepaid.divWadDown(4_000 ether).mulWadUp(1.1e18));
    assertEq(floatingBorrowShares, 4_000 ether - assetsRepaid);
    assertEq(floatingBorrowShares, remainingDebt);

    (uint256 ethCollateral, uint256 ethDebt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(ethCollateral, remainingCollateral.mulWadDown(0.9e18));
    assertEq(ethDebt, (remainingDebt.divWadUp(0.8e18) * 0.00025e18) / 1e18);

    daiPriceFeed.setPrice(0.001e18);
    // full liquidation
    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);

    (, remainingDebt) = market.accountSnapshot(address(this));
    (remainingCollateral, ) = marketWETH.accountSnapshot(address(this));
    (ethCollateral, ethDebt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    (, , floatingBorrowShares) = market.accounts(address(this));
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
    assertEq(ethCollateral, 0);
    assertEq(ethDebt, 0);
    assertEq(floatingBorrowShares, 0);
    assertEq(weth.balanceOf(BOB), 1.15 ether);
  }

  function testLiquidateFlexibleBorrowChargeLendersAssetsToLiquidator() external {
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);

    daiPriceFeed.setPrice(0.0002e18);
    market.borrow(4_000 ether, address(this), address(this));
    daiPriceFeed.setPrice(0.0003333333333e18);

    uint256 bobDAIBalanceBefore = ERC20(market.asset()).balanceOf(BOB);
    vm.prank(BOB);
    market.liquidate(address(this), 100 ether, marketWETH);
    uint256 assetsRepaid = uint256(100 ether).divWadDown(1.01e18);
    uint256 lendersIncentiveRepaid = assetsRepaid.mulWadDown(0.01e18);
    uint256 assetsSeized = assetsRepaid.mulDivUp(10 ** 18, 3_000 ether).mulWadUp(1.1e18);
    assertEq(ERC20(market.asset()).balanceOf(BOB), bobDAIBalanceBefore - assetsRepaid - lendersIncentiveRepaid);
    assertApproxEqRel(weth.balanceOf(BOB), assetsSeized, 1e10);
    assertEq(market.earningsAccumulator(), lendersIncentiveRepaid);
  }

  function testLiquidateFlexibleAndFixedBorrowPositionsInSingleCall() external {
    irm.setRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    daiPriceFeed.setPrice(0.0002e18);
    market.deposit(50_000 ether, ALICE);

    for (uint256 i = 1; i <= 2; i++) {
      market.borrowAtMaturity(FixedLib.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }

    market.borrow(2_000 ether, address(this), address(this));
    daiPriceFeed.setPrice(0.00025e18);

    vm.prank(BOB);
    market.liquidate(address(this), 1000 ether, marketWETH);
    uint256 assetsRepaid = uint256(1000 ether).divWadDown(1.01e18);
    // only repaid in the first maturity
    (uint256 principal, uint256 fee) = market.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal + fee, 1_000 ether - assetsRepaid);
    (principal, fee) = market.fixedBorrowPositions(FixedLib.INTERVAL * 2, address(this));
    (, , uint256 floatingBorrowShares) = market.accounts(address(this));
    assertEq(principal + fee, 1_000 ether);
    assertEq(floatingBorrowShares, 2_000 ether);

    vm.prank(BOB);
    market.liquidate(address(this), 1500 ether, marketWETH);
    assetsRepaid += uint256(1500 ether).divWadDown(1.01e18);
    (principal, fee) = market.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal + fee, 0);
    (principal, fee) = market.fixedBorrowPositions(FixedLib.INTERVAL * 2, address(this));
    (, , floatingBorrowShares) = market.accounts(address(this));
    assertEq(principal + fee, 0);
    assertEq(floatingBorrowShares, 2_000 ether - (assetsRepaid - 2_000 ether));

    vm.prank(BOB);
    market.liquidate(address(this), 1500 ether, marketWETH);
  }

  function testLiquidateAndChargeIncentiveForLenders() external {
    irm.setRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);
    market.setMaxFuturePools(12);

    daiPriceFeed.setPrice(0.0002e18);
    for (uint256 i = 1; i <= 4; i++) {
      market.borrowAtMaturity(FixedLib.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }
    daiPriceFeed.setPrice(0.000333333333333333e18);

    uint256 bobDAIBalanceBefore = ERC20(market.asset()).balanceOf(BOB);
    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);
    uint256 bobDAIBalanceAfter = ERC20(market.asset()).balanceOf(BOB);
    // if 110% is 1.15 ether then 100% is 1.0454545455 ether * 3_000 (eth price) = 3136363636363636363637
    // bob will repay 1% of that amount
    uint256 totalBobRepayment = uint256(3136363636363636363637).mulWadDown(1.01e18);

    // BOB STILL SEIZES ALL ACCOUNT COLLATERAL
    assertEq(weth.balanceOf(BOB), 1.15 ether);
    assertApproxEqRel(bobDAIBalanceBefore - bobDAIBalanceAfter, totalBobRepayment, 1e8);
  }

  function testLiquidateFlexibleBorrowConsideringDebtOverTime() external {
    vm.warp(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);

    daiPriceFeed.setPrice(0.0002e18);
    market.borrow(4_000 ether, address(this), address(this));

    // 10% yearly interest
    vm.warp(365 days);
    assertEq(market.previewDebt(address(this)), 4_000 ether + 400 ether);

    // bob is allowed to repay 2970
    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);
    uint256 lendersIncentive = 29694323144104803450;

    assertApproxEqRel(market.previewDebt(address(this)), 1_430 ether, 1e18);
    assertApproxEqRel(market.floatingDebt(), 1_430 ether, 1e18);
    assertEq(market.earningsAccumulator(), lendersIncentive);
    assertEq(market.lastFloatingDebtUpdate(), 365 days);
  }

  function testLiquidateAndDistributeLosses() external {
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);
    market.setMaxFuturePools(12);

    // distribute earnings to accumulator
    market.setBackupFeeRate(1e18);

    irm = MockInterestRateModel(address(new MockBorrowRate(1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));

    vm.prank(ALICE);
    market.borrowAtMaturity(FixedLib.INTERVAL, 10_000 ether, 20_000 ether, ALICE, ALICE);
    market.depositAtMaturity(FixedLib.INTERVAL, 10_000 ether, 10_000 ether, ALICE);

    irm.setRate(0);
    daiPriceFeed.setPrice(0.0002e18);
    for (uint256 i = 1; i <= 4; i++) {
      market.borrowAtMaturity(FixedLib.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }
    daiPriceFeed.setPrice(0.0003333333333333e18);

    uint256 bobDAIBalanceBefore = ERC20(market.asset()).balanceOf(BOB);
    uint256 accumulatorBefore = market.earningsAccumulator();
    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);
    uint256 bobDAIBalanceAfter = ERC20(market.asset()).balanceOf(BOB);
    uint256 accumulatorAfter = market.earningsAccumulator();
    uint256 totalethDebt = 1_000 ether * 4;
    // if 110% is 1.15 ether then 100% is 1.0454545455 ether * 3_000 (eth price) = 3136363636363636363637
    uint256 totalBobRepayment = 3136363636363636363637;
    uint256 lendersIncentive = uint256(3136363636363636363637).mulWadDown(0.01e18);
    (, uint256 fixedBorrows, ) = market.accounts(address(this));

    // BOB SEIZES ALL ACCOUNT COLLATERAL
    assertEq(weth.balanceOf(BOB), 1.15 ether);
    assertApproxEqRel(bobDAIBalanceBefore - bobDAIBalanceAfter, totalBobRepayment + lendersIncentive, 1e10);
    assertApproxEqRel(accumulatorBefore - accumulatorAfter + lendersIncentive, totalethDebt - totalBobRepayment, 1e10);
    assertEq(fixedBorrows, 0);
    for (uint256 i = 1; i <= 4; i++) {
      (uint256 principal, uint256 fee) = market.fixedBorrowPositions(FixedLib.INTERVAL * i, address(this));
      assertEq(principal + fee, 0);
    }
  }

  function testLiquidateTransferRepayAssetsBeforeSeize() external {
    auditor.setAdjustFactor(market, 0.9e18);

    vm.startPrank(ALICE);

    // ALICE deposits and borrows DAI
    uint256 assets = 10_000 ether;
    ERC20 asset = market.asset();
    deal(address(asset), ALICE, assets);
    market.deposit(assets, ALICE);
    market.borrow((assets * 9 * 9) / 10 / 10, ALICE, ALICE);

    vm.stopPrank();

    skip(10 days);

    // LIQUIDATION doesn't fail as transfer from is before withdrawing collateral
    address liquidator = makeAddr("liquidator");
    deal(address(asset), liquidator, 100_000 ether);
    vm.startPrank(liquidator);
    asset.approve(address(market), type(uint256).max);
    market.liquidate(ALICE, type(uint256).max, market);
    vm.stopPrank();
  }

  function testClearBadDebtBeforeMaturity() external {
    market.deposit(5 ether, address(this));
    market.deposit(5_000 ether, ALICE);
    marketWETH.deposit(100_000 ether, ALICE);

    uint256 maxVal = type(uint256).max;
    vm.prank(ALICE);
    market.borrowAtMaturity(4 weeks, 1_00 ether, maxVal, ALICE, ALICE);

    vm.warp(12 weeks);
    market.repayAtMaturity(4 weeks, maxVal, maxVal, ALICE);

    uint256 maturity16 = 16 weeks;
    market.borrowAtMaturity(maturity16, 1 ether, maxVal, address(this), address(this));

    daiPriceFeed.setPrice(5_000e18);
    uint256 borrowAmount = 5000 ether;
    marketWETH.borrowAtMaturity(maturity16, borrowAmount, borrowAmount * 2, address(this), address(this));

    daiPriceFeed.setPrice(1_000e18);
    weth.mint(ALICE, 1_000_000 ether);
    vm.prank(ALICE);
    weth.approve(address(marketWETH), maxVal);

    vm.prank(ALICE);
    marketWETH.liquidate(address(this), maxVal, market);

    (, , uint256 unassignedEarningsAfter, ) = market.fixedPools(maturity16);
    assertEq(unassignedEarningsAfter, 0);
  }

  function testLiquidateAndSubtractLossesFromAccumulator() external {
    vm.warp(1);
    marketWETH.deposit(1.3 ether, address(this));
    market.deposit(100_000 ether, ALICE);
    market.setMaxFuturePools(12);
    market.setPenaltyRate(2e11);

    // distribute earnings to accumulator
    market.setBackupFeeRate(1e18);

    irm = MockInterestRateModel(address(new MockBorrowRate(1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));
    vm.prank(ALICE);
    market.borrowAtMaturity(FixedLib.INTERVAL, 20_000 ether, 40_000 ether, ALICE, ALICE);
    market.depositAtMaturity(FixedLib.INTERVAL, 20_000 ether, 20_000 ether, ALICE);

    irm.setRate(0.1e18);
    market.setBackupFeeRate(0);
    daiPriceFeed.setPrice(0.0002e18);
    for (uint256 i = 3; i <= 6; i++) {
      market.borrowAtMaturity(FixedLib.INTERVAL * i, 1_000 ether, 1_100 ether, address(this), address(this));
    }
    vm.prank(ALICE);
    market.borrowAtMaturity(FixedLib.INTERVAL, 5_000 ether, 5_500 ether, ALICE, ALICE);
    daiPriceFeed.setPrice(0.01e18);

    vm.warp(FixedLib.INTERVAL * 2);

    (uint256 principal, uint256 fee) = market.fixedBorrowPositions(FixedLib.INTERVAL, ALICE);
    (, uint256 debt) = market.accountSnapshot(ALICE);
    vm.prank(ALICE);
    market.repayAtMaturity(FixedLib.INTERVAL, principal + fee, debt, ALICE);
    uint256 earningsAccumulatorBefore = market.earningsAccumulator();
    uint256 lendersIncentive = 1181818181818181800;
    uint256 distributedEarnings = 680440721299864513;
    uint256 badDebt = 981818181818181818100 + 1100000000000000000000 + 1100000000000000000000 + 1100000000000000000000;
    uint256 untrackedUnassignedEarnings = 300000000000000000000 + 29752070215138961802;
    uint256 earlyRepayEarnings = 3069658128703695345;
    uint256 accumulatedEarnings = (earningsAccumulatorBefore + lendersIncentive).mulDivDown(
      block.timestamp - market.lastAccumulatorAccrual(),
      block.timestamp -
        market.lastAccumulatorAccrual() +
        market.earningsAccumulatorSmoothFactor().mulWadDown(market.maxFuturePools() * FixedLib.INTERVAL)
    );

    vm.prank(BOB);
    vm.expectEmit(true, true, true, true, address(market));
    emit SpreadBadDebt(address(this), badDebt);
    market.liquidate(address(this), type(uint256).max, marketWETH);

    assertGt(market.earningsAccumulator(), 0);
    assertApproxEqRel(
      badDebt,
      earningsAccumulatorBefore -
        market.earningsAccumulator() -
        accumulatedEarnings +
        earlyRepayEarnings +
        lendersIncentive +
        untrackedUnassignedEarnings +
        distributedEarnings,
      1e2
    );
    (, uint256 fixedBorrows, ) = market.accounts(address(this));
    assertEq(fixedBorrows, 0);
  }

  function testInitConsolidated() external {
    market.deposit(300_000 ether, address(this));
    market.depositAtMaturity(FixedLib.INTERVAL, 10_000 ether, 10_000 ether, address(this));
    market.depositAtMaturity(FixedLib.INTERVAL * 2, 15_000 ether, 15_000 ether, address(this));
    market.depositAtMaturity(FixedLib.INTERVAL * 3, 20_000 ether, 20_000 ether, address(this));

    vm.warp(block.timestamp + 10_000);
    market.borrowAtMaturity(FixedLib.INTERVAL, 10_000 ether, 20_000 ether, address(this), address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL * 2, 15_000 ether, 30_000 ether, address(this), address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL * 3, 20_000 ether, 40_000 ether, address(this), address(this));

    market.initConsolidated(address(this));
    (uint256 deposits, uint256 borrows) = market.fixedConsolidated(address(this));
    (uint256 totalDeposits, uint256 totalBorrows) = market.fixedOps();
    assertEq(deposits, 45_000 ether);
    assertEq(borrows, 45_000 ether);
    assertEq(totalDeposits, 45_000 ether);
    assertEq(totalBorrows, 45_000 ether);
  }

  function testDistributionOfLossesShouldReduceFromFloatingBackupBorrowedAccordingly() external {
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);
    market.setMaxFuturePools(12);

    // distribute earnings to accumulator
    market.setBackupFeeRate(1e18);

    irm = MockInterestRateModel(address(new MockBorrowRate(1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));

    vm.prank(ALICE);
    market.borrowAtMaturity(FixedLib.INTERVAL, 10_000 ether, 20_000 ether, ALICE, ALICE);
    market.depositAtMaturity(FixedLib.INTERVAL, 10_000 ether, 10_000 ether, ALICE);

    irm.setRate(0);
    daiPriceFeed.setPrice(0.0002e18);
    for (uint256 i = 1; i <= 4; i++) {
      market.borrowAtMaturity(FixedLib.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));

      // deposit so floatingBackupBorrowed is 0
      market.depositAtMaturity(FixedLib.INTERVAL * i, 1_000 ether, 1_000 ether, address(this));
    }
    daiPriceFeed.setPrice(0.0003333333333e18);

    assertEq(market.floatingBackupBorrowed(), 0);
    vm.prank(BOB);
    // distribution of losses should not reduce more of floatingBackupBorrowed
    market.liquidate(address(this), type(uint256).max, marketWETH);
    assertEq(market.floatingBackupBorrowed(), 0);

    marketWETH.deposit(1.15 ether, address(this));
    daiPriceFeed.setPrice(0.0002e18);
    for (uint256 i = 1; i <= 4; i++) {
      market.borrowAtMaturity(FixedLib.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));

      // withdraw 500 so floatingBackupBorrowed is half
      market.withdrawAtMaturity(FixedLib.INTERVAL * i, 500 ether, 500 ether, address(this), address(this));
    }
    daiPriceFeed.setPrice(0.0003333333333e18);

    assertEq(market.floatingBackupBorrowed(), (1_000 ether * 4) / 2);
    vm.prank(BOB);
    // distribution of losses should reduce the remaining from floatingBackupBorrowed
    market.liquidate(address(this), type(uint256).max, marketWETH);
    assertEq(market.floatingBackupBorrowed(), 0);
  }

  function testLiquidationClearingDebtOfAllAccountMarkets() external {
    daiPriceFeed.setPrice(0.0003333333333e18);
    marketWETH.deposit(10 ether, BOB);
    market.deposit(50_000 ether, BOB);
    marketWETH.deposit(1 ether, address(this));

    // distribute earnings to accumulator
    market.setBackupFeeRate(1e18);
    marketWETH.setBackupFeeRate(1e18);

    irm = MockInterestRateModel(address(new MockBorrowRate(1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));
    marketWETH.setInterestRateModel(InterestRateModel(address(irm)));

    vm.prank(BOB);
    market.borrowAtMaturity(FixedLib.INTERVAL, 15_000 ether, 30_000 ether, BOB, BOB);
    market.depositAtMaturity(FixedLib.INTERVAL, 15_000 ether, 15_000 ether, BOB);
    vm.prank(BOB);
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 2 ether, 4 ether, BOB, BOB);
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 2 ether, 2 ether, BOB);

    irm.setRate(1e17);
    market.borrow(500 ether, address(this), address(this));
    marketWETH.borrow(0.25 ether, address(this), address(this));

    daiPriceFeed.setPrice(0.01e18);
    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);

    (uint256 daiBalance, uint256 daiDebt) = market.accountSnapshot(address(this));
    (uint256 wethBalance, uint256 wethDebt) = marketWETH.accountSnapshot(address(this));
    assertEq(daiBalance, 0);
    assertEq(daiDebt, 0);
    assertEq(wethBalance, 0);
    assertEq(wethDebt, 0);
  }

  function testCappedLiquidation() external {
    irm.setRate(0);
    daiPriceFeed.setPrice(0.0005e18);

    market.deposit(50_000 ether, ALICE);
    marketWETH.deposit(1 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));

    daiPriceFeed.setPrice(0.001111111111e18);

    vm.prank(BOB);
    // vm.expectEmit(true, true, true, true, address(market));
    // emit Liquidate(BOB, address(this), 818181818181818181819, 8181818181818181818, marketWETH, 1 ether);
    // expect the liquidation to cap the max amount of possible assets to repay
    market.liquidate(address(this), type(uint256).max, marketWETH);
    (uint256 remainingCollateral, ) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(remainingCollateral, 0);
  }

  function testLiquidationResultingInZeroCollateralAndZeroDebt() external {
    daiPriceFeed.setPrice(0.0005e18);

    market.deposit(500_000 ether, ALICE);
    vm.prank(ALICE);
    market.approve(address(this), type(uint256).max);

    irm = MockInterestRateModel(address(new MockBorrowRate(0.1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));
    market.borrowAtMaturity(FixedLib.INTERVAL, 100_000 ether, 110_000 ether, ALICE, ALICE);
    market.depositAtMaturity(FixedLib.INTERVAL, 100_000 ether, 100_000 ether, ALICE);

    irm.setRate(0);
    marketWETH.deposit(1 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));

    daiPriceFeed.setPrice(0.001111111111111111e18);

    vm.prank(BOB);
    vm.expectEmit(true, true, true, true, address(market));
    emit Liquidate(BOB, address(this), 818181818181818263719, 8181818181818182637, marketWETH, 1 ether);
    market.liquidate(address(this), 1_000 ether, marketWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      Market(address(0)),
      0
    );
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
  }

  function testUpdateFloatingAssetsAverageWithDampSpeedUp() external {
    vm.warp(0);
    market.deposit(100 ether, address(this));

    vm.warp(217);
    assertLt(market.previewFloatingAssetsAverage(), market.floatingAssets());

    vm.warp(435);
    assertLt(market.previewFloatingAssetsAverage(), market.floatingAssets());

    // with a damp speed up of 0.0046, the floatingAssetsAverage is equal to the floatingAssets
    // when 9011 seconds went by
    vm.warp(9446);
    assertEq(market.previewFloatingAssetsAverage(), market.floatingAssets());

    vm.warp(300000);
    assertEq(market.previewFloatingAssetsAverage(), market.floatingAssets());
  }

  function testUpdateFloatingAssetsAverageWithDampSpeedDown() external {
    vm.warp(0);
    market.deposit(100 ether, address(this));

    vm.warp(218);
    market.withdraw(50 ether, address(this), address(this));

    vm.warp(220);
    assertLt(market.previewFloatingAssetsAverage(), market.floatingAssetsAverage());

    vm.warp(300);
    assertApproxEqRel(market.previewFloatingAssetsAverage(), market.floatingAssets(), 1e6);

    // with a damp speed down of 0.42, the floatingAssetsAverage is equal to the floatingAssets
    // when 23 seconds went by
    vm.warp(323);
    assertEq(market.previewFloatingAssetsAverage(), market.floatingAssets());
  }

  function testUpdateFloatingAssetsAverageWhenDepositingRightBeforeEarlyWithdraw() external {
    uint256 initialBalance = 10 ether;
    uint256 amount = 1 ether;

    vm.warp(0);
    market.deposit(initialBalance, address(this));
    market.depositAtMaturity(FixedLib.INTERVAL, amount, amount, address(this));

    vm.warp(2000);
    market.deposit(100 ether, address(this));
    market.withdrawAtMaturity(FixedLib.INTERVAL, amount, 0.9 ether, address(this), address(this));
    assertApproxEqRel(market.floatingAssetsAverage(), initialBalance, 1e15);
    assertEq(market.floatingAssets(), 100 ether + initialBalance);
  }

  function testUpdateFloatingAssetsAverageWhenDepositingRightBeforeBorrow() external {
    uint256 initialBalance = 10 ether;
    vm.warp(0);
    market.deposit(initialBalance, address(this));

    vm.warp(2000);
    market.deposit(100 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1, 2, address(this), address(this));
    assertApproxEqRel(market.floatingAssetsAverage(), initialBalance, 1e15);
    assertEq(market.floatingAssets(), 100 ether + initialBalance);
  }

  function testUpdateFloatingAssetsAverageWhenDepositingSomeSecondsBeforeBorrow() external {
    vm.warp(0);
    market.deposit(10 ether, address(this));

    vm.warp(218);
    market.deposit(100 ether, address(this));
    uint256 lastFloatingAssetsAverage = market.floatingAssetsAverage();

    vm.warp(250);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1, 2, address(this), address(this));
    uint256 supplyAverageFactor = uint256(
      1e18 - FixedPointMathLib.expWad(-int256(market.floatingAssetsDampSpeedUp() * (250 - 218)))
    );
    assertEq(
      market.previewFloatingAssetsAverage(),
      lastFloatingAssetsAverage.mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(market.floatingAssets())
    );
    assertEq(market.previewFloatingAssetsAverage(), 20.521498717652997528 ether);

    vm.warp(9541);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1, 2, address(this), address(this));
    assertEq(market.previewFloatingAssetsAverage(), market.floatingAssets());
  }

  function testUpdateFloatingAssetsAverageWhenDepositingAndBorrowingContinuously() external {
    vm.warp(0);
    market.deposit(10 ether, address(this));

    vm.warp(218);
    market.deposit(100 ether, address(this));

    vm.warp(219);
    assertEq(market.previewFloatingAssetsAverage(), 6.807271809941046233 ether);

    vm.warp(220);
    assertEq(market.previewFloatingAssetsAverage(), 7.280868252688897854 ether);

    vm.warp(221);
    assertEq(market.previewFloatingAssetsAverage(), 7.752291154776303685 ether);

    vm.warp(222);
    assertEq(market.previewFloatingAssetsAverage(), 8.221550491529461768 ether);
  }

  function testUpdateFloatingAssetsAverageWhenWithdrawingRightBeforeBorrow() external {
    uint256 initialBalance = 10 ether;
    vm.warp(0);
    market.deposit(initialBalance, address(this));

    vm.warp(2000);
    market.withdraw(5 ether, address(this), address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1, 2, address(this), address(this));
    assertApproxEqRel(market.previewFloatingAssetsAverage(), initialBalance, 1e15);
    assertEq(market.floatingAssets(), initialBalance - 5 ether);
  }

  function testUpdateFloatingAssetsAverageWhenWithdrawingRightBeforeEarlyWithdraw() external {
    uint256 initialBalance = 10 ether;
    uint256 amount = 1 ether;
    vm.warp(0);
    market.deposit(initialBalance, address(this));
    market.depositAtMaturity(FixedLib.INTERVAL, amount, amount, address(this));

    vm.warp(2000);
    market.withdraw(5 ether, address(this), address(this));
    market.withdrawAtMaturity(FixedLib.INTERVAL, amount, 0.9 ether, address(this), address(this));
    assertApproxEqRel(market.previewFloatingAssetsAverage(), initialBalance, 1e15);
    assertEq(market.floatingAssets(), initialBalance - 5 ether);
  }

  function testUpdateFloatingAssetsAverageWhenWithdrawingSomeSecondsBeforeBorrow() external {
    vm.warp(0);
    market.deposit(10 ether, address(this));

    vm.warp(218);
    market.withdraw(5 ether, address(this), address(this));
    uint256 lastFloatingAssetsAverage = market.previewFloatingAssetsAverage();

    vm.warp(219);
    uint256 supplyAverageFactor = uint256(
      1e18 - FixedPointMathLib.expWad(-int256(market.floatingAssetsDampSpeedDown() * (block.timestamp - 218)))
    );
    assertEq(
      market.previewFloatingAssetsAverage(),
      lastFloatingAssetsAverage.mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(market.floatingAssets())
    );
    assertEq(market.previewFloatingAssetsAverage(), 5.874852456225897297 ether);

    vm.warp(221);
    supplyAverageFactor = uint256(
      1e18 - FixedPointMathLib.expWad(-int256(market.floatingAssetsDampSpeedDown() * (block.timestamp - 218)))
    );
    assertEq(
      market.previewFloatingAssetsAverage(),
      lastFloatingAssetsAverage.mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(market.floatingAssets())
    );
    assertEq(market.previewFloatingAssetsAverage(), 5.377683011800498152 ether);

    vm.warp(444);
    assertEq(market.previewFloatingAssetsAverage(), market.floatingAssets());
  }

  function testFixedBorrowFailingWhenFlexibleBorrowAccruesDebt() external {
    market.deposit(1_000 ether, ALICE);
    market.deposit(100 ether, address(this));

    market.borrow(50 ether, address(this), address(this));

    vm.warp(365 days);
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    market.borrowAtMaturity(FixedLib.INTERVAL * 14, 10 ether, 15 ether, address(this), address(this));

    vm.expectRevert(InsufficientAccountLiquidity.selector);
    market.transfer(BOB, 15 ether);

    vm.expectRevert(InsufficientAccountLiquidity.selector);
    market.withdraw(15 ether, address(this), address(this));

    vm.expectRevert(InsufficientAccountLiquidity.selector);
    market.withdraw(15 ether, address(this), address(this));

    market.approve(BOB, 15 ether);

    vm.prank(BOB);
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    market.transferFrom(address(this), BOB, 15 ether);
  }

  function testDepositShouldUpdateFlexibleBorrowVariables() external {
    vm.warp(0);
    market.deposit(100 ether, address(this));
    market.borrow(10 ether, address(this), address(this));

    vm.warp(365 days);
    market.deposit(2, address(this));

    assertEq(market.floatingDebt(), 11 ether);
    assertEq(market.floatingAssets(), 101 ether + 2);
    assertEq(market.lastFloatingDebtUpdate(), 365 days);

    vm.warp(730 days);
    market.mint(1, address(this));
    assertEq(market.floatingDebt(), 12.1 ether);
    assertEq(market.floatingAssets(), 102.1 ether + 4);
    assertEq(market.lastFloatingDebtUpdate(), 730 days);
  }

  function testWithdrawShouldUpdateFlexibleBorrowVariables() external {
    vm.warp(0);
    market.deposit(100 ether, address(this));
    market.borrow(10 ether, address(this), address(this));

    vm.warp(365 days);
    market.withdraw(1, address(this), address(this));

    assertEq(market.floatingDebt(), 11 ether);
    assertEq(market.floatingAssets(), 101 ether - 1);
    assertEq(market.lastFloatingDebtUpdate(), 365 days);

    vm.warp(730 days);
    market.redeem(1, address(this), address(this));

    assertEq(market.floatingDebt(), 12.1 ether);
    assertEq(market.floatingAssets(), 102.1 ether - 2);
    assertEq(market.lastFloatingDebtUpdate(), 730 days);
  }

  function testChargeTreasuryToFixedBorrows() external {
    market.setTreasury(BOB, 0.1e18);
    assertEq(market.treasury(), BOB);
    assertEq(market.treasuryFeeRate(), 0.1e18);

    irm = MockInterestRateModel(address(new MockBorrowRate(0.1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));

    market.deposit(10 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));
    // treasury earns 10% of the 10% that is charged to the borrower
    assertEq(market.balanceOf(BOB), 0.01 ether, "1");
    // the treasury earnings are instantly added to the smart pool assets
    assertEq(market.floatingAssets(), 10 ether + 0.01 ether, "2");

    (, , uint256 unassignedEarnings, ) = market.fixedPools(FixedLib.INTERVAL);
    // rest of it goes to unassignedEarnings of the fixed pool
    assertEq(unassignedEarnings, 0.09 ether, "3");

    // when no fees are charged, the treasury logic should not revert
    irm.setRate(0);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this), address(this));

    assertEq(market.balanceOf(BOB), 0.01 ether, "4");
    assertEq(market.floatingAssets(), 10 ether + 0.01 ether, "5");

    vm.warp(FixedLib.INTERVAL / 2);

    vm.prank(ALICE);
    market.deposit(5 ether, address(this));
    irm.setRate(0.1e18);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));
    // treasury even ends up accruing more earnings
    assertLt(market.balanceOf(BOB), 0.02 ether, "6");
    assertGt(market.maxWithdraw(BOB), 0.02 ether, "7");
  }

  function testCollectTreasuryFreeLunchToFixedBorrows() external {
    irm = MockInterestRateModel(address(new MockBorrowRate(0.1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));
    market.setTreasury(BOB, 0.1e18);
    market.deposit(10 ether, address(this));
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    // treasury should earn all inefficient earnings charged to the borrower
    assertEq(market.balanceOf(BOB), 0.1 ether);
    // the treasury earnings are instantly added to the smart pool assets
    assertEq(market.floatingAssets(), 10 ether + 0.1 ether);

    (, , uint256 unassignedEarnings, ) = market.fixedPools(FixedLib.INTERVAL);
    // unassignedEarnings and accumulator should not receive anything
    assertEq(unassignedEarnings, 0);
    assertEq(market.earningsAccumulator(), 0);

    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 2 ether, 3 ether, address(this), address(this));

    // treasury should earn 10% of 0.2 = 0.02
    // and HALF of inefficient earnings charged to the borrower = (0.2 - 0.02) / 2 = 0.09
    assertEq(market.balanceOf(BOB), 0.1 ether + 0.02 ether + 0.09 ether);
    // the treasury earnings are instantly added to the smart pool assets
    assertEq(market.floatingAssets(), 10 ether + 0.1 ether + 0.02 ether + 0.09 ether);

    (, , unassignedEarnings, ) = market.fixedPools(FixedLib.INTERVAL);
    // unassignedEarnings should receive the other half
    assertEq(unassignedEarnings, 0.09 ether);
    assertEq(market.earningsAccumulator(), 0);

    // now when treasury fee is 0 again, all inefficient fees charged go to accumulator
    market.depositAtMaturity(FixedLib.INTERVAL, 2 ether, 1 ether, address(this));
    market.setTreasury(BOB, 0);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    assertGt(market.earningsAccumulator(), 0.1 ether);
    assertEq(market.balanceOf(BOB), 0.1 ether + 0.02 ether + 0.09 ether);
  }

  function testCollectTreasuryFreeLunchToFixedBorrowsWithZeroFees() external {
    market.setTreasury(BOB, 0.1e18);
    market.deposit(10 ether, address(this));
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
    // when no fees are charged, the treasury logic should not revert
    irm.setRate(0);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    // treasury shouldn't earn earnings
    assertEq(market.balanceOf(BOB), 0);
    assertEq(market.floatingAssets(), 10 ether);

    (, , uint256 unassignedEarnings, ) = market.fixedPools(FixedLib.INTERVAL);
    // unassignedEarnings and accumulator should not receive anything either
    assertEq(unassignedEarnings, 0);
    assertEq(market.earningsAccumulator(), 0);
  }

  function testChargeTreasuryToEarlyWithdraws() external {
    market.deposit(10 ether, address(this));
    market.depositAtMaturity(FixedLib.INTERVAL, 2 ether, 2 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 2 ether, 3 ether, address(this), address(this));

    market.setTreasury(BOB, 0.1e18);
    market.withdrawAtMaturity(FixedLib.INTERVAL, 1 ether, 0.9 ether, address(this), address(this));
    // treasury earns 10% of the 10% that is charged to the borrower
    assertEq(market.balanceOf(BOB), 0.000761283306144643 ether);
    // the treasury earnings are instantly added to the smart pool assets
    assertEq(market.floatingAssets(), 10 ether + 0.000761283306144643 ether);

    (, , uint256 unassignedEarnings, ) = market.fixedPools(FixedLib.INTERVAL);
    // rest of it goes to unassignedEarnings of the fixed pool
    assertEq(unassignedEarnings, 1 ether - 0.993148450244698205 ether);

    // when no fees are charged, the treasury logic should not revert
    irm.setRate(0);
    market.withdrawAtMaturity(FixedLib.INTERVAL, 0.5 ether, 0.4 ether, address(this), address(this));

    assertEq(market.balanceOf(BOB), 0.000761283306144643 ether);
    assertEq(market.floatingAssets(), 10 ether + 0.000761283306144643 ether);

    vm.warp(FixedLib.INTERVAL / 2);

    market.withdrawAtMaturity(FixedLib.INTERVAL, 0.5 ether, 0.4 ether, address(this), address(this));
    // treasury even ends up accruing more earnings
    assertGt(market.maxWithdraw(BOB), market.balanceOf(BOB));
  }

  function testCollectTreasuryFreeLunchToEarlyWithdraws() external {
    market.setTreasury(BOB, 0.1e18);
    market.deposit(10 ether, address(this));
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
    market.withdrawAtMaturity(FixedLib.INTERVAL, 1 ether, 0.9 ether, address(this), address(this));
    // treasury should earn all inefficient earnings charged to the borrower
    assertEq(market.balanceOf(BOB), 0.007612833061446438 ether);
    // the treasury earnings are instantly added to the smart pool assets
    assertEq(market.floatingAssets(), 10 ether + 0.007612833061446438 ether);

    (, , uint256 unassignedEarnings, ) = market.fixedPools(FixedLib.INTERVAL);
    // unassignedEarnings and accumulator should not receive anything
    assertEq(unassignedEarnings, 0);
    assertEq(market.earningsAccumulator(), 0);

    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
    irm.setRate(0);
    market.borrowAtMaturity(FixedLib.INTERVAL, 0.5 ether, 1 ether, address(this), address(this));
    irm.setRate(0.1e18);
    market.withdrawAtMaturity(FixedLib.INTERVAL, 1 ether, 0.9 ether, address(this), address(this));

    // treasury and unassignedEarnings should earn earnings
    assertEq(market.balanceOf(BOB), 0.011773611328372327 ether);
    // the treasury earnings are instantly added to the smart pool assets
    assertEq(market.floatingAssets(), 10 ether + 0.011773611328372327 ether);

    (, , unassignedEarnings, ) = market.fixedPools(FixedLib.INTERVAL);
    // unassignedEarnings should receive the other part
    assertEq(unassignedEarnings, 0.003452054794520549 ether);
    assertEq(market.earningsAccumulator(), 0);

    // now when treasury fee is 0 again, all inefficient fees charged go to accumulator
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
    market.setTreasury(BOB, 0);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    assertEq(market.earningsAccumulator(), 0.004180821917808218 ether);
    assertEq(market.balanceOf(BOB), 0.011773611328372327 ether);
  }

  function testCollectTreasuryFreeLunchToEarlyWithdrawsWithZeroFees() external {
    market.setTreasury(BOB, 0.1e18);
    market.deposit(10 ether, address(this));
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
    // when no fees are charged, the treasury logic should not revert
    irm.setRate(0);
    market.withdrawAtMaturity(FixedLib.INTERVAL, 1 ether, 0.9 ether, address(this), address(this));
    // treasury shouldn't earn earnings charged to the borrower
    assertEq(market.balanceOf(BOB), 0);
    assertEq(market.floatingAssets(), 10 ether);

    (, , uint256 unassignedEarnings, ) = market.fixedPools(FixedLib.INTERVAL);
    // unassignedEarnings and accumulator should not receive anything either
    assertEq(unassignedEarnings, 0);
    assertEq(market.earningsAccumulator(), 0);
  }

  function testFlexibleBorrow() external {
    market.deposit(10 ether, address(this));
    uint256 balanceBefore = market.asset().balanceOf(address(this));
    market.borrow(1 ether, address(this), address(this));
    uint256 balanceAfter = market.asset().balanceOf(address(this));
    (, , uint256 floatingBorrowShares) = market.accounts(address(this));

    assertEq(floatingBorrowShares, 1 ether);
    assertEq(balanceAfter, balanceBefore + 1 ether);
  }

  function testRepayFlexibleBorrow() external {
    vm.warp(0);
    market.deposit(10 ether, address(this));
    vm.prank(BOB);
    market.deposit(10 ether, BOB);

    market.borrow(1 ether, address(this), address(this));

    vm.warp(365 days);
    vm.prank(BOB);
    market.borrow(1 ether, BOB, BOB);
    uint256 balanceContractBefore = ERC20(market.asset()).balanceOf(address(this));

    (, , uint256 floatingBorrowShares) = market.accounts(BOB);
    assertLt(floatingBorrowShares, 1 ether);
    market.repay(0.5 ether, BOB);
    (, , floatingBorrowShares) = market.accounts(BOB);
    assertEq(market.previewRefund(floatingBorrowShares), 0.5 ether + 1);
    assertLt(market.previewRepay(0.5 ether), floatingBorrowShares);
    market.repay(0.5 ether, BOB);
    (, , floatingBorrowShares) = market.accounts(BOB);
    assertEq(floatingBorrowShares, 1);
    assertEq(balanceContractBefore - ERC20(market.asset()).balanceOf(address(this)), 1 ether);

    balanceContractBefore = ERC20(market.asset()).balanceOf(address(this));
    // send more to repay
    market.repay(5 ether, address(this));
    (, , floatingBorrowShares) = market.accounts(address(this));
    // only repay the max amount of debt that the contract had
    assertEq(balanceContractBefore - ERC20(market.asset()).balanceOf(address(this)), 1.1 ether - 1);
    assertEq(floatingBorrowShares, 0);
  }

  function testUpdateFloatingDebtBeforeSettingTreasury() external {
    vm.warp(3 days);
    market.setTreasury(BOB, 0.1e18);
    assertEq(market.lastFloatingDebtUpdate(), 3 days);
  }

  function testFlexibleBorrowChargingDebtToTreasury() external {
    vm.warp(0);
    market.setTreasury(BOB, 0.1e18);

    market.deposit(10 ether, address(this));
    market.borrow(1 ether, address(this), address(this));

    vm.warp(365 days);
    // can dynamically calculate borrow debt
    assertEq(market.previewDebt(address(this)), 1.1 ether);
    // distribute borrow debt with another borrow
    market.borrow(1, address(this), address(this));

    // treasury earns 10% of the 10% that is charged to the borrower (rounded down)
    assertEq(market.maxWithdraw(BOB), 0.01 ether - 1);
    // the treasury earnings + debt accrued are instantly added to the smart pool assets
    assertEq(market.floatingAssets(), 10 ether + 0.1 ether);
  }

  function testFlexibleBorrowFromAnotherUserWithAllowance() external {
    vm.prank(BOB);
    market.deposit(10 ether, BOB);
    vm.prank(BOB);
    market.approve(address(this), type(uint256).max);
    market.borrow(1 ether, address(this), BOB);
  }

  function testFlexibleBorrowFromAnotherUserSubtractsAllowance() external {
    vm.prank(BOB);
    market.deposit(10 ether, BOB);
    vm.prank(BOB);
    market.approve(address(this), 2 ether);
    market.borrow(1 ether, address(this), BOB);

    assertEq(market.allowance(BOB, address(this)), 2 ether - 1 ether);
  }

  function testFlexibleBorrowFromAnotherUserWithoutAllowance() external {
    market.deposit(10 ether, address(this));
    vm.expectRevert(stdError.arithmeticError);
    market.borrow(1 ether, address(this), BOB);
  }

  function testFlexibleBorrowAccountingDebt() external {
    vm.warp(0);
    market.deposit(10 ether, address(this));
    market.borrow(1 ether, address(this), address(this));
    (, , uint256 floatingBorrowShares) = market.accounts(address(this));
    assertEq(market.floatingDebt(), 1 ether);
    assertEq(market.totalFloatingBorrowShares(), floatingBorrowShares);

    // after 1 year 10% is the accumulated debt (using a mock interest rate model)
    vm.warp(365 days);
    assertEq(market.previewDebt(address(this)), 1.1 ether);
    market.refund(0.5 ether, address(this));
    assertEq(market.floatingDebt(), 0.55 ether);
    (, , floatingBorrowShares) = market.accounts(address(this));
    assertEq(market.totalFloatingBorrowShares(), floatingBorrowShares);

    (, , floatingBorrowShares) = market.accounts(address(this));
    assertEq(floatingBorrowShares, 0.5 ether);
    market.refund(0.5 ether, address(this));
    (, , floatingBorrowShares) = market.accounts(address(this));
    assertEq(floatingBorrowShares, 0);
  }

  function testFlexibleBorrowAccountingDebtMultipleAccounts() internal {
    // TODO refactor
    vm.warp(0);

    daiPriceFeed.setPrice(0.001e18);
    weth.mint(BOB, 1 ether);
    vm.prank(BOB);
    weth.approve(address(marketWETH), 1 ether);
    vm.prank(BOB);
    marketWETH.deposit(1 ether, BOB);
    vm.prank(BOB);
    auditor.enterMarket(marketWETH);

    weth.mint(ALICE, 1 ether);
    vm.prank(ALICE);
    weth.approve(address(marketWETH), 1 ether);
    vm.prank(ALICE);
    marketWETH.deposit(1 ether, ALICE);
    vm.prank(ALICE);
    auditor.enterMarket(marketWETH);

    market.deposit(10 ether, address(this));
    market.borrow(1 ether, address(this), address(this));

    irm.setRate(0.05e18);
    // after 1/2 year 2.5% is the accumulated debt (using a mock interest rate model)
    vm.warp(182.5 days);
    assertEq(market.previewRefund(1 ether), 1.025 ether);
    assertEq(market.previewDebt(address(this)), 1.025 ether);

    vm.prank(BOB);
    market.borrow(1 ether, BOB, BOB);
    (, , uint256 floatingBorrowShares) = market.accounts(address(this));
    assertEq(market.previewRefund(1 ether), market.previewDebt(BOB));
    assertEq(market.previewRefund(1.025 ether), floatingBorrowShares);

    // after 1/4 year 1.25% is the accumulated debt
    // contract now owes 1.025 * 1.0125 = 1.0378125 ether
    // bob now owes      1 * 1.0125     = 1.0125 ether
    vm.warp(273.75 days);
    vm.prank(ALICE);
    market.borrow(1 ether, ALICE, ALICE);
    // TODO check rounding
    (, , floatingBorrowShares) = market.accounts(ALICE);
    assertEq(market.previewRefund(1 ether), floatingBorrowShares + 1);
    (, , floatingBorrowShares) = market.accounts(BOB);
    assertEq(market.previewRefund(1.0125 ether), floatingBorrowShares);
    (, , floatingBorrowShares) = market.accounts(address(this));
    assertEq(market.previewRefund(1.0378125 ether), floatingBorrowShares);

    // after another 1/4 year 1.25% is the accumulated debt
    // contract now owes 1.0378125 * 1.0125 = 1.0507851525 ether
    // bob now owes      1.0125 * 1.0125    = 1.02515625 ether
    // alice now owes    1 * 1.0125         = 1.0125 ether
    vm.warp(365 days);
    vm.prank(ALICE);
    market.refund(1.05078515625 ether, address(this));
    vm.prank(BOB);
    market.refund(1.02515625 ether, BOB);
    vm.prank(ALICE);
    market.refund(1.0125 ether, ALICE);

    (, , floatingBorrowShares) = market.accounts(address(this));
    assertEq(floatingBorrowShares, 0);
    (, , floatingBorrowShares) = market.accounts(BOB);
    assertEq(floatingBorrowShares, 0);
    (, , floatingBorrowShares) = market.accounts(ALICE);
    assertEq(floatingBorrowShares, 0);

    uint256 flexibleDebtAccrued = 0.05078515625 ether + 0.02515625 ether + 0.0125 ether;
    assertEq(market.floatingAssets(), 10 ether + flexibleDebtAccrued);
  }

  function testFlexibleBorrowExceedingReserve() external {
    marketWETH.deposit(1 ether, address(this));
    daiPriceFeed.setPrice(0.001e18);

    market.deposit(10 ether, address(this));
    market.setReserveFactor(0.1e18);

    market.borrow(9 ether, address(this), address(this));
    market.refund(9 ether, address(this));

    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.borrow(9.01 ether, address(this), address(this));
  }

  function testFlexibleBorrowExceedingReserveIncludingFixedBorrow() external {
    marketWETH.deposit(1 ether, address(this));
    daiPriceFeed.setPrice(0.001e18);

    market.deposit(10 ether, address(this));
    market.setReserveFactor(0.1e18);

    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));

    market.borrow(8 ether, address(this), address(this));
    market.refund(8 ether, address(this));

    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.borrow(8.01 ether, address(this), address(this));
  }

  function testFlexibleBorrowExceedingReserveWithNewDebt() external {
    marketWETH.deposit(1 ether, address(this));
    daiPriceFeed.setPrice(0.001e18);

    market.deposit(10 ether, address(this));
    market.setReserveFactor(0.1e18);
    market.borrow(8.8 ether, address(this), address(this));
    vm.warp(365 days);

    // it doesn't revert because the flexible debt also increases the smart pool assets
    market.borrow(0.1 ether, address(this), address(this));
  }

  function testOperationsShouldUpdateFloatingAssetsAverage() external {
    market.deposit(100 ether, address(this));
    uint256 currentFloatingAssets = market.floatingAssetsAverage();
    assertEq(market.floatingAssetsAverage(), 0);
    uint256 previousFloatingAssets = currentFloatingAssets;

    // SMART POOL WITHDRAW
    vm.warp(1000);
    market.withdraw(1, address(this), address(this));
    currentFloatingAssets = market.floatingAssetsAverage();
    assertGt(currentFloatingAssets, previousFloatingAssets);
    previousFloatingAssets = currentFloatingAssets;

    vm.warp(2000);
    // SMART POOL DEPOSIT (LIQUIDATE SHOULD ALSO UPDATE SP ASSETS AVERAGE)
    market.deposit(1, address(this));
    currentFloatingAssets = market.floatingAssetsAverage();
    assertGt(currentFloatingAssets, previousFloatingAssets);
    previousFloatingAssets = currentFloatingAssets;

    vm.warp(3000);
    // FIXED BORROW DOESN'T UPDATE
    market.borrowAtMaturity(FixedLib.INTERVAL, 1, 2, address(this), address(this));
    currentFloatingAssets = market.floatingAssetsAverage();
    assertEq(currentFloatingAssets, previousFloatingAssets);

    vm.warp(4000);
    // EARLY WITHDRAW DOESN'T UPDATE
    market.depositAtMaturity(FixedLib.INTERVAL, 10, 1, address(this));
    market.withdrawAtMaturity(FixedLib.INTERVAL, 1, 0, address(this), address(this));
    currentFloatingAssets = market.floatingAssetsAverage();
    assertEq(currentFloatingAssets, previousFloatingAssets);

    vm.warp(5000);
    // FLEXIBLE BORROW DOESN'T UPDATE
    market.borrow(1 ether, address(this), address(this));
    currentFloatingAssets = market.floatingAssetsAverage();
    assertEq(currentFloatingAssets, previousFloatingAssets);

    vm.warp(6000);
    // FLEXIBLE REPAY DOESN'T UPDATE
    market.refund(1 ether, address(this));
    currentFloatingAssets = market.floatingAssetsAverage();
    assertEq(currentFloatingAssets, previousFloatingAssets);
  }

  function testInsufficientProtocolLiquidity() external {
    daiPriceFeed.setPrice(0.001e18);

    marketWETH.deposit(50 ether, address(this));
    // smart pool assets = 100
    market.deposit(100 ether, address(this));

    // fixed borrows = 51
    market.borrowAtMaturity(FixedLib.INTERVAL, 51 ether, 60 ether, address(this), address(this));

    // withdrawing 50 should revert (liquidity = 49)
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.withdraw(50 ether, address(this), address(this));

    // smart pool assets = 151 & fixed borrows = 51 (liquidity = 100)
    market.deposit(51 ether, address(this));

    // flexible borrows = 51 eth
    market.borrow(51 ether, address(this), address(this));

    // withdrawing 50 should revert (liquidity = 49)
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.withdraw(50 ether, address(this), address(this));

    // withdrawing 49 should not revert
    market.withdraw(49 ether, address(this), address(this));
  }

  function testMaturityInsufficientProtocolLiquidity() external {
    daiPriceFeed.setPrice(0.001e18);
    market.setReserveFactor(0.1e18);

    marketWETH.deposit(50 ether, address(this));
    // smart pool assets = 100
    market.deposit(100 ether, address(this));
    // assets in maturity number 1 = 50
    market.depositAtMaturity(FixedLib.INTERVAL, 50 ether, 50 ether, address(this));

    // borrowing more from maturity number 2 should revert
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.borrowAtMaturity(FixedLib.INTERVAL * 2, 100 ether + 1, type(uint256).max, address(this), address(this));

    // assets in maturity number 2 = 50
    market.depositAtMaturity(FixedLib.INTERVAL * 2, 50 ether, 50 ether, address(this));
    // assets in maturity number 1 = 25
    market.borrowAtMaturity(FixedLib.INTERVAL, 125 ether, type(uint256).max, address(this), address(this));

    // withdrawing 50 from maturity number 1 should revert
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.withdrawAtMaturity(FixedLib.INTERVAL, 50 ether, 40 ether, address(this), address(this));

    // borrowing 25 eth should revert due to reserve factor
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.borrow(25 ether, address(this), address(this));
    // borrowing 25 eth from maturity should revert due to reserve factor
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.borrowAtMaturity(FixedLib.INTERVAL, 25 ether, type(uint256).max, address(this), address(this));
  }

  function testEarlyRepaymentWithExcessiveAmountOfFees() external {
    market.setInterestRateModel(
      new InterestRateModel(
        Parameters({
          minRate: 3.5e16,
          naturalRate: 8e16,
          maxUtilization: 1e18 + 1,
          naturalUtilization: 0.7e18,
          growthSpeed: 1.5e18,
          sigmoidSpeed: 1.5e18,
          spreadFactor: 1e18,
          maturitySpeed: 0.5e18,
          timePreference: 0,
          fixedAllocation: 0.3e18,
          maxRate: 100e16
        }),
        market
      )
    );

    market.deposit(1_000_000 ether, address(this));
    marketWETH.deposit(100_000 ether, BOB);
    daiPriceFeed.setPrice(0.0002e18);
    vm.prank(BOB);
    auditor.enterMarket(marketWETH);

    vm.warp(66_666);
    market.borrowAtMaturity(FixedLib.INTERVAL, 100, type(uint256).max, address(this), address(this));
    vm.prank(BOB);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1_000_000 ether - 100, type(uint256).max, BOB, BOB);

    // contract can cover all debt by repaying less than initial amount borrowed (93 < 100)
    (uint256 principal, uint256 fee) = market.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    market.repayAtMaturity(FixedLib.INTERVAL, principal + fee, 94, address(this));
  }

  function testClearMaturity() external {
    irm = MockInterestRateModel(address(new MockBorrowRate(0.1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));
    market.setMaxFuturePools(5);
    market.deposit(100 ether, address(this));

    // we borrow in the first, third and fifth maturity
    market.borrowAtMaturity(FixedLib.INTERVAL * 1, 1 ether, 1.1 ether, address(this), address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL * 3, 1 ether, 1.1 ether, address(this), address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL * 5, 1 ether, 1.1 ether, address(this), address(this));

    // we repay all first maturity debt and clear the base maturity
    market.repayAtMaturity(FixedLib.INTERVAL * 1, 1.1 ether, 1.1 ether, address(this));
    assertEq(market.previewDebt(address(this)), 2.2 ether);

    // we repay all third maturity debt and clear the base maturity
    market.repayAtMaturity(FixedLib.INTERVAL * 3, 1.1 ether, 1.1 ether, address(this));
    assertEq(market.previewDebt(address(this)), 1.1 ether);

    // we repay all fifth maturity debt and clear the whole map
    market.repayAtMaturity(FixedLib.INTERVAL * 5, 1.1 ether, 1.1 ether, address(this));
    (, uint256 fixedBorrows, ) = market.accounts(address(this));
    assertEq(market.previewDebt(address(this)), 0);
    assertEq(fixedBorrows, 0);
  }

  function testOperationsWithStEthAsset() external {
    MockStETH stETH = new MockStETH(1090725952265553962);
    Market marketStETH = Market(address(new ERC1967Proxy(address(new Market(stETH, auditor)), "")));
    marketStETH.initialize(
      MarketParams({
        maxFuturePools: 3,
        earningsAccumulatorSmoothFactor: 1e18,
        interestRateModel: InterestRateModel(address(irm)),
        penaltyRate: 0.02e18 / uint256(1 days),
        backupFeeRate: 1e17,
        reserveFactor: 0,
        floatingAssetsDampSpeedUp: 0.0046e18,
        floatingAssetsDampSpeedDown: 0.42e18,
        uDampSpeedUp: 0.23e18,
        uDampSpeedDown: 0.000053e18,
        fixedBorrowThreshold: 1e18,
        curveFactor: 0.1e18,
        minThresholdFactor: 1e18
      })
    );
    PriceFeedWrapper priceFeedWrapper = new PriceFeedWrapper(
      new MockPriceFeed(18, 0.99e18),
      address(stETH),
      MockStETH.getPooledEthByShares.selector,
      1e18
    );
    auditor.enableMarket(marketStETH, priceFeedWrapper, 0.8e18);

    stETH.mint(address(this), 50_000 ether);
    stETH.approve(address(marketStETH), type(uint256).max);

    assertEq(auditor.assetPrice(priceFeedWrapper), 1079818692742898422);

    marketStETH.deposit(50_000 ether, address(this));
    marketStETH.borrow(5_000 ether, address(this), address(this));
    vm.warp(10 days);
    marketStETH.repay(2_500 ether, address(this));
    marketStETH.withdraw(20_000 ether, address(this), address(this));
  }

  function testOperationsWithBtcWbtcRate() external {
    MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
    Market marketWBTC = Market(address(new ERC1967Proxy(address(new Market(wbtc, auditor)), "")));
    marketWBTC.initialize(
      MarketParams({
        maxFuturePools: 3,
        earningsAccumulatorSmoothFactor: 1e18,
        interestRateModel: InterestRateModel(address(irm)),
        penaltyRate: 0.02e18 / uint256(1 days),
        backupFeeRate: 1e17,
        reserveFactor: 0,
        floatingAssetsDampSpeedUp: 0.0046e18,
        floatingAssetsDampSpeedDown: 0.42e18,
        uDampSpeedUp: 0.23e18,
        uDampSpeedDown: 0.000053e18,
        fixedBorrowThreshold: 1e18,
        curveFactor: 0.1e18,
        minThresholdFactor: 1e18
      })
    );
    PriceFeedDouble priceFeedDouble = new PriceFeedDouble(
      new MockPriceFeed(18, 14 ether),
      new MockPriceFeed(8, 99000000)
    );
    auditor.enableMarket(marketWBTC, priceFeedDouble, 0.8e18);

    wbtc.mint(address(this), 50_000e8);
    wbtc.approve(address(marketWBTC), type(uint256).max);

    assertEq(auditor.assetPrice(priceFeedDouble), 1386e16);

    marketWBTC.deposit(50_000e8, address(this));
    marketWBTC.borrow(5_000e8, address(this), address(this));
    vm.warp(10 days);
    marketWBTC.repay(2_500e8, address(this));
    marketWBTC.withdraw(20_000e8, address(this), address(this));
  }

  function testMultipleBorrowsForMultipleAssets() external {
    irm.setRate(0);
    vm.warp(0);
    Market[4] memory markets;
    string[4] memory symbols = ["DAI", "USDC", "WETH", "WBTC"];
    for (uint256 i = 0; i < symbols.length; i++) {
      MockERC20 asset = new MockERC20(symbols[i], symbols[i], 18);
      markets[i] = Market(address(new ERC1967Proxy(address(new Market(asset, auditor)), "")));
      markets[i].initialize(
        MarketParams({
          maxFuturePools: 3,
          earningsAccumulatorSmoothFactor: 1e18,
          interestRateModel: InterestRateModel(address(irm)),
          penaltyRate: 0.02e18 / uint256(1 days),
          backupFeeRate: 1e17,
          reserveFactor: 0,
          floatingAssetsDampSpeedUp: 0.0046e18,
          floatingAssetsDampSpeedDown: 0.42e18,
          uDampSpeedUp: 0.23e18,
          uDampSpeedDown: 0.000053e18,
          fixedBorrowThreshold: 1e18,
          curveFactor: 0.1e18,
          minThresholdFactor: 1e18
        })
      );

      auditor.enableMarket(markets[i], daiPriceFeed, 0.8e18);
      asset.mint(BOB, 50_000 ether);
      asset.mint(address(this), 50_000 ether);
      vm.prank(BOB);
      asset.approve(address(markets[i]), type(uint256).max);
      asset.approve(address(markets[i]), type(uint256).max);
      markets[i].deposit(30_000 ether, address(this));
    }

    // since 224 is the max amount of consecutive maturities where an account can borrow
    // 221 is the last valid cycle (the last maturity where it borrows is 224)
    for (uint256 m = 0; m < 221; m += 3) {
      vm.warp(FixedLib.INTERVAL * m);
      for (uint256 i = 0; i < markets.length; ++i) {
        for (uint256 j = m + 1; j <= m + 3; ++j) {
          markets[i].borrowAtMaturity(FixedLib.INTERVAL * j, 1 ether, 1.2 ether, address(this), address(this));
        }
      }
    }

    // repay does not increase in cost
    markets[0].repayAtMaturity(FixedLib.INTERVAL, 1 ether, 1000 ether, address(this));
    // withdraw DOES increase in cost
    markets[0].withdraw(1 ether, address(this), address(this));

    // normal operations of another account are not impacted
    vm.prank(BOB);
    markets[0].deposit(100 ether, BOB);
    vm.prank(BOB);
    markets[0].withdraw(1 ether, BOB, BOB);
    vm.prank(BOB);
    vm.warp(FixedLib.INTERVAL * 400);
    markets[0].borrowAtMaturity(FixedLib.INTERVAL * 401, 1 ether, 1.2 ether, BOB, BOB);

    // liquidate function to account's borrows DOES increase in cost
    vm.prank(BOB);
    markets[0].liquidate(address(this), 1_000 ether, markets[0]);
  }

  function testFixedBorrowRateToMaturity() external {
    market.deposit(10 ether, address(this));
    auditor.enterMarket(market);
    uint256 rate = 0.2e18;
    uint256 assets = 1 ether;
    irm.setRate(rate);
    uint256 assetsOwed = market.borrowAtMaturity(
      FixedLib.INTERVAL,
      assets,
      type(uint256).max,
      address(this),
      address(this)
    );
    assertEq(assetsOwed, assets + assets.mulWadDown(rate.mulDivDown(FixedLib.INTERVAL - block.timestamp, 365 days)));
  }

  function testAccountsFixedConsolidated() external {
    market.deposit(10 ether, address(this));
    market.deposit(10 ether, ALICE);

    market.depositAtMaturity(FixedLib.INTERVAL, 0.5 ether, 0.5 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    (uint256 fixedDeposits, uint256 fixedBorrows) = market.fixedConsolidated(address(this));
    (uint256 totalFixedDeposits, uint256 totalFixedBorrows) = market.fixedOps();

    assertEq(fixedDeposits, 0.5 ether);
    assertEq(fixedBorrows, 1 ether);
    assertEq(totalFixedDeposits, 0.5 ether);
    assertEq(totalFixedBorrows, 1 ether);

    vm.startPrank(ALICE);
    market.depositAtMaturity(FixedLib.INTERVAL, 0.5 ether, 0.5 ether, ALICE);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, ALICE, ALICE);
    (fixedDeposits, fixedBorrows) = market.fixedConsolidated(ALICE);
    vm.stopPrank();

    (fixedDeposits, fixedBorrows) = market.fixedConsolidated(address(this));
    (totalFixedDeposits, totalFixedBorrows) = market.fixedOps();

    assertEq(fixedDeposits, 0.5 ether);
    assertEq(fixedBorrows, 1 ether);
    assertEq(totalFixedDeposits, 1 ether);
    assertEq(totalFixedBorrows, 2 ether);

    vm.warp(FixedLib.INTERVAL);

    (uint256 principal, uint256 fee) = market.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    market.repayAtMaturity(FixedLib.INTERVAL, principal + fee, principal + fee, address(this));
    (principal, fee) = market.fixedDepositPositions(FixedLib.INTERVAL, address(this));
    market.withdrawAtMaturity(FixedLib.INTERVAL, principal + fee, principal + fee, address(this), address(this));
    (fixedDeposits, fixedBorrows) = market.fixedConsolidated(address(this));
    assertEq(fixedDeposits, 0);
    assertEq(fixedBorrows, 0);

    vm.startPrank(ALICE);
    (principal, fee) = market.fixedBorrowPositions(FixedLib.INTERVAL, ALICE);
    market.repayAtMaturity(FixedLib.INTERVAL, (principal + fee) / 2, (principal + fee) / 2, ALICE);
    (principal, fee) = market.fixedDepositPositions(FixedLib.INTERVAL, ALICE);
    market.withdrawAtMaturity(FixedLib.INTERVAL, (principal + fee) / 2, (principal + fee) / 2, ALICE, ALICE);
    vm.stopPrank();

    (fixedDeposits, fixedBorrows) = market.fixedConsolidated(ALICE);
    assertEq(fixedDeposits, 0.25 ether);
    assertEq(fixedBorrows, 0.5 ether);

    (totalFixedDeposits, totalFixedBorrows) = market.fixedOps();
    assertEq(totalFixedDeposits, 0.25 ether);
    assertEq(totalFixedBorrows, 0.5 ether);
  }

  function testAccountsFixedConsolidatedWhenSenderNotOwner() external {
    market.deposit(10 ether, address(this));
    market.deposit(10 ether, ALICE);

    vm.prank(ALICE);
    market.approve(address(this), type(uint256).max);

    market.depositAtMaturity(FixedLib.INTERVAL, 0.5 ether, 0.5 ether, ALICE);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), ALICE);

    (uint256 fixedDeposits, uint256 fixedBorrows) = market.fixedConsolidated(ALICE);
    assertEq(fixedDeposits, 0.5 ether);
    assertEq(fixedBorrows, 1 ether);
  }

  function testAccountsFixedConsolidatedWithPartialRepayAndWithdraw() external {
    market.deposit(10 ether, address(this));

    market.borrowAtMaturity(FixedLib.INTERVAL, 1.23 ether, type(uint256).max, address(this), address(this));
    market.depositAtMaturity(FixedLib.INTERVAL, 0.57 ether, 0.57 ether, address(this));
    (uint256 principal, ) = market.fixedDepositPositions(FixedLib.INTERVAL, address(this));
    (uint256 fixedDeposits, uint256 fixedBorrows) = market.fixedConsolidated(address(this));
    assertEq(principal, fixedDeposits);
    (principal, ) = market.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal, fixedBorrows);

    vm.warp(FixedLib.INTERVAL / 3);

    market.repayAtMaturity(FixedLib.INTERVAL, 0.78 ether, 0.78 ether, address(this));
    market.withdrawAtMaturity(FixedLib.INTERVAL, 0.11 ether, 0, address(this), address(this));

    (principal, ) = market.fixedDepositPositions(FixedLib.INTERVAL, address(this));
    (fixedDeposits, fixedBorrows) = market.fixedConsolidated(address(this));
    assertEq(principal, fixedDeposits);
    (principal, ) = market.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal, fixedBorrows);

    vm.warp(FixedLib.INTERVAL / 2);

    market.repayAtMaturity(FixedLib.INTERVAL, 0.239 ether, 0.239 ether, address(this));
    market.withdrawAtMaturity(FixedLib.INTERVAL, 0.03821 ether, 0, address(this), address(this));

    (principal, ) = market.fixedDepositPositions(FixedLib.INTERVAL, address(this));
    (fixedDeposits, fixedBorrows) = market.fixedConsolidated(address(this));
    assertEq(principal, fixedDeposits);
    (principal, ) = market.fixedBorrowPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal, fixedBorrows);
  }

  function testAccountsFixedConsolidatedWhenClearBadDebt() external {
    irm = MockInterestRateModel(address(new MockBorrowRate(1e18)));
    market.setInterestRateModel(InterestRateModel(address(irm)));
    marketWETH.setInterestRateModel(InterestRateModel(address(irm)));
    daiPriceFeed.setPrice(50_000_000_000_000e18);
    market.deposit(0.0000000001 ether, address(this));
    auditor.enterMarket(market);

    marketWETH.deposit(1_000 ether, BOB);
    vm.warp(1 hours);
    vm.startPrank(BOB);
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 200 ether, type(uint256).max, BOB, BOB);
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 200 ether, 200 ether, BOB);
    vm.stopPrank();
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 5 ether, type(uint256).max, address(this), address(this));

    (uint256 fixedDeposits, uint256 fixedBorrows) = marketWETH.fixedConsolidated(address(this));
    (uint256 totalFixedDeposits, uint256 totalFixedBorrows) = marketWETH.fixedOps();
    assertEq(fixedDeposits, 0);
    assertEq(fixedBorrows, 5 ether);
    assertEq(totalFixedDeposits, 200 ether);
    assertEq(totalFixedBorrows, 205 ether);

    daiPriceFeed.setPrice(1);

    auditor.handleBadDebt(address(this));

    (fixedDeposits, fixedBorrows) = marketWETH.fixedConsolidated(address(this));
    (totalFixedDeposits, totalFixedBorrows) = marketWETH.fixedOps();
    assertEq(fixedDeposits, 0);
    assertEq(fixedBorrows, 0);
    assertEq(totalFixedDeposits, 200 ether);
    assertEq(totalFixedBorrows, 200 ether);
  }

  function testCanBorrowAtMaturity() external {
    market.setFixedBorrowFactors(0.4e18, 0.5e18, 0.25e18);
    market.deposit(1_000 ether, address(this));

    vm.warp(1 days);
    uint256 maxAmount = uint256(
      (market.fixedBorrowThreshold() *
        ((((market.curveFactor() *
          int256(
            (FixedLib.INTERVAL - block.timestamp - (FixedLib.INTERVAL - (block.timestamp % FixedLib.INTERVAL)) + 1)
              .divWadDown(market.maxFuturePools() * FixedLib.INTERVAL)
          ).lnWad()) / 1e18).expWad() * market.minThresholdFactor()) / 1e18).expWad()) / 1e18
    ).mulWadDown(market.previewFloatingAssetsAverage());
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.borrowAtMaturity(FixedLib.INTERVAL, maxAmount + 1_000, type(uint256).max, address(this), address(this));

    market.borrowAtMaturity(FixedLib.INTERVAL, maxAmount, type(uint256).max, address(this), address(this));
  }

  function testCanBorrowAtMaturityWithMaxFixedBorrowThreshold() external {
    market.setFixedBorrowFactors(0.4e18, 0.5e18, 0.25e18);
    market.deposit(1_000 ether, address(this));

    vm.warp(1 days);
    market.borrowAtMaturity(FixedLib.INTERVAL, 399 ether, type(uint256).max, address(this), address(this));

    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.borrowAtMaturity(FixedLib.INTERVAL * 2, 10 ether, type(uint256).max, address(this), address(this));
  }

  function testFuzzCanBorrowAtMaturity(
    int256 fixedBorrowThreshold,
    int256 curveFactor,
    int256 minThresholdFactor,
    uint64[12] calldata amounts,
    uint8[12] calldata pools,
    uint24[12] calldata times
  ) external {
    uint8 maxFuturePools = 12;
    fixedBorrowThreshold = _bound(fixedBorrowThreshold, 1, 1e18);
    curveFactor = _bound(curveFactor, 1, 1e18);
    minThresholdFactor = _bound(minThresholdFactor, 1, 1e18);
    market.setFixedBorrowFactors(fixedBorrowThreshold, curveFactor, minThresholdFactor);
    market.setMaxFuturePools(maxFuturePools);

    market.deposit(1_000 ether, address(this));

    uint256 maxTime = maxFuturePools * FixedLib.INTERVAL;
    for (uint256 i = 0; i < maxFuturePools; i++) {
      vm.warp(block.timestamp + times[i]);

      uint256 maturity = _bound(pools[i], 1, maxFuturePools) * FixedLib.INTERVAL;
      uint256 memFloatingAssetsAverage = market.previewFloatingAssetsAverage();
      if (block.timestamp >= maturity || memFloatingAssetsAverage == 0) continue;

      uint256 totalBorrows = 0;
      for (uint256 m = maturity; m <= maxTime; m += FixedLib.INTERVAL) {
        (uint256 borrowed, uint256 supplied, , ) = market.fixedPools(m);
        if (m == maturity) borrowed += amounts[i];
        totalBorrows += borrowed > supplied ? borrowed - supplied : 0;
      }
      bool canBorrow = memFloatingAssetsAverage > 0
        ? totalBorrows.divWadDown(memFloatingAssetsAverage) <=
          uint256(
            (market.fixedBorrowThreshold() *
              ((((market.curveFactor() *
                int256(
                  (maturity - block.timestamp - (FixedLib.INTERVAL - (block.timestamp % FixedLib.INTERVAL)) + 1)
                    .divWadDown(maxTime)
                ).lnWad()) / 1e18).expWad() * market.minThresholdFactor()) / 1e18).expWad()) / 1e18
          ) &&
          market.floatingBackupBorrowed() + amounts[i] <=
          memFloatingAssetsAverage.mulWadDown(uint256(market.fixedBorrowThreshold()))
        : true;
      if (amounts[i] == 0) {
        vm.expectRevert(ZeroBorrow.selector);
      } else if (!canBorrow) vm.expectRevert(InsufficientProtocolLiquidity.selector);
      uint256 assetsOwed = market.borrowAtMaturity(
        maturity,
        amounts[i],
        type(uint256).max,
        address(this),
        address(this)
      );
      if (assetsOwed > 0) {
        assertLe(
          market.floatingBackupBorrowed(),
          memFloatingAssetsAverage.mulWadDown(uint256(market.fixedBorrowThreshold()))
        );
      }
    }
  }

  function testPausable() external {
    assertFalse(market.paused());
    market.grantRole(market.PAUSER_ROLE(), address(this));
    market.pause();
    assertTrue(market.paused());
    market.unpause();
    assertFalse(market.paused());
  }

  function testFullPause() external {
    market.grantRole(market.PAUSER_ROLE(), address(this));

    market.deposit(10 ether, address(this));
    market.pause();
    vm.expectRevert(bytes(""));
    market.deposit(10 ether, address(this));

    market.unpause();
    market.withdraw(1 ether, address(this), address(this));
    market.pause();
    vm.expectRevert(bytes(""));
    market.withdraw(1 ether, address(this), address(this));

    market.unpause();
    market.borrow(2 ether, address(this), address(this));
    market.pause();
    vm.expectRevert(bytes(""));
    market.borrow(2 ether, address(this), address(this));

    market.unpause();
    market.repay(1 ether, address(this));
    market.pause();
    vm.expectRevert(bytes(""));
    market.repay(1 ether, address(this));

    market.unpause();
    market.refund(1 ether, address(this));
    market.pause();
    vm.expectRevert(bytes(""));
    market.refund(1 ether, address(this));

    market.unpause();
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
    market.pause();
    vm.expectRevert(bytes(""));
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));

    market.unpause();
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    market.pause();
    vm.expectRevert(bytes(""));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));

    market.unpause();
    market.depositAtMaturity(FixedLib.INTERVAL, 2 ether, 2 ether, address(this));
    skip(FixedLib.INTERVAL);
    market.withdrawAtMaturity(FixedLib.INTERVAL, 0.5 ether, 0.5 ether, address(this), address(this));
    market.pause();
    vm.expectRevert(bytes(""));
    market.withdrawAtMaturity(FixedLib.INTERVAL, 0.5 ether, 0.5 ether, address(this), address(this));

    market.unpause();
    market.borrowAtMaturity(FixedLib.INTERVAL * 2, 1 ether, 2 ether, address(this), address(this));
    market.repayAtMaturity(FixedLib.INTERVAL * 2, 1 ether, 2 ether, address(this));
    market.pause();
    vm.expectRevert(bytes(""));
    market.repayAtMaturity(FixedLib.INTERVAL * 2, 1 ether, 2 ether, address(this));

    // liquidate
    market.unpause();
    marketWETH.deposit(1 ether, BOB);
    daiPriceFeed.setPrice(0.0001e18);
    vm.startPrank(BOB);
    auditor.enterMarket(marketWETH);
    market.borrow(5 ether, BOB, BOB);
    vm.stopPrank();

    daiPriceFeed.setPrice(0.2e18);
    market.liquidate(BOB, 1 ether, marketWETH);

    market.pause();
    vm.expectRevert(bytes(""));
    market.liquidate(BOB, 1 ether, marketWETH);
    market.unpause();

    marketWETH.grantRole(marketWETH.PAUSER_ROLE(), address(this));
    marketWETH.pause();
    vm.expectRevert(bytes(""));
    market.liquidate(BOB, 1 ether, marketWETH);
    marketWETH.unpause();

    market.redeem(1 ether, address(this), address(this));
    market.pause();
    vm.expectRevert(bytes(""));
    market.redeem(1 ether, address(this), address(this));

    market.unpause();
    market.transfer(BOB, 1 ether);
    market.pause();
    vm.expectRevert(bytes(""));
    market.transfer(BOB, 1 ether);

    market.unpause();
    market.approve(BOB, type(uint256).max);
    vm.prank(BOB);
    market.transferFrom(address(this), BOB, 1 ether);

    market.pause();
    vm.prank(BOB);
    vm.expectRevert(bytes(""));
    market.transferFrom(address(this), BOB, 1 ether);
  }

  function testPauserRole() external {
    assertFalse(market.hasRole(market.PAUSER_ROLE(), address(this)));
    market.grantRole(market.PAUSER_ROLE(), address(this));
    assertTrue(market.hasRole(market.PAUSER_ROLE(), address(this)));
  }

  function testInitiallyUnfrozen() external view {
    assertFalse(market.isFrozen());
  }

  function testOnlyAdminCanFreezeUnfreeze() external {
    vm.startPrank(BOB);
    vm.expectRevert(bytes(""));
    market.setFrozen(false);
    vm.expectRevert(bytes(""));
    market.setFrozen(false);
    vm.stopPrank();

    market.setFrozen(true);
    assertTrue(market.isFrozen());
    market.setFrozen(false);
    assertFalse(market.isFrozen());
  }

  function testDepositWhenFrozen() external {
    market.setFrozen(true);
    vm.expectRevert(MarketFrozen.selector);
    market.deposit(10 ether, address(this));
  }

  function testDepositAtMaturityWhenFrozen() external {
    market.setFrozen(true);
    vm.expectRevert(MarketFrozen.selector);
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
  }

  function testDepositAfterFreezing() external {
    market.setFrozen(true);
    market.setFrozen(false);
    market.deposit(10 ether, address(this));
  }

  function testDepositAtMaturityAfterFreezing() external {
    market.setFrozen(true);
    market.setFrozen(false);
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
  }

  function testBorrowWhenFrozen() external {
    market.setFrozen(true);
    vm.expectRevert(MarketFrozen.selector);
    market.borrow(1 ether, address(this), address(this));
  }

  function testBorrowAtMaturityWhenFrozen() external {
    market.setFrozen(true);
    vm.expectRevert(MarketFrozen.selector);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this), address(this));
  }

  function testBorrowAfterFreezing() external {
    market.deposit(2 ether, address(this));
    market.setFrozen(true);
    market.setFrozen(false);
    market.borrow(1 ether, address(this), address(this));
  }

  function testBorrowAtMaturityAfterFreezing() external {
    market.deposit(2 ether, address(this));
    market.setFrozen(true);
    market.setFrozen(false);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));
  }

  function testRepayWhenFrozen() external {
    market.deposit(2 ether, address(this));
    market.borrow(1 ether, address(this), address(this));
    market.setFrozen(true);
    market.repay(1 ether, address(this));
  }

  function testWithdrawWhenFrozen() external {
    market.deposit(2 ether, address(this));
    market.setFrozen(true);
    market.withdraw(2 ether, address(this), address(this));
  }

  function testLiquidateWhenFrozen() external {
    market.deposit(10 ether, address(this));
    marketWETH.deposit(1 ether, BOB);
    daiPriceFeed.setPrice(0.0001e18);
    vm.startPrank(BOB);
    auditor.enterMarket(marketWETH);
    market.borrow(5 ether, BOB, BOB);
    vm.stopPrank();

    market.setFrozen(true);
    daiPriceFeed.setPrice(0.2e18);
    market.liquidate(BOB, 1 ether, marketWETH);
  }

  function testEmitFrozen() external {
    vm.expectEmit(true, true, true, true, address(market));
    emit Frozen(address(this), true);
    market.setFrozen(true);

    vm.expectEmit(true, true, true, true, address(market));
    emit Frozen(address(this), false);
    market.setFrozen(false);
  }

  function testAuditorSequencerDown() external {
    MockSequencerFeed mockSequencerFeed = new MockSequencerFeed();
    mockSequencerFeed.setAnswer(1);

    auditor.setSequencerFeed(mockSequencerFeed);

    market.deposit(1 ether, address(this));
    vm.expectRevert(SequencerDown.selector);
    market.borrow(0.1 ether, address(this), address(this));
  }

  function testAuditorSequencerGracePeriodNotOver() external {
    MockSequencerFeed mockSequencerFeed = new MockSequencerFeed();
    mockSequencerFeed.setStartedAt(1);

    auditor.setSequencerFeed(mockSequencerFeed);

    market.deposit(1 ether, address(this));
    vm.expectRevert(GracePeriodNotOver.selector);
    market.borrow(0.1 ether, address(this), address(this));
  }

  function testEmergencyAdminRole() external {
    assertFalse(market.hasRole(market.EMERGENCY_ADMIN_ROLE(), address(this)));
    vm.expectRevert(NotPausingRole.selector);
    market.pause();

    market.grantRole(market.EMERGENCY_ADMIN_ROLE(), address(this));
    assertFalse(market.paused());
    // emergency admin can pause without having the pauser role
    assertFalse(market.hasRole(market.PAUSER_ROLE(), address(this)));
    market.pause();
    assertTrue(market.paused());

    // but emergency admin can not unpause
    vm.expectRevert(bytes(""));
    market.unpause();

    // pauser can unpause
    market.grantRole(market.PAUSER_ROLE(), address(this));
    assertTrue(market.hasRole(market.PAUSER_ROLE(), address(this)));
    market.unpause();
    assertFalse(market.paused());
  }

  event MarketUpdate(
    uint256 timestamp,
    uint256 floatingDepositShares,
    uint256 floatingAssets,
    uint256 floatingBorrowShares,
    uint256 floatingDebt,
    uint256 earningsAccumulator
  );
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
    uint256 positionAssets,
    uint256 assets
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
  event Borrow(
    address indexed caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 shares
  );
  event Repay(address indexed caller, address indexed borrower, uint256 assets, uint256 shares);
  event Liquidate(
    address indexed receiver,
    address indexed borrower,
    uint256 repaidAssets,
    uint256 lendersAssets,
    Market indexed seizeMarket,
    uint256 seizedAssets
  );
  event SpreadBadDebt(address indexed borrower, uint256 assets);
  event Frozen(address indexed account, bool isFrozen);
}

contract MarketHarness is Market {
  constructor(ERC20 asset_, Auditor auditor_, MarketParams memory p) Market(asset_, auditor_) {
    // solhint-disable-next-line no-inline-assembly
    assembly {
      sstore(0, 0xffff)
    }
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    setMaxFuturePools(p.maxFuturePools);
    setEarningsAccumulatorSmoothFactor(p.earningsAccumulatorSmoothFactor);
    setInterestRateModel(p.interestRateModel);
    setPenaltyRate(p.penaltyRate);
    setBackupFeeRate(p.backupFeeRate);
    setReserveFactor(p.reserveFactor);
    setDampSpeed(p.floatingAssetsDampSpeedUp, p.floatingAssetsDampSpeedDown, p.uDampSpeedUp, p.uDampSpeedDown);
    setFixedBorrowFactors(p.fixedBorrowThreshold, p.curveFactor, p.minThresholdFactor);
  }

  function setSupply(uint256 supply) external {
    totalSupply = supply;
  }

  function setFloatingAssets(uint256 balance) external {
    floatingAssets = balance;
  }
}
