// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts-v4/utils/math/Math.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Market, InsufficientProtocolLiquidity } from "../contracts/Market.sol";
import { InterestRateModel, AlreadyMatured, Parameters } from "../contracts/InterestRateModel.sol";
import { Auditor, InsufficientAccountLiquidity, IPriceFeed } from "../contracts/Auditor.sol";
import { RewardsController } from "../contracts/RewardsController.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import { Previewer } from "../contracts/periphery/Previewer.sol";
import { FixedLib } from "../contracts/utils/FixedLib.sol";
import { MockBorrowRate } from "../contracts/mocks/MockBorrowRate.sol";

contract PreviewerTest is Test {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;

  address internal constant BOB = address(69);
  address internal constant ALICE = address(70);

  Market internal market;
  Auditor internal auditor;
  MockERC20 internal asset;
  MockERC20 internal rewardAsset;
  MockPriceFeed internal ethPriceFeed;
  MockPriceFeed internal daiPriceFeed;
  MockPriceFeed internal opPriceFeed;
  Previewer internal previewer;
  InterestRateModel internal irm;

  function setUp() external {
    asset = new MockERC20("Dai Stablecoin", "DAI", 18);
    rewardAsset = new MockERC20("OP", "OP", 18);
    ethPriceFeed = new MockPriceFeed(8, 1_000e8);
    daiPriceFeed = new MockPriceFeed(18, 1e18);
    opPriceFeed = new MockPriceFeed(18, 2e18);

    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    vm.label(address(auditor), "Auditor");

    market = Market(address(new ERC1967Proxy(address(new Market(asset, auditor)), "")));
    irm = new InterestRateModel(
      Parameters({
        minRate: 3.5e16,
        naturalRate: 8e16,
        maxUtilization: 1.1e18,
        naturalUtilization: 0.75e18,
        growthSpeed: 1.1e18,
        sigmoidSpeed: 1.5e18,
        spreadFactor: 0.2e18,
        maturitySpeed: 0.5e18,
        timePreference: 0.01e18,
        fixedAllocation: 0.3e18,
        maxRate: 150e16
      }),
      market
    );
    market.initialize("", 12, 1e18, irm, 0.02e18 / uint256(1 days), 0.1e18, 0, 0.0046e18, 0.42e18);
    vm.label(address(market), "MarketDAI");
    auditor.enableMarket(market, daiPriceFeed, 0.8e18);

    vm.label(BOB, "Bob");
    vm.label(ALICE, "Alice");
    asset.mint(BOB, 50_000 ether);
    asset.mint(ALICE, 50_000 ether);
    asset.mint(address(this), 50_000 ether);
    asset.approve(address(market), 50_000 ether);
    vm.prank(BOB);
    asset.approve(address(market), 50_000 ether);
    vm.prank(ALICE);
    asset.approve(address(market), 50_000 ether);

    previewer = new Previewer(auditor, ethPriceFeed);
  }

  function testPreviewDepositAtMaturityReturningAccurateAmount() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10 ether, address(this));
    vm.warp(200 seconds);
    market.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    Previewer.FixedPreview memory preview = previewer.previewDepositAtMaturity(market, maturity, 1 ether);
    market.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));
    (uint256 principalAfterDeposit, uint256 earningsAfterDeposit) = market.fixedDepositPositions(
      maturity,
      address(this)
    );

    assertEq(preview.assets, principalAfterDeposit + earningsAfterDeposit);
  }

  function testPreviewDepositAtAllMaturitiesReturningAccurateAmounts() external {
    uint256 firstMaturity = FixedLib.INTERVAL;
    uint256 secondMaturity = FixedLib.INTERVAL * 2;
    uint256 thirdMaturity = FixedLib.INTERVAL * 3;
    market.deposit(10 ether, address(this));
    vm.warp(200 seconds);
    market.borrowAtMaturity(firstMaturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(500 seconds);
    market.borrowAtMaturity(secondMaturity, 0.389 ether, 1 ether, address(this), address(this));

    vm.warp(1 days);
    market.borrowAtMaturity(thirdMaturity, 2.31 ether, 3 ether, address(this), address(this));

    vm.warp(2 days + 3 hours);
    market.depositAtMaturity(thirdMaturity, 1.1 ether, 1.1 ether, BOB);

    vm.warp(3 days);
    Previewer.FixedPreview[] memory positionAssetsMaturities = previewer.previewDepositAtAllMaturities(market, 1 ether);

    market.depositAtMaturity(firstMaturity, 1 ether, 1 ether, address(this));
    (uint256 principalAfterDeposit, uint256 earningsAfterDeposit) = market.fixedDepositPositions(
      firstMaturity,
      address(this)
    );
    assertEq(positionAssetsMaturities[0].maturity, firstMaturity);
    assertEq(positionAssetsMaturities[0].assets, principalAfterDeposit + earningsAfterDeposit);

    market.depositAtMaturity(secondMaturity, 1 ether, 1 ether, address(this));
    (principalAfterDeposit, earningsAfterDeposit) = market.fixedDepositPositions(secondMaturity, address(this));
    assertEq(positionAssetsMaturities[1].maturity, secondMaturity);
    assertEq(positionAssetsMaturities[1].assets, principalAfterDeposit + earningsAfterDeposit);

    positionAssetsMaturities = previewer.previewDepositAtAllMaturities(market, 0.18239 ether);
    market.depositAtMaturity(thirdMaturity, 0.18239 ether, 0.18239 ether, address(this));
    (principalAfterDeposit, earningsAfterDeposit) = market.fixedDepositPositions(thirdMaturity, address(this));
    assertEq(positionAssetsMaturities[2].maturity, thirdMaturity);
    assertEq(positionAssetsMaturities[2].assets, principalAfterDeposit + earningsAfterDeposit);
  }

  function testPreviewDepositAtMaturityWithZeroAmount() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10 ether, address(this));
    vm.warp(120 seconds);
    market.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    Previewer.FixedPreview memory preview = previewer.previewDepositAtMaturity(market, maturity, 0);

    assertEq(preview.assets, 0);
  }

  function testPreviewDepositAtMaturityWithOneUnit() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10 ether, address(this));
    vm.warp(120 seconds);
    market.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(3 days);
    Previewer.FixedPreview memory preview = previewer.previewDepositAtMaturity(market, maturity, 1);

    assertEq(preview.assets, 1);
  }

  function testPreviewDepositAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10 ether, address(this));
    vm.warp(150 seconds);
    market.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.warp(2 days);
    market.borrowAtMaturity(maturity, 2.3 ether, 3 ether, address(this), address(this));

    vm.warp(3 days);
    Previewer.FixedPreview memory preview = previewer.previewDepositAtMaturity(market, maturity, 0.47 ether);
    market.depositAtMaturity(maturity, 0.47 ether, 0.47 ether, address(this));
    (uint256 principalAfterDeposit, uint256 earningsAfterDeposit) = market.fixedDepositPositions(
      maturity,
      address(this)
    );
    assertEq(preview.assets, principalAfterDeposit + earningsAfterDeposit);

    vm.warp(5 days);
    preview = previewer.previewDepositAtMaturity(market, maturity, 1 ether);
    market.depositAtMaturity(maturity, 1 ether, 1 ether, BOB);
    (principalAfterDeposit, earningsAfterDeposit) = market.fixedDepositPositions(maturity, BOB);
    assertEq(preview.assets, principalAfterDeposit + earningsAfterDeposit);

    vm.warp(6 days);
    preview = previewer.previewDepositAtMaturity(market, maturity, 20 ether);
    market.depositAtMaturity(maturity, 20 ether, 20 ether, ALICE);
    (principalAfterDeposit, earningsAfterDeposit) = market.fixedDepositPositions(maturity, ALICE);
    assertEq(preview.assets, principalAfterDeposit + earningsAfterDeposit);
  }

  function testPreviewDepositAtMaturityWithEmptyMaturity() external view {
    Previewer.FixedPreview memory preview = previewer.previewDepositAtMaturity(market, FixedLib.INTERVAL, 1 ether);
    assertEq(preview.assets, 1 ether);
  }

  function testPreviewDepositAtMaturityWithEmptyMaturityAndZeroAmount() external view {
    Previewer.FixedPreview memory preview = previewer.previewDepositAtMaturity(market, FixedLib.INTERVAL, 0);
    assertEq(preview.assets, 0);
  }

  function testPreviewDepositAtMaturityWithInvalidMaturity() external view {
    Previewer.FixedPreview memory preview = previewer.previewDepositAtMaturity(market, 376 seconds, 1 ether);
    assertEq(preview.assets, 1 ether);
  }

  function testPreviewDepositAtMaturityWithSameTimestamp() external {
    uint256 maturity = FixedLib.INTERVAL;
    vm.warp(maturity);
    Previewer.FixedPreview memory preview = previewer.previewDepositAtMaturity(market, maturity, 1 ether);
    assertEq(preview.assets, 1 ether);
  }

  function testPreviewDepositAtMaturityWithMaturedMaturity() external {
    uint256 maturity = FixedLib.INTERVAL;
    vm.warp(maturity + 1);
    vm.expectRevert(AlreadyMatured.selector);
    previewer.previewDepositAtMaturity(market, maturity, 1 ether);
  }

  function testPreviewBorrowAtAllMaturitiesReturningAccurateAmount() external {
    uint256 firstMaturity = FixedLib.INTERVAL;
    uint256 secondMaturity = FixedLib.INTERVAL * 2;
    uint256 thirdMaturity = FixedLib.INTERVAL * 3;
    market.deposit(10 ether, address(this));
    vm.startPrank(BOB);
    market.deposit(10 ether, BOB);
    vm.warp(200 seconds);
    market.borrowAtMaturity(firstMaturity, 1 ether, 2 ether, BOB, BOB);
    vm.warp(500 seconds);
    market.borrowAtMaturity(secondMaturity, 0.389 ether, 1 ether, BOB, BOB);
    vm.warp(1 days);
    market.borrowAtMaturity(thirdMaturity, 2.31 ether, 3 ether, BOB, BOB);
    vm.warp(2 days + 3 hours);
    market.depositAtMaturity(thirdMaturity, 1.1 ether, 1.1 ether, BOB);
    vm.stopPrank();

    vm.warp(3 days);
    Previewer.FixedPreview[] memory positionAssetsMaturities = previewer.previewBorrowAtAllMaturities(market, 1 ether);

    market.borrowAtMaturity(firstMaturity, 1 ether, 2 ether, address(this), address(this));
    (uint256 principalAfterBorrow, uint256 feesAfterBorrow) = market.fixedBorrowPositions(firstMaturity, address(this));
    assertEq(positionAssetsMaturities[0].maturity, firstMaturity);
    assertEq(positionAssetsMaturities[0].assets, principalAfterBorrow + feesAfterBorrow);

    positionAssetsMaturities = previewer.previewBorrowAtAllMaturities(market, 1 ether);
    market.borrowAtMaturity(secondMaturity, 1 ether, 2 ether, address(this), address(this));
    (principalAfterBorrow, feesAfterBorrow) = market.fixedBorrowPositions(secondMaturity, address(this));
    assertEq(positionAssetsMaturities[1].maturity, secondMaturity);
    assertEq(positionAssetsMaturities[1].assets, principalAfterBorrow + feesAfterBorrow);

    positionAssetsMaturities = previewer.previewBorrowAtAllMaturities(market, 0.18239 ether);
    market.borrowAtMaturity(thirdMaturity, 0.18239 ether, 2 ether, address(this), address(this));
    (principalAfterBorrow, feesAfterBorrow) = market.fixedBorrowPositions(thirdMaturity, address(this));
    assertEq(positionAssetsMaturities[2].maturity, thirdMaturity);
    assertEq(positionAssetsMaturities[2].assets, principalAfterBorrow + feesAfterBorrow);
  }

  function testPreviewBorrowAtMaturityReturningAccurateAmount() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10 ether, address(this));
    vm.warp(180 seconds);
    Previewer.FixedPreview memory preview = previewer.previewBorrowAtMaturity(market, maturity, 1 ether);
    market.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));
    (uint256 principalAfterBorrow, uint256 feesAfterBorrow) = market.fixedBorrowPositions(maturity, address(this));

    assertEq(preview.assets, principalAfterBorrow + feesAfterBorrow);
  }

  function testPreviewBorrowAtMaturityReturningAccurateUtilization() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10 ether, address(this));
    vm.warp(180 seconds);
    Previewer.FixedPreview memory preview = previewer.previewBorrowAtMaturity(market, maturity, 1 ether);
    assertEq(preview.utilization, uint256(1 ether).divWadUp(previewFloatingAssetsAverage(maturity)));

    market.depositAtMaturity(maturity, 1.47 ether, 1.47 ether, address(this));
    vm.warp(5301 seconds);
    preview = previewer.previewBorrowAtMaturity(market, maturity, 2.33 ether);

    assertEq(preview.utilization, uint256(2.33 ether).divWadUp(1.47 ether + previewFloatingAssetsAverage(maturity)));
  }

  function testPreviewBorrowAtMaturityWithZeroAmount() external {
    market.deposit(10 ether, address(this));
    vm.warp(5 seconds);
    Previewer.FixedPreview memory preview = previewer.previewBorrowAtMaturity(market, FixedLib.INTERVAL, 0);
    assertEq(preview.assets, 0);
  }

  function testPreviewBorrowAtMaturityWithOneUnit() external {
    market.deposit(5 ether, address(this));
    vm.warp(100 seconds);
    market.deposit(5 ether, address(this));
    Previewer.FixedPreview memory preview = previewer.previewBorrowAtMaturity(market, FixedLib.INTERVAL, 1);
    assertEq(preview.assets, 2);
  }

  function testPreviewBorrowAtMaturityWithFiveUnits() external {
    market.deposit(5 ether, address(this));
    vm.warp(100 seconds);
    market.deposit(5 ether, address(this));
    Previewer.FixedPreview memory preview = previewer.previewBorrowAtMaturity(market, FixedLib.INTERVAL, 5);
    assertEq(preview.assets, 6);
  }

  function testPreviewBorrowAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10 ether, address(this));
    market.deposit(10 ether, BOB);
    market.deposit(50 ether, ALICE);

    vm.warp(2 days);
    Previewer.FixedPreview memory preview = previewer.previewBorrowAtMaturity(market, maturity, 2.3 ether);
    market.borrowAtMaturity(maturity, 2.3 ether, 3 ether, address(this), address(this));
    (uint256 principalAfterBorrow, uint256 feesAfterBorrow) = market.fixedBorrowPositions(maturity, address(this));
    assertEq(preview.assets, principalAfterBorrow + feesAfterBorrow);

    vm.warp(3 days);
    market.depositAtMaturity(maturity, 1.47 ether, 1.47 ether, address(this));

    vm.warp(5 days);
    preview = previewer.previewBorrowAtMaturity(market, maturity, 1 ether);
    vm.prank(BOB);
    market.borrowAtMaturity(maturity, 1 ether, 2 ether, BOB, BOB);
    (principalAfterBorrow, feesAfterBorrow) = market.fixedBorrowPositions(maturity, BOB);
    assertEq(preview.assets, principalAfterBorrow + feesAfterBorrow);

    vm.warp(6 days);
    preview = previewer.previewBorrowAtMaturity(market, maturity, 20 ether);
    vm.prank(ALICE);
    market.borrowAtMaturity(maturity, 20 ether, 30 ether, ALICE, ALICE);
    (principalAfterBorrow, feesAfterBorrow) = market.fixedBorrowPositions(maturity, ALICE);
    assertEq(preview.assets, principalAfterBorrow + feesAfterBorrow);
  }

  function testPreviewBorrowAtMaturityWithInvalidMaturity() external {
    market.deposit(10 ether, address(this));
    vm.warp(100 seconds);
    Previewer.FixedPreview memory preview = previewer.previewBorrowAtMaturity(market, 376 seconds, 1 ether);
    assertGe(preview.assets, 1 ether);
  }

  function testPreviewBorrowAtMaturityWithSameTimestamp() external {
    uint256 maturity = FixedLib.INTERVAL;
    vm.warp(maturity);
    vm.expectRevert(AlreadyMatured.selector);
    previewer.previewBorrowAtMaturity(market, maturity, 1 ether);
  }

  function testPreviewBorrowAtMaturityWithMaturedMaturity() external {
    uint256 maturity = FixedLib.INTERVAL;
    vm.warp(maturity + 1);
    vm.expectRevert(AlreadyMatured.selector);
    previewer.previewBorrowAtMaturity(market, maturity, 1 ether);
  }

  function testPreviewRepayAtMaturityReturningAccurateAmount() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10 ether, address(this));
    market.deposit(10 ether, BOB);
    vm.warp(300 seconds);
    market.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));

    vm.prank(BOB);
    market.borrowAtMaturity(maturity, 2 ether, 3 ether, BOB, BOB);

    vm.warp(3 days);
    Previewer.FixedPreview memory preview = previewer.previewRepayAtMaturity(market, maturity, 1 ether, address(this));
    uint256 balanceBeforeRepay = asset.balanceOf(address(this));
    market.repayAtMaturity(maturity, 1 ether, 1 ether, address(this));
    uint256 discountAfterRepay = 1 ether - (balanceBeforeRepay - asset.balanceOf(address(this)));

    assertEq(preview.assets, 1 ether - discountAfterRepay);
  }

  function testPreviewRepayAtMaturityWithZeroAmount() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10 ether, address(this));
    vm.warp(100 seconds);
    market.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));
    vm.warp(3 days);

    Previewer.FixedPreview memory preview = previewer.previewRepayAtMaturity(market, maturity, 0, address(this));
    assertEq(preview.assets, 0);
  }

  function testPreviewRepayAtMaturityWithOneUnit() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10 ether, address(this));
    vm.warp(100 seconds);
    market.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));
    vm.warp(3 days);

    Previewer.FixedPreview memory preview = previewer.previewRepayAtMaturity(market, maturity, 1, address(this));
    assertEq(preview.assets, 1);
  }

  function testPreviewRepayAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10 ether, address(this));
    market.deposit(10 ether, BOB);
    vm.warp(200 seconds);
    market.borrowAtMaturity(maturity, 3 ether, 4 ether, address(this), address(this));

    vm.warp(2 days);
    vm.prank(BOB);
    market.borrowAtMaturity(maturity, 2.3 ether, 3 ether, BOB, BOB);

    vm.warp(3 days);
    Previewer.FixedPreview memory preview = previewer.previewRepayAtMaturity(
      market,
      maturity,
      0.47 ether,
      address(this)
    );
    uint256 balanceBeforeRepay = asset.balanceOf(address(this));
    market.repayAtMaturity(maturity, 0.47 ether, 0.47 ether, address(this));
    uint256 discountAfterRepay = 0.47 ether - (balanceBeforeRepay - asset.balanceOf(address(this)));
    assertEq(preview.assets, 0.47 ether - discountAfterRepay);

    vm.warp(5 days);
    preview = previewer.previewRepayAtMaturity(market, maturity, 1.1 ether, address(this));
    balanceBeforeRepay = asset.balanceOf(address(this));
    market.repayAtMaturity(maturity, 1.1 ether, 1.1 ether, address(this));
    discountAfterRepay = 1.1 ether - (balanceBeforeRepay - asset.balanceOf(address(this)));
    assertEq(preview.assets, 1.1 ether - discountAfterRepay);

    vm.warp(6 days);
    (uint256 bobOwedPrincipal, uint256 bobOwedFee) = market.fixedBorrowPositions(maturity, BOB);
    uint256 totalOwedBob = bobOwedPrincipal + bobOwedFee;
    preview = previewer.previewRepayAtMaturity(market, maturity, totalOwedBob, BOB);
    balanceBeforeRepay = asset.balanceOf(BOB);
    vm.prank(BOB);
    market.repayAtMaturity(maturity, totalOwedBob, totalOwedBob, BOB);
    discountAfterRepay = totalOwedBob - (balanceBeforeRepay - asset.balanceOf(BOB));
    (bobOwedPrincipal, ) = market.fixedBorrowPositions(maturity, BOB);
    assertEq(preview.assets, totalOwedBob - discountAfterRepay);
    assertEq(bobOwedPrincipal, 0);
  }

  function testFixedPoolsA() external {
    uint256 maxFuturePools = market.maxFuturePools();
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    Market marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "",
      12,
      1e18,
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
        marketWETH
      ),
      0.02e18 / uint256(1 days),
      0.1e18,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.7e18);
    ethPriceFeed.setPrice(2800e18);
    daiPriceFeed.setPrice(0.0003571428571e18);
    weth.mint(address(this), 50_000 ether);
    weth.approve(address(marketWETH), 50_000 ether);
    marketWETH.deposit(50_000 ether, address(this));
    auditor.enterMarket(marketWETH);

    // supply 100 to the smart pool
    market.deposit(100 ether, address(this));
    // let 9011 seconds go by so floatingAssetsAverage is equal to floatingDepositAssets
    vm.warp(9012 seconds);

    // borrow 10 from the first maturity
    market.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, 15 ether, address(this), address(this));
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    for (uint256 i = 0; i < maxFuturePools; i++) {
      // MarketDAI
      assertEq(data[0].fixedPools[i].maturity, FixedLib.INTERVAL + FixedLib.INTERVAL * i);
      assertEq(data[0].fixedPools[i].available, 90 ether);
      // MarketWETH
      assertEq(data[1].fixedPools[i].maturity, FixedLib.INTERVAL + FixedLib.INTERVAL * i);
      assertEq(data[1].fixedPools[i].available, 50_000 ether);
    }

    // deposit 50 ether in the first maturity
    market.depositAtMaturity(FixedLib.INTERVAL, 50 ether, 50 ether, address(this));
    data = previewer.exactly(address(this));
    for (uint256 i = 0; i < maxFuturePools; i++) {
      if (i == 0) assertEq(data[0].fixedPools[i].available, 140 ether);
      else assertEq(data[0].fixedPools[i].available, 100 ether);
    }

    // deposit 100 ether in the second maturity
    market.depositAtMaturity(FixedLib.INTERVAL * 2, 100 ether, 100 ether, address(this));
    data = previewer.exactly(address(this));
    for (uint256 i = 0; i < maxFuturePools; i++) {
      if (i == 0) assertEq(data[0].fixedPools[i].available, 140 ether);
      else if (i == 1) assertEq(data[0].fixedPools[i].available, 200 ether);
      else assertEq(data[0].fixedPools[i].available, 100 ether);
    }
    // try to borrow 140 ether + 1 (ONE UNIT) from first maturity and it should fail
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.borrowAtMaturity(FixedLib.INTERVAL, 140 ether + 1, 250 ether, address(this), address(this));
    // try to borrow 200 ether + 1 (ONE UNIT) from second maturity and it should fail
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.borrowAtMaturity(FixedLib.INTERVAL * 2, 200 ether + 1, 2_500 ether, address(this), address(this));
    // try to borrow 100 ether + 1 (ONE UNIT) from any other maturity and it should fail
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.borrowAtMaturity(FixedLib.INTERVAL * 7, 100 ether + 1, 2_500 ether, address(this), address(this));

    // finally borrow 200 ether from second maturity and it doesn't fail
    market.borrowAtMaturity(FixedLib.INTERVAL * 2, 200 ether, 2_500 ether, address(this), address(this));

    // repay back the 10 borrowed from the first maturity
    uint256 totalBorrowed = data[0].fixedBorrowPositions[0].position.principal +
      data[0].fixedBorrowPositions[0].position.fee;
    market.repayAtMaturity(FixedLib.INTERVAL, totalBorrowed, totalBorrowed, address(this));
    data = previewer.exactly(address(this));
    for (uint256 i = 0; i < maxFuturePools; i++) {
      if (i == 0) assertEq(data[0].fixedPools[i].available, 50 ether);
      else assertEq(data[0].fixedPools[i].available, 0 ether);
    }

    // supply 100 more to the smart pool
    market.deposit(100 ether, address(this));
    uint256 distributedEarnings = 6415907858003678;
    // set the smart pool reserve in 10%
    // since smart pool supply is 200 then 10% is 20
    market.setReserveFactor(0.1e18);
    data = previewer.exactly(address(this));
    for (uint256 i = 0; i < maxFuturePools; i++) {
      if (i == 0) assertEq(data[0].fixedPools[i].available, 80 ether + 50 ether + distributedEarnings);
      else assertEq(data[0].fixedPools[i].available, 80 ether + distributedEarnings);
    }

    // borrow 20 from the flexible borrow pool
    market.borrow(20 ether, address(this), address(this));
    data = previewer.exactly(address(this));
    for (uint256 i = 0; i < maxFuturePools; i++) {
      if (i == 0) assertEq(data[0].fixedPools[i].available, 130 ether + distributedEarnings - 20 ether);
      else assertEq(data[0].fixedPools[i].available, 80 ether + distributedEarnings - 20 ether);
    }
  }

  function testFixedPoolsRatesAndUtilizations() external {
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    Market marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "WETH",
      12,
      1e18,
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
        marketWETH
      ),
      0.02e18 / uint256(1 days),
      0.1e18,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.7e18);
    ethPriceFeed.setPrice(2800e18);
    daiPriceFeed.setPrice(0.0003571428571e18);
    weth.mint(address(this), 50_000 ether);
    weth.approve(address(marketWETH), 50_000 ether);
    marketWETH.deposit(50_000 ether, address(this));
    auditor.enterMarket(marketWETH);
    market.deposit(100 ether, address(this));

    // let 9012 seconds go by so floatingAssetsAverage is equal to floatingDepositAssets
    vm.warp(9012 seconds);

    // borrow 10 from the first maturity of marketDAI
    market.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, 15 ether, address(this), address(this));
    // borrow 200 from the second maturity of marketWETH
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL * 2, 200 ether, 300 ether, address(this), address(this));

    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    uint256 depositRate = 33432052065142420;
    // MarketDAI
    assertEq(data[0].fixedPools[0].optimalDeposit, 10 ether);
    assertEq(data[0].fixedPools[0].minBorrowRate, 37146724516824931);
    assertEq(data[0].fixedPools[0].depositRate, depositRate);
    assertEq(data[0].fixedPools[0].utilization, 0.1 ether);
    assertEq(data[0].fixedPools[1].optimalDeposit, 0);
    assertEq(data[0].fixedPools[1].minBorrowRate, 32312833259717580);
    assertEq(data[0].fixedPools[1].depositRate, 0);
    assertEq(data[0].fixedPools[1].utilization, 0);
    // MarketWETH
    assertEq(data[1].fixedPools[0].optimalDeposit, 0);
    assertEq(data[1].fixedPools[0].minBorrowRate, 33083889313081921);
    assertEq(data[1].fixedPools[0].depositRate, 0);
    assertEq(data[1].fixedPools[0].utilization, 0);
    assertEq(data[1].fixedPools[1].optimalDeposit, 200 ether);
    assertEq(data[1].fixedPools[1].minBorrowRate, 37997829162598044);
    assertEq(data[1].fixedPools[1].depositRate, 34198046246338230);
    assertEq(data[1].fixedPools[1].utilization, 0.004 ether);

    vm.warp(block.timestamp + 1 days);
    data = previewer.exactly(address(this));
    assertApproxEqAbs(data[0].fixedPools[0].depositRate, depositRate, 11);

    vm.warp(block.timestamp + 3 hours + 4 minutes + 19 minutes);
    data = previewer.exactly(address(this));
    assertApproxEqAbs(data[0].fixedPools[0].depositRate, depositRate, 11);
  }

  function testRewardsRateX() external {
    RewardsController rewardsController = RewardsController(
      address(new ERC1967Proxy(address(new RewardsController()), ""))
    );
    rewardsController.initialize();
    rewardAsset.mint(address(rewardsController), 500_000 ether);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: market,
      reward: rewardAsset,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    market.setRewardsController(rewardsController);
    uint256 deltaTime = 1 hours;
    uint256 depositAmount = 10_000 ether;
    uint256 floatingBorrowAmount = 2_000 ether;
    uint256 fixedBorrowAmount = 1_000 ether;
    market.deposit(depositAmount, address(this));
    market.borrow(floatingBorrowAmount, address(this), address(this));
    vm.warp(block.timestamp + 10_000 seconds);
    market.borrowAtMaturity(FixedLib.INTERVAL, fixedBorrowAmount, 2_000 ether, address(this), address(this));
    vm.warp(block.timestamp + 1 weeks);
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].rewardRates.length, 1);
    assertEq(address(data[0].rewardRates[0].asset), address(rewardAsset));
    assertEq(data[0].rewardRates[0].assetName, rewardAsset.name());
    assertEq(data[0].rewardRates[0].assetSymbol, rewardAsset.symbol());

    uint256 newDepositRewards = 17985931229760000;
    uint256 newDepositRewardsValue = newDepositRewards.mulDivDown(
      uint256(opPriceFeed.latestAnswer()),
      10 ** opPriceFeed.decimals()
    );
    uint256 annualRewardValue = newDepositRewardsValue.mulDivDown(365 days, deltaTime);
    assertApproxEqAbs(data[0].rewardRates[0].floatingDeposit, annualRewardValue.mulDivDown(1e18, depositAmount), 1e4);

    uint256 newFloatingBorrowRewards = 238622379993700;
    uint256 newFloatingBorrowRewardsValue = newFloatingBorrowRewards.mulDivDown(
      uint256(opPriceFeed.latestAnswer()),
      10 ** opPriceFeed.decimals()
    );
    annualRewardValue = newFloatingBorrowRewardsValue.mulDivDown(365 days, deltaTime);
    assertApproxEqAbs(data[0].rewardRates[0].borrow, annualRewardValue.mulDivDown(1e18, floatingBorrowAmount), 3e17);

    assertEq(data[0].rewardRates[0].maturities[0], FixedLib.INTERVAL);
    assertEq(data[0].rewardRates[0].maturities.length, 12);
    market.setMaxFuturePools(3);
    data = previewer.exactly(address(this));
    assertEq(data[0].rewardRates[0].maturities[0], FixedLib.INTERVAL);
    assertEq(data[0].rewardRates[0].maturities[1], FixedLib.INTERVAL * 2);
    assertEq(data[0].rewardRates[0].maturities[2], FixedLib.INTERVAL * 3);
    assertEq(data[0].rewardRates[0].maturities.length, 3);

    // claimable rewards
    assertEq(data[0].claimableRewards.length, 1);
    assertEq(data[0].claimableRewards[0].asset, address(rewardAsset));
    assertEq(data[0].claimableRewards[0].assetName, rewardAsset.name());
    assertEq(data[0].claimableRewards[0].assetSymbol, rewardAsset.symbol());
    assertEq(data[0].claimableRewards[0].amount, rewardsController.allClaimable(address(this), rewardAsset));
  }

  function testRewardsRateWithDifferentRewardLengths() external {
    MockERC20 exa = new MockERC20("EXA", "EXA", 18);
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    weth.mint(address(this), 1_000 ether);
    Market marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "WETH",
      12,
      1e18,
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
        marketWETH
      ),
      0.02e18 / uint256(1 days),
      0.1e18,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.7e18);
    weth.approve(address(marketWETH), type(uint256).max);

    RewardsController rewardsController = RewardsController(
      address(new ERC1967Proxy(address(new RewardsController()), ""))
    );
    rewardsController.initialize();
    rewardAsset.mint(address(rewardsController), 500_000 ether);
    exa.mint(address(rewardsController), 500_000 ether);
    RewardsController.Config[] memory configs = new RewardsController.Config[](3);
    configs[0] = RewardsController.Config({
      market: market,
      reward: rewardAsset,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    configs[1] = RewardsController.Config({
      market: market,
      reward: exa,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    configs[2] = RewardsController.Config({
      market: marketWETH,
      reward: exa,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    market.setRewardsController(rewardsController);
    marketWETH.setRewardsController(rewardsController);

    market.deposit(1_000 ether, address(this));
    marketWETH.deposit(1_000 ether, address(this));
    market.borrow(100 ether, address(this), address(this));
    marketWETH.borrow(100 ether, address(this), address(this));
    vm.warp(block.timestamp + 1 weeks);
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].rewardRates.length, 2);
    assertEq(data[1].rewardRates.length, 1);
    assertEq(address(data[0].rewardRates[0].asset), address(rewardAsset));
    assertEq(address(data[0].rewardRates[1].asset), address(exa));
    assertEq(address(data[1].rewardRates[0].asset), address(exa));
  }

  function testRewardRatesMaturities() external {
    vm.warp(55 * 365 days);
    RewardsController rewardsController = RewardsController(
      address(new ERC1967Proxy(address(new RewardsController()), ""))
    );
    rewardsController.initialize();
    MockERC20 exa = new MockERC20("EXA", "EXA", 18);
    RewardsController.Config[] memory configs = new RewardsController.Config[](2);
    configs[0] = RewardsController.Config({
      market: market,
      reward: rewardAsset,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    configs[1] = RewardsController.Config({
      market: market,
      reward: exa,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    market.setRewardsController(rewardsController);

    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data.length, 1);
    assertEq(data[0].rewardRates.length, 2);
    assertEq(data[0].rewardRates[0].maturities.length, 12);
    assertEq(data[0].rewardRates[1].maturities.length, 12);
  }

  function testRewardsRateAfterDistributionEnd() external {
    RewardsController rewardsController = RewardsController(
      address(new ERC1967Proxy(address(new RewardsController()), ""))
    );
    rewardsController.initialize();
    rewardAsset.mint(address(rewardsController), 500_000 ether);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: market,
      reward: rewardAsset,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    market.setRewardsController(rewardsController);
    market.deposit(200 ether, address(this));
    market.borrow(50 ether, address(this), address(this));

    vm.warp(13 weeks);
    market.deposit(10 ether, address(this));
    market.borrow(10 ether, address(this), address(this));

    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertGt(data[0].rewardRates[0].floatingDeposit, 0);
    assertGt(data[0].rewardRates[0].borrow, 0);
  }

  function testRewardsRateOnlyWithFixedBorrows() external {
    RewardsController rewardsController = RewardsController(
      address(new ERC1967Proxy(address(new RewardsController()), ""))
    );
    rewardsController.initialize();
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: market,
      reward: rewardAsset,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    market.setRewardsController(rewardsController);
    market.deposit(200 ether, address(this));
    vm.warp(block.timestamp + 10_000 seconds);
    market.borrowAtMaturity(FixedLib.INTERVAL, 50 ether, 100 ether, address(this), address(this));

    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertGt(data[0].rewardRates[0].floatingDeposit, 0);
    assertGt(data[0].rewardRates[0].borrow, 0);
  }

  function testRewardsRateWithMarketWithDifferentDecimals() external {
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    Market marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "WETH",
      12,
      1e18,
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
        marketWETH
      ),
      0.02e18 / uint256(1 days),
      0.1e18,
      0,
      0.0046e18,
      0.42e18
    );
    ethPriceFeed = new MockPriceFeed(18, 1_000e18);
    auditor.enableMarket(marketWETH, ethPriceFeed, 0.7e18);
    weth.mint(address(this), 50_000 ether);
    weth.approve(address(marketWETH), 50_000 ether);
    RewardsController rewardsController = RewardsController(
      address(new ERC1967Proxy(address(new RewardsController()), ""))
    );
    rewardsController.initialize();
    rewardAsset.mint(address(rewardsController), 500_000 ether);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: marketWETH,
      reward: rewardAsset,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    marketWETH.setRewardsController(rewardsController);
    uint256 deltaTime = 1 hours;
    uint256 depositAmount = 100 ether;
    uint256 floatingBorrowAmount = 20 ether;
    uint256 fixedBorrowAmount = 1 ether;
    marketWETH.deposit(depositAmount, address(this));
    marketWETH.borrow(floatingBorrowAmount, address(this), address(this));
    vm.warp(block.timestamp + 10_000 seconds);
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, fixedBorrowAmount, 2_000 ether, address(this), address(this));
    vm.warp(block.timestamp + 1 weeks);
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[1].rewardRates.length, 1);
    assertEq(address(data[1].rewardRates[0].asset), address(rewardAsset));
    assertEq(data[1].rewardRates[0].assetName, rewardAsset.name());
    assertEq(data[1].rewardRates[0].assetSymbol, rewardAsset.symbol());

    uint256 newDepositRewards = 20354615714200;
    uint256 newDepositRewardsValue = newDepositRewards.mulWadDown(uint256(opPriceFeed.latestAnswer()));
    uint256 annualRewardValue = newDepositRewardsValue.mulDivDown(365 days, deltaTime);
    assertApproxEqAbs(
      data[1].rewardRates[0].floatingDeposit,
      annualRewardValue.mulDivDown(
        10 ** marketWETH.decimals(),
        depositAmount.mulWadDown(uint256(ethPriceFeed.latestAnswer()))
      ),
      2e14
    );

    uint256 newFloatingBorrowRewards = 379410543666460;
    uint256 newFloatingBorrowRewardsValue = newFloatingBorrowRewards.mulWadDown(uint256(opPriceFeed.latestAnswer()));
    annualRewardValue = newFloatingBorrowRewardsValue.mulDivDown(365 days, deltaTime);
    assertApproxEqAbs(
      data[1].rewardRates[0].borrow,
      annualRewardValue.mulDivDown(
        10 ** marketWETH.decimals(),
        floatingBorrowAmount.mulWadDown(uint256(ethPriceFeed.latestAnswer()))
      ),
      4e16
    );

    assertEq(data[1].rewardRates[0].maturities[0], FixedLib.INTERVAL);
    assertEq(data[1].rewardRates[0].maturities.length, 12);
    marketWETH.setMaxFuturePools(3);
    data = previewer.exactly(address(this));
    assertEq(data[1].rewardRates[0].maturities[0], FixedLib.INTERVAL);
    assertEq(data[1].rewardRates[0].maturities[1], FixedLib.INTERVAL * 2);
    assertEq(data[1].rewardRates[0].maturities[2], FixedLib.INTERVAL * 3);
    assertEq(data[1].rewardRates[0].maturities.length, 3);

    // claimable rewards
    assertEq(data[1].claimableRewards.length, 1);
    assertEq(data[1].claimableRewards[0].asset, address(rewardAsset));
    assertEq(data[1].claimableRewards[0].assetName, rewardAsset.name());
    assertEq(data[1].claimableRewards[0].assetSymbol, rewardAsset.symbol());
    assertEq(data[1].claimableRewards[0].amount, rewardsController.allClaimable(address(this), rewardAsset));
  }

  function testEmptyExactly() external {
    vm.warp(365 days);
    market.setMaxFuturePools(3);
    RewardsController rewardsController = RewardsController(
      address(new ERC1967Proxy(address(new RewardsController()), ""))
    );
    rewardsController.initialize();
    rewardAsset.mint(address(rewardsController), 500_000 ether);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: market,
      reward: rewardAsset,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 24 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    market.setRewardsController(rewardsController);
    previewer.exactly(address(this));
  }

  function testJustUpdatedRewardRatesShouldStillReturnRate() external {
    RewardsController rewardsController = RewardsController(
      address(new ERC1967Proxy(address(new RewardsController()), ""))
    );
    rewardsController.initialize();
    rewardAsset.mint(address(rewardsController), 500_000 ether);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: market,
      reward: rewardAsset,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    market.setRewardsController(rewardsController);
    market.deposit(10_000 ether, address(this));
    market.borrow(2_000 ether, address(this), address(this));
    vm.warp(block.timestamp + 1 weeks);
    market.borrow(1, address(this), address(this));
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].rewardRates.length, 1);
    assertEq(data[0].rewardRates[0].maturities.length, 12);
    assertGt(data[0].rewardRates[0].borrow, 0);
  }

  function testReturnRewardAssetUsdPrice() external {
    RewardsController rewardsController = RewardsController(
      address(new ERC1967Proxy(address(new RewardsController()), ""))
    );
    rewardsController.initialize();
    opPriceFeed = new MockPriceFeed(18, 0.002e18);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: market,
      reward: rewardAsset,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    market.setRewardsController(rewardsController);
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].rewardRates.length, 1);
    assertEq(data[0].rewardRates[0].maturities.length, 12);
    assertEq(data[0].rewardRates[0].floatingDeposit, 0);
    assertEq(data[0].rewardRates[0].borrow, 0);
    assertEq(data[0].rewardRates[0].usdPrice, 2e18);

    opPriceFeed.setPrice(0.005e18);
    data = previewer.exactly(address(this));
    assertEq(data[0].rewardRates[0].usdPrice, 5e18);
  }

  function testActualTimeBeforeStartDistributionRewards() external {
    RewardsController rewardsController = RewardsController(
      address(new ERC1967Proxy(address(new RewardsController()), ""))
    );
    rewardsController.initialize();
    opPriceFeed = new MockPriceFeed(18, 0.002e18);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: market,
      reward: rewardAsset,
      priceFeed: opPriceFeed,
      targetDebt: 2_000_000 ether,
      totalDistribution: 50_000 ether,
      start: 30 days,
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.00005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    market.setRewardsController(rewardsController);

    vm.warp(1 days);
    market.deposit(100 ether, address(this));
    market.borrow(10 ether, address(this), address(this));

    vm.warp(5 days);
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].rewardRates.length, 1);
    assertEq(data[0].rewardRates[0].maturities.length, 11);
    assertEq(data[0].rewardRates[0].floatingDeposit, 0);
    assertEq(data[0].rewardRates[0].borrow, 0);
    assertEq(data[0].rewardRates[0].usdPrice, 2e18);

    opPriceFeed.setPrice(0.005e18);
    data = previewer.exactly(address(this));
    assertEq(data[0].rewardRates[0].usdPrice, 5e18);
  }

  function testFloatingRateAndUtilization() external {
    auditor.enterMarket(market);
    market.deposit(100 ether, address(this));
    market.borrow(64 ether, address(this), address(this));
    Previewer.MarketAccount[] memory exactly = previewer.exactly(address(this));
    assertEq(exactly[0].floatingBorrowRate, 55318189842169626);
    assertEq(exactly[0].floatingUtilization, 0.64e18);
  }

  function testPreviewValueInFixedOperations() external {
    market.deposit(100 ether, address(this));
    vm.warp(1 days);

    market.depositAtMaturity(FixedLib.INTERVAL, 50 ether, 50 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, 15 ether, address(this), address(this));
    market.depositAtMaturity(FixedLib.INTERVAL * 2, 10 ether, 10 ether, address(this));

    (uint256 firstMaturitySupplyPrincipal, uint256 firstMaturitySupplyFee) = market.fixedDepositPositions(
      FixedLib.INTERVAL,
      address(this)
    );
    (uint256 secondMaturitySupplyPrincipal, uint256 secondMaturitySupplyFee) = market.fixedDepositPositions(
      FixedLib.INTERVAL * 2,
      address(this)
    );
    (uint256 firstMaturityBorrowPrincipal, uint256 firstMaturityBorrowFee) = market.fixedBorrowPositions(
      FixedLib.INTERVAL,
      address(this)
    );
    vm.warp(4 days + 20 minutes + 69 seconds);
    Previewer.FixedPreview memory firstMaturityPreviewWithdraw = previewer.previewWithdrawAtMaturity(
      market,
      FixedLib.INTERVAL,
      firstMaturitySupplyPrincipal + firstMaturitySupplyFee,
      address(this)
    );
    Previewer.FixedPreview memory secondMaturityPreviewWithdraw = previewer.previewWithdrawAtMaturity(
      market,
      FixedLib.INTERVAL * 2,
      secondMaturitySupplyPrincipal + secondMaturitySupplyFee,
      address(this)
    );
    Previewer.FixedPreview memory firstMaturityPreviewRepay = previewer.previewRepayAtMaturity(
      market,
      FixedLib.INTERVAL,
      firstMaturityBorrowPrincipal + firstMaturityBorrowFee,
      address(this)
    );

    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].fixedDepositPositions[0].maturity, FixedLib.INTERVAL);
    assertEq(data[0].fixedDepositPositions[0].position.principal, firstMaturitySupplyPrincipal);
    assertEq(data[0].fixedDepositPositions[0].position.fee, firstMaturitySupplyFee);
    assertEq(data[0].fixedDepositPositions[0].previewValue, firstMaturityPreviewWithdraw.assets);
    assertEq(data[0].fixedDepositPositions[1].maturity, FixedLib.INTERVAL * 2);
    assertEq(data[0].fixedDepositPositions[1].position.principal, secondMaturitySupplyPrincipal);
    assertEq(data[0].fixedDepositPositions[1].position.fee, secondMaturitySupplyFee);
    assertEq(data[0].fixedDepositPositions[1].previewValue, secondMaturityPreviewWithdraw.assets);
    assertEq(data[0].fixedDepositPositions.length, 2);

    assertEq(data[0].fixedBorrowPositions[0].maturity, FixedLib.INTERVAL);
    assertEq(data[0].fixedBorrowPositions[0].position.principal, firstMaturityBorrowPrincipal);
    assertEq(data[0].fixedBorrowPositions[0].position.fee, firstMaturityBorrowFee);
    assertEq(data[0].fixedBorrowPositions[0].previewValue, firstMaturityPreviewRepay.assets);
    assertEq(data[0].fixedBorrowPositions.length, 1);

    vm.warp(FixedLib.INTERVAL + 5 days);
    data = previewer.exactly(address(this));
    assertEq(data[0].fixedDepositPositions[0].previewValue, firstMaturitySupplyPrincipal + firstMaturitySupplyFee);
    assertEq(
      data[0].fixedBorrowPositions[0].previewValue,
      firstMaturityBorrowPrincipal +
        firstMaturityBorrowFee +
        (firstMaturityBorrowPrincipal + firstMaturityBorrowFee).mulWadDown(market.penaltyRate() * 5 days)
    );
  }

  function testFlexibleAvailableLiquidity() external {
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    Market marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "WETH",
      12,
      1e18,
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
        marketWETH
      ),
      0.02e18 / uint256(1 days),
      0.1e18,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.7e18);
    ethPriceFeed.setPrice(2_800e8);
    daiPriceFeed.setPrice(0.0003571428571e18);
    weth.mint(address(this), 50_000 ether);
    weth.approve(address(marketWETH), 50_000 ether);
    marketWETH.deposit(50_000 ether, address(this));
    auditor.enterMarket(marketWETH);

    // supply 100 to the smart pool
    market.deposit(100 ether, address(this));

    // let 9011 seconds go by so floatingAssetsAverage is equal to floatingDepositAssets
    vm.warp(9012 seconds);

    // borrow 10 from the first maturity
    market.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, 15 ether, address(this), address(this));
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].floatingAvailableAssets, 90 ether);

    // deposit 50 ether in the first maturity
    market.depositAtMaturity(FixedLib.INTERVAL, 50 ether, 50 ether, address(this));
    data = previewer.exactly(address(this));
    assertEq(data[0].floatingAvailableAssets, 100 ether);

    // deposit 100 ether in the second maturity
    market.depositAtMaturity(FixedLib.INTERVAL * 2, 100 ether, 100 ether, address(this));
    data = previewer.exactly(address(this));
    assertEq(data[0].floatingAvailableAssets, 100 ether);
    // try to borrow 100 ether + 1 (ONE UNIT) from flexible borrow pool and it should fail
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.borrow(100 ether + 1, address(this), address(this));

    // borrow 100 ether from flexible borrow pool and it doesn't fail
    market.borrow(100 ether, address(this), address(this));

    // repay back the 10 borrowed from the first maturity but liquidity is still 0
    uint256 totalBorrowed = data[0].fixedBorrowPositions[0].position.principal +
      data[0].fixedBorrowPositions[0].position.fee;
    market.repayAtMaturity(FixedLib.INTERVAL, totalBorrowed, totalBorrowed, address(this));
    data = previewer.exactly(address(this));
    assertEq(data[0].floatingAvailableAssets, 0 ether);

    // supply 100 more to the smart pool
    market.deposit(100 ether, address(this));
    uint256 distributedEarnings = 792852744101;
    // set the smart pool reserve to 10%
    // since smart pool supply is 200 then 10% is 20
    market.setReserveFactor(0.1e18);
    data = previewer.exactly(address(this));
    assertEq(data[0].floatingAvailableAssets, 80 ether + distributedEarnings);
  }

  function testFloatingAvailableLiquidityProjectingNewFloatingDebt() external {
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    Market marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "WETH",
      12,
      1e18,
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
        marketWETH
      ),
      0.02e18 / uint256(1 days),
      0.1e18,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.7e18);
    ethPriceFeed.setPrice(2_800e8);
    daiPriceFeed.setPrice(0.0003571428571e18);
    weth.mint(address(this), 50_000 ether);
    weth.approve(address(marketWETH), 50_000 ether);
    marketWETH.deposit(50_000 ether, address(this));
    auditor.enterMarket(marketWETH);
    market.setReserveFactor(0.1e18);

    // supply 100 to the floating pool
    market.deposit(100 ether, address(this));

    // borrow 50 from the floating pool
    market.borrow(50 ether, address(this), address(this));

    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].floatingAvailableAssets, 40 ether);

    vm.warp(5 days);
    data = previewer.exactly(address(this));
    // borrowing the available from the floating pool shouldn't fail
    market.borrow(data[0].floatingAvailableAssets, address(this), address(this));
  }

  function testFixedAvailableLiquidityProjectingNewFloatingDebt() external {
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    Market marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "WETH",
      12,
      1e18,
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
        marketWETH
      ),
      0.02e18 / uint256(1 days),
      0.1e18,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.7e18);
    ethPriceFeed.setPrice(2_800e8);
    daiPriceFeed.setPrice(0.0003571428571e18);
    weth.mint(address(this), 50_000 ether);
    weth.approve(address(marketWETH), 50_000 ether);
    marketWETH.deposit(50_000 ether, address(this));
    auditor.enterMarket(marketWETH);
    market.setReserveFactor(0.1e18);

    // supply 100 to the floating pool
    market.deposit(100 ether, address(this));

    // let 9012 seconds go by so floatingAssetsAverage is equal to floatingDepositAssets
    vm.warp(9012 seconds);

    // borrow 50 from the floating pool
    market.borrow(50 ether, address(this), address(this));

    // borrow 10 from the first maturity
    market.borrowAtMaturity(FixedLib.INTERVAL, 10 ether, 100 ether, address(this), address(this));
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].floatingAvailableAssets, 30 ether);

    vm.warp(5 days);
    data = previewer.exactly(address(this));
    // borrowing the available from a fixed pool shouldn't fail
    market.borrowAtMaturity(
      FixedLib.INTERVAL,
      data[0].fixedPools[0].available,
      type(uint256).max,
      address(this),
      address(this)
    );
  }

  function testFixedPoolsWithFloatingAssetsAverage() external {
    uint256 maxFuturePools = market.maxFuturePools();
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    Market marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "WETH",
      12,
      1e18,
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
        marketWETH
      ),
      0.02e18 / uint256(1 days),
      0.1e18,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.7e18);
    ethPriceFeed.setPrice(2_800e8);
    daiPriceFeed.setPrice(0.0003571428571e18);
    weth.mint(address(this), 50_000 ether);
    weth.approve(address(marketWETH), 50_000 ether);
    marketWETH.deposit(50_000 ether, address(this));
    auditor.enterMarket(marketWETH);

    // supply 100 to the smart pool
    market.deposit(100 ether, address(this));
    // let only 10 seconds go by
    vm.warp(10 seconds);
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    uint256 floatingAssetsAverage;
    for (uint256 i = 0; i < maxFuturePools; i++) {
      floatingAssetsAverage = previewFloatingAssetsAverage(FixedLib.INTERVAL + FixedLib.INTERVAL * i);
      assertEq(data[0].fixedPools[i].available, floatingAssetsAverage);
    }
    floatingAssetsAverage = previewFloatingAssetsAverage(FixedLib.INTERVAL);

    // borrowing exactly floatingAssetsAverage doesn't revert
    market.borrowAtMaturity(FixedLib.INTERVAL, floatingAssetsAverage, 50 ether, address(this), address(this));

    // after 200 seconds pass there's more available liquidity
    vm.warp(200 seconds);
    data = previewer.exactly(address(this));
    for (uint256 i = 0; i < maxFuturePools; i++) {
      floatingAssetsAverage = previewFloatingAssetsAverage(FixedLib.INTERVAL + FixedLib.INTERVAL * i);
      assertApproxEqAbs(data[0].fixedPools[i].available, floatingAssetsAverage, 1e10);
    }

    // after 1000 seconds the floatingDepositAssets minus the already borrowed is lower than the floatingAssetsAverage
    vm.warp(1000 seconds);
    data = previewer.exactly(address(this));
    uint256 borrowed = data[0].fixedBorrowPositions[0].position.principal;
    for (uint256 i = 0; i < maxFuturePools; i++) {
      floatingAssetsAverage = previewFloatingAssetsAverage(FixedLib.INTERVAL + FixedLib.INTERVAL * i);
      assertEq(data[0].fixedPools[i].available, Math.min(market.floatingAssets() - borrowed, floatingAssetsAverage));
    }

    // once floatingAssetsAverage = floatingDepositAssets, withdraw all liquidity available
    borrowed += data[0].fixedBorrowPositions[0].position.fee;
    market.repayAtMaturity(FixedLib.INTERVAL, borrowed, borrowed, address(this));
    uint256 accumulatorBefore = market.earningsAccumulator();
    vm.warp(9012 seconds);
    market.withdraw(market.floatingAssets(), address(this), address(this));

    // one second later floatingAssetsAverage STILL has big positive value but floatingDepositAssets is 0
    // actually the available liquidity is an extra dust distributed by the accumulator
    vm.warp(9013 seconds);
    data = previewer.exactly(address(this));
    for (uint256 i = 0; i < maxFuturePools; i++) {
      assertEq(data[0].fixedPools[i].available, accumulatorBefore - market.earningsAccumulator());
    }
  }

  function testExactlyReturningInterestRateModelData() external view {
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));

    assertEq(data[0].interestRateModel.id, address(irm));
    assertEq(data[0].interestRateModel.parameters.maxUtilization, irm.floatingMaxUtilization());
    assertEq(data[0].interestRateModel.parameters.naturalUtilization, irm.naturalUtilization());
    assertEq(data[0].interestRateModel.parameters.growthSpeed, uint256(irm.growthSpeed()));
    assertEq(data[0].interestRateModel.parameters.sigmoidSpeed, uint256(irm.sigmoidSpeed()));
    assertEq(data[0].interestRateModel.parameters.spreadFactor, uint256(irm.spreadFactor()));
    assertEq(data[0].interestRateModel.parameters.maturitySpeed, uint256(irm.maturitySpeed()));
    assertEq(data[0].interestRateModel.parameters.timePreference, irm.timePreference());
    assertEq(data[0].interestRateModel.parameters.fixedAllocation, irm.fixedAllocation());
    assertEq(data[0].interestRateModel.parameters.maxRate, irm.maxRate());
  }

  function testMaxBorrowAssetsCapacity() external {
    market.deposit(100 ether, address(this));
    auditor.enterMarket(market);

    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].maxBorrowAssets, 64 ether);
    // try to borrow max assets + 1 unit should revert
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    market.borrow(64 ether + 1, address(this), address(this));

    // once borrowing max assets, capacity should be 0
    market.borrow(64 ether, address(this), address(this));
    data = previewer.exactly(address(this));
    assertEq(data[0].maxBorrowAssets, 0);

    // max borrow assets for BOB should be 0
    data = previewer.exactly(BOB);
    assertEq(data[0].maxBorrowAssets, 0);
  }

  function testMaxBorrowAssetsCapacityForAccountWithShortfall() external {
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    Market marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "WETH",
      12,
      1e18,
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
        marketWETH
      ),
      0.02e18 / uint256(1 days),
      0.1e18,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.7e18);
    ethPriceFeed.setPrice(1_000e8);
    daiPriceFeed.setPrice(0.001e18);
    weth.mint(address(this), 1 ether);
    weth.approve(address(marketWETH), 1 ether);
    marketWETH.deposit(1 ether, address(this));
    market.deposit(1000 ether, address(this));
    auditor.enterMarket(marketWETH);
    auditor.enterMarket(market);

    market.borrow(1000 ether, address(this), address(this));
    ethPriceFeed.setPrice(100e8);
    daiPriceFeed.setPrice(0.01e18);

    // if account has shortfall then max borrow assets should be 0
    (uint256 collateral, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].maxBorrowAssets, 0);
    assertGt(debt, collateral);
  }

  function testMaxBorrowAssetsCapacityPerMarket() external {
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    Market marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "WETH",
      12,
      1e18,
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
        marketWETH
      ),
      0.02e18 / uint256(1 days),
      0.1e18,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.7e18);
    ethPriceFeed.setPrice(1_000e8);
    daiPriceFeed.setPrice(0.001e18);
    weth.mint(address(this), 1 ether);
    weth.approve(address(marketWETH), 1 ether);
    marketWETH.deposit(1 ether, address(this));
    market.deposit(1000 ether, address(this));
    auditor.enterMarket(marketWETH);
    auditor.enterMarket(market);

    // add liquidity as bob
    weth.mint(BOB, 10 ether);
    vm.prank(BOB);
    weth.approve(address(marketWETH), 1_000 ether);
    vm.prank(BOB);
    marketWETH.deposit(10 ether, BOB);
    vm.prank(BOB);
    market.deposit(5000 ether, BOB);

    // dai collateral (1000) * 0.8 = 800
    // eth collateral (1000) * 0.7 = 700
    // 1500 * 0.8 = 1200 (dai)
    // 1500 * 0.7 = 1050 / 1000 = 1.05 (eth)
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].maxBorrowAssets, 1200 ether);
    assertEq(data[1].maxBorrowAssets, 1.05 ether);
    // try to borrow dai max assets + 1 unit should revert
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    market.borrow(1200 ether + 1, address(this), address(this));
    // try to borrow weth max assets + 1 unit should revert
    vm.expectRevert(InsufficientAccountLiquidity.selector);
    marketWETH.borrow(1.05 ether + 1, address(this), address(this));

    // once borrowing max assets, capacity should be 0
    marketWETH.borrow(1.05 ether, address(this), address(this));
    data = previewer.exactly(address(this));
    assertEq(data[0].maxBorrowAssets, 0);
  }

  function testFixedPoolsChangingMaturityInTime() external {
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].fixedPools[0].maturity, FixedLib.INTERVAL);

    // now first maturity is FixedLib.INTERVAL * 2
    vm.warp(FixedLib.INTERVAL);
    data = previewer.exactly(address(this));
    assertEq(data[0].fixedPools[0].maturity, FixedLib.INTERVAL * 2);

    // now first maturity is FixedLib.INTERVAL * 3
    vm.warp(FixedLib.INTERVAL * 2 + 3000);
    data = previewer.exactly(address(this));
    assertEq(data[0].fixedPools[0].maturity, FixedLib.INTERVAL * 3);
  }

  function testFlexibleBorrowSharesAndAssets() external {
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].floatingBorrowAssets, 0);
    assertEq(data[0].floatingBorrowShares, 0);

    market.deposit(100 ether, address(this));
    market.borrow(10 ether, address(this), address(this));

    data = previewer.exactly(address(this));
    assertEq(data[0].floatingBorrowAssets, 10 ether);
    assertEq(data[0].floatingBorrowShares, 10 ether);

    vm.warp(365 days);
    data = previewer.exactly(address(this));
    assertGt(data[0].floatingBorrowAssets, 10.2 ether);
    assertEq(data[0].floatingBorrowAssets, market.previewDebt(address(this)));
    assertEq(data[0].floatingBorrowShares, 10 ether);

    vm.warp(365 days + 80 days);
    vm.prank(BOB);
    market.deposit(100 ether, BOB);
    vm.prank(BOB);
    market.borrow(10 ether, BOB, BOB);

    vm.warp(365 days + 120 days);
    data = previewer.exactly(address(this));
    assertEq(data[0].floatingBorrowAssets, market.previewDebt(address(this)));
    assertEq(data[0].floatingBorrowShares, 10 ether);

    vm.warp(365 days + 123 days + 7 seconds);
    data = previewer.exactly(BOB);
    (, , uint256 floatingBorrowShares) = market.accounts(BOB);
    assertEq(data[0].floatingBorrowAssets, market.previewDebt(BOB));
    assertEq(data[0].floatingBorrowShares, floatingBorrowShares);
  }

  function testPreviewRepayAtMaturityWithEmptyMaturity() external {
    vm.expectRevert(bytes(""));
    previewer.previewRepayAtMaturity(market, FixedLib.INTERVAL, 1 ether, address(this));
  }

  function testPreviewRepayAtMaturityWithEmptyMaturityAndZeroAmount() external {
    vm.expectRevert(bytes(""));
    previewer.previewRepayAtMaturity(market, FixedLib.INTERVAL, 0, address(this));
  }

  function testPreviewRepayAtMaturityWithInvalidMaturity() external {
    vm.expectRevert(bytes(""));
    previewer.previewRepayAtMaturity(market, 376 seconds, 1 ether, address(this));
  }

  function testPreviewRepayAtMaturityWithSameTimestamp() external {
    market.deposit(10 ether, address(this));
    vm.warp(9011);
    uint256 maturity = FixedLib.INTERVAL;
    uint256 assets = market.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));
    vm.warp(maturity);

    Previewer.FixedPreview memory preview = previewer.previewRepayAtMaturity(market, maturity, assets, address(this));
    assertEq(preview.assets, assets);
  }

  function testPreviewRepayAtMaturityWithMaturedMaturity() external {
    market.deposit(10 ether, address(this));
    vm.warp(9011);
    uint256 maturity = FixedLib.INTERVAL;
    uint256 assets = market.borrowAtMaturity(maturity, 1 ether, 2 ether, address(this), address(this));
    vm.warp(maturity + 100);
    uint256 penalties = assets.mulWadDown(100 * market.penaltyRate());

    Previewer.FixedPreview memory preview = previewer.previewRepayAtMaturity(market, maturity, assets, address(this));
    assertEq(preview.assets, assets + penalties);
  }

  function testPreviewWithdrawAtMaturityReturningAccurateAmount() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.depositAtMaturity(maturity, 10 ether, 10 ether, address(this));

    vm.warp(3 days);
    Previewer.FixedPreview memory preview = previewer.previewWithdrawAtMaturity(
      market,
      maturity,
      10 ether,
      address(this)
    );
    uint256 balanceBeforeWithdraw = asset.balanceOf(address(this));
    market.withdrawAtMaturity(maturity, 10 ether, 0.9 ether, address(this), address(this));
    uint256 feeAfterWithdraw = 10 ether - (asset.balanceOf(address(this)) - balanceBeforeWithdraw);

    assertEq(preview.assets, 10 ether - feeAfterWithdraw);
  }

  function testPreviewWithdrawAtMaturityWithZeroAmount() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));

    vm.warp(3 days);
    Previewer.FixedPreview memory preview = previewer.previewWithdrawAtMaturity(market, maturity, 0, address(this));
    assertEq(preview.assets, 0);
  }

  function testPreviewWithdrawAtMaturityWithOneUnit() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));

    vm.warp(3 days);
    Previewer.FixedPreview memory preview = previewer.previewWithdrawAtMaturity(market, maturity, 1, address(this));

    assertEq(preview.assets, 1 - 1);
  }

  function testPreviewWithdrawAtMaturityWithFiveUnits() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));

    vm.warp(3 days);
    Previewer.FixedPreview memory preview = previewer.previewWithdrawAtMaturity(market, maturity, 5, address(this));

    assertEq(preview.assets, 5 - 1);
  }

  function testPreviewWithdrawAtMaturityReturningAccurateAmountWithIntermediateOperations() external {
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10 ether, address(this));
    market.deposit(10 ether, BOB);
    market.depositAtMaturity(maturity, 5 ether, 5 ether, address(this));

    vm.warp(2 days);
    vm.prank(BOB);
    market.borrowAtMaturity(maturity, 2.3 ether, 4 ether, BOB, BOB);

    vm.warp(3 days);
    Previewer.FixedPreview memory preview = previewer.previewWithdrawAtMaturity(
      market,
      maturity,
      0.47 ether,
      address(this)
    );
    uint256 balanceBeforeWithdraw = asset.balanceOf(address(this));
    market.withdrawAtMaturity(maturity, 0.47 ether, 0.3 ether, address(this), address(this));
    uint256 feeAfterWithdraw = 0.47 ether - (asset.balanceOf(address(this)) - balanceBeforeWithdraw);
    assertEq(preview.assets, 0.47 ether - feeAfterWithdraw);

    vm.warp(5 days);
    preview = previewer.previewWithdrawAtMaturity(market, maturity, 1.1 ether, address(this));
    balanceBeforeWithdraw = asset.balanceOf(address(this));
    market.withdrawAtMaturity(maturity, 1.1 ether, 0.7 ether, address(this), address(this));
    feeAfterWithdraw = 1.1 ether - (asset.balanceOf(address(this)) - balanceBeforeWithdraw);
    assertEq(preview.assets, 1.1 ether - feeAfterWithdraw);

    vm.warp(6 days);
    (uint256 contractPositionPrincipal, uint256 contractPositionEarnings) = market.fixedDepositPositions(
      maturity,
      address(this)
    );
    uint256 contractPosition = contractPositionPrincipal + contractPositionEarnings;
    preview = previewer.previewWithdrawAtMaturity(market, maturity, contractPosition, address(this));
    balanceBeforeWithdraw = asset.balanceOf(address(this));
    market.withdrawAtMaturity(maturity, contractPosition, contractPosition - 1 ether, address(this), address(this));
    feeAfterWithdraw = contractPosition - (asset.balanceOf(address(this)) - balanceBeforeWithdraw);
    (contractPositionPrincipal, ) = market.fixedDepositPositions(maturity, address(this));

    assertEq(preview.assets, contractPosition - feeAfterWithdraw);
  }

  function testPreviewWithdrawAtMaturityWithEmptyMaturity() external {
    vm.expectRevert(bytes(""));
    previewer.previewWithdrawAtMaturity(market, FixedLib.INTERVAL, 1 ether, address(this));
  }

  function testPreviewWithdrawAtMaturityWithEmptyMaturityAndZeroAmount() external {
    vm.expectRevert(bytes(""));
    previewer.previewWithdrawAtMaturity(market, FixedLib.INTERVAL, 0, address(this));
  }

  function testPreviewWithdrawAtMaturityWithInvalidMaturity() external {
    vm.expectRevert(bytes(""));
    previewer.previewWithdrawAtMaturity(market, 376 seconds, 1 ether, address(this));
  }

  function testPreviewWithdrawAtMaturityWithSameTimestamp() external {
    uint256 maturity = FixedLib.INTERVAL;
    uint256 assets = market.depositAtMaturity(maturity, 1 ether, 0, address(this));
    vm.warp(maturity);

    Previewer.FixedPreview memory preview = previewer.previewWithdrawAtMaturity(
      market,
      maturity,
      assets,
      address(this)
    );
    assertEq(preview.assets, assets);
  }

  function testPreviewWithdrawAtMaturityWithMaturedMaturity() external {
    uint256 maturity = FixedLib.INTERVAL;
    uint256 assets = market.depositAtMaturity(maturity, 1 ether, 0, address(this));
    vm.warp(maturity + 1);

    Previewer.FixedPreview memory preview = previewer.previewWithdrawAtMaturity(
      market,
      maturity,
      assets,
      address(this)
    );
    assertEq(preview.assets, assets);
  }

  function testAccountsReturningAccurateAmounts() external {
    market.deposit(10 ether, address(this));
    vm.warp(100 seconds);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));

    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));

    // sum all the collateral prices
    uint256 sumCollateral = data[0]
      .floatingDepositAssets
      .mulDivDown(
        data[0].usdPrice.mulDivDown(10 ** ethPriceFeed.decimals(), uint256(ethPriceFeed.latestAnswer())),
        10 ** data[0].decimals
      )
      .mulWadDown(data[0].adjustFactor);

    // sum all the debt
    uint256 sumDebt = (data[0].fixedBorrowPositions[0].position.principal +
      data[0].fixedBorrowPositions[0].position.fee)
      .mulDivUp(
        data[0].usdPrice.mulDivDown(10 ** ethPriceFeed.decimals(), uint256(ethPriceFeed.latestAnswer())),
        10 ** data[0].decimals
      )
      .divWadUp(data[0].adjustFactor);

    (uint256 realCollateral, uint256 realDebt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);

    assertEq(sumCollateral, realCollateral);
    assertEq(sumDebt, realDebt);
  }

  function testOraclePriceReturningAccurateValues() external {
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    Market marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "WETH",
      12,
      1e18,
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
        marketWETH
      ),
      0.02e18 / uint256(1 days),
      0.1e18,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.7e18);
    ethPriceFeed.setPrice(2_000e8);
    daiPriceFeed.setPrice(0.0005e18);

    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].usdPrice, 1e18);
    assertEq(data[1].usdPrice, 2_000e18);
  }

  function testAccountsWithIntermediateOperationsReturningAccurateAmounts() external {
    // deploy a new asset for more liquidity combinations
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    Market marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      "WETH",
      12,
      1e18,
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
        marketWETH
      ),
      0.02e18 / uint256(1 days),
      0.1e18,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.7e18);
    ethPriceFeed.setPrice(2_000e8);
    daiPriceFeed.setPrice(0.0005e18);
    weth.mint(address(this), 50_000 ether);
    weth.approve(address(marketWETH), 50_000 ether);

    market.deposit(10 ether, address(this));
    vm.warp(100 seconds);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL, 1.321 ether, 2 ether, address(this), address(this));
    market.deposit(2 ether, address(this));

    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));

    // sum all the collateral prices
    uint256 sumCollateral = data[0]
      .floatingDepositAssets
      .mulDivDown(data[0].usdPrice, 10 ** data[0].decimals)
      .mulWadDown(data[0].adjustFactor);

    // sum all the debt
    uint256 sumDebt = (data[0].fixedBorrowPositions[0].position.principal +
      data[0].fixedBorrowPositions[0].position.fee).mulDivUp(data[0].usdPrice, 10 ** data[0].decimals).divWadUp(
        data[0].adjustFactor
      );

    (uint256 realCollateral, uint256 realDebt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqRel(sumCollateral - sumDebt, ((realCollateral - realDebt) * 2000e18) / 1e18, 1e5);
    assertEq(data[0].isCollateral, true);

    marketWETH.deposit(100 ether, address(this));
    data = previewer.exactly(address(this));
    assertEq(data[1].floatingDepositAssets, 100 ether);
    assertEq(data[1].isCollateral, false);
    assertEq(data.length, 2);

    auditor.enterMarket(marketWETH);
    data = previewer.exactly(address(this));
    sumCollateral += data[1].floatingDepositAssets.mulDivDown(data[1].usdPrice, 10 ** data[1].decimals).mulWadDown(
      data[1].adjustFactor
    );
    (realCollateral, realDebt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqRel(sumCollateral - sumDebt, ((realCollateral - realDebt) * 2000e18) / 1e18, 1e5);
    assertEq(data[1].isCollateral, true);

    vm.warp(200 seconds);
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL * 2, 33 ether, 60 ether, address(this), address(this));
    data = previewer.exactly(address(this));

    sumDebt += (data[1].fixedBorrowPositions[0].position.principal + data[1].fixedBorrowPositions[0].position.fee)
      .mulDivDown(data[1].usdPrice, 10 ** data[1].decimals)
      .divWadDown(data[1].adjustFactor);

    (realCollateral, realDebt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqRel(sumCollateral - sumDebt, ((realCollateral - realDebt) * 2000e18) / 1e18, 1e10);

    ethPriceFeed.setPrice(1_831e8);
    data = previewer.exactly(address(this));
    assertEq(data[1].usdPrice, 1_831e18);
  }

  function testAccountsWithAccountThatHasBalances() external {
    market.deposit(10 ether, address(this));
    vm.warp(400 seconds);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    market.depositAtMaturity(FixedLib.INTERVAL, 1 ether, 1 ether, address(this));
    market.borrowAtMaturity(FixedLib.INTERVAL * 2, 2.33 ether, 4 ether, address(this), address(this));
    market.depositAtMaturity(FixedLib.INTERVAL * 2, 1.19 ether, 1.19 ether, address(this));
    (uint256 firstMaturitySupplyPrincipal, uint256 firstMaturitySupplyFee) = market.fixedDepositPositions(
      FixedLib.INTERVAL,
      address(this)
    );
    (uint256 secondMaturitySupplyPrincipal, uint256 secondMaturitySupplyFee) = market.fixedDepositPositions(
      FixedLib.INTERVAL * 2,
      address(this)
    );
    (uint256 firstMaturityBorrowPrincipal, uint256 firstMaturityBorrowFee) = market.fixedBorrowPositions(
      FixedLib.INTERVAL,
      address(this)
    );
    (uint256 secondMaturityBorrowPrincipal, uint256 secondMaturityBorrowFee) = market.fixedBorrowPositions(
      FixedLib.INTERVAL * 2,
      address(this)
    );

    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));

    assertEq(data[0].symbol, market.symbol());
    assertEq(data[0].asset, address(market.asset()));
    assertEq(data[0].assetName, market.asset().name());
    assertEq(data[0].assetSymbol, market.asset().symbol());
    assertEq(data[0].floatingDepositAssets, market.convertToAssets(market.balanceOf(address(this))));
    assertEq(data[0].floatingDepositShares, market.balanceOf(address(this)));
    assertEq(data[0].totalFloatingBorrowShares, market.totalFloatingBorrowShares());
    assertEq(data[0].totalFloatingDepositShares, market.totalSupply());

    assertEq(data[0].fixedDepositPositions[0].maturity, FixedLib.INTERVAL);
    assertEq(data[0].fixedDepositPositions[0].position.principal, firstMaturitySupplyPrincipal);
    assertEq(data[0].fixedDepositPositions[0].position.fee, firstMaturitySupplyFee);
    assertEq(data[0].fixedDepositPositions[1].maturity, FixedLib.INTERVAL * 2);
    assertEq(data[0].fixedDepositPositions[1].position.principal, secondMaturitySupplyPrincipal);
    assertEq(data[0].fixedDepositPositions[1].position.fee, secondMaturitySupplyFee);
    assertEq(data[0].fixedDepositPositions.length, 2);
    assertEq(data[0].fixedBorrowPositions[0].maturity, FixedLib.INTERVAL);
    assertEq(data[0].fixedBorrowPositions[0].position.principal, firstMaturityBorrowPrincipal);
    assertEq(data[0].fixedBorrowPositions[0].position.fee, firstMaturityBorrowFee);
    assertEq(data[0].fixedBorrowPositions[1].maturity, FixedLib.INTERVAL * 2);
    assertEq(data[0].fixedBorrowPositions[1].position.principal, secondMaturityBorrowPrincipal);
    assertEq(data[0].fixedBorrowPositions[1].position.fee, secondMaturityBorrowFee);
    assertEq(data[0].fixedBorrowPositions.length, 2);

    assertEq(data[0].usdPrice, 1_000e18);
    assertEq(data[0].adjustFactor, 0.8e18);
    assertEq(data[0].decimals, 18);
    assertEq(data[0].maxFuturePools, 12);
    assertEq(data[0].penaltyRate, market.penaltyRate());
    assertEq(data[0].isCollateral, true);
  }

  function testAccountsWithAccountOnlyDeposit() external {
    market.deposit(10 ether, address(this));
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));

    assertEq(data[0].assetSymbol, "DAI");
    assertEq(data[0].floatingDepositAssets, 10 ether);
    assertEq(data[0].floatingDepositShares, market.convertToShares(10 ether));
    assertEq(data[0].totalFloatingBorrowShares, 0);
    assertEq(data[0].totalFloatingDepositShares, market.convertToShares(10 ether));
    assertEq(data[0].fixedDepositPositions.length, 0);
    assertEq(data[0].fixedBorrowPositions.length, 0);
    assertEq(data[0].usdPrice, 1_000e18);
    assertEq(data[0].adjustFactor, 0.8e18);
    assertEq(data[0].decimals, 18);
    assertEq(data[0].maxFuturePools, 12);
    assertEq(data[0].isCollateral, false);
  }

  function testAccountsReturningUtilizationForDifferentMaturities() external {
    market.deposit(10 ether, address(this));

    vm.warp(2113);
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));

    assertEq(data[0].fixedPools.length, 12);
    assertEq(data[0].fixedPools[0].maturity, FixedLib.INTERVAL);
    assertEq(data[0].fixedPools[0].utilization, 0);
    assertEq(data[0].fixedPools[1].maturity, FixedLib.INTERVAL * 2);
    assertEq(data[0].fixedPools[1].utilization, 0);
    assertEq(data[0].fixedPools[2].maturity, FixedLib.INTERVAL * 3);
    assertEq(data[0].fixedPools[2].utilization, 0);

    vm.warp(3490);
    market.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    data = previewer.exactly(address(this));

    assertEq(
      data[0].fixedPools[0].utilization,
      uint256(1 ether).divWadUp(previewFloatingAssetsAverage(FixedLib.INTERVAL))
    );
    assertEq(data[0].fixedPools[1].utilization, 0);
    assertEq(data[0].fixedPools[2].utilization, 0);

    vm.warp(8491);
    market.borrowAtMaturity(FixedLib.INTERVAL * 2, 0.172 ether, 1 ether, address(this), address(this));
    data = previewer.exactly(address(this));

    assertEq(
      data[0].fixedPools[0].utilization,
      uint256(1 ether).divWadUp(previewFloatingAssetsAverage(FixedLib.INTERVAL))
    );
    assertEq(
      data[0].fixedPools[1].utilization,
      uint256(0.172 ether).divWadUp(previewFloatingAssetsAverage(FixedLib.INTERVAL * 2))
    );
    assertEq(data[0].fixedPools[2].utilization, 0);

    vm.warp(8999);
    market.borrowAtMaturity(FixedLib.INTERVAL * 3, 1.929 ether, 3 ether, address(this), address(this));
    data = previewer.exactly(address(this));

    assertEq(
      data[0].fixedPools[0].utilization,
      uint256(1 ether).divWadUp(previewFloatingAssetsAverage(FixedLib.INTERVAL))
    );
    assertEq(
      data[0].fixedPools[1].utilization,
      uint256(0.172 ether).divWadUp(previewFloatingAssetsAverage(FixedLib.INTERVAL * 2))
    );
    assertEq(
      data[0].fixedPools[2].utilization,
      uint256(1.929 ether).divWadUp(previewFloatingAssetsAverage(FixedLib.INTERVAL * 3))
    );
  }

  function testAccountsWithEmptyAccount() external view {
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));

    assertEq(data[0].symbol, market.symbol());
    assertEq(data[0].asset, address(market.asset()));
    assertEq(data[0].assetSymbol, "DAI");
    assertEq(data[0].assetName, "Dai Stablecoin");
    assertEq(data[0].floatingDepositAssets, 0);
    assertEq(data[0].floatingDepositShares, 0);
    assertEq(data[0].totalFloatingBorrowShares, 0);
    assertEq(data[0].totalFloatingDepositShares, 0);
    assertEq(data[0].fixedDepositPositions.length, 0);
    assertEq(data[0].fixedBorrowPositions.length, 0);
    assertEq(data[0].usdPrice, 1_000e18);
    assertEq(data[0].adjustFactor, 0.8e18);
    assertEq(data[0].decimals, 18);
    assertEq(data[0].maxFuturePools, 12);
    assertEq(data[0].penaltyRate, market.penaltyRate());
    assertEq(data[0].isCollateral, false);
  }

  function testReserveFactor() external {
    market.setReserveFactor(0.05e18);
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].reserveFactor, market.reserveFactor());
  }

  function testIsFrozen() external {
    Previewer.MarketAccount[] memory data = previewer.exactly(address(this));
    assertEq(data[0].isFrozen, false);
    market.setFrozen(true);
    data = previewer.exactly(address(this));
    assertEq(data[0].isFrozen, true);
  }

  function testPreviewRepayAtMaturityLastAccrualIsMaturity() external {
    market.setInterestRateModel(InterestRateModel(address(new MockBorrowRate(0.1e18))));
    uint256 maturity = FixedLib.INTERVAL;
    market.deposit(10e18, address(this));
    market.borrowAtMaturity(maturity, 1e18, 1.1e18, address(this), address(this));

    vm.startPrank(BOB);
    market.deposit(10e18, BOB);
    market.borrowAtMaturity(maturity, 1e18, 2e18, BOB, BOB);

    vm.warp(block.timestamp + maturity * 2);

    market.repayAtMaturity(maturity, 2e18, 2e18, BOB);
    vm.stopPrank();

    Previewer.FixedPreview memory preview = previewer.previewRepayAtMaturity(market, maturity, 1.1e18, address(this));

    uint256 debt = market.previewDebt(address(this));
    assertEq(preview.assets, debt);
  }

  function previewFloatingAssetsAverage(uint256 maturity) internal view returns (uint256) {
    (, , uint256 unassignedEarnings, uint256 lastAccrual) = market.fixedPools(maturity);
    uint256 floatingDepositAssets = market.floatingAssets() +
      unassignedEarnings.mulDivDown(block.timestamp - lastAccrual, maturity - lastAccrual);
    uint256 floatingAssetsAverage = market.floatingAssetsAverage();
    uint256 dampSpeedFactor = floatingDepositAssets < floatingAssetsAverage
      ? market.dampSpeedDown()
      : market.dampSpeedUp();
    uint256 averageFactor = uint256(
      1e18 - (-int256(dampSpeedFactor * (block.timestamp - market.lastAverageUpdate()))).expWad()
    );

    return floatingAssetsAverage.mulWadDown(1e18 - averageFactor) + averageFactor.mulWadDown(floatingDepositAssets);
  }
}
