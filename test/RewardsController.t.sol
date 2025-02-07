// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MockInterestRateModel } from "../contracts/mocks/MockInterestRateModel.sol";
import { InterestRateModel } from "../contracts/InterestRateModel.sol";
import { Auditor, IPriceFeed } from "../contracts/Auditor.sol";
import { Market } from "../contracts/Market.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import {
  ERC20,
  RewardsController,
  ClaimPermit,
  InvalidConfig,
  NotKeeper,
  NotEnded
} from "../contracts/RewardsController.sol";
import { FixedLib } from "../contracts/utils/FixedLib.sol";

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
      "USDC.e",
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
      "WETH",
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
      "WBTC",
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
      start: uint32(block.timestamp),
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
      start: uint32(block.timestamp),
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.5e18,
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
      start: uint32(block.timestamp),
      distributionPeriod: 3 weeks,
      undistributedFactor: 0.5e18,
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
    weth.mint(address(this), 50_000 ether);
    weth.mint(ALICE, 1_000 ether);
    wbtc.mint(address(this), 1_000e8);
    wbtc.mint(BOB, 1_000e8);
    usdc.approve(address(marketUSDC), type(uint256).max);
    weth.approve(address(marketWETH), type(uint256).max);
    wbtc.approve(address(marketWBTC), type(uint256).max);
    vm.prank(ALICE);
    usdc.approve(address(marketUSDC), type(uint256).max);
    vm.prank(ALICE);
    weth.approve(address(marketWETH), type(uint256).max);
    vm.prank(BOB);
    usdc.approve(address(marketUSDC), type(uint256).max);
    vm.prank(BOB);
    wbtc.approve(address(marketWBTC), type(uint256).max);
  }

  function testTriggerHandleBorrowHookBeforeUpdatingFloatingDebt() external {
    marketWBTC.deposit(1e8, address(this));
    marketWBTC.deposit(1e8, ALICE);
    auditor.enterMarket(marketWBTC);
    vm.prank(ALICE);
    auditor.enterMarket(marketWBTC);

    marketWETH.deposit(65_000, ALICE);
    vm.warp(10_000);
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 20_000, 20_000, address(this));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 20_000, 40_000, address(this), address(this));

    vm.warp(2694383);
    uint256 rewards = rewardsController.allClaimable(address(this), opRewardAsset);
    vm.warp(2694384);
    vm.prank(ALICE);
    marketWETH.borrow(60_008, ALICE, ALICE);
    assertGe(rewardsController.allClaimable(address(this), opRewardAsset), rewards);
  }

  function testAllClaimableOnlyWithUSDCOps() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.borrow(30e6, address(this), address(this));

    vm.warp(3 days);
    RewardsController.AllClaimable[] memory allClaimable = rewardsController.allClaimable(address(this));
    uint256 allRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    ERC20[] memory rewardList = rewardsController.allRewards();

    assertEq(allClaimable.length, rewardList.length);
    assertEq(address(allClaimable[0].reward), address(opRewardAsset));
    assertEq(allClaimable[0].claimable.length, 2);
    assertEq(address(allClaimable[0].claimable[0].market), address(marketUSDC));
    assertEq(address(allClaimable[0].claimable[1].market), address(marketWETH));
    assertEq(address(allClaimable[1].claimable[0].market), address(marketUSDC));
    assertEq(address(allClaimable[1].claimable[1].market), address(marketWETH));
    assertGt(allClaimable[0].claimable[0].amount, 0);
    assertEq(allClaimable[0].claimable[0].amount, allRewards);
    assertEq(allClaimable[0].claimable[1].amount, 0);
    assertGt(allClaimable[1].claimable[0].amount, 0);
  }

  function testAllClaimableWithMultipleMarketOps() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.borrow(30e6, address(this), address(this));
    marketWETH.deposit(1 ether, address(this));
    marketWETH.borrow(0.5 ether, address(this), address(this));

    vm.warp(1 days);
    marketUSDC.borrow(10e6, address(this), address(this));
    marketWETH.borrow(0.1 ether, address(this), address(this));

    vm.warp(3 days);
    RewardsController.AllClaimable[] memory allClaimable = rewardsController.allClaimable(address(this));
    uint256 allOpRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    ERC20[] memory rewardList = rewardsController.allRewards();

    assertEq(allClaimable.length, rewardList.length);
    assertEq(address(allClaimable[0].reward), address(opRewardAsset));
    assertEq(address(allClaimable[1].reward), address(exaRewardAsset));
    assertEq(allClaimable[0].claimable.length, 2);
    assertEq(address(allClaimable[0].claimable[0].market), address(marketUSDC));
    assertEq(address(allClaimable[0].claimable[1].market), address(marketWETH));
    assertEq(address(allClaimable[1].claimable[0].market), address(marketUSDC));
    assertEq(address(allClaimable[1].claimable[1].market), address(marketWETH));
    assertGt(allClaimable[0].claimable[0].amount, 0);
    assertGt(allClaimable[0].claimable[1].amount, 0);
    assertGt(allClaimable[1].claimable[0].amount, 0);
    assertEq(allClaimable[1].claimable[1].amount, 0);
    assertEq(allClaimable[0].claimable[0].amount + allClaimable[0].claimable[1].amount, allOpRewards);
  }

  Market[] internal claimableMarkets;
  ERC20[] internal claimableRewardAssets;

  function testClaimWithAllClaimableArgs() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.borrow(30e6, address(this), address(this));
    marketWETH.deposit(1 ether, address(this));
    marketWETH.borrow(0.5 ether, address(this), address(this));

    vm.warp(1 days);
    marketUSDC.borrow(10e6, address(this), address(this));
    marketWETH.borrow(0.1 ether, address(this), address(this));

    vm.warp(3 days);
    RewardsController.AllClaimable[] memory allClaimable = rewardsController.allClaimable(address(this));

    bool rewardAsset;
    for (uint256 i = 0; i < allClaimable.length; i++) {
      for (uint256 j = 0; j < allClaimable[i].claimable.length; j++) {
        if (allClaimable[i].claimable[j].amount > 0) {
          claimableMarkets.push(allClaimable[i].claimable[j].market);
          rewardAsset = true;
        }
      }
      if (rewardAsset) {
        claimableRewardAssets.push(allClaimable[i].reward);
        rewardAsset = false;
      }
    }

    bool[] memory ops = new bool[](2);
    ops[0] = true;
    ops[1] = false;
    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](
      claimableMarkets.length
    );
    for (uint256 i = 0; i < claimableMarkets.length; i++) {
      marketOps[i] = RewardsController.MarketOperation({ market: claimableMarkets[i], operations: ops });
    }
    ERC20[] memory rewardList = new ERC20[](claimableRewardAssets.length);
    for (uint256 i = 0; i < claimableRewardAssets.length; i++) {
      rewardList[i] = claimableRewardAssets[i];
    }
    rewardsController.claim(marketOps, address(this), rewardList);
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

  function testAllClaimableUSDCWithFixedDeposit() external {
    vm.startPrank(BOB);
    marketUSDC.mint(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.depositAtMaturity(FixedLib.INTERVAL, 10e6, 10e6, address(this));

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

  function testOperationAfterDistributionEnded() external {
    vm.warp(13 weeks);
    marketWETH.deposit(100 ether, address(this));
    marketWETH.borrow(10 ether, address(this), address(this));
    vm.warp(14 weeks);
    assertGt(rewardsController.allClaimable(address(this), opRewardAsset), 0);
  }

  function testUtilizationEqualZero() external {
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.targetDebt = 1000;
    configs[0] = config;
    rewardsController.config(configs);

    marketWETH.deposit(100 ether, address(this));
    marketWETH.borrow(1, address(this), address(this));
    vm.warp(1 days);
    marketWETH.deposit(100 ether, address(this));
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
    irm.setRate(0);
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
    (uint256 borrowIndex, uint256 depositIndex, ) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);
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

    (borrowIndex, depositIndex, ) = rewardsController.rewardIndexes(marketUSDC, exaRewardAsset);
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
    marketUSDC.deposit(50_000e6, address(this));
    vm.warp(10_000 seconds);
    marketUSDC.borrowAtMaturity(FixedLib.INTERVAL, 20_000e6, 22_000e6, address(this), address(this));

    vm.warp(FixedLib.INTERVAL - 1 days);
    uint256 opRewardsPreMaturity = rewardsController.allClaimable(address(this), opRewardAsset);
    uint256 exaRewardsPreMaturity = rewardsController.allClaimable(address(this), exaRewardAsset);
    vm.warp(FixedLib.INTERVAL);
    uint256 opRewardsPostMaturity = rewardsController.allClaimable(address(this), opRewardAsset);
    uint256 exaRewardsPostMaturity = rewardsController.allClaimable(address(this), exaRewardAsset);
    assertGt(opRewardsPostMaturity, opRewardsPreMaturity);
    assertGt(exaRewardsPostMaturity, exaRewardsPreMaturity);

    vm.warp(FixedLib.INTERVAL + 1 days);
    assertApproxEqAbs(rewardsController.allClaimable(address(this), exaRewardAsset), exaRewardsPostMaturity, 2e17);
  }

  function testWithTwelveFixedPools() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.setMaxFuturePools(12);
    vm.warp(10_000 seconds);
    for (uint256 i = 0; i < 12; ++i) {
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
    (, , uint32 lastUpdate) = rewardsController.distributionTime(marketUSDC, opRewardAsset);
    (uint256 borrowIndex, uint256 depositIndex, uint256 lastUndistributed) = rewardsController.rewardIndexes(
      marketUSDC,
      opRewardAsset
    );
    assertEq(opRewards, 0);

    marketUSDC.deposit(10 ether, address(this));
    marketUSDC.borrow(2 ether, address(this), address(this));
    (, , uint32 newLastUpdate) = rewardsController.distributionTime(marketUSDC, opRewardAsset);
    (uint256 newBorrowIndex, uint256 newDepositIndex, uint256 newLastUndistributed) = rewardsController.rewardIndexes(
      marketUSDC,
      opRewardAsset
    );

    assertEq(rewardsController.allClaimable(address(this), opRewardAsset), opRewards);
    assertEq(newLastUpdate, lastUpdate);
    assertEq(newLastUndistributed, lastUndistributed);
    assertEq(borrowIndex, newBorrowIndex);
    assertEq(depositIndex, newDepositIndex);
  }

  function testUpdateWithTotalDebtZeroShouldUpdateLastUndistributed() external {
    marketUSDC.deposit(10 ether, address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);

    vm.warp(1 days);
    (uint256 borrowIndex, uint256 depositIndex, ) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);
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
    (, , uint32 newLastUpdate) = rewardsController.distributionTime(marketUSDC, opRewardAsset);
    (, , uint256 newLastUndistributed) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);

    assertGt(newLastUndistributed, lastUndistributed);
    assertEq(newLastUpdate, block.timestamp);
  }

  function testUpdateIndexesWithUtilizationEqualToOne() external {
    marketWBTC.deposit(1_000e8, address(this));
    auditor.enterMarket(marketWBTC);

    vm.warp(1 days);
    marketWETH.deposit(200 ether, address(this));
    marketWETH.borrow(200 ether, address(this), address(this));

    vm.warp(2 days);
    // should not fail
    rewardsController.claimAll(address(this));
  }

  function testUpdateIndexesWithUtilizationHigherThanOne() external {
    marketWBTC.deposit(1_000e8, address(this));
    auditor.enterMarket(marketWBTC);

    vm.warp(1 days);
    marketWETH.deposit(200 ether, address(this));
    marketWETH.borrow(200 ether, address(this), address(this));
    marketWETH.setTreasury(address(this), 0.1e18);

    vm.warp(2 days);
    // should not fail
    rewardsController.claimAll(address(this));
  }

  function testOperationsBeforeDistributionStart() external {
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: marketWETH,
      reward: exaRewardAsset,
      priceFeed: IPriceFeed(address(0)),
      targetDebt: 20_000 ether,
      totalDistribution: 2_000 ether,
      start: 30 days,
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

    vm.warp(1 days);
    marketWETH.deposit(100 ether, address(this));
    marketWETH.borrow(10 ether, address(this), address(this));

    vm.warp(10 days);
    marketWETH.deposit(30 ether, address(this));

    vm.warp(20 days);
    assertEq(rewardsController.allClaimable(address(this), exaRewardAsset), 0);
    rewardsController.claimAll(address(this));
    assertEq(exaRewardAsset.balanceOf(address(this)), 0);
  }

  function testConfigSettingNewStartWithOnGoingDistributionShouldNotUpdate() external {
    vm.warp(1);
    marketWETH.deposit(100 ether, address(this));
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.start = 1 days;
    configs[0] = config;
    rewardsController.config(configs);

    config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    assertEq(config.start, 0);
  }

  function testConfigWithDistributionNotYetStartedShouldNotFail() external {
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: marketWBTC,
      reward: opRewardAsset,
      priceFeed: MockPriceFeed(address(0)),
      targetDebt: 10_000e8,
      totalDistribution: 1_500 ether,
      start: 2 days,
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

    vm.warp(0.5 days);
    marketWBTC.deposit(100e8, address(this));

    vm.warp(1 days);
    rewardsController.config(configs);
  }

  function testConfigWithZeroDepositAllocationWeightFactorShouldRevert() external {
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.depositAllocationWeightFactor = 0;
    configs[0] = config;

    vm.expectRevert(InvalidConfig.selector);
    rewardsController.config(configs);
  }

  function testConfigWithTransitionFactorHigherOrEqThanCap() external {
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.transitionFactor = 1e18;
    configs[0] = config;
    vm.expectRevert(InvalidConfig.selector);
    rewardsController.config(configs);

    config.transitionFactor = 1e18 + 1;
    configs[0] = config;
    vm.expectRevert(InvalidConfig.selector);
    rewardsController.config(configs);
  }

  function testAccrueRewardsForWholeDistributionPeriod() external {
    marketWETH.deposit(10_000 ether, address(this));
    marketWETH.borrow(5_000 ether, address(this), address(this));

    vm.warp(12 weeks);
    uint256 distributedRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertApproxEqAbs(distributedRewards, 589 ether, 3e18);
    assertApproxEqAbs(lastUndistributed, 1_410 ether, 3e18);
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
      start: uint32(FixedLib.INTERVAL * 2),
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
    // should earn rewards from previous fixed pool borrows
    assertGt(rewardsController.allClaimable(address(this), exaRewardAsset), 0);
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
    bool[] memory ops = new bool[](2);
    ops[0] = true;
    ops[1] = false;
    marketOps[0] = RewardsController.MarketOperation({ market: marketWBTC, operations: ops });
    ERC20[] memory rewardList = new ERC20[](2);
    rewardList[0] = opRewardAsset;
    rewardList[1] = exaRewardAsset;
    rewardsController.claim(marketOps, address(this), rewardList);
    assertEq(opRewardAsset.balanceOf(address(this)), 0);
  }

  function testAfterDistributionPeriodEnd() external {
    uint256 totalDistribution = 2_000 ether;
    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));

    (, uint256 distributionEnd, ) = rewardsController.distributionTime(marketWETH, opRewardAsset);
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

  function testLastUpdateAfterDistributionPeriodEnd() external {
    marketWETH.deposit(40_000 ether, address(this));
    marketWETH.borrow(20_000 ether, address(this), address(this));

    (, uint256 distributionEnd, ) = rewardsController.distributionTime(marketWETH, opRewardAsset);
    vm.warp(distributionEnd / 2);
    rewardsController.claimAll(address(this));

    vm.warp(distributionEnd + 1);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    (, , uint256 lastUpdate) = rewardsController.distributionTime(marketWETH, opRewardAsset);
    assertEq(lastUndistributed, 0);
    assertEq(lastUpdate, distributionEnd + 1);

    vm.warp(distributionEnd * 2);
    rewardsController.claimAll(address(this));
    (, , lastUpdate) = rewardsController.distributionTime(marketWETH, opRewardAsset);

    (, , lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    (, , lastUpdate) = rewardsController.distributionTime(marketWETH, opRewardAsset);
    assertEq(lastUndistributed, 0);
    assertEq(lastUpdate, distributionEnd + 1);
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
      start: uint32(block.timestamp),
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
    bool[] memory ops = new bool[](2);
    ops[0] = true;
    ops[1] = false;
    marketOps[0] = RewardsController.MarketOperation({ market: marketWBTC, operations: ops });
    uint256 claimableRewards = rewardsController.claimable(marketOps, address(this), opRewardAsset);
    assertEq(claimableRewards, 0);

    vm.warp(7 days);
    claimableRewards = rewardsController.claimable(marketOps, address(this), opRewardAsset);
    ERC20[] memory rewardList = new ERC20[](2);
    rewardList[0] = opRewardAsset;
    rewardList[1] = exaRewardAsset;
    rewardsController.claim(marketOps, address(this), rewardList);
    assertEq(claimableRewards, opRewardAsset.balanceOf(address(this)));
  }

  function testSetNewTreasuryFeeShouldImpactAllocation() external {
    marketWETH.deposit(10_000 ether, address(this));
    marketWETH.borrow(5_000 ether, address(this), address(this));

    (uint256 borrowIndex, uint256 depositIndex, ) = rewardsController.previewAllocation(
      marketWETH,
      opRewardAsset,
      1 days
    );
    marketWETH.setTreasury(address(this), 0.1e18);
    (uint256 newBorrowIndex, uint256 newDepositIndex, ) = rewardsController.previewAllocation(
      marketWETH,
      opRewardAsset,
      1 days
    );

    assertGt(newBorrowIndex, borrowIndex);
    assertGt(depositIndex, newDepositIndex);
  }

  function testSetNewTargetDebt() external {
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    marketWETH.deposit(10_000 ether, address(this));
    marketWETH.borrow(5_000 ether, address(this), address(this));

    vm.warp(6 weeks);
    rewardsController.claimAll(address(this));
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    config.targetDebt = 40_000 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(12 weeks);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    uint256 releaseOne = config.totalDistribution.mulDivDown(6 weeks, config.distributionPeriod);
    uint256 releaseTwo = config.totalDistribution.mulDivDown(6 weeks, config.distributionPeriod);
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)) + lastUndistributed, releaseOne + releaseTwo, 1e14);
    assertApproxEqAbs(lastUndistributed, config.totalDistribution - opRewardAsset.balanceOf(address(this)), 1e14);
  }

  function testSetNewTargetDebtWithClaimOnlyAtEnd() external {
    vm.warp(1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    marketWETH.deposit(50_000 ether, address(this));
    marketWETH.borrow(30_000 ether, address(this), address(this));

    vm.warp(6 weeks);
    config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    config.targetDebt = 40_000 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(12 weeks);
    rewardsController.claimAll(address(this));
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), 1772 ether, 1e18);
  }

  function testSetLowerDistributionPeriod() external {
    vm.warp(1);
    marketWETH.deposit(50_000 ether, address(this));
    marketWETH.borrow(20_000 ether, address(this), address(this));

    vm.warp(6 weeks);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.distributionPeriod = 10 weeks;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(10 weeks);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertApproxEqAbs(lastUndistributed, config.totalDistribution - opRewardAsset.balanceOf(address(this)), 1e14);
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);

    vm.warp(12 weeks);
    rewardsController.claimAll(address(this));
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);

    vm.warp(18 weeks);
    rewardsController.claimAll(address(this));
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);
  }

  function testSetLowerAndEqualDistributionPeriodThanCurrentTimestampShouldRevert() external {
    vm.warp(1);
    marketWETH.deposit(50_000 ether, address(this));
    marketWETH.borrow(20_000 ether, address(this), address(this));

    vm.warp(6 weeks);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.distributionPeriod = 5 weeks;
    configs[0] = config;
    vm.expectRevert(InvalidConfig.selector);
    rewardsController.config(configs);

    config.distributionPeriod = 6 weeks;
    configs[0] = config;
    vm.expectRevert(InvalidConfig.selector);
    rewardsController.config(configs);

    config.distributionPeriod = 6 weeks + 1;
    configs[0] = config;
    rewardsController.config(configs);
  }

  function testSetLowerAndEqualTotalDistributionThanReleasedShouldRevert() external {
    vm.warp(1);
    marketWETH.deposit(50_000 ether, address(this));
    marketWETH.borrow(20_000 ether, address(this), address(this));

    vm.warp(6 weeks);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.totalDistribution = 900 ether;
    configs[0] = config;
    vm.expectRevert(InvalidConfig.selector);
    rewardsController.config(configs);

    config.totalDistribution = 999999999999996710400;
    configs[0] = config;
    vm.expectRevert(InvalidConfig.selector);
    rewardsController.config(configs);

    config.totalDistribution = 999999999999996710400 + 1;
    configs[0] = config;
    rewardsController.config(configs);
  }

  function testSetLowerDistributionPeriodAndLowerTotalDistribution() external {
    vm.warp(1);
    marketWETH.deposit(50_000 ether, address(this));
    marketWETH.borrow(20_000 ether, address(this), address(this));

    vm.warp(6 weeks);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.distributionPeriod = 10 weeks;
    config.totalDistribution = 1_800 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(10 weeks);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertApproxEqAbs(lastUndistributed, config.totalDistribution - opRewardAsset.balanceOf(address(this)), 1e14);
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);

    vm.warp(12 weeks);
    rewardsController.claimAll(address(this));
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);

    vm.warp(18 weeks);
    rewardsController.claimAll(address(this));
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);
  }

  function testSetLowerTotalDistribution() external {
    vm.warp(1);
    marketWETH.deposit(50_000 ether, address(this));
    marketWETH.borrow(20_000 ether, address(this), address(this));

    vm.warp(6 weeks);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.totalDistribution = 1_500 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(12 weeks);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertApproxEqAbs(lastUndistributed, config.totalDistribution - opRewardAsset.balanceOf(address(this)), 1e14);
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);

    vm.warp(15 weeks);
    rewardsController.claimAll(address(this));
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);
  }

  function testSetHigherTotalDistribution() external {
    vm.warp(1);
    marketWETH.deposit(50_000 ether, address(this));
    marketWETH.borrow(20_000 ether, address(this), address(this));

    vm.warp(6 weeks);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.totalDistribution = 3_000 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(12 weeks);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertApproxEqAbs(lastUndistributed, config.totalDistribution - opRewardAsset.balanceOf(address(this)), 1e14);
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);

    vm.warp(15 weeks);
    rewardsController.claimAll(address(this));
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);
  }

  function testSetNewDistributionPeriod() external {
    vm.warp(1);
    marketWETH.deposit(50_000 ether, address(this));
    marketWETH.borrow(20_000 ether, address(this), address(this));

    vm.warp(10 weeks);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.distributionPeriod = 18 weeks;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(18 weeks);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertApproxEqAbs(lastUndistributed, config.totalDistribution - opRewardAsset.balanceOf(address(this)), 1e14);
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);

    vm.warp(24 weeks);
    rewardsController.claimAll(address(this));
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);

    vm.warp(28 weeks);
    rewardsController.claimAll(address(this));
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);

    vm.warp(40 weeks);
    rewardsController.claimAll(address(this));
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);
  }

  function testSetTargetDebtMultipleTimes() external {
    vm.warp(1);
    marketWETH.deposit(25_000 ether, address(this));
    marketWETH.borrow(15_000 ether, address(this), address(this));

    vm.warp(4 weeks);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.targetDebt = 10_000 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(8 weeks);
    config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.targetDebt = 15_000 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(10 weeks);
    config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.targetDebt = 20_000 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(12 weeks);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertApproxEqAbs(lastUndistributed, config.totalDistribution - opRewardAsset.balanceOf(address(this)), 1e14);
    marketWETH.borrow(5_000 ether, address(this), address(this));

    vm.warp(45 weeks);
    rewardsController.claimAll(address(this));
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), 1950 ether, 1e18);
  }

  function testSetTargetDebtMultipleTimesAfterEnd() external {
    vm.warp(1);
    marketWETH.deposit(30_000 ether, address(this));
    marketWETH.borrow(15_000 ether, address(this), address(this));

    vm.warp(12 weeks);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.targetDebt = 10_000 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(14 weeks);
    config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.targetDebt = 15_000 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(15 weeks);
    config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.targetDebt = 20_000 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(17 weeks);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertApproxEqAbs(lastUndistributed, config.totalDistribution - opRewardAsset.balanceOf(address(this)), 1e14);
    marketWETH.borrow(5_000 ether, address(this), address(this));

    vm.warp(45 weeks);
    rewardsController.claimAll(address(this));
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), 1892 ether, 1e18);
  }

  function testSetTotalDistributionMultipleTimes() external {
    vm.warp(1);
    marketWETH.deposit(50_000 ether, address(this));
    marketWETH.borrow(20_000 ether, address(this), address(this));

    vm.warp(4 weeks);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.totalDistribution = 2_500 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(8 weeks);
    config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.totalDistribution = 3_000 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(10 weeks);
    config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.totalDistribution = 3_500 ether;
    configs[0] = config;
    rewardsController.config(configs);

    vm.warp(12 weeks);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertApproxEqAbs(lastUndistributed, config.totalDistribution - opRewardAsset.balanceOf(address(this)), 1e14);
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)), config.totalDistribution, 2e14);
  }

  function testSetNewTargetDebtAfterDistributionEnds() external {
    vm.warp(1);
    marketWETH.deposit(5_000 ether, address(this));
    marketWETH.borrow(1_000 ether, address(this), address(this));

    vm.warp(13 weeks);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    config.targetDebt = 30_000 ether;
    configs[0] = config;
    rewardsController.config(configs);
    rewardsController.claimAll(address(this));
    config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    assertEq(config.targetDebt, 30_000 ether);
    uint256 rewardsBefore = opRewardAsset.balanceOf(address(this));

    vm.warp(14 weeks);
    rewardsController.claimAll(address(this));
    assertGt(opRewardAsset.balanceOf(address(this)), rewardsBefore);
  }

  function testSetNewDistributionPeriodAfterDistributionEnds() external {
    vm.warp(1);
    marketWETH.deposit(30_000 ether, address(this));
    marketWETH.borrow(20_000 ether, address(this), address(this));

    vm.warp(13 weeks);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    uint256 previousTotalDistribution = config.totalDistribution;
    config.start = 13 weeks;
    config.distributionPeriod = 6 weeks;
    config.totalDistribution = 1_000 ether;
    configs[0] = config;
    opRewardAsset.mint(address(rewardsController), 1_000 ether);
    rewardsController.config(configs);
    (uint256 start, uint256 end, uint256 lastUpdate) = rewardsController.distributionTime(marketWETH, opRewardAsset);
    (, , uint256 lastUndistributed) = rewardsController.distributionTime(marketWETH, opRewardAsset);
    assertEq(start, block.timestamp);
    assertEq(lastUpdate, block.timestamp);
    assertEq(end, block.timestamp + 6 weeks);
    assertGt(lastUndistributed, 0);

    vm.warp(19 weeks);
    rewardsController.claimAll(address(this));
    (, , lastUndistributed) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertApproxEqAbs(
      lastUndistributed,
      config.totalDistribution + previousTotalDistribution - opRewardAsset.balanceOf(address(this)),
      1e14
    );
    assertApproxEqAbs(
      opRewardAsset.balanceOf(address(this)),
      config.totalDistribution + previousTotalDistribution,
      2e18
    );
  }

  function testUpdateConfig() external {
    vm.warp(1 days);
    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));
    (uint256 preBorrowIndex, uint256 preDepositIndex, ) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);

    vm.warp(3 days);
    uint256 claimableRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: marketWETH,
      reward: opRewardAsset,
      priceFeed: MockPriceFeed(address(0)),
      targetDebt: 10_000 ether,
      totalDistribution: 1_500 ether,
      start: 0,
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

    (uint256 borrowIndex, uint256 depositIndex, ) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertGt(borrowIndex, preBorrowIndex);
    assertGt(depositIndex, preDepositIndex);

    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    (, , uint32 lastUpdate) = rewardsController.distributionTime(marketWETH, opRewardAsset);
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
    bool[] memory ops = new bool[](2);
    ops[0] = false;
    ops[1] = true;
    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
    marketOps[0] = RewardsController.MarketOperation({ market: marketUSDC, operations: ops });
    ERC20[] memory rewardList = new ERC20[](2);
    rewardList[0] = opRewardAsset;
    rewardList[1] = exaRewardAsset;
    rewardsController.claim(marketOps, address(this), rewardList);

    assertEq(opRewardAsset.balanceOf(address(this)), opClaimableRewards);
    assertEq(rewardsController.allClaimable(address(this), opRewardAsset), 0);
  }

  function testPermitClaim() external {
    uint256 accountKey = 0xb0b;
    address account = vm.addr(accountKey);
    marketUSDC.deposit(100e6, account);
    vm.prank(account);
    marketUSDC.borrow(10e6, account, account);

    vm.warp(4 days + 20 minutes);
    uint256 opClaimableRewards = rewardsController.allClaimable(account, opRewardAsset);
    bool[] memory ops = new bool[](2);
    ops[0] = false;
    ops[1] = true;
    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
    marketOps[0] = RewardsController.MarketOperation({ market: marketUSDC, operations: ops });
    ERC20[] memory assets = new ERC20[](2);
    assets[0] = opRewardAsset;
    assets[1] = exaRewardAsset;

    ClaimPermit memory permit;
    permit.owner = account;
    permit.assets = assets;
    permit.deadline = block.timestamp;
    (permit.v, permit.r, permit.s) = vm.sign(
      accountKey,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          rewardsController.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("ClaimPermit(address owner,address spender,address[] assets,uint256 deadline)"),
              permit.owner,
              address(this),
              permit.assets,
              rewardsController.nonces(permit.owner),
              permit.deadline
            )
          )
        )
      )
    );

    rewardsController.claim(marketOps, permit);

    assertEq(opRewardAsset.balanceOf(address(this)), opClaimableRewards);
    assertEq(rewardsController.allClaimable(address(this), opRewardAsset), 0);
  }

  function testClaimWithNotEnabledRewardAsset() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.borrow(10e6, address(this), address(this));

    vm.warp(4 days + 20 minutes);
    uint256 opClaimableRewards = rewardsController.allClaimable(address(this), opRewardAsset);
    bool[] memory ops = new bool[](2);
    ops[0] = false;
    ops[1] = true;
    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
    marketOps[0] = RewardsController.MarketOperation({ market: marketUSDC, operations: ops });
    ERC20[] memory rewardList = new ERC20[](2);
    rewardList[0] = marketUSDC.asset();
    rewardList[1] = opRewardAsset;
    rewardsController.claim(marketOps, address(this), rewardList);

    assertEq(opRewardAsset.balanceOf(address(this)), opClaimableRewards);
    assertEq(rewardsController.allClaimable(address(this), opRewardAsset), 0);
    assertGt(rewardsController.allClaimable(address(this), exaRewardAsset), 0);
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

  function testWithdrawUndistributed() external {
    marketUSDC.deposit(10_000e6, address(this));
    marketUSDC.borrow(1_000e6, address(this), address(this));

    vm.warp(1 days);
    marketUSDC.borrow(1_000e6, address(this), address(this));

    vm.warp(2 days);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);
    assertGt(lastUndistributed, 0);

    uint256 bobBalance = opRewardAsset.balanceOf(BOB);

    vm.warp(12 weeks);
    rewardsController.withdrawUndistributed(marketUSDC, opRewardAsset, BOB);
    (, , lastUndistributed) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);
    (, , uint32 lastUpdate) = rewardsController.distributionTime(marketUSDC, opRewardAsset);

    assertGt(opRewardAsset.balanceOf(BOB), bobBalance);
    assertEq(lastUndistributed, 0);
    assertEq(lastUpdate, 12 weeks);
  }

  function testWithdrawUndistributedOnlyEndedDistribution() external {
    vm.expectRevert(NotEnded.selector);
    rewardsController.withdrawUndistributed(marketUSDC, opRewardAsset, BOB);

    vm.warp(12 weeks);
    rewardsController.withdrawUndistributed(marketUSDC, opRewardAsset, BOB);
  }

  function testWithdrawUndistributedOnlyAdminRole() external {
    vm.expectRevert(bytes(""));
    vm.prank(BOB);
    rewardsController.withdrawUndistributed(marketUSDC, opRewardAsset, BOB);

    vm.warp(12 weeks);
    // withdraw call from contract should not revert
    rewardsController.withdrawUndistributed(marketUSDC, opRewardAsset, BOB);
  }

  function testWithdrawAllRewardBalance() external {
    uint256 opRewardBalance = opRewardAsset.balanceOf(address(rewardsController));
    rewardsController.withdraw(opRewardAsset, address(this));

    assertEq(opRewardAsset.balanceOf(address(this)), opRewardBalance);
    assertEq(opRewardAsset.balanceOf(address(rewardsController)), 0);
  }

  function testAllRewards() external {
    marketWETH.deposit(1 ether, address(this));
    ERC20[] memory rewards = rewardsController.allRewards();

    assertEq(address(rewards[0]), address(opRewardAsset));
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
    emit Accrue(marketWETH, opRewardAsset, address(this), true, 0, borrowIndex, 18445762012054140);
    rewardsController.claimAll(address(this));

    vm.warp(2 days);
    (, uint256 newDepositIndex, ) = rewardsController.previewAllocation(marketWETH, opRewardAsset, 1 days);
    vm.expectEmit(true, true, true, true, address(rewardsController));
    emit Accrue(marketWETH, opRewardAsset, address(this), false, depositIndex, newDepositIndex, 5466772660369400);
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
      start: uint32(block.timestamp),
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
      start: uint32(block.timestamp),
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

  function testLastUndistributed() external {
    marketUSDC.deposit(5_000e6, address(this));
    marketUSDC.borrow(1_000e6, address(this), address(this));

    vm.warp(6 weeks);
    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);
    RewardsController.Config memory config = rewardsController.rewardConfig(marketUSDC, opRewardAsset);
    uint256 releaseRate = config.totalDistribution / config.distributionPeriod;
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)) + lastUndistributed, releaseRate * 6 weeks, 1e6);

    vm.warp(8 weeks);
    rewardsController.claimAll(address(this));
    (, , lastUndistributed) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);
    assertApproxEqAbs(
      lastUndistributed + releaseRate * 4 weeks,
      config.totalDistribution - opRewardAsset.balanceOf(address(this)),
      1e12
    );

    vm.warp(12 weeks);
    rewardsController.claimAll(address(this));
    (, , lastUndistributed) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);
    assertApproxEqAbs(opRewardAsset.balanceOf(address(this)) + lastUndistributed, releaseRate * 12 weeks, 1e6);
  }

  function testAccountKeeperClaimOnBehalfOf() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(10_000e6, BOB);
    marketUSDC.borrow(3_000e6, BOB, BOB);
    vm.stopPrank();

    vm.warp(6 weeks);
    uint256 bobRewards = rewardsController.allClaimable(BOB, opRewardAsset);
    assertGt(bobRewards, 0);

    rewardsController.setKeeper(BOB, address(this));

    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
    bool[] memory ops = new bool[](2);
    ops[0] = true;
    ops[1] = false;
    marketOps[0] = RewardsController.MarketOperation({ market: marketUSDC, operations: ops });
    ERC20[] memory rewardList = new ERC20[](2);
    rewardList[0] = opRewardAsset;
    rewardsController.claimOnBehalfOf(marketOps, BOB, rewardList);
    assertEq(bobRewards, opRewardAsset.balanceOf(BOB));
    bobRewards = rewardsController.allClaimable(BOB, opRewardAsset);
    assertEq(bobRewards, 0);

    rewardsController.setKeeper(BOB, address(0));
  }

  function testNotKeeperClaimOnBehalfOf() external {
    RewardsController.MarketOperation[] memory marketOps;
    ERC20[] memory rewardList;

    vm.expectRevert(NotKeeper.selector);
    rewardsController.claimOnBehalfOf(marketOps, BOB, rewardList);

    rewardsController.setKeeper(BOB, address(this));
    rewardsController.claimOnBehalfOf(marketOps, BOB, rewardList);

    rewardsController.setKeeper(BOB, address(0));
    vm.expectRevert(NotKeeper.selector);
    rewardsController.claimOnBehalfOf(marketOps, BOB, rewardList);
  }

  function testSetKeeperOnlyAdminRole() external {
    vm.expectRevert(bytes(""));
    vm.prank(BOB);
    rewardsController.setKeeper(BOB, address(this));

    // setKeeper call from contract should not revert
    rewardsController.setKeeper(BOB, address(this));
  }

  function testSetDistributionConfigWithDifferentDecimals() external {
    MockERC20 rewardAsset = new MockERC20("Reward", "RWD", 10);
    MockERC20 asset = new MockERC20("Asset", "AST", 6);
    Market market = Market(address(new ERC1967Proxy(address(new Market(asset, auditor)), "")));
    market.initialize(
      "AST",
      3,
      1e18,
      InterestRateModel(address(irm)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      0.0046e18,
      0.42e18
    );
    auditor.enableMarket(market, new MockPriceFeed(18, 1e18), 0.8e18);

    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: market,
      reward: rewardAsset,
      priceFeed: MockPriceFeed(address(0)),
      targetDebt: 1_000e6,
      totalDistribution: 2_000e10,
      start: uint32(block.timestamp),
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
    marketUSDC.deposit(50_000e6, address(this));
    marketUSDC.borrow(20_000e6, address(this), address(this));
    marketWETH.deposit(50_000 ether, address(this));
    marketWETH.borrow(20_000 ether, address(this), address(this));

    vm.warp(6 weeks);
    assertApproxEqAbs(rewardsController.allClaimable(address(this), rewardAsset), 1_000e10, 6e10);
    assertApproxEqAbs(
      rewardsController.allClaimable(address(this), opRewardAsset),
      (2_000 * 10 ** opRewardAsset.decimals()),
      11e18
    );

    uint256 releaseRate = 275573192238000; // mock value with 18 decimals
    RewardsController.Config memory config = rewardsController.rewardConfig(marketWETH, opRewardAsset);
    uint256 releaseRateWETH = config.totalDistribution.mulWadDown(1e18 / config.distributionPeriod);
    assertEq(releaseRateWETH, releaseRate);

    config = rewardsController.rewardConfig(marketUSDC, opRewardAsset);
    uint256 releaseRateUSDC = config.totalDistribution.mulWadDown(1e18 / config.distributionPeriod);
    assertEq(releaseRateUSDC, releaseRate);

    config = rewardsController.rewardConfig(market, rewardAsset);
    uint256 releaseRateAsset = config.totalDistribution.mulWadDown(1e18 / config.distributionPeriod);

    assertEq(releaseRateAsset, releaseRate / 10 ** (18 - rewardAsset.decimals()));

    rewardsController.claimAll(address(this));
    (, , uint256 lastUndistributed) = rewardsController.rewardIndexes(market, rewardAsset);
    assertApproxEqAbs(rewardAsset.balanceOf(address(this)) + lastUndistributed, releaseRateAsset * 6 weeks, 1e6);
    assertApproxEqAbs(
      lastUndistributed + releaseRateAsset * 6 weeks,
      config.totalDistribution - rewardAsset.balanceOf(address(this)),
      1e12
    );

    vm.warp(block.timestamp + 6 weeks);
    assertApproxEqAbs(
      rewardsController.allClaimable(address(this), rewardAsset),
      2_000e10 - rewardAsset.balanceOf(address(this)),
      20e13
    );
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
      start: 1,
      distributionPeriod: 10 days,
      undistributedFactor: 0.5e18,
      flipSpeed: 2e18,
      compensationFactor: 0.5e18,
      transitionFactor: 0.64e18,
      borrowAllocationWeightFactor: 0,
      depositAllocationWeightAddend: 0,
      depositAllocationWeightFactor: 1
    });
    rewardsController.config(configs);

    (, , uint256 lastUpdate) = rewardsController.distributionTime(marketUSDC, opRewardAsset);
    assertEq(lastUpdate, 1);
  }

  function testAccrueRewardsWithSeizeOfAllDepositShares() external {
    vm.prank(BOB);
    marketUSDC.approve(address(this), type(uint256).max);

    marketUSDC.deposit(1_000_000e6, address(this));
    marketUSDC.deposit(1_000_000e6, BOB);
    marketUSDC.borrow(500_000e6, BOB, BOB);

    marketWBTC.deposit(100e8, BOB);
    auditor.enterMarket(marketUSDC);
    marketWBTC.borrow(20e8, address(this), address(this));
    (, , , , IPriceFeed wbtcPriceFeed) = auditor.markets(marketWBTC);
    MockPriceFeed(address(wbtcPriceFeed)).setPrice(50_000e18);

    vm.warp(4 weeks);
    vm.prank(BOB);
    marketWBTC.liquidate(address(this), type(uint256).max, marketUSDC);
    assertGt(rewardsController.allClaimable(address(this), opRewardAsset), 0);
  }

  function testAccrueRewardsWithBadDebtClearingOfFixedBorrow() external {
    vm.prank(BOB);
    marketUSDC.approve(address(this), type(uint256).max);

    marketWBTC.deposit(40e8, address(this));
    auditor.enterMarket(marketWBTC);

    marketUSDC.deposit(1_000_000e6, BOB);
    marketWETH.deposit(1 ether, BOB);
    vm.warp(10_000 seconds);
    marketUSDC.borrowAtMaturity(FixedLib.INTERVAL, 10_000e6, 30_000e6, address(this), address(this));
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 0.1 ether, 0.2 ether, address(this), address(this));

    // distribute earnings to accumulator so it can cover bad debt
    marketUSDC.setBackupFeeRate(1e18);
    irm.setRate(1e18);
    marketUSDC.borrowAtMaturity(FixedLib.INTERVAL, 30_000e6, 60_000e6, BOB, BOB);
    marketUSDC.depositAtMaturity(FixedLib.INTERVAL, 30_000e6, 30_000e6, BOB);

    vm.warp(4 weeks);
    (, , , , IPriceFeed wbtcPriceFeed) = auditor.markets(marketWBTC);
    MockPriceFeed(address(wbtcPriceFeed)).setPrice(10);
    vm.prank(ALICE);
    marketWETH.liquidate(address(this), type(uint256).max, marketWBTC);
    auditor.handleBadDebt(address(this));

    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
    bool[] memory ops = new bool[](1);
    ops[0] = true;
    marketOps[0] = RewardsController.MarketOperation({ market: marketUSDC, operations: ops });
    assertGt(rewardsController.claimable(marketOps, address(this), opRewardAsset), 0);
  }

  function testAccrueRewardsWithFixedWithdraw() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(1_000_000e6, BOB);
    marketUSDC.borrow(100_000e6, BOB, BOB);
    vm.stopPrank();

    marketUSDC.depositAtMaturity(FixedLib.INTERVAL, 30_000e6, 30_000e6, address(this));

    vm.warp(3 weeks);
    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
    bool[] memory ops = new bool[](2);
    ops[0] = true;
    ops[1] = false;
    marketOps[0] = RewardsController.MarketOperation({ market: marketUSDC, operations: ops });

    (uint256 principal, uint256 fee) = marketUSDC.fixedDepositPositions(FixedLib.INTERVAL, address(this));
    marketUSDC.withdrawAtMaturity(FixedLib.INTERVAL, principal + fee, 0, address(this), address(this));
    uint256 claimableRewards = rewardsController.claimable(marketOps, address(this), opRewardAsset);
    (principal, fee) = marketUSDC.fixedDepositPositions(FixedLib.INTERVAL, address(this));
    assertEq(principal + fee, 0);
    assertGt(claimableRewards, 0);

    vm.warp(4 weeks);
    assertEq(claimableRewards, rewardsController.claimable(marketOps, address(this), opRewardAsset));
  }

  function testClaimFixedDepositRewards() external {
    marketUSDC.deposit(100_000e6, address(this));
    marketUSDC.borrow(50_000e6, address(this), address(this));

    vm.prank(BOB);
    marketUSDC.depositAtMaturity(FixedLib.INTERVAL, 10_000e6, 10_000e6, BOB);

    vm.warp(1 weeks);
    uint256 claimableRewards = rewardsController.allClaimable(BOB, opRewardAsset);
    assertGt(claimableRewards, 0);

    (uint256 principal, uint256 fee) = marketUSDC.fixedDepositPositions(FixedLib.INTERVAL, BOB);
    vm.prank(BOB);
    marketUSDC.withdrawAtMaturity(FixedLib.INTERVAL, principal + fee, 0, BOB, BOB);

    vm.warp(2 weeks);
    assertGt(rewardsController.allClaimable(BOB, opRewardAsset), claimableRewards);
  }

  function testAccrueRewardsWithRepayOfBorrowBalance() external {
    marketWBTC.deposit(100e8, address(this));
    auditor.enterMarket(marketWBTC);
    marketUSDC.deposit(1_000_000e6, BOB);
    marketUSDC.borrow(500_000e6, address(this), address(this));

    vm.warp(4 weeks);
    (, , , , IPriceFeed wbtcPriceFeed) = auditor.markets(marketWBTC);
    MockPriceFeed(address(wbtcPriceFeed)).setPrice(100e18);
    vm.prank(ALICE);
    marketUSDC.liquidate(address(this), type(uint256).max, marketWBTC);
    // if reward position had not been updated when repaying the floating borrow
    // then rewards would be way less than 400 ether
    assertGt(rewardsController.allClaimable(address(this), opRewardAsset), 400 ether);
  }

  function testAccrueRewardsWithRepayOfFixedBorrowBalance() external {
    marketWBTC.deposit(100e8, address(this));
    auditor.enterMarket(marketWBTC);
    marketUSDC.deposit(1_000_000e6, BOB);
    vm.warp(10_000 seconds);
    marketUSDC.borrowAtMaturity(FixedLib.INTERVAL, 100_000e6, 200_000e6, address(this), address(this));

    vm.warp(4 weeks);
    (, , , , IPriceFeed wbtcPriceFeed) = auditor.markets(marketWBTC);
    MockPriceFeed(address(wbtcPriceFeed)).setPrice(100e18);
    vm.prank(ALICE);
    marketUSDC.liquidate(address(this), type(uint256).max, marketWBTC);
    // if reward position had not been updated when repaying the fixed borrow
    // then rewards would be way less than 400 ether
    assertGt(rewardsController.allClaimable(address(this), opRewardAsset), 500 ether);
  }

  function testMarketInitConsolidatedShouldNotUpdateBorrowIndex() external {
    marketWETH.deposit(1 ether, address(this));
    marketWETH.borrow(0.2 ether, address(this), address(this));

    vm.warp(block.timestamp + 10_000);
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 0.1 ether, 0.2 ether, address(this), address(this));

    vm.warp(block.timestamp + 1 days);
    (, uint256 previousAccountIndex) = rewardsController.accountOperation(
      address(this),
      marketWETH,
      true,
      opRewardAsset
    );

    vm.warp(block.timestamp + 1 days);
    marketWETH.initConsolidated(address(this));
    (, uint256 accountIndex) = rewardsController.accountOperation(address(this), marketWETH, true, opRewardAsset);
    assertEq(accountIndex, previousAccountIndex);
  }

  function testClaimShouldInitConsolidated() external {
    bool[] memory ops = new bool[](2);
    ops[0] = true;
    ops[1] = false;
    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
    marketOps[0] = RewardsController.MarketOperation({ market: marketWETH, operations: ops });
    ERC20[] memory rewardList = new ERC20[](1);
    rewardList[0] = opRewardAsset;
    rewardsController.claim(marketOps, address(this), rewardList);

    assertEq(marketWETH.isInitialized(address(this)), true);
  }

  function testFloatingDepositShouldInitConsolidated() external {
    marketWETH.deposit(1 ether, address(this));

    assertEq(marketWETH.isInitialized(address(this)), true);
  }

  function testFloatingTransferShouldInitConsolidated() external {
    marketWETH.deposit(1 ether, address(this));
    marketWETH.transfer(ALICE, 1 ether);

    assertEq(marketWETH.isInitialized(ALICE), true);
  }

  function testFloatingBorrowShouldInitConsolidated() external {
    vm.prank(ALICE);
    marketWETH.deposit(10 ether, ALICE);

    marketWBTC.deposit(100e8, address(this));
    auditor.enterMarket(marketWBTC);
    marketWETH.borrow(1 ether, address(this), address(this));

    assertEq(marketWETH.isInitialized(address(this)), true);
  }

  function testFixedDepositShouldInitConsolidated() external {
    marketWETH.depositAtMaturity(FixedLib.INTERVAL, 20_000, 20_000, address(this));

    assertEq(marketWETH.isInitialized(address(this)), true);
  }

  function testFixedBorrowShouldInitConsolidated() external {
    vm.prank(ALICE);
    marketWETH.deposit(10 ether, ALICE);

    vm.warp(10_000);
    marketWBTC.deposit(100e8, address(this));
    auditor.enterMarket(marketWBTC);
    marketWETH.borrowAtMaturity(FixedLib.INTERVAL, 1 ether, 2 ether, address(this), address(this));

    assertEq(marketWETH.isInitialized(address(this)), true);
  }

  function accountBalanceOperations(
    Market market,
    bool[] memory ops,
    address account
  ) internal view returns (RewardsController.AccountOperation[] memory accountBalanceOps) {
    accountBalanceOps = new RewardsController.AccountOperation[](ops.length);
    (uint256 fixedDeposits, uint256 fixedBorrows) = market.fixedConsolidated(account);
    for (uint256 i = 0; i < ops.length; i++) {
      if (ops[i]) {
        (, , uint256 floatingBorrowShares) = market.accounts(account);
        accountBalanceOps[i] = RewardsController.AccountOperation({
          operation: ops[i],
          balance: floatingBorrowShares + market.previewRepay(fixedBorrows)
        });
      } else {
        accountBalanceOps[i] = RewardsController.AccountOperation({
          operation: ops[i],
          balance: market.balanceOf(account) + market.previewWithdraw(fixedDeposits)
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
    uint256 baseUnit = 10 ** ops.market.decimals();
    (, , uint32 lastUpdate) = rewardsController.distributionTime(ops.market, rewardAsset);
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
      if (ops.accountOperations[o].operation) {
        nextIndex = borrowIndex;
      } else {
        nextIndex = depositIndex;
      }

      rewards += ops.accountOperations[o].balance.mulDivDown(nextIndex - accountIndex, baseUnit);
    }
  }

  event Accrue(
    Market indexed market,
    ERC20 indexed reward,
    address indexed account,
    bool operation,
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
