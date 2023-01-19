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
  MockERC20 internal rewardsAsset;
  MockInterestRateModel internal irm;

  function setUp() external {
    vm.warp(0);
    MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
    MockERC20 weth = new MockERC20("WETH", "WETH", 18);
    MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 18);
    rewardsAsset = new MockERC20("OP", "OP", 18);

    auditor = Auditor(address(new ERC1967Proxy(address(new Auditor(18)), "")));
    auditor.initialize(Auditor.LiquidationIncentive(0.09e18, 0.01e18));
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
    auditor.enableMarket(marketWBTC, new MockPriceFeed(18, 20_000e18), 0.9e18, 18);

    rewardsController = RewardsController(address(new ERC1967Proxy(address(new RewardsController(auditor)), "")));
    rewardsController.initialize();
    RewardsController.Config[] memory configs = new RewardsController.Config[](2);
    configs[0] = RewardsController.Config({
      market: marketUSDC,
      reward: address(rewardsAsset),
      targetDebt: 20_000 ether,
      totalDistribution: 2_000 ether,
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.5e18,
      decaySpeed: 2,
      compensationFactor: 0.85e18,
      borrowConstantReward: 0,
      depositConstantReward: 0.02e18
    });
    configs[1] = RewardsController.Config({
      market: marketWETH,
      reward: address(rewardsAsset),
      targetDebt: 20_000 ether,
      totalDistribution: 2_000 ether,
      distributionPeriod: 12 weeks,
      undistributedFactor: 0.5e18,
      decaySpeed: 2,
      compensationFactor: 0.85e18,
      borrowConstantReward: 0,
      depositConstantReward: 0.02e18
    });
    rewardsController.config(configs);
    marketUSDC.setRewardsController(rewardsController);
    marketWETH.setRewardsController(rewardsController);
    rewardsAsset.mint(address(rewardsController), 4_000 ether);

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
      rewardsController.claimable(address(this), address(rewardsAsset)),
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
    vm.warp(3 days + 20 minutes);
    assertEq(
      rewardsController.claimable(address(this), address(rewardsAsset)),
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
    vm.warp(7 days);
    assertEq(
      rewardsController.claimable(address(this), address(rewardsAsset)),
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
  }

  function testClaimableUSDCWithMint() external {
    marketUSDC.mint(100e6, address(this));
    marketUSDC.borrow(30e6, address(this), address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), address(rewardsAsset));
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );

    vm.warp(7 days);
    uint256 newAccruedRewards = rewardsController.claimable(address(this), address(rewardsAsset));
    assertEq(
      newAccruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
    assertGt(newAccruedRewards, accruedRewards);
  }

  function testClaimableUSDCWithTransfer() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.deposit(100e6, address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), address(rewardsAsset));
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
    marketUSDC.transfer(ALICE, marketUSDC.balanceOf(address(this)));

    vm.warp(7 days);
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
    assertEq(
      rewardsController.claimable(ALICE, address(rewardsAsset)),
      claimable(rewardsController.allAccountOperations(ALICE), ALICE, address(rewardsAsset))
    );
  }

  function testClaimableUSDCWithTransferFrom() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.deposit(100e6, address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), address(rewardsAsset));
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
    marketUSDC.approve(address(this), type(uint256).max);
    marketUSDC.transferFrom(address(this), ALICE, marketUSDC.balanceOf(address(this)));

    vm.warp(7 days);
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
    assertEq(
      rewardsController.claimable(ALICE, address(rewardsAsset)),
      claimable(rewardsController.allAccountOperations(ALICE), ALICE, address(rewardsAsset))
    );
  }

  function testClaimableUSDCWithWithdraw() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.deposit(100e6, address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), address(rewardsAsset));
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
    marketUSDC.withdraw(marketUSDC.convertToAssets(marketUSDC.balanceOf(address(this))), address(this), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.claimable(address(this), address(rewardsAsset)), accruedRewards);
  }

  function testClaimableUSDCWithRedeem() external {
    vm.startPrank(BOB);
    marketUSDC.deposit(100e6, BOB);
    marketUSDC.borrow(30e6, BOB, BOB);
    vm.stopPrank();
    marketUSDC.deposit(100e6, address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), address(rewardsAsset));
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
    marketUSDC.redeem(marketUSDC.balanceOf(address(this)), address(this), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.claimable(address(this), address(rewardsAsset)), accruedRewards);
  }

  function testClaimableUSDCWithFloatingBorrow() external {
    vm.prank(ALICE);
    marketUSDC.deposit(100e6, ALICE);

    marketWBTC.deposit(1_000 ether, address(this));
    auditor.enterMarket(marketWBTC);
    marketUSDC.borrow(50e6, address(this), address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), address(rewardsAsset));
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );

    vm.warp(7 days);
    uint256 newAccruedRewards = rewardsController.claimable(address(this), address(rewardsAsset));
    assertEq(
      newAccruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
    assertGt(newAccruedRewards, accruedRewards);
  }

  function testClaimableUSDCWithFloatingRefund() external {
    vm.prank(ALICE);
    marketUSDC.deposit(100e6, ALICE);

    marketWBTC.deposit(1_000 ether, address(this));
    auditor.enterMarket(marketWBTC);
    marketUSDC.borrow(50e6, address(this), address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), address(rewardsAsset));
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
    marketUSDC.refund(50 ether, address(this));

    vm.warp(7 days);
    assertEq(rewardsController.claimable(address(this), address(rewardsAsset)), accruedRewards);
  }

  function testClaimableUSDCWithFloatingRepay() external {
    vm.prank(ALICE);
    marketUSDC.deposit(100e6, ALICE);

    marketWBTC.deposit(1_000 ether, address(this));
    auditor.enterMarket(marketWBTC);
    marketUSDC.borrow(50e6, address(this), address(this));

    vm.warp(3 days);
    uint256 accruedRewards = rewardsController.claimable(address(this), address(rewardsAsset));
    assertEq(
      accruedRewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );
    marketUSDC.repay(marketUSDC.previewRefund(50 ether), address(this));

    vm.warp(7 days);
    assertEq(rewardsController.claimable(address(this), address(rewardsAsset)), accruedRewards);
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

    uint256 aliceFirstRewards = rewardsController.claimable(ALICE, address(rewardsAsset));
    assertEq(aliceFirstRewards, claimable(rewardsController.allAccountOperations(ALICE), ALICE, address(rewardsAsset)));
    assertEq(rewardsController.claimable(BOB, address(rewardsAsset)), 0);

    vm.warp(3 days);
    (uint256 depositRewards, uint256 borrowRewards) = previewRewards(marketUSDC);
    uint256 aliceRewards = rewardsController.claimable(ALICE, address(rewardsAsset));
    uint256 bobRewards = rewardsController.claimable(BOB, address(rewardsAsset));

    assertEq(aliceRewards, claimable(rewardsController.allAccountOperations(ALICE), ALICE, address(rewardsAsset)));
    assertEq(bobRewards, aliceRewards - aliceFirstRewards);
    assertEq(depositRewards + borrowRewards, (aliceRewards - aliceFirstRewards) + bobRewards);
  }

  function testClaimableWithMaturedFixedPool() external {
    marketUSDC.deposit(100e6, address(this));
    vm.warp(10_000 seconds);
    marketUSDC.borrowAtMaturity(FixedLib.INTERVAL, 10e6, 20e6, address(this), address(this));

    vm.warp(FixedLib.INTERVAL - 1 seconds);
    uint256 rewardsBefMaturity = rewardsController.claimable(address(this), address(rewardsAsset));
    vm.warp(FixedLib.INTERVAL);
    uint256 rewardsAftMaturity = rewardsController.claimable(address(this), address(rewardsAsset));
    assertGt(rewardsAftMaturity, rewardsBefMaturity);
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
    uint256 rewards = rewardsController.claimable(address(this), address(rewardsAsset));
    (uint256 lastUpdate, , , , uint256 lastUndistributed) = rewardsController.rewardsData(
      marketUSDC,
      address(rewardsAsset)
    );
    (uint256 floatingBorrowIndex, uint256 floatingDepositIndex) = rewardsController.rewardIndexes(
      marketUSDC,
      address(rewardsAsset)
    );
    assertEq(rewards, 0);

    marketUSDC.deposit(10 ether, address(this));
    marketUSDC.borrow(2 ether, address(this), address(this));
    (uint256 newLastUpdate, , , , uint256 newLastUndistributed) = rewardsController.rewardsData(
      marketUSDC,
      address(rewardsAsset)
    );
    (uint256 newFloatingBorrowIndex, uint256 newFloatingDepositIndex) = rewardsController.rewardIndexes(
      marketUSDC,
      address(rewardsAsset)
    );

    assertEq(rewardsController.claimable(address(this), address(rewardsAsset)), rewards);
    assertEq(newLastUpdate, lastUpdate);
    assertEq(newLastUndistributed, lastUndistributed);
    assertEq(floatingBorrowIndex, newFloatingBorrowIndex);
    assertEq(floatingDepositIndex, newFloatingDepositIndex);
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
    (, , , , uint256 lastUndistributed) = rewardsController.rewardsData(marketUSDC, address(rewardsAsset));

    vm.warp(1 days);
    (uint256 depositRewards, uint256 borrowRewards) = previewRewards(marketUSDC);
    assertEq(depositRewards, 0);
    assertEq(borrowRewards, 0);
    marketUSDC.deposit(10 ether, address(this));
    (uint256 newLastUpdate, , , , uint256 newLastUndistributed) = rewardsController.rewardsData(
      marketUSDC,
      address(rewardsAsset)
    );

    assertEq(newLastUndistributed, lastUndistributed);
    assertEq(newLastUpdate, block.timestamp);
  }

  function testClaimableWETH() external {
    marketWETH.deposit(10 ether, address(this));
    marketWETH.borrow(1 ether, address(this), address(this));

    vm.warp(3 days);
    uint256 rewards = rewardsController.claimable(address(this), address(rewardsAsset));
    assertEq(
      rewards,
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );

    vm.warp(3 days + 20 minutes);
    assertEq(
      rewardsController.claimable(address(this), address(rewardsAsset)),
      claimable(rewardsController.allAccountOperations(address(this)), address(this), address(rewardsAsset))
    );

    vm.warp(7 days);
    uint256 newRewards = rewardsController.claimable(address(this), address(rewardsAsset));
    assertEq(rewardsController.claimable(address(this), address(rewardsAsset)), newRewards);
    assertGt(newRewards, rewards);
  }

  function testClaim() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.borrow(10e6, address(this), address(this));

    vm.warp(4 days + 20 minutes);
    uint256 rewardsToBeClaimed = rewardsController.claimable(address(this), address(rewardsAsset));
    RewardsController.Operation[] memory ops = new RewardsController.Operation[](2);
    ops[0] = RewardsController.Operation.Deposit;
    ops[1] = RewardsController.Operation.Borrow;
    RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
    marketOps[0] = RewardsController.MarketOperation({ market: marketUSDC, operations: ops });
    rewardsController.claim(marketOps, address(this));

    assertEq(rewardsAsset.balanceOf(address(this)), rewardsToBeClaimed);
    assertEq(rewardsController.claimable(address(this), address(rewardsAsset)), 0);
  }

  function testClaimAll() external {
    marketUSDC.deposit(100e6, address(this));
    marketUSDC.borrow(10e6, address(this), address(this));
    marketWETH.deposit(100 ether, address(this));
    marketWETH.borrow(10 ether, address(this), address(this));

    vm.warp(4 days + 20 minutes);
    uint256 rewardsToBeClaimed = rewardsController.claimable(address(this), address(rewardsAsset));
    rewardsController.claimAll(address(this));

    assertEq(rewardsAsset.balanceOf(address(this)), rewardsToBeClaimed);
    assertEq(rewardsController.claimable(address(this), address(rewardsAsset)), 0);
  }

  function testSetDistributionOperationShouldUpdateIndex() external {
    vm.warp(2 days);
    RewardsController.Config[] memory configs = new RewardsController.Config[](1);
    configs[0] = RewardsController.Config({
      market: marketUSDC,
      reward: address(rewardsAsset),
      targetDebt: 1_000 ether,
      totalDistribution: 100_000 ether,
      distributionPeriod: 10 days,
      undistributedFactor: 0.5e18,
      decaySpeed: 2,
      compensationFactor: 0.5e18,
      borrowConstantReward: 0,
      depositConstantReward: 0
    });
    rewardsController.config(configs);

    (uint256 lastUpdate, , , , ) = rewardsController.rewardsData(marketUSDC, address(rewardsAsset));
    assertEq(lastUpdate, 2 days);
  }

  function accountMaturityOperations(
    Market market,
    RewardsController.Operation[] memory ops,
    address account
  ) internal view returns (RewardsController.AccountOperation[] memory accountMaturityOps) {
    accountMaturityOps = new RewardsController.AccountOperation[](ops.length);
    for (uint256 i = 0; i < ops.length; i++) {
      if (ops[i] == RewardsController.Operation.Deposit) {
        accountMaturityOps[i] = RewardsController.AccountOperation({
          operation: ops[i],
          balance: market.balanceOf(account)
        });
      } else if (ops[i] == RewardsController.Operation.Borrow) {
        (, , uint256 floatingBorrowShares) = market.accounts(account);
        accountMaturityOps[i] = RewardsController.AccountOperation({
          operation: ops[i],
          balance: floatingBorrowShares + accountFixedBorrowShares(market, account)
        });
      }
    }
  }

  function claimable(
    RewardsController.MarketOperation[] memory marketOps,
    address account,
    address reward
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
          reward
        );
        unclaimedRewards += accrued;
      }
      unclaimedRewards += pendingRewards(
        account,
        reward,
        RewardsController.AccountMarketOperation({ market: marketOps[i].market, accountOperations: ops })
      );
    }
  }

  function pendingRewards(
    address account,
    address reward,
    RewardsController.AccountMarketOperation memory ops
  ) internal view returns (uint256 rewards) {
    uint256 baseUnit = 10 ** rewardsController.decimals(ops.market);
    (uint256 depositRewards, uint256 borrowRewards) = previewRewards(ops.market);
    (uint256 borrowIndex, uint256 depositIndex) = rewardsController.rewardIndexes(ops.market, reward);
    depositIndex += ops.market.totalSupply() > 0 ? depositRewards.mulDivDown(baseUnit, ops.market.totalSupply()) : 0;
    borrowIndex += ops.market.totalFloatingBorrowShares() + totalFixedBorrowShares(ops.market) > 0
      ? borrowRewards.mulDivDown(baseUnit, ops.market.totalFloatingBorrowShares() + totalFixedBorrowShares(ops.market))
      : 0;
    for (uint256 o = 0; o < ops.accountOperations.length; ++o) {
      (, uint256 accountIndex) = rewardsController.accountOperation(
        account,
        ops.market,
        ops.accountOperations[o].operation,
        reward
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

  function previewRewards(Market market) internal view returns (uint256 depositRewards, uint256 borrowRewards) {
    (
      uint256 lastUpdate,
      uint256 targetDebt,
      uint256 mintingRate,
      uint256 undistributedFactor,
      uint256 lastUndistributed
    ) = rewardsController.rewardsData(market, address(rewardsAsset));
    uint256 totalDebt = market.totalFloatingBorrowAssets();
    {
      uint256 memMaxFuturePools = market.maxFuturePools();
      uint256 latestMaturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL);
      uint256 maxMaturity = latestMaturity + memMaxFuturePools * FixedLib.INTERVAL;
      for (uint256 m = latestMaturity; m <= maxMaturity; m += FixedLib.INTERVAL) {
        (uint256 borrowed, , , ) = market.fixedPools(m);
        totalDebt += borrowed;
      }
    }

    uint256 target = totalDebt < targetDebt ? totalDebt.divWadDown(targetDebt) : 1e18;
    uint256 distributionFactor = undistributedFactor.mulWadDown(target);
    if (distributionFactor > 0) {
      uint256 deltaTime = block.timestamp - lastUpdate;

      uint256 exponential = uint256((-int256(distributionFactor * deltaTime)).expWad());
      uint256 newUndistributed = lastUndistributed +
        mintingRate.mulWadDown(1e18 - target).divWadDown(distributionFactor).mulWadDown(1e18 - exponential) -
        lastUndistributed.mulWadDown(1e18 - exponential);
      uint256 rewards = targetDebt.mulWadDown(
        uint256(int256(mintingRate * deltaTime) - (int256(newUndistributed) - int256(lastUndistributed)))
      );
      // reusing vars due to stack too deep :(
      (exponential, newUndistributed) = allocationFactors(market, totalDebt, target);
      borrowRewards = rewards.mulWadDown(exponential);
      depositRewards = rewards.mulWadDown(newUndistributed);
    }
  }

  function allocationFactors(
    Market market,
    uint256 totalDebt,
    uint256 target
  ) internal view returns (uint256, uint256) {
    RewardsController.AllocationVars memory v;
    {
      (
        uint256 decaySpeed,
        uint256 compensationFactor,
        uint256 borrowConstantReward,
        uint256 depositConstantReward
      ) = rewardsController.rewardAllocationParams(market, address(rewardsAsset));
      v.utilization = market.totalAssets() > 0 ? totalDebt.divWadDown(market.totalAssets()) : 0;
      v.adjustFactor = rewardsController.auditor().adjustFactor(market);
      v.sigmoid = v.utilization > 0
        ? uint256(1e18).divWadDown(
          1e18 +
            (1e18 - v.utilization).divWadDown(v.utilization).mulWadDown(
              (v.adjustFactor.mulWadDown(v.adjustFactor)).divWadDown(1e18 - v.adjustFactor.mulWadDown(v.adjustFactor))
            ) **
              decaySpeed /
            1e18 ** (decaySpeed - 1)
        )
        : 0;
      v.borrowRewardRule = compensationFactor
        .mulWadDown(
          market.interestRateModel().floatingRate(v.utilization).mulWadDown(
            1e18 - v.utilization.mulWadDown(1e18 - target)
          ) + borrowConstantReward
        )
        .mulWadDown(1e18 - v.sigmoid);
      v.depositRewardRule =
        depositConstantReward +
        (v.adjustFactor.mulWadDown(v.adjustFactor))
          .divWadDown(1e18 - v.adjustFactor.mulWadDown(v.adjustFactor))
          .mulWadDown(borrowConstantReward)
          .mulWadDown(v.sigmoid);
      v.borrowAllocation = v.borrowRewardRule.divWadDown(v.borrowRewardRule + v.depositRewardRule);
      v.depositAllocation = 1e18 - v.borrowAllocation;
      return (v.borrowAllocation, v.depositAllocation);
    }
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
}
