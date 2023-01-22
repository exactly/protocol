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
    MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 18);
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
    auditor.enableMarket(marketUSDC, new MockPriceFeed(18, 1e18), 0.8e18, 18);

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
    auditor.enableMarket(marketWETH, IPriceFeed(auditor.BASE_FEED()), 0.9e18, 18);

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
    auditor.enableMarket(marketWBTC, new MockPriceFeed(18, 20_000e18), 0.9e18, 18);

    rewardsController = RewardsController(address(new ERC1967Proxy(address(new RewardsController(auditor)), "")));
    rewardsController.initialize();
    vm.label(address(rewardsController), "RewardsController");
    RewardsController.Config[] memory configs = new RewardsController.Config[](3);
    configs[0] = RewardsController.Config({
      market: marketUSDC,
      reward: opRewardAsset,
      targetDebt: 20_000e6,
      totalDistribution: 2_000 ether,
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.5e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.64e18,
      borrowConstantReward: 0,
      depositConstantReward: 0.02e18,
      depositConstantRewardHighU: 0.01e18
    });
    configs[1] = RewardsController.Config({
      market: marketWETH,
      reward: opRewardAsset,
      targetDebt: 20_000 ether,
      totalDistribution: 2_000 ether,
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.5e18,
      flipSpeed: 2e18,
      compensationFactor: 0.85e18,
      transitionFactor: 0.81e18,
      borrowConstantReward: 0,
      depositConstantReward: 0.02e18,
      depositConstantRewardHighU: 0.01e18
    });
    configs[2] = RewardsController.Config({
      market: marketUSDC,
      reward: exaRewardAsset,
      targetDebt: 20_000e6,
      totalDistribution: 2_000 ether,
      distributionPeriod: 3 weeks,
      undistributedFactor: 0.3e18,
      flipSpeed: 3e18,
      compensationFactor: 0.4e18,
      transitionFactor: 0.64e18,
      borrowConstantReward: 0,
      depositConstantReward: 0.025e18,
      depositConstantRewardHighU: 0.01e18
    });

    rewardsController.config(configs);
    marketUSDC.setRewardsController(rewardsController);
    marketWETH.setRewardsController(rewardsController);
    opRewardAsset.mint(address(rewardsController), 4_000 ether);
    exaRewardAsset.mint(address(rewardsController), 4_000 ether);

    usdc.mint(address(this), 100 ether);
    usdc.mint(ALICE, 100 ether);
    usdc.mint(BOB, 100 ether);
    weth.mint(address(this), 1_000 ether);
    wbtc.mint(address(this), 1_000 ether);
    usdc.approve(address(marketUSDC), type(uint256).max);
    weth.approve(address(marketWETH), type(uint256).max);
    wbtc.approve(address(marketWBTC), type(uint256).max);
    vm.prank(ALICE);
    usdc.approve(address(marketUSDC), type(uint256).max);
    vm.prank(BOB);
    usdc.approve(address(marketUSDC), type(uint256).max);
  }

  function testClaimableUSDCWithDeposit() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.borrow(30e6, address(this), address(this));

    vm.warp(3 days);
    assertEq(
      rewardsController.claimable(address(this), opRewardAsset),
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    assertEq(
      rewardsController.claimable(address(this), exaRewardAsset),
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );
    vm.warp(3 days + 20 minutes);
    assertEq(
      rewardsController.claimable(address(this), opRewardAsset),
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    assertEq(
      rewardsController.claimable(address(this), exaRewardAsset),
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );
    vm.warp(7 days);
    assertEq(
      rewardsController.claimable(address(this), opRewardAsset),
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    assertEq(
      rewardsController.claimable(address(this), exaRewardAsset),
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );
  }

  function testClaimableUSDCWithMint() external {
    marketUSDC.mint(100e6, address(this));
    marketUSDC.borrow(30e6, address(this), address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    uint256 accruedExaRewards = rewardsController.claimable(address(this), exaRewardAsset);
    assertEq(
      accruedExaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );

    vm.warp(7 days);
    uint256 newAccruedRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertEq(
      newAccruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    uint256 newAccruedExaRewards = rewardsController.claimable(address(this), exaRewardAsset);
    assertGt(newAccruedRewards, accruedRewards);
    assertEq(
      newAccruedExaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );
    assertGt(newAccruedExaRewards, accruedExaRewards);
  }

  function testClaimableUSDCWithTransfer() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.deposit(100e6, address(this));

    vm.warp(3 days);
    uint256 bobAccruedRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertEq(
      bobAccruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    uint256 bobAccruedExaRewards = rewardsController.claimable(address(this), exaRewardAsset);
    assertEq(
      bobAccruedExaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );

    marketUSDC.transfer(ALICE, marketUSDC.balanceOf(address(this)));

    vm.warp(7 days);
    assertEq(
      bobAccruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    assertEq(
      bobAccruedExaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );
    assertEq(
      rewardsController.claimable(ALICE, opRewardAsset),
      claimable(rewardsController.allAccountOperations(ALICE), ALICE, opRewardAsset)
    );
    assertEq(
      rewardsController.claimable(ALICE, exaRewardAsset),
      claimable(rewardsController.allAccountOperations(ALICE), ALICE, exaRewardAsset)
    );
    assertGt(rewardsController.claimable(ALICE, opRewardAsset), bobAccruedRewards);
    assertGt(rewardsController.claimable(ALICE, exaRewardAsset), bobAccruedExaRewards);
  }

  function testClaimableUSDCWithTransferFrom() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.deposit(100e6, address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    uint256 accruedExaRewards = rewardsController.claimable(address(this), exaRewardAsset);
    assertEq(
      accruedExaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );

    marketUSDC.approve(address(this), type(uint256).max);
    marketUSDC.transferFrom(address(this), ALICE, marketUSDC.balanceOf(address(this)));

    vm.warp(7 days);
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    assertEq(
      accruedExaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );
    assertEq(
      rewardsController.claimable(ALICE, opRewardAsset),
      claimable(rewardsController.allAccountOperations(ALICE), ALICE, opRewardAsset)
    );
    assertEq(
      rewardsController.claimable(ALICE, exaRewardAsset),
      claimable(rewardsController.allAccountOperations(ALICE), ALICE, exaRewardAsset)
    );
  }

  function testClaimableUSDCWithWithdraw() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.deposit(100e6, address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    uint256 accruedExaRewards = rewardsController.claimable(address(this), exaRewardAsset);
    assertEq(
      accruedExaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );

    marketUSDC.withdraw(marketUSDC.convertToAssets(marketUSDC.balanceOf(address(this))), address(this), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.claimable(address(this), opRewardAsset), accruedRewards);
    assertEq(rewardsController.claimable(address(this), exaRewardAsset), accruedExaRewards);
  }

  function testClaimableUSDCWithRedeem() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.deposit(100e6, address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    uint256 accruedExaRewards = rewardsController.claimable(address(this), exaRewardAsset);
    assertEq(
      accruedExaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );

    marketUSDC.redeem(marketUSDC.balanceOf(address(this)), address(this), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.claimable(address(this), opRewardAsset), accruedRewards);
    assertEq(rewardsController.claimable(address(this), exaRewardAsset), accruedExaRewards);
  }

  function testClaimableUSDCWithFloatingBorrow() external {
    vm.prank(ALICE);
    marketUSDC.deposit(100e6, ALICE);

    marketWBTC.deposit(1_000 ether, address(this));
    auditor.enterMarket(marketWBTC);
    marketUSDC.borrow(50e6, address(this), address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    uint256 accruedExaRewards = rewardsController.claimable(address(this), exaRewardAsset);
    assertEq(
      accruedExaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );

    vm.warp(7 days);
    uint256 newAccruedRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertEq(
      newAccruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    assertGt(newAccruedRewards, accruedRewards);
    uint256 newAccruedExaRewards = rewardsController.claimable(address(this), exaRewardAsset);
    assertEq(
      newAccruedExaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );
    assertGt(newAccruedExaRewards, accruedExaRewards);
  }

  function testClaimableUSDCWithFloatingRefund() external {
    vm.prank(ALICE);
    marketUSDC.deposit(100e6, ALICE);

    marketWBTC.deposit(1_000 ether, address(this));
    auditor.enterMarket(marketWBTC);
    marketUSDC.borrow(50e6, address(this), address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    uint256 accruedExaRewards = rewardsController.claimable(address(this), exaRewardAsset);
    assertEq(
      accruedExaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );

    marketUSDC.refund(50 ether, address(this));

    vm.warp(7 days);
    assertEq(rewardsController.claimable(address(this), opRewardAsset), accruedRewards);
    assertEq(rewardsController.claimable(address(this), exaRewardAsset), accruedExaRewards);
  }

  function testClaimableUSDCWithFloatingRepay() external {
    vm.prank(ALICE);
    marketUSDC.deposit(100e6, ALICE);

    marketWBTC.deposit(1_000 ether, address(this));
    auditor.enterMarket(marketWBTC);
    marketUSDC.borrow(50e6, address(this), address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    uint256 accruedExaRewards = rewardsController.claimable(address(this), exaRewardAsset);
    assertEq(
      accruedExaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );

    marketUSDC.repay(marketUSDC.previewRefund(50 ether), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.claimable(address(this), opRewardAsset), accruedRewards);
    assertEq(rewardsController.claimable(address(this), exaRewardAsset), accruedExaRewards);
  }

  function testClaimableUSDCWithAnotherAccountInPool() external {
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

    uint256 aliceFirstRewards = rewardsController.claimable(ALICE, opRewardAsset);
    assertEq(aliceFirstRewards, claimable(rewardsController.allAccountOperations(ALICE), ALICE, opRewardAsset));
    assertEq(rewardsController.claimable(BOB, opRewardAsset), 0);
    uint256 aliceFirstExaRewards = rewardsController.claimable(ALICE, exaRewardAsset);
    assertEq(aliceFirstExaRewards, claimable(rewardsController.allAccountOperations(ALICE), ALICE, exaRewardAsset));
    assertEq(rewardsController.claimable(BOB, exaRewardAsset), 0);

    vm.warp(3 days);
    (uint256 depositRewards, uint256 borrowRewards) = previewRewards(marketUSDC, opRewardAsset);
    uint256 aliceRewards = rewardsController.claimable(ALICE, opRewardAsset);
    uint256 bobRewards = rewardsController.claimable(BOB, opRewardAsset);

    assertEq(aliceRewards, claimable(rewardsController.allAccountOperations(ALICE), ALICE, opRewardAsset));
    assertEq(bobRewards, aliceRewards - aliceFirstRewards);
    assertEq(depositRewards + borrowRewards, (aliceRewards - aliceFirstRewards) + bobRewards);

    (depositRewards, borrowRewards) = previewRewards(marketUSDC, exaRewardAsset);
    aliceRewards = rewardsController.claimable(ALICE, exaRewardAsset);
    bobRewards = rewardsController.claimable(BOB, exaRewardAsset);

    assertEq(aliceRewards, claimable(rewardsController.allAccountOperations(ALICE), ALICE, exaRewardAsset));
    assertEq(bobRewards, aliceRewards - aliceFirstExaRewards);
    assertEq(depositRewards + borrowRewards, (aliceRewards - aliceFirstExaRewards) + bobRewards);
  }

  function testClaimableWithMaturedFixedPool() external {
    marketUSDC.deposit(100e6, address(this));
    vm.warp(10_000 seconds);
    marketUSDC.borrowAtMaturity(FixedLib.INTERVAL, 10e6, 20e6, address(this), address(this));

    vm.warp(FixedLib.INTERVAL - 1 days);
    uint256 opRewardsPreMaturity = rewardsController.claimable(address(this), opRewardAsset);
    uint256 exaRewardsPreMaturity = rewardsController.claimable(address(this), exaRewardAsset);
    vm.warp(FixedLib.INTERVAL);
    uint256 opRewardsPostMaturity = rewardsController.claimable(address(this), opRewardAsset);
    uint256 exaRewardsPostMaturity = rewardsController.claimable(address(this), exaRewardAsset);
    assertApproxEqAbs(opRewardsPostMaturity, opRewardsPreMaturity, 1e2);
    assertApproxEqAbs(exaRewardsPostMaturity, exaRewardsPreMaturity, 1e2);

    vm.warp(FixedLib.INTERVAL + 1 days);
    assertApproxEqAbs(rewardsController.claimable(address(this), exaRewardAsset), exaRewardsPostMaturity, 1e2);
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

  function testClaimableWithTimeElapsedZero() external {
    marketUSDC.deposit(10 ether, address(this));
    marketUSDC.borrow(2 ether, address(this), address(this));

    vm.warp(1 days);
    rewardsController.claimAll(address(this));
    uint256 opRewards = rewardsController.claimable(address(this), opRewardAsset);
    (uint256 lastUpdate, , , , uint256 lastUndistributed) = rewardsController.rewardsData(marketUSDC, opRewardAsset);
    (uint256 borrowIndex, uint256 depositIndex) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);
    assertEq(opRewards, 0);

    marketUSDC.deposit(10 ether, address(this));
    marketUSDC.borrow(2 ether, address(this), address(this));
    (uint256 newLastUpdate, , , , uint256 newLastUndistributed) = rewardsController.rewardsData(
      marketUSDC,
      opRewardAsset
    );
    (uint256 newBorrowIndex, uint256 newDepositIndex) = rewardsController.rewardIndexes(marketUSDC, opRewardAsset);

    assertEq(rewardsController.claimable(address(this), opRewardAsset), opRewards);
    assertEq(newLastUpdate, lastUpdate);
    assertEq(newLastUndistributed, lastUndistributed);
    assertEq(borrowIndex, newBorrowIndex);
    assertEq(depositIndex, newDepositIndex);
  }

  function testOperationsArrayShouldNotPushSameOperationTwice() external {
    marketUSDC.deposit(10 ether, address(this));
    marketUSDC.withdraw(10 ether, address(this), address(this));
    rewardsController.claimAll(address(this));
    rewardsController.claimAll(address(this));
    rewardsController.claimAll(address(this));
    RewardsController.MarketOperation[] memory marketOps = rewardsController.allAccountOperations((address(this)));

    assertEq(marketOps[0].operations.length, 1);
  }

  function testUpdateWithTotalDebtZeroShouldNotUpdateLastUndistributed() external {
    marketUSDC.deposit(10 ether, address(this));
    (, , , , uint256 lastUndistributed) = rewardsController.rewardsData(marketUSDC, opRewardAsset);

    vm.warp(1 days);
    (uint256 depositRewards, uint256 borrowRewards) = previewRewards(marketUSDC, opRewardAsset);
    assertEq(depositRewards, 0);
    assertEq(borrowRewards, 0);
    marketUSDC.deposit(10 ether, address(this));
    (uint256 newLastUpdate, , , , uint256 newLastUndistributed) = rewardsController.rewardsData(
      marketUSDC,
      opRewardAsset
    );

    assertEq(newLastUndistributed, lastUndistributed);
    assertEq(newLastUpdate, block.timestamp);
  }

  function testClaimableWETH() external {
    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 opRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertEq(opRewards, claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset));
    uint256 exaRewards = rewardsController.claimable(address(this), exaRewardAsset);
    assertEq(
      exaRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), exaRewardAsset)
    );

    vm.warp(3 days + 20 minutes);
    assertEq(
      rewardsController.claimable(address(this), opRewardAsset),
      claimable(rewardsController.allAccountOperations(address(this)), address(this), opRewardAsset)
    );
    assertEq(rewardsController.claimable(address(this), exaRewardAsset), 0);

    vm.warp(7 days);
    uint256 newOpRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertEq(rewardsController.claimable(address(this), opRewardAsset), newOpRewards);
    assertGt(newOpRewards, opRewards);
  }

  function testAfterDistributionPeriodEnd() external {
    uint256 totalDistribution = 2_000 ether;
    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));

    (, uint256 distributionEnd) = rewardsController.distributionTime(marketWETH);
    vm.warp(distributionEnd);
    uint256 opRewards = rewardsController.claimable(address(this), opRewardAsset);
    vm.warp(distributionEnd + 1);
    assertGt(rewardsController.claimable(address(this), opRewardAsset), opRewards);
    // move in time far away from end of distribution, still rewards are lower than total distribution
    vm.warp(distributionEnd * 4);
    opRewards = rewardsController.claimable(address(this), opRewardAsset);
    assertGt(totalDistribution, opRewards);
    assertApproxEqAbs(totalDistribution, opRewards, 1e12);

    rewardsController.claimAll(address(this));
    assertEq(opRewardAsset.balanceOf(address(this)), opRewards);
  }

  function testUpdateConfig() external {
    vm.warp(1 days);
    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));
    (uint256 preBorrowIndex, uint256 preDepositIndex) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);

    vm.warp(3 days);
    uint256 claimableRewards = rewardsController.claimable(address(this), opRewardAsset);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: marketWETH,
      reward: opRewardAsset,
      targetDebt: 10_000 ether,
      totalDistribution: 1_500 ether,
      distributionPeriod: 10 weeks,
      undistributedFactor: 0.6e18,
      flipSpeed: 1e18,
      compensationFactor: 0.65e18,
      transitionFactor: 0.71e18,
      borrowConstantReward: 0,
      depositConstantReward: 0.02e18,
      depositConstantRewardHighU: 0.01e18
    });
    rewardsController.config(configs);

    (uint256 borrowIndex, uint256 depositIndex) = rewardsController.rewardIndexes(marketWETH, opRewardAsset);
    assertGt(borrowIndex, preBorrowIndex);
    assertGt(depositIndex, preDepositIndex);

    (uint256 lastUpdate, uint256 targetDebt, , uint256 undistributedFactor, ) = rewardsController.rewardsData(
      marketWETH,
      opRewardAsset
    );
    assertEq(lastUpdate, block.timestamp);
    assertEq(targetDebt, 10_000 ether);
    assertEq(undistributedFactor, 0.6e18);

    rewardsController.claimAll(address(this));
    assertEq(opRewardAsset.balanceOf(address(this)), claimableRewards);
  }

  function testClaim() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.borrow(10e6, address(this), address(this));

    vm.warp(4 days + 20 minutes);
    uint256 opClaimableRewards = rewardsController.claimable(address(this), opRewardAsset);
    RewardsController.Operation[] memory ops = new RewardsController.Operation[](2);
    ops[0] = RewardsController.Operation.Deposit;
    ops[1] = RewardsController.Operation.Borrow;
    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
    marketOps[0] = RewardsController.MarketOperation({ market: marketUSDC, operations: ops });
    rewardsController.claim(marketOps, address(this));

    assertEq(opRewardAsset.balanceOf(address(this)), opClaimableRewards);
    assertEq(rewardsController.claimable(address(this), opRewardAsset), 0);
  }

  function testClaimAll() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.borrow(10e6, address(this), address(this));
    marketWETH.deposit(100 ether, address(this));
    marketWETH.borrow(10 ether, address(this), address(this));

    vm.warp(4 days + 20 minutes);
    uint256 opClaimableRewards = rewardsController.claimable(address(this), opRewardAsset);
    uint256 exaClaimableRewards = rewardsController.claimable(address(this), exaRewardAsset);
    rewardsController.claimAll(address(this));

    assertEq(opRewardAsset.balanceOf(address(this)), opClaimableRewards);
    assertEq(rewardsController.claimable(address(this), opRewardAsset), 0);
    assertEq(exaRewardAsset.balanceOf(address(this)), exaClaimableRewards);
    assertEq(rewardsController.claimable(address(this), exaRewardAsset), 0);
  }

  function testSetDistributionOperationShouldUpdateIndex() external {
    vm.warp(2 days);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: marketUSDC,
      reward: opRewardAsset,
      targetDebt: 1_000 ether,
      totalDistribution: 100_000 ether,
      distributionPeriod: 10 days,
      undistributedFactor: 0.5e18,
      flipSpeed: 2e18,
      compensationFactor: 0.5e18,
      transitionFactor: 0.64e18,
      borrowConstantReward: 0,
      depositConstantReward: 0,
      depositConstantRewardHighU: 0
    });
    rewardsController.config(configs);

    (uint256 lastUpdate, , , , ) = rewardsController.rewardsData(marketUSDC, opRewardAsset);
    assertEq(lastUpdate, 2 days);
  }

  function accountMaturityOperations(
    Market market,
    RewardsController.Operation[] memory ops,
    address account
  ) internal view returns (RewardsController.AccountOperation[] memory accountMaturityOps) {
    accountMaturityOps = new RewardsController.AccountOperation[](ops.length);
    for (uint256 i = 0; i < ops.length; i++) {
      if (ops[i] == RewardsController.Operation.Borrow) {
        (, , uint256 floatingBorrowShares) = market.accounts(account);
        accountMaturityOps[i] = RewardsController.AccountOperation({
          operation: ops[i],
          balance: floatingBorrowShares + accountFixedBorrowShares(market, account)
        });
      } else {
        accountMaturityOps[i] = RewardsController.AccountOperation({
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

      RewardsController.AccountOperation[] memory ops = accountMaturityOperations(
        marketOps[i].market,
        marketOps[i].operations,
        account
      );
      for (uint256 o = 0; o < ops.length; ++o) {
        (uint256 accrued, ) = rewardsController.accountOperation(
          account,
          marketOps[i].market,
          ops[o].operation,
          rewardAsset
        );
        unclaimedRewards += accrued;
      }
      unclaimedRewards += pendingRewards(
        account,
        rewardAsset,
        RewardsController.AccountMarketOperation({ market: marketOps[i].market, accountOperations: ops })
      );
    }
  }

  function pendingRewards(
    address account,
    ERC20 rewardAsset,
    RewardsController.AccountMarketOperation memory ops
  ) internal view returns (uint256 rewards) {
    uint256 baseUnit = 10 ** rewardsController.decimals(ops.market);
    (uint256 borrowRewards, uint256 depositRewards) = previewRewards(ops.market, rewardAsset);
    (uint256 borrowIndex, uint256 depositIndex) = rewardsController.rewardIndexes(ops.market, rewardAsset);
    {
      uint256 totalDebt = ops.market.totalFloatingBorrowShares() + totalFixedBorrowShares(ops.market);
      uint256 totalSupply = ops.market.totalSupply();
      borrowIndex += totalDebt > 0 ? borrowRewards.mulDivDown(baseUnit, totalDebt) : 0;
      depositIndex += totalSupply > 0 ? depositRewards.mulDivDown(baseUnit, totalSupply) : 0;
    }
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

  function previewRewards(
    Market market,
    ERC20 rewardAsset
  ) internal view returns (uint256 borrowRewards, uint256 depositRewards) {
    RewardsData memory r;
    (r.lastUpdate, r.targetDebt, r.mintingRate, r.undistributedFactor, r.lastUndistributed) = rewardsController
      .rewardsData(market, rewardAsset);
    RewardsController.TotalMarketBalance memory m;
    m.debt = market.totalFloatingBorrowAssets();
    m.supply = market.totalAssets();
    {
      (uint256 distributionStart, ) = rewardsController.distributionTime(market);
      uint256 firstMaturity = distributionStart - (distributionStart % FixedLib.INTERVAL) + FixedLib.INTERVAL;
      uint256 maxMaturity = block.timestamp -
        (block.timestamp % FixedLib.INTERVAL) +
        (FixedLib.INTERVAL * market.maxFuturePools());
      for (uint256 maturity = firstMaturity; maturity <= maxMaturity; maturity += FixedLib.INTERVAL) {
        (uint256 borrowed, uint256 supplied) = market.fixedPoolBalance(maturity);
        m.debt += borrowed;
        m.supply += supplied;
      }
    }

    uint256 target = m.debt < r.targetDebt ? m.debt.divWadDown(r.targetDebt) : 1e18;
    uint256 distributionFactor = r.undistributedFactor.mulWadDown(target);
    if (distributionFactor > 0) {
      uint256 rewards;
      {
        (, uint256 distributionEnd) = rewardsController.distributionTime(market);
        if (block.timestamp <= distributionEnd) {
          uint256 deltaTime = block.timestamp - r.lastUpdate;
          uint256 exponential = uint256((-int256(distributionFactor * deltaTime)).expWad());
          uint256 newUndistributed = r.lastUndistributed +
            r.mintingRate.mulWadDown(1e18 - target).divWadDown(distributionFactor).mulWadDown(1e18 - exponential) -
            r.lastUndistributed.mulWadDown(1e18 - exponential);
          rewards = r.targetDebt.mulWadDown(
            uint256(int256(r.mintingRate * deltaTime) - (int256(newUndistributed) - int256(r.lastUndistributed)))
          );
        } else if (r.lastUpdate > distributionEnd) {
          uint256 newUndistributed = r.lastUndistributed -
            r.lastUndistributed.mulWadDown(
              1e18 - uint256((-int256(distributionFactor * (block.timestamp - r.lastUpdate))).expWad())
            );
          rewards = r.targetDebt.mulWadDown(uint256(-(int256(newUndistributed) - int256(r.lastUndistributed))));
        } else {
          uint256 deltaTime = distributionEnd - r.lastUpdate;
          uint256 exponential = uint256((-int256(distributionFactor * deltaTime)).expWad());
          uint256 newUndistributed = r.lastUndistributed +
            r.mintingRate.mulWadDown(1e18 - target).divWadDown(distributionFactor).mulWadDown(1e18 - exponential) -
            r.lastUndistributed.mulWadDown(1e18 - exponential);
          exponential = uint256((-int256(distributionFactor * (block.timestamp - distributionEnd))).expWad());
          newUndistributed = newUndistributed - newUndistributed.mulWadDown(1e18 - exponential);
          rewards = r.targetDebt.mulWadDown(
            uint256(int256(r.mintingRate * deltaTime) - (int256(newUndistributed) - int256(r.lastUndistributed)))
          );
        }
      }

      // reusing vars due to stack too deep
      (m.debt, m.supply) = allocationFactors(market, m.debt, m.supply, target, rewardAsset);
      borrowRewards = rewards.mulWadDown(m.debt);
      depositRewards = rewards.mulWadDown(m.supply);
    }
  }

  function allocationFactors(
    Market market,
    uint256 totalDebt,
    uint256 totalDeposits,
    uint256 target,
    ERC20 rewardAsset
  ) internal view returns (uint256, uint256) {
    RewardsController.AllocationVars memory v;
    AllocationParams memory p;
    (
      p.flipSpeed,
      p.compensationFactor,
      p.transitionFactor,
      p.borrowConstantReward,
      p.depositConstantReward,
      p.depositConstantRewardHighU
    ) = rewardsController.rewardAllocationParams(market, rewardAsset);
    v.utilization = totalDeposits > 0 ? totalDebt.divWadDown(totalDeposits) : 0;
    v.sigmoid = v.utilization > 0
      ? uint256(1e18).divWadDown(
        1e18 +
          uint256(
            (-(p.flipSpeed *
              (int256(v.utilization.divWadDown(1e18 - v.utilization)).lnWad() -
                int256(p.transitionFactor.divWadDown(1e18 - p.transitionFactor)).lnWad())) / 1e18).expWad()
          )
      )
      : 0;
    v.borrowRewardRule = p
      .compensationFactor
      .mulWadDown(
        market.interestRateModel().floatingRate(v.utilization).mulWadDown(
          1e18 - v.utilization.mulWadDown(1e18 - target)
        ) + p.borrowConstantReward
      )
      .mulWadDown(1e18 - v.sigmoid);
    v.depositRewardRule =
      p.depositConstantReward.mulWadDown(1e18 - v.sigmoid) +
      p.depositConstantRewardHighU.mulWadDown(p.borrowConstantReward).mulWadDown(v.sigmoid);
    v.borrowAllocation = v.borrowRewardRule.divWadDown(v.borrowRewardRule + v.depositRewardRule);
    v.depositAllocation = 1e18 - v.borrowAllocation;
    return (v.borrowAllocation, v.depositAllocation);
  }

  function totalFixedBorrowShares(Market market) internal view returns (uint256 fixedDebt) {
    for (uint256 i = 0; i < market.maxFuturePools(); i++) {
      (uint256 borrowed, , , ) = market.fixedPools(
        block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL * (i + 1)
      );
      fixedDebt += borrowed;
    }
    fixedDebt = market.previewRepay(fixedDebt);
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

  struct AllocationParams {
    int256 flipSpeed;
    uint256 compensationFactor;
    uint256 transitionFactor;
    uint256 borrowConstantReward;
    uint256 depositConstantReward;
    uint256 depositConstantRewardHighU;
  }

  struct RewardsData {
    uint256 lastUpdate;
    uint256 targetDebt;
    uint256 mintingRate;
    uint256 undistributedFactor;
    uint256 lastUndistributed;
  }
}
