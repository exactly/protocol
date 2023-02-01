// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Vm } from "forge-std/Vm.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MockInterestRateModel } from "../../contracts/mocks/MockInterestRateModel.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { Auditor, IPriceFeed } from "../../contracts/Auditor.sol";
import { Market } from "../../contracts/Market.sol";
import { MockPriceFeed } from "../../contracts/mocks/MockPriceFeed.sol";
import { ERC20, RewardsController } from "../../contracts/RewardsController.sol";
import { FixedLib } from "../../contracts/utils/FixedLib.sol";

contract RewardsControllerTest is Test {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;

  address internal constant ALICE = address(0x420);
  address internal constant BOB = address(0x69);

  RewardsController internal rewardsController;
  Auditor internal auditor;
  Market internal marketUSDC;
  Market internal marketWETH;
  Market internal marketWBTC;
  MockERC20 internal opRewardAsset;
  MockERC20 internal exaRewardAsset;
  MockInterestRateModel internal irm;

  function setUp() external {
    vm.warp(0);
    MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
    opRewardAsset = new MockERC20("OP", "OP", 18);
    exaRewardAsset = new MockERC20("Exa Reward", "EXA", 18);

    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    vm.label(address(auditor), "Auditor");
    irm = new MockInterestRateModel(0.1e18);

    marketUSDC = Market(address(new ERC1967Proxy(address(new Market(usdc, auditor)), "")));
    marketUSDC.initialize(
      3,
      1e18,
      InterestRateModel(address(irm)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    vm.label(address(marketUSDC), "MarketUSDC");
    auditor.enableMarket(marketUSDC, new MockPriceFeed(18, 1e18), 0.8e18);

    marketWETH = Market(address(new ERC1967Proxy(address(new Market(weth, auditor)), "")));
    marketWETH.initialize(
      3,
      1e18,
      InterestRateModel(address(irm)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    vm.label(address(marketWETH), "MarketWETH");
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.9e18);

    marketWBTC = Market(address(new ERC1967Proxy(address(new Market(wbtc, auditor)), "")));
    marketWBTC.initialize(
      3,
      1e18,
      InterestRateModel(address(irm)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    vm.label(address(marketWBTC), "MarketWBTC");
    auditor.enableMarket(marketWBTC, new MockPriceFeed(18, 20_000e18), 0.9e18);

    rewardsController = RewardsController(address(new ERC1967Proxy(address(new RewardsController()), "")));
    rewardsController.initialize();
    vm.label(address(rewardsController), "RewardsController");
    RewardsController.Config[] memory configs = new RewardsController.Config[](3);
    configs[0] = RewardsController.Config({
      market: marketUSDC,
      reward: opRewardAsset,
      priceFeed: MockPriceFeed(address(0)),
      targetDebt: 20_000e6,
      totalDistribution: 2_000 ether,
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.5e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    configs[1] = RewardsController.Config({
      market: marketWETH,
      reward: opRewardAsset,
      priceFeed: IPriceFeed(address(0)),
      targetDebt: 20_000 ether,
      totalDistribution: 2_000 ether,
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.0005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.81e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    configs[2] = RewardsController.Config({
      market: marketUSDC,
      reward: exaRewardAsset,
      priceFeed: IPriceFeed(address(0)),
      targetDebt: 20_000e6,
      totalDistribution: 2_000 ether,
      distributionPeriod: 3 weeks,
      undistributedFactor: 0.3e18,
      flipSpeed: 3e18,
      compensationFactor: 0.4e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.025e18,
      depositAllocationWeightFactor: 0.01e18
    });

    rewardsController.config(configs);
    marketUSDC.setRewardsController(rewardsController);
    marketWETH.setRewardsController(rewardsController);
    opRewardAsset.mint(address(rewardsController), 4_000 ether);
    exaRewardAsset.mint(address(rewardsController), 4_000 ether);

    usdc.mint(address(this), 100 ether);
    usdc.mint(ALICE, 100 ether);
    usdc.mint(BOB, 100 ether);
    weth.mint(address(this), 10_000 ether);
    weth.mint(ALICE, 1_000 ether);
    wbtc.mint(address(this), 1_000 ether);
    usdc.approve(address(marketUSDC), type(uint256).max);
    weth.approve(address(marketWETH), type(uint256).max);
    wbtc.approve(address(marketWBTC), type(uint256).max);
    vm.prank(ALICE);
    usdc.approve(address(marketUSDC), type(uint256).max);
    vm.prank(ALICE);
    weth.approve(address(marketWETH), type(uint256).max);
    vm.prank(BOB);
    usdc.approve(address(marketUSDC), type(uint256).max);
  }

  function testAllClaimableUSDCWithDeposit() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.borrow(30e6, address(this), address(this));

    vm.warp(3 days);
    assertEq(
      rewardsController.allClaimable(address(this), opRewardAsset),
      claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset)
    );
    assertEq(
      rewardsController.allClaimable(address(this), exaRewardAsset),
      claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset)
    );
    vm.warp(3 days + 20 minutes);
    assertEq(
      rewardsController.allClaimable(address(this), opRewardAsset),
      claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset)
    );
    assertEq(
      rewardsController.allClaimable(address(this), exaRewardAsset),
      claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset)
    );
    vm.warp(7 days);
    assertEq(
      rewardsController.allClaimable(address(this), opRewardAsset),
      claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset)
    );
    assertEq(
      rewardsController.allClaimable(address(this), exaRewardAsset),
      claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset)
    );
  }

  function testAllClaimableUSDCWithMint() external {
    marketUSDC.mint(100e6, address(this));
    marketUSDC.borrow(30e6, address(this), address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertEq(accruedRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    uint256 accruedExaRewards = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertEq(accruedExaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));

    vm.warp(7 days);
    uint256 newAccruedRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertEq(newAccruedRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    uint256 newAccruedExaRewards = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertGt(newAccruedRewards, accruedRewards);
    assertEq(newAccruedExaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));
    assertGt(newAccruedExaRewards, accruedExaRewards);
  }

  function testAllClaimableUSDCWithTransfer() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.deposit(100e6, address(this));

    vm.warp(3 days);
    uint256 bobAccruedRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertEq(bobAccruedRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    uint256 bobAccruedExaRewards = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertEq(bobAccruedExaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));

    marketUSDC.transfer(ALICE, marketUSDC.balanceOf(address(this)));

    vm.warp(7 days);
    assertEq(bobAccruedRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    assertEq(bobAccruedExaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));
    assertEq(
      rewardsController.allClaimable(ALICE, opRewardAsset),
      claimable(rewardsController.allMarketsOperations(), ALICE, opRewardAsset)
    );
    assertEq(
      rewardsController.allClaimable(ALICE, exaRewardAsset),
      claimable(rewardsController.allMarketsOperations(), ALICE, exaRewardAsset)
    );
    assertGt(rewardsController.allClaimable(ALICE, opRewardAsset), bobAccruedRewards);
    assertGt(rewardsController.allClaimable(ALICE, exaRewardAsset), bobAccruedExaRewards);
  }

  function testAllClaimableUSDCWithTransferFrom() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.deposit(100e6, address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertEq(accruedRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    uint256 accruedExaRewards = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertEq(accruedExaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));

    marketUSDC.approve(address(this), type(uint256).max);
    marketUSDC.transferFrom(address(this), ALICE, marketUSDC.balanceOf(address(this)));

    vm.warp(7 days);
    assertEq(accruedRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    assertEq(accruedExaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));
    assertEq(
      rewardsController.allClaimable(ALICE, opRewardAsset),
      claimable(rewardsController.allMarketsOperations(), ALICE, opRewardAsset)
    );
    assertEq(
      rewardsController.allClaimable(ALICE, exaRewardAsset),
      claimable(rewardsController.allMarketsOperations(), ALICE, exaRewardAsset)
    );
  }

  function testAllClaimableUSDCWithWithdraw() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.deposit(100e6, address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertEq(accruedRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    uint256 accruedExaRewards = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertEq(accruedExaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));

    marketUSDC.withdraw(marketUSDC.convertToAssets(marketUSDC.balanceOf(address(this))), address(this), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.allClaimable(address(this), opRewardAsset), accruedRewards);
    assertEq(rewardsController.allClaimable(address(this), exaRewardAsset), accruedExaRewards);
  }

  function testAllClaimableUSDCWithRedeem() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.deposit(100e6, address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertEq(accruedRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    uint256 accruedExaRewards = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertEq(accruedExaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));

    marketUSDC.redeem(marketUSDC.balanceOf(address(this)), address(this), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.allClaimable(address(this), opRewardAsset), accruedRewards);
    assertEq(rewardsController.allClaimable(address(this), exaRewardAsset), accruedExaRewards);
  }

  function testAllClaimableUSDCWithFloatingBorrow() external {
    vm.prank(ALICE);
    marketUSDC.deposit(100e6, ALICE);

    marketWBTC.deposit(1_000e8, address(this));
    auditor.enterMarket(marketWBTC);
    marketUSDC.borrow(50e6, address(this), address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertEq(accruedRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    uint256 accruedExaRewards = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertEq(accruedExaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));

    vm.warp(7 days);
    uint256 newAccruedRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertEq(newAccruedRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    assertGt(newAccruedRewards, accruedRewards);
    uint256 newAccruedExaRewards = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertEq(newAccruedExaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));
    assertGt(newAccruedExaRewards, accruedExaRewards);
  }

  function testAllClaimableUSDCWithFloatingRefund() external {
    vm.prank(ALICE);
    marketUSDC.deposit(100e6, ALICE);

    marketWBTC.deposit(1_000e8, address(this));
    auditor.enterMarket(marketWBTC);
    marketUSDC.borrow(50e6, address(this), address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertEq(accruedRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    uint256 accruedExaRewards = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertEq(accruedExaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));

    marketUSDC.refund(50 ether, address(this));

    vm.warp(7 days);
    assertEq(rewardsController.allClaimable(address(this), opRewardAsset), accruedRewards);
    assertEq(rewardsController.allClaimable(address(this), exaRewardAsset), accruedExaRewards);
  }

  function testAllClaimableUSDCWithFloatingRepay() external {
    vm.prank(ALICE);
    marketUSDC.deposit(100e6, ALICE);

    marketWBTC.deposit(1_000e8, address(this));
    auditor.enterMarket(marketWBTC);
    marketUSDC.borrow(50e6, address(this), address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertEq(accruedRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    uint256 accruedExaRewards = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertEq(accruedExaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));

    marketUSDC.repay(marketUSDC.previewRefund(50 ether), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.allClaimable(address(this), opRewardAsset), accruedRewards);
    assertEq(rewardsController.allClaimable(address(this), exaRewardAsset), accruedExaRewards);
  }

  function testAllClaimableUSDCWithAnotherAccountInPool() external {
    irm.setBorrowRate(0);
    vm.prank(ALICE);
    marketUSDC.deposit(100e6, ALICE);
    vm.prank(ALICE);
    marketUSDC.borrow(20e6, ALICE, ALICE);
    vm.warp(2 days);
    vm.prank(BOB);
    marketUSDC.deposit(100e6, BOB);
    vm.prank(BOB);
    marketUSDC.borrow(20e6, BOB, BOB);

    uint256 aliceFirstRewards = rewardsController.allClaimable(ALICE, opRewardAsset);
    assertEq(aliceFirstRewards, claimable(rewardsController.allMarketsOperations(), ALICE, opRewardAsset));
    assertEq(rewardsController.allClaimable(BOB, opRewardAsset), 0);
    uint256 aliceFirstExaRewards = rewardsController.allClaimable(ALICE, exaRewardAsset);
    assertEq(aliceFirstExaRewards, claimable(rewardsController.allMarketsOperations(), ALICE, exaRewardAsset));
    assertEq(rewardsController.allClaimable(BOB, exaRewardAsset), 0);

    vm.warp(3 days);
    (uint256 borrowIndex, uint256 depositIndex) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);
    (uint256 projectedBorrowIndex, uint256 projectedDepositIndex, ) = rewardsController.previewAllocation(
      marketUSDC,
      opRewardAsset,
      1 days
    );
    uint256 borrowRewards = (projectedBorrowIndex - borrowIndex).mulDivDown(
      marketUSDC.totalFloatingBorrowShares(),
      1e6
    );
    uint256 depositRewards = (projectedDepositIndex - depositIndex).mulDivDown(marketUSDC.totalAssets(), 1e6);
    uint256 aliceRewards = rewardsController.allClaimable(ALICE, opRewardAsset);
    uint256 bobRewards = rewardsController.allClaimable(BOB, opRewardAsset);

    assertEq(aliceRewards, claimable(rewardsController.allMarketsOperations(), ALICE, opRewardAsset));
    assertEq(bobRewards, aliceRewards - aliceFirstRewards);
    assertEq(depositRewards + borrowRewards, (aliceRewards - aliceFirstRewards) + bobRewards);

    (borrowIndex, depositIndex) = rewardsController.rewardIndexes(marketUSDC, exaRewardAsset);
    (projectedBorrowIndex, projectedDepositIndex, ) = rewardsController.previewAllocation(
      marketUSDC,
      exaRewardAsset,
      1 days
    );
    borrowRewards = (projectedBorrowIndex - borrowIndex).mulDivDown(marketUSDC.totalFloatingBorrowShares(), 1e6);
    depositRewards = (projectedDepositIndex - depositIndex).mulDivDown(marketUSDC.totalAssets(), 1e6);
    aliceRewards = rewardsController.allClaimable(ALICE, exaRewardAsset);
    bobRewards = rewardsController.allClaimable(BOB, exaRewardAsset);

    assertEq(aliceRewards, claimable(rewardsController.allMarketsOperations(), ALICE, exaRewardAsset));
    assertEq(bobRewards, aliceRewards - aliceFirstExaRewards);
    assertEq(depositRewards + borrowRewards, (aliceRewards - aliceFirstExaRewards) + bobRewards);
  }

  function testAllClaimableWithMaturedFixedPool() external {
    marketUSDC.deposit(100e6, address(this));
    vm.warp(10_000 seconds);
    marketUSDC.borrowAtMaturity(FixedLib.INTERVAL, 10e6, 20e6, address(this), address(this));

    vm.warp(FixedLib.INTERVAL - 1 days);
    uint256 opRewardsPreMaturity = rewardsController.allClaimable(address(this), opRewardAsset);
    uint256 exaRewardsPreMaturity = rewardsController.allClaimable(address(this), exaRewardAsset);
    vm.warp(FixedLib.INTERVAL);
    uint256 opRewardsPostMaturity = rewardsController.allClaimable(address(this), opRewardAsset);
    uint256 exaRewardsPostMaturity = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertGt(opRewardsPostMaturity, opRewardsPreMaturity);
    assertGt(exaRewardsPostMaturity, exaRewardsPreMaturity);

    vm.warp(FixedLib.INTERVAL + 1 days);
    assertApproxEqAbs(rewardsController.allClaimable(address(this), exaRewardAsset), exaRewardsPostMaturity, 1e2);
  }

  function testWithTwelveFixedPools() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.setMaxFuturePools(12);
    vm.warp(10_000 seconds);
    for (uint i = 0; i < 12; ++i) {
      vm.warp(block.timestamp + 1 days);
      marketUSDC.borrowAtMaturity(FixedLib.INTERVAL * (0 + 1), 1e6, 2e6, address(this), address(this));
    }
    vm.warp(block.timestamp + 1 days);
    marketUSDC.borrowAtMaturity(FixedLib.INTERVAL, 1e6, 2e6, address(this), address(this));

    rewardsController.claimAll(address(this));
  }

  function testAllClaimableWithTimeElapsedZero() external {
    marketUSDC.deposit(10 ether, address(this));
    marketUSDC.borrow(2 ether, address(this), address(this));

    vm.warp(1 days);
    rewardsController.claimAll(address(this));
    uint256 opRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    (, , uint32 lastUpdate, uint256 lastUndistributed) = rewardsController.distributionTime(marketUSDC, opRewardAsset);
    (uint256 borrowIndex, uint256 depositIndex) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);
    assertEq(opRewards, 0);

    marketUSDC.deposit(10 ether, address(this));
    marketUSDC.borrow(2 ether, address(this), address(this));
    (, , uint32 newLastUpdate, uint256 newLastUndistributed) = rewardsController.distributionTime(
      marketUSDC,
      opRewardAsset
    );
    (uint256 newBorrowIndex, uint256 newDepositIndex) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);

    assertEq(rewardsController.allClaimable(address(this), opRewardAsset), opRewards);
    assertEq(newLastUpdate, lastUpdate);
    assertEq(newLastUndistributed, lastUndistributed);
    assertEq(borrowIndex, newBorrowIndex);
    assertEq(depositIndex, newDepositIndex);
  }

  function testUpdateWithTotalDebtZeroShouldUpdateLastUndistributed() external {
    marketUSDC.deposit(10 ether, address(this));
    (, , , uint256 lastUndistributed) = rewardsController.distributionTime(marketUSDC, opRewardAsset);

    vm.warp(1 days);
    (uint256 borrowIndex, uint256 depositIndex) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);
    (uint256 projectedBorrowIndex, uint256 projectedDepositIndex, ) = rewardsController.previewAllocation(
      marketUSDC,
      opRewardAsset,
      1 days
    );
    uint256 borrowRewards = (projectedBorrowIndex - borrowIndex).mulDivDown(
      marketUSDC.totalFloatingBorrowShares(),
      1e8
    );
    uint256 depositRewards = (projectedDepositIndex - depositIndex).mulDivDown(marketUSDC.totalAssets(), 1e8);
    assertEq(depositRewards, 0);
    assertEq(borrowRewards, 0);
    marketUSDC.deposit(10 ether, address(this));
    (, , uint32 newLastUpdate, uint256 newLastUndistributed) = rewardsController.distributionTime(
      marketUSDC,
      opRewardAsset
    );

    assertGt(newLastUndistributed, lastUndistributed);
    assertEq(newLastUpdate, block.timestamp);
  }

  function testAccrueRewardsForWholeDistributionPeriod() external {
    marketWETH.deposit(200 ether, address(this));
    marketWETH.borrow(5 ether, address(this), address(this));

    vm.warp(12 weeks);
    uint256 distributedRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    rewardsController.claimAll(address(this));
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    (, , , uint256 lastUndistributed) = rewardsController.distributionTime(marketWETH, opRewardAsset);
    assertApproxEqAbs(distributedRewards, 700 ether, 3e18);
    assertApproxEqAbs(lastUndistributed.mulWadDown(config.targetDebt), 1_300 ether, 3e18);
  }

  function testAllClaimableWETH() external {
    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 opRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertEq(opRewards, claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset));
    uint256 exaRewards = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertEq(exaRewards, claimable(rewardsController.allMarketsOperations(), address(this), exaRewardAsset));

    vm.warp(3 days + 20 minutes);
    assertEq(
      rewardsController.allClaimable(address(this), opRewardAsset),
      claimable(rewardsController.allMarketsOperations(), address(this), opRewardAsset)
    );
    assertEq(rewardsController.allClaimable(address(this), exaRewardAsset), 0);

    vm.warp(7 days);
    uint256 newOpRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertEq(rewardsController.allClaimable(address(this), opRewardAsset), newOpRewards);
    assertGt(newOpRewards, opRewards);
  }

  function testDifferentDistributionTimeForDifferentRewards() external {
    vm.prank(ALICE);
    marketWETH.deposit(100 ether, address(this));

    marketWBTC.deposit(100e8, address(this));
    auditor.enterMarket(marketWBTC);
    vm.warp(10_000 seconds);
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 20 ether, 40 ether, address(this), address(this));

    vm.warp(FixedLib.INTERVAL * 2);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: marketWETH,
      reward: exaRewardAsset,
      priceFeed: MockPriceFeed(address(0)),
      targetDebt: 10_000 ether,
      totalDistribution: 1_500 ether,
      distributionPeriod: 10 weeks,
      undistributedFactor: 0.6e18,
      flipSpeed: 1e18,
      compensationFactor: 0.65e18,
      transitionFactor: 0.71e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    vm.warp(block.timestamp + 10 days);
    // should not earn rewards from previous fixed pool borrow
    assertEq(rewardsController.allClaimable(address(this), exaRewardAsset), 0);
    assertGt(rewardsController.allClaimable(address(this), opRewardAsset), 0);

    marketWETH.borrowAtMaturity(FixedLib.INTERVAL * 3, 20 ether, 40 ether, address(this), address(this));
    vm.warp(block.timestamp + 10 days);
    assertGt(rewardsController.allClaimable(address(this), exaRewardAsset), 0);
  }

  function testClaimMarketWithoutRewards() external {
    marketWETH.deposit(100 ether, address(this));
    marketWBTC.deposit(100e8, address(this));
    vm.warp(10_000 seconds);
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 20 ether, 40 ether, address(this), address(this));
    marketWBTC.borrowAtMaturity(FixedLib.INTERVAL, 20e8, 40e8, address(this), address(this));

    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
    RewardsController.Operation[] memory ops = new RewardsController.Operation[](2);
    ops[0] = RewardsController.Operation.Borrow;
    ops[1] = RewardsController.Operation.Deposit;
    marketOps[0] = RewardsController.MarketOperation({ market: marketWBTC, operations: ops });
    rewardsController.claim(marketOps, address(this));
    assertEq(opRewardAsset.balanceOf(address(this)), 0);
  }

  function testAfterDistributionPeriodEnd() external {
    uint256 totalDistribution = 2_000 ether;
    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));

    (, uint256 distributionEnd, , ) = rewardsController.distributionTime(marketWETH, opRewardAsset);
    vm.warp(distributionEnd);
    uint256 opRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    vm.warp(distributionEnd + 1);
    assertGt(rewardsController.allClaimable(address(this), opRewardAsset), opRewards);
    // move in time far away from end of distribution, still rewards are lower than total distribution
    vm.warp(distributionEnd * 4);
    opRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    assertGt(totalDistribution, opRewards);

    rewardsController.claimAll(address(this));
    assertEq(opRewardAsset.balanceOf(address(this)), opRewards);
  }

  function testSetDistributionWithOnGoingMarketOperations() external {
    vm.warp(1 days);
    marketWBTC.deposit(10e8, address(this));
    marketWBTC.borrow(1e8, address(this), address(this));

    vm.warp(3 days);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: marketWBTC,
      reward: opRewardAsset,
      priceFeed: MockPriceFeed(address(0)),
      targetDebt: 10_000e8,
      totalDistribution: 1_500 ether,
      distributionPeriod: 10 weeks,
      undistributedFactor: 0.6e18,
      flipSpeed: 1e18,
      compensationFactor: 0.65e18,
      transitionFactor: 0.71e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    marketWBTC.setRewardsController(rewardsController);
    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
    RewardsController.Operation[] memory ops = new RewardsController.Operation[](2);
    ops[0] = RewardsController.Operation.Borrow;
    ops[1] = RewardsController.Operation.Deposit;
    marketOps[0] = RewardsController.MarketOperation({ market: marketWBTC, operations: ops });
    uint256 claimableRewards = rewardsController.claimable(marketOps, address(this), opRewardAsset);
    assertEq(claimableRewards, 0);

    vm.warp(7 days);
    claimableRewards = rewardsController.claimable(marketOps, address(this), opRewardAsset);
    rewardsController.claim(marketOps, address(this));
    assertEq(claimableRewards, opRewardAsset.balanceOf(address(this)));
  }

  function testUpdateConfig() external {
    vm.warp(1 days);
    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));
    (uint256 preBorrowIndex, uint256 preDepositIndex) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);

    vm.warp(3 days);
    uint256 claimableRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: marketWETH,
      reward: opRewardAsset,
      priceFeed: MockPriceFeed(address(0)),
      targetDebt: 10_000 ether,
      totalDistribution: 1_500 ether,
      distributionPeriod: 10 weeks,
      undistributedFactor: 0.6e18,
      flipSpeed: 1e18,
      compensationFactor: 0.65e18,
      transitionFactor: 0.71e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);

    (uint256 borrowIndex, uint256 depositIndex) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertGt(borrowIndex, preBorrowIndex);
    assertGt(depositIndex, preDepositIndex);

    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    (, , uint32 lastUpdate, ) = rewardsController.distributionTime(marketWETH, opRewardAsset);
    assertEq(lastUpdate, block.timestamp);
    assertEq(config.targetDebt, 10_000 ether);
    assertEq(config.undistributedFactor, 0.6e18);

    rewardsController.claimAll(address(this));
    assertEq(opRewardAsset.balanceOf(address(this)), claimableRewards);
  }

  function testClaim() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.borrow(10e6, address(this), address(this));

    vm.warp(4 days + 20 minutes);
    uint256 opClaimableRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    RewardsController.Operation[] memory ops = new RewardsController.Operation[](2);
    ops[0] = RewardsController.Operation.Deposit;
    ops[1] = RewardsController.Operation.Borrow;
    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
    marketOps[0] = RewardsController.MarketOperation({ market: marketUSDC, operations: ops });
    rewardsController.claim(marketOps, address(this));

    assertEq(opRewardAsset.balanceOf(address(this)), opClaimableRewards);
    assertEq(rewardsController.allClaimable(address(this), opRewardAsset), 0);
  }

  function testClaimAll() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.borrow(10e6, address(this), address(this));
    marketWETH.deposit(100 ether, address(this));
    marketWETH.borrow(10 ether, address(this), address(this));

    vm.warp(4 days + 20 minutes);
    uint256 opClaimableRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    uint256 exaClaimableRewards = rewardsController.allClaimable(address(this), exaRewardAsset);
    rewardsController.claimAll(address(this));

    assertEq(opRewardAsset.balanceOf(address(this)), opClaimableRewards);
    assertEq(rewardsController.allClaimable(address(this), opRewardAsset), 0);
    assertEq(exaRewardAsset.balanceOf(address(this)), exaClaimableRewards);
    assertEq(rewardsController.allClaimable(address(this), exaRewardAsset), 0);
  }

  function testWithdrawOnlyAdminRole() external {
    vm.expectRevert(bytes(""));
    vm.prank(BOB);
    rewardsController.withdraw(opRewardAsset, BOB);

    // withdraw call from contract should not revert
    rewardsController.withdraw(opRewardAsset, BOB);
  }

  function testWithdrawAllRewardBalance() external {
    uint256 opRewardBalance = opRewardAsset.balanceOf(address(rewardsController));
    rewardsController.withdraw(opRewardAsset, address(this));

    assertEq(opRewardAsset.balanceOf(address(this)), opRewardBalance);
    assertEq(opRewardAsset.balanceOf(address(rewardsController)), 0);
  }

  function testEmitClaimRewards() external {
    marketWETH.deposit(100 ether, address(this));
    marketWETH.borrow(20 ether, address(this), address(this));

    vm.warp(1 days);
    uint256 rewards = rewardsController.allClaimable(address(this), opRewardAsset);
    vm.expectEmit(true, true, true, true, address(rewardsController));
    emit Claim(address(this), opRewardAsset, address(this), rewards);
    rewardsController.claimAll(address(this));
  }

  function testEmitAccrue() external {
    marketWETH.deposit(100 ether, address(this));
    marketWETH.borrow(20 ether, address(this), address(this));

    vm.warp(1 days);
    (uint256 borrowIndex, uint256 depositIndex, ) = rewardsController.previewAllocation(
      marketWETH,
      opRewardAsset,
      1 days
    );
    vm.expectEmit(true, true, true, true, address(rewardsController));
    emit Accrue(
      marketWETH,
      opRewardAsset,
      address(this),
      RewardsController.Operation.Borrow,
      0,
      borrowIndex,
      409876612891463680
    );
    rewardsController.claimAll(address(this));

    vm.warp(2 days);
    (, uint256 newDepositIndex, ) = rewardsController.previewAllocation(marketWETH, opRewardAsset, 1 days);
    vm.expectEmit(true, true, true, true, address(rewardsController));
    emit Accrue(
      marketWETH,
      opRewardAsset,
      address(this),
      RewardsController.Operation.Deposit,
      depositIndex,
      newDepositIndex,
      344353723509616000
    );
    marketWETH.deposit(10 ether, address(this));
  }

  function testEmitIndexUpdate() external {
    marketWETH.deposit(100 ether, address(this));
    marketWETH.borrow(20 ether, address(this), address(this));

    vm.warp(1 days);
    (uint256 borrowIndex, uint256 depositIndex, uint256 newUndistributed) = rewardsController.previewAllocation(
      marketWETH,
      opRewardAsset,
      1 days
    );
    vm.expectEmit(true, true, true, true, address(rewardsController));
    emit IndexUpdate(marketWETH, opRewardAsset, borrowIndex, depositIndex, newUndistributed, block.timestamp);
    rewardsController.claimAll(address(this));

    vm.warp(2 days);
    (borrowIndex, depositIndex, newUndistributed) = rewardsController.previewAllocation(
      marketWETH,
      opRewardAsset,
      1 days
    );
    vm.expectEmit(true, true, true, true, address(rewardsController));
    emit IndexUpdate(marketWETH, opRewardAsset, borrowIndex, depositIndex, newUndistributed, block.timestamp);
    rewardsController.claimAll(address(this));
  }

  function testEmitConfigUpdate() external {
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: marketUSDC,
      reward: opRewardAsset,
      priceFeed: MockPriceFeed(address(0)),
      targetDebt: 20_000e6,
      totalDistribution: 2_000 ether,
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.5e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    vm.expectEmit(true, true, true, true, address(rewardsController));
    emit DistributionSet(configs[0].market, configs[0].reward, configs[0]);
    rewardsController.config(configs);

    configs[0] = RewardsController.Config({
      market: marketWBTC,
      reward: opRewardAsset,
      priceFeed: IPriceFeed(address(0)),
      targetDebt: 20_000e8,
      totalDistribution: 2_000 ether,
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.0005e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.81e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    vm.expectEmit(true, true, true, true, address(rewardsController));
    emit DistributionSet(configs[0].market, configs[0].reward, configs[0]);
    rewardsController.config(configs);
  }

  function testSetDistributionConfigWithDifferentDecimals() external {
    MockERC20 rewardAsset = new MockERC20("Reward", "RWD", 10);
    MockERC20 asset = new MockERC20("Asset", "AST", 6);
    Market market = Market(address(new ERC1967Proxy(address(new Market(asset, auditor)), "")));
    market.initialize(3, 1e18, InterestRateModel(address(irm)), 0.02e18 / uint256(1 days), 1e17, 0, 0.0046e18, 0.42e18);
    auditor.enableMarket(market, new MockPriceFeed(18, 1e18), 0.8e18);

    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: market,
      reward: rewardAsset,
      priceFeed: MockPriceFeed(address(0)),
      targetDebt: 20_000e6,
      totalDistribution: 2_000e10,
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.5e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0.02e18,
      depositAllocationWeightFactor: 0.01e18
    });
    rewardsController.config(configs);
    rewardAsset.mint(address(rewardsController), 2_000e10);
    asset.mint(address(this), 10_000e6);
    asset.approve(address(market), type(uint256).max);

    market.deposit(10_000e6, address(this));
    market.borrow(1_000e6, address(this), address(this));
    marketUSDC.deposit(10_000e8, address(this));
    marketUSDC.borrow(1_000e8, address(this), address(this));
    marketWETH.deposit(10_000 ether, address(this));
    marketWETH.borrow(1_000 ether, address(this), address(this));

    vm.warp(6 weeks);
    assertApproxEqAbs(
      rewardsController.allClaimable(address(this), rewardAsset),
      1_000 * 10 ** rewardAsset.decimals(),
      1e9
    );
    assertApproxEqAbs(
      rewardsController.allClaimable(address(this), opRewardAsset),
      (2_000 * 10 ** opRewardAsset.decimals()) - 11e18,
      1e18
    );
    uint256 mintingRate = 13778659611;
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    uint256 mintingRateWETH = config.totalDistribution.divWadDown(config.targetDebt).mulWadDown(
      1e18 / config.distributionPeriod
    );
    assertEq(mintingRateWETH, mintingRate * 10 ** (opRewardAsset.decimals() - marketWETH.decimals()));

    config = rewardsController.rewardConfig(marketUSDC, opRewardAsset);
    uint256 mintingRateUSDC = config.totalDistribution.divWadDown(config.targetDebt).mulWadDown(
      1e18 / config.distributionPeriod
    );
    assertEq(mintingRateUSDC, mintingRate * 10 ** (opRewardAsset.decimals() - marketUSDC.decimals()) + 9e11);

    config = rewardsController.rewardConfig(market, rewardAsset);
    uint256 mintingRateAsset = config.totalDistribution.divWadDown(config.targetDebt).mulWadDown(
      1e18 / config.distributionPeriod
    );
    assertEq(mintingRateAsset, mintingRate * 10 ** (rewardAsset.decimals() - market.decimals()) + 9e3);
  }

  function testSetDistributionOperationShouldUpdateIndex() external {
    vm.warp(2 days);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: marketUSDC,
      reward: opRewardAsset,
      priceFeed: MockPriceFeed(address(0)),
      targetDebt: 1_000 ether,
      totalDistribution: 100_000 ether,
      distributionPeriod: 10 days,
      undistributedFactor: 0.5e18,
      flipSpeed: 2e18,
      compensationFactor: 0.5e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0,
      depositAllocationWeightFactor: 0
    });
    rewardsController.config(configs);

    (, , uint256 lastUpdate, ) = rewardsController.distributionTime(marketUSDC, opRewardAsset);
    assertEq(lastUpdate, 2 days);
  }

  function accountBalanceOperations(
    Market market,
    RewardsController.Operation[] memory ops,
    address account
  ) internal view returns (RewardsController.AccountOperation[] memory accountBalanceOps) {
    accountBalanceOps = new RewardsController.AccountOperation[](ops.length);
    for (uint256 i = 0; i < ops.length; i++) {
      if (ops[i] == RewardsController.Operation.Borrow) {
        (, , uint256 floatingBorrowShares) = market.accounts(account);
        accountBalanceOps[i] = RewardsController.AccountOperation({
          operation: ops[i],
          balance: floatingBorrowShares + accountFixedBorrowShares(market, account)
        });
      } else {
        accountBalanceOps[i] = RewardsController.AccountOperation({
          operation: ops[i],
          balance: market.balanceOf(account)
        });
      }
    }
  }

  function claimable(
    RewardsController.MarketOperation[] memory marketOps,
    address account,
    ERC20 rewardAsset
  ) internal view returns (uint256 unclaimedRewards) {
    for (uint256 i = 0; i < marketOps.length; ++i) {
      if (rewardsController.availableRewardsCount(marketOps[i].market) == 0) continue;

      RewardsController.AccountOperation[] memory ops = accountBalanceOperations(
        marketOps[i].market,
        marketOps[i].operations,
        account
      );
      uint256 totalBalance;
      for (uint256 o = 0; o < ops.length; ++o) {
        (uint256 accrued, ) = rewardsController.accountOperation(
          account,
          marketOps[i].market,
          ops[o].operation,
          rewardAsset
        );
        totalBalance += ops[o].balance;
        unclaimedRewards += accrued;
      }
      if (totalBalance > 0) {
        unclaimedRewards += pendingRewards(
          account,
          rewardAsset,
          RewardsController.AccountMarketOperation({ market: marketOps[i].market, accountOperations: ops })
        );
      }
    }
  }

  function pendingRewards(
    address account,
    ERC20 rewardAsset,
    RewardsController.AccountMarketOperation memory ops
  ) internal view returns (uint256 rewards) {
    uint256 baseUnit = 10 ** rewardsController.decimals(ops.market);
    (, , uint32 lastUpdate, ) = rewardsController.distributionTime(ops.market, rewardAsset);
    (uint256 borrowIndex, uint256 depositIndex, ) = rewardsController.previewAllocation(
      ops.market,
      rewardAsset,
      block.timestamp - lastUpdate
    );
    for (uint256 o = 0; o < ops.accountOperations.length; ++o) {
      (, uint256 accountIndex) = rewardsController.accountOperation(
        account,
        ops.market,
        ops.accountOperations[o].operation,
        rewardAsset
      );
      uint256 nextIndex;
      if (ops.accountOperations[o].operation == RewardsController.Operation.Borrow) {
        nextIndex = borrowIndex;
      } else if (ops.accountOperations[o].operation == RewardsController.Operation.Deposit) {
        nextIndex = depositIndex;
      }

      rewards += ops.accountOperations[o].balance.mulDivDown(nextIndex - accountIndex, baseUnit);
    }
  }

  function accountFixedBorrowShares(Market market, address account) internal view returns (uint256 fixedDebt) {
    for (uint256 i = 0; i < market.maxFuturePools(); i++) {
      (uint256 principal, ) = market.fixedBorrowPositions(
        block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL * (i + 1),
        account
      );
      fixedDebt += principal;
    }
    fixedDebt = market.previewRepay(fixedDebt);
  }

  event Accrue(
    Market indexed market,
    ERC20 indexed reward,
    address indexed account,
    RewardsController.Operation operation,
    uint256 accountIndex,
    uint256 operationIndex,
    uint256 rewardsAccrued
  );
  event Claim(address indexed account, ERC20 indexed reward, address indexed to, uint256 amount);
  event DistributionSet(Market indexed market, ERC20 indexed reward, RewardsController.Config config);
  event IndexUpdate(
    Market indexed market,
    ERC20 indexed reward,
    uint256 borrowIndex,
    uint256 depositIndex,
    uint256 newUndistributed,
    uint256 lastUpdate
  );
}
