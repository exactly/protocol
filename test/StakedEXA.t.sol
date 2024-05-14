// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
  IERC20Upgradeable as IERC20
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import { Test } from "forge-std/Test.sol";

import {
  StakedEXA,
  InsufficientBalance,
  NotFinished,
  Untransferable,
  ZeroAmount,
  ZeroRate
} from "../contracts/StakedEXA.sol";

contract StakedEXATest is Test {
  using FixedPointMathLib for uint256;

  address internal constant BOB = address(0x420);
  StakedEXA internal stEXA;
  MockERC20 internal exa;
  MockERC20 internal rewardsToken;
  uint256 internal exaBalance;
  uint256 internal initialAmount;
  uint256 internal duration;
  uint256 internal minTime;
  uint256 internal refTime;
  uint256 internal excessFactor;
  uint256 internal penaltyGrowth;
  uint256 internal penaltyThreshold;

  function setUp() external {
    vm.warp(1_704_067_200); // 01/01/2024 @ 00:00 (UTC)
    exa = new MockERC20("Exactly token", "EXA", 18);
    vm.label(address(exa), "EXA");
    rewardsToken = new MockERC20("Rewards token", "REW", 18);
    vm.label(address(rewardsToken), "Rewards token");

    duration = 24 weeks;
    initialAmount = 1_000 ether;
    minTime = 1 weeks;
    refTime = duration;
    excessFactor = 0.5e18;
    penaltyGrowth = 2e18;
    penaltyThreshold = 0.5e18;

    stEXA = StakedEXA(address(new ERC1967Proxy(address(new StakedEXA(IERC20(address(exa)), rewardsToken)), "")));
    stEXA.initialize(minTime, refTime, excessFactor, penaltyGrowth, penaltyThreshold);
    vm.label(address(stEXA), "StakedEXA");

    exaBalance = 1_000_000 ether;
    exa.mint(address(this), exaBalance);

    exa.approve(address(stEXA), type(uint256).max);

    rewardsToken.mint(address(stEXA), initialAmount);

    stEXA.setRewardsDuration(duration);
    stEXA.notifyRewardAmount(initialAmount);

    vm.label(BOB, "bob");
    exa.mint(BOB, exaBalance);
  }

  function testInitialValues() external view {
    assertEq(stEXA.duration(), duration);
    assertEq(stEXA.rewardRate(), initialAmount / duration);
    assertEq(stEXA.finishAt(), block.timestamp + duration);
    assertEq(stEXA.updatedAt(), block.timestamp);
    assertEq(stEXA.index(), 0);
    assertEq(stEXA.totalSupply(), 0);
    assertEq(stEXA.balanceOf(address(this)), 0);

    assertEq(stEXA.minTime(), minTime);
    assertEq(stEXA.refTime(), refTime);
    assertEq(stEXA.penaltyGrowth(), penaltyGrowth);
    assertEq(stEXA.penaltyThreshold(), penaltyThreshold);
  }

  function testInsufficientBalanceError(uint256 amount) external {
    amount = _bound(amount, 1e8, initialAmount * 2);
    vm.expectRevert(InsufficientBalance.selector);
    stEXA.notifyRewardAmount(amount);
  }

  function testZeroRateError() external {
    skip(duration + 1);
    vm.expectRevert(ZeroRate.selector);
    stEXA.notifyRewardAmount(0);
  }

  function testUntransferable(uint256 assets) external {
    assets = _bound(assets, 1, exaBalance);

    uint256 shares = stEXA.deposit(assets, address(this));

    vm.expectRevert(Untransferable.selector);
    stEXA.transfer(address(0x1), shares);
  }

  function testSetDuration(uint256 skipTime, uint256 duration_) external {
    skipTime = _bound(skipTime, 1, duration * 2);
    duration_ = _bound(duration_, 1, 200 weeks);

    skip(skipTime);
    if (skipTime < duration) vm.expectRevert(NotFinished.selector);
    stEXA.setRewardsDuration(duration_);

    if (skipTime <= duration) assertEq(stEXA.duration(), duration);
    else assertEq(stEXA.duration(), duration_);
  }

  function testTotalSupplyDeposit(uint256 assets) external {
    assets = _bound(assets, 0, exaBalance);
    uint256 prevSupply = stEXA.totalSupply();

    if (assets == 0) vm.expectRevert(ZeroAmount.selector);
    stEXA.deposit(assets, address(this));
    assertEq(stEXA.totalSupply(), prevSupply + assets);
  }

  function testTotalSupplyWithdraw(uint256 assets) external {
    assets = _bound(assets, 0, stEXA.balanceOf(address(this)));
    uint256 prevSupply = stEXA.totalSupply();

    if (assets == 0) vm.expectRevert(ZeroAmount.selector);
    stEXA.withdraw(assets, address(this), address(this));
    assertEq(stEXA.totalSupply(), prevSupply - assets);
  }

  function testBalanceOfDeposit(uint256 assets) external {
    assets = _bound(assets, 0, exaBalance);
    uint256 prevBalance = stEXA.balanceOf(address(this));

    if (assets == 0) vm.expectRevert(ZeroAmount.selector);
    stEXA.deposit(assets, address(this));
    assertEq(stEXA.balanceOf(address(this)), prevBalance + assets);
  }

  function testBalanceOfWithdraw(uint256 assets) external {
    assets = _bound(assets, 0, stEXA.balanceOf(address(this)));
    uint256 prevBalance = stEXA.balanceOf(address(this));
    if (assets == 0) vm.expectRevert(ZeroAmount.selector);
    stEXA.withdraw(assets, address(this), address(this));
    assertEq(stEXA.balanceOf(address(this)), prevBalance - assets);
  }

  function testEarnedWithTime(uint256 time) external {
    uint256 prevEarned = stEXA.earned(address(this));

    time = _bound(time, 1, duration + 1);
    skip(time);

    uint256 earned = stEXA.earned(address(this));

    if (stEXA.balanceOf(address(this)) != 0) assertGt(earned, prevEarned);
    else assertEq(earned, prevEarned);
  }

  function testWithdrawWithRewards(uint256 assets) external {
    assets = _bound(assets, 1, exaBalance);

    stEXA.deposit(assets, address(this));
    uint256 rate = initialAmount / duration;
    skip(duration / 2);
    uint256 earned = rate * (duration / 2);
    assertApproxEqAbs(stEXA.earned(address(this)), earned, 1e6);

    uint256 thisClaimable = stEXA.claimable(address(this));
    stEXA.withdraw(assets, address(this), address(this));
    assertApproxEqAbs(rewardsToken.balanceOf(address(this)), thisClaimable, 1e6, "rewards != earned");
  }

  // events
  function testDepositEvent(uint256 assets) external {
    assets = _bound(assets, 1, exaBalance);

    uint256 shares = stEXA.previewDeposit(assets);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit Deposit(address(this), address(this), assets, shares);
    stEXA.deposit(assets, address(this));
  }

  function testWithdrawEvent(uint256 assets) external {
    assets = _bound(assets, 1, exaBalance);

    uint256 shares = stEXA.deposit(assets, address(this));

    vm.expectEmit(true, true, true, true, address(stEXA));
    emit Withdraw(address(this), address(this), address(this), assets, shares);
    stEXA.withdraw(assets, address(this), address(this));
  }

  function testRewardAmountNotifiedEvent(uint256 amount) external {
    amount = _bound(amount, 1, initialAmount * 2);

    rewardsToken.mint(address(stEXA), amount);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardAmountNotified(address(this), amount);
    stEXA.notifyRewardAmount(amount);
  }

  function testRewardPaidEvent(uint256 assets, uint256 time) external {
    assets = _bound(assets, 1, initialAmount * 2);
    time = _bound(time, 1, duration + 1);

    stEXA.deposit(assets, address(this));

    skip(time);

    uint256 claimable = stEXA.claimable(address(this));

    if (claimable != 0) {
      vm.expectEmit(true, true, true, true, address(stEXA));
      emit RewardPaid(address(this), claimable);
    }
    stEXA.withdraw(assets, address(this), address(this));
  }

  function testRewardsDurationSetEvent(uint256 duration_) external {
    skip(duration + 1);

    duration_ = _bound(duration_, 1, 200 weeks);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardsDurationSet(address(this), duration_);
    stEXA.setRewardsDuration(duration_);
  }

  function testNotifyRewardAmount(uint256 amount, uint256 time) external {
    amount = _bound(amount, 1e8, initialAmount * 2);
    time = _bound(time, 1, duration * 2);

    vm.warp(block.timestamp + time);

    uint256 expectedRate = 0;
    if (block.timestamp >= stEXA.finishAt()) {
      expectedRate = amount / stEXA.duration();
    } else {
      expectedRate = (amount + (stEXA.finishAt() - block.timestamp) * stEXA.rewardRate()) / stEXA.duration();
    }

    rewardsToken.mint(address(stEXA), amount);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardAmountNotified(address(this), amount);
    stEXA.notifyRewardAmount(amount);

    assertEq(stEXA.rewardRate(), expectedRate, "rate != expected");
    assertEq(stEXA.finishAt(), block.timestamp + stEXA.duration(), "finishAt != expected");
    assertEq(stEXA.updatedAt(), block.timestamp, "updatedAt != expected");
  }

  // restricted functions
  function testOnlyAdminSetRewardsDuration() external {
    address nonAdmin = address(0x1);
    skip(duration + 1);

    vm.prank(nonAdmin);
    vm.expectRevert(bytes(""));
    stEXA.setRewardsDuration(1);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    stEXA.setRewardsDuration(1);

    assertEq(stEXA.duration(), 1);
  }

  function testOnlyAdminNotifyRewardAmount() external {
    address nonAdmin = address(0x1);

    uint256 amount = 1_000e18;

    rewardsToken.mint(address(stEXA), amount);

    vm.prank(nonAdmin);
    vm.expectRevert(bytes(""));
    stEXA.notifyRewardAmount(amount);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardAmountNotified(admin, amount);
    stEXA.notifyRewardAmount(amount);

    assertEq(stEXA.finishAt(), block.timestamp + stEXA.duration());
    assertEq(stEXA.updatedAt(), block.timestamp);
  }

  function testRewardsAmounts(uint256 assets) external {
    assets = _bound(assets, 1, exaBalance);

    uint256 time = 10 days;
    uint256 rate = stEXA.rewardRate();
    stEXA.deposit(assets, address(this));

    skip(time);
    uint256 thisRewards = rate * time;

    vm.startPrank(BOB);
    exa.approve(address(stEXA), assets);
    stEXA.deposit(assets, BOB);
    vm.stopPrank();

    skip(time);

    uint256 bobRewards = (rate * time) / 2;
    thisRewards += bobRewards;

    assertApproxEqAbs(stEXA.earned(address(this)), thisRewards, 1e7, "this rewards != earned expected");
    assertApproxEqAbs(stEXA.earned(BOB), bobRewards, 1e7, "bob rewards != earned expected");

    uint256 thisClaimable = stEXA.claimable(address(this));
    stEXA.withdraw(assets, address(this), address(this));
    assertApproxEqAbs(rewardsToken.balanceOf(address(this)), thisClaimable, 1e7, "this rewards != expected");

    uint256 bobBefore = rewardsToken.balanceOf(BOB);

    uint256 bobClaimable = stEXA.claimable(BOB);
    vm.prank(BOB);
    stEXA.withdraw(assets, BOB, BOB);

    assertApproxEqAbs(rewardsToken.balanceOf(BOB) - bobBefore, bobClaimable, 1e7, "bob rewards != expected");
  }

  function testNoRewardsAfterPeriod(uint256 timeAfterPeriod) external {
    timeAfterPeriod = _bound(timeAfterPeriod, 1, duration * 2);
    uint256 assets = 1_000e18;

    uint256 time = duration / 2;
    uint256 rate = stEXA.rewardRate();
    stEXA.deposit(assets, address(this));

    skip(time);

    uint256 thisRewards = rate * time;

    vm.startPrank(BOB);
    exa.approve(address(stEXA), assets);
    stEXA.deposit(assets, BOB);
    vm.stopPrank();

    skip(time);

    uint256 bobRewards = (rate * time) / 2;
    thisRewards += bobRewards;

    assertApproxEqAbs(stEXA.earned(address(this)), thisRewards, 600, "this rewards != earned expected");
    assertApproxEqAbs(stEXA.earned(BOB), bobRewards, 200, "bob rewards != earned expected");

    skip(timeAfterPeriod);

    uint256 thisClaimable = stEXA.claimable(address(this));
    stEXA.withdraw(assets, address(this), address(this));
    assertApproxEqAbs(rewardsToken.balanceOf(address(this)), thisClaimable, 600, "this rewards != expected");

    uint256 bobClaimable = stEXA.claimable(BOB);
    vm.prank(BOB);
    stEXA.withdraw(assets, BOB, BOB);
    assertApproxEqAbs(rewardsToken.balanceOf(BOB), bobClaimable, 200, "bob rewards != expected");

    assertEq(stEXA.earned(address(this)), 0);
    assertEq(stEXA.earned(BOB), 0);

    skip(timeAfterPeriod);

    assertEq(stEXA.earned(address(this)), 0);
    assertEq(stEXA.earned(BOB), 0);
  }

  function testAvgTime(uint256[3] memory assets, uint256[2] memory times) external {
    assets[0] = _bound(assets[0], 1, exaBalance / 3);
    assets[1] = _bound(assets[1], 1, exaBalance / 3);
    assets[2] = _bound(assets[2], 1, exaBalance / 3);
    times[0] = _bound(times[0], 1, duration / 2);
    times[1] = _bound(times[1], 1, duration / 2);

    uint256 avgTime = block.timestamp * 1e18;
    stEXA.deposit(assets[0], address(this));
    assertEq(stEXA.avgStart(address(this)), avgTime);

    skip(times[0]);

    uint256 opWeight = assets[0].divWadDown(assets[0] + assets[1]);
    avgTime = avgTime.mulWadDown(opWeight) + (block.timestamp) * (1e18 - opWeight);
    stEXA.deposit(assets[1], address(this));
    assertEq(stEXA.avgStart(address(this)), avgTime);

    skip(times[1]);

    uint256 balance = assets[0] + assets[1];
    opWeight = balance.divWadDown(balance + assets[2]);
    avgTime = avgTime.mulWadDown(opWeight) + (block.timestamp) * (1e18 - opWeight);

    stEXA.deposit(assets[2], address(this));
    assertEq(stEXA.avgStart(address(this)), avgTime);
  }

  function testAvgIndex(uint256[3] memory assets, uint256[2] memory times) external {
    assets[0] = _bound(assets[0], 1, exaBalance / 3);
    assets[1] = _bound(assets[1], 1, exaBalance / 3);
    assets[2] = _bound(assets[2], 1, exaBalance / 3);
    times[0] = _bound(times[0], 1, duration / 2);
    times[1] = _bound(times[1], 1, duration / 2);

    stEXA.deposit(assets[0], address(this));
    uint256 avgIndex = stEXA.globalIndex();
    assertEq(stEXA.avgIndexes(address(this)), avgIndex, "avgIndex.0 != globalIndex");

    skip(times[0]);

    uint256 opWeight = assets[0].divWadDown(assets[0] + assets[1]);
    stEXA.deposit(assets[1], address(this));
    avgIndex = avgIndex.mulWadDown(opWeight) + stEXA.globalIndex().mulWadDown(1e18 - opWeight);
    assertEq(stEXA.avgIndexes(address(this)), avgIndex, "avgIndex.1 != globalIndex");

    skip(times[1]);

    uint256 balance = assets[0] + assets[1];
    opWeight = balance.divWadDown(balance + assets[2]);
    avgIndex = avgIndex.mulWadDown(opWeight) + stEXA.globalIndex().mulWadDown(1e18 - opWeight);
    stEXA.deposit(assets[2], address(this));
    assertEq(stEXA.avgIndexes(address(this)), avgIndex, "avgIndex.2 != globalIndex");
  }

  function testDepositWithdrawAvgTimeAndIndex(
    uint256[3] memory assets,
    uint256 partialWithdraw,
    uint256[5] memory times
  ) external {
    assets[0] = _bound(assets[0], 2, exaBalance / 3);
    assets[1] = _bound(assets[1], 1, exaBalance / 3);
    assets[2] = _bound(assets[2], 1, exaBalance / 3);
    partialWithdraw = _bound(partialWithdraw, 1, assets[0] - 1);
    times[0] = _bound(times[0], 1, duration / 5);
    times[1] = _bound(times[1], 1, duration / 5);
    times[2] = _bound(times[2], 1, duration / 5);
    times[3] = _bound(times[3], 1, duration / 5);
    times[4] = _bound(times[4], 1, duration / 5);

    skip(times[0]);
    stEXA.deposit(assets[0], address(this));

    uint256 avgTime = block.timestamp * 1e18;
    uint256 avgIndex = stEXA.globalIndex();

    // skip + partial withdraw -> avg time and index shouldn't change
    skip(times[1]);
    stEXA.withdraw(partialWithdraw, address(this), address(this));
    assertEq(stEXA.avgStart(address(this)), avgTime, "avgTime != expected");
    assertEq(stEXA.avgIndexes(address(this)), avgIndex, "avgIndex != expected");

    // skip + new deposit -> avg time and index should change
    skip(times[2]);
    stEXA.deposit(assets[1], address(this));
    uint256 balance = assets[0] - partialWithdraw;
    uint256 opWeight = balance.divWadDown(balance + assets[1]);
    avgTime = avgTime.mulWadDown(opWeight) + (block.timestamp) * (1e18 - opWeight);
    avgIndex = avgIndex.mulWadDown(opWeight) + stEXA.globalIndex().mulWadDown(1e18 - opWeight);

    // skip + full withdraw -> avg time and index shouldn't change
    skip(times[3]);
    uint256 fullWithdraw = assets[0] + assets[1] - partialWithdraw;
    stEXA.withdraw(fullWithdraw, address(this), address(this));
    assertEq(stEXA.avgStart(address(this)), avgTime, "avgTime != expected");
    assertEq(stEXA.avgIndexes(address(this)), avgIndex, "avgIndex != expected");

    // skip + new deposit -> avg time and index should be restarted
    skip(times[4]);
    stEXA.deposit(assets[2], address(this));
    avgTime = block.timestamp * 1e18;
    avgIndex = stEXA.globalIndex();
    assertEq(stEXA.avgStart(address(this)), avgTime, "avgTime != expected");
    assertEq(stEXA.avgIndexes(address(this)), avgIndex, "avgIndex != expected");
  }

  function testWithdrawSameAmountRewardsShouldEqual(uint256 amount, uint256 time) external {
    amount = _bound(amount, 2, exaBalance);
    time = _bound(time, 1, duration - 1);

    stEXA.deposit(amount, address(this));
    uint256 rewBalance = rewardsToken.balanceOf(address(this));

    skip(time);
    // withdraw 1/2 of the assets
    stEXA.withdraw(amount / 2, address(this), address(this));
    uint256 claimedRewards = rewardsToken.balanceOf(address(this)) - rewBalance;

    // withdraw same amount
    rewBalance = rewardsToken.balanceOf(address(this));
    stEXA.withdraw(amount / 2, address(this), address(this));
    uint256 claimedRewards2 = rewardsToken.balanceOf(address(this)) - rewBalance;

    assertEq(claimedRewards, claimedRewards2, "claimed rewards != expected");
  }

  event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
  event Withdraw(
    address indexed sender,
    address indexed receiver,
    address indexed owner,
    uint256 assets,
    uint256 shares
  );
  event RewardAmountNotified(address indexed account, uint256 amount);
  event RewardPaid(address indexed account, uint256 amount);
  event RewardsDurationSet(address indexed account, uint256 duration);
}
