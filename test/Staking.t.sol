// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Test } from "forge-std/Test.sol";

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

import { Staking, InsufficientBalance, NotFinished, ZeroAmount, ZeroRate } from "../contracts/Staking.sol";

contract StakingTest is Test {
  Staking internal staking;
  MockERC20 internal exa;
  MockERC20 internal rewardsToken;
  uint256 internal exaBalance;
  uint256 internal initialAmount;
  uint256 internal initialDuration;

  function setUp() external {
    vm.warp(1_704_067_200); // 01/01/2024 @ 00:00 (UTC)
    exa = new MockERC20("Exactly token", "EXA", 18);
    rewardsToken = new MockERC20("Rewards token", "REW", 18);

    staking = Staking(address(new ERC1967Proxy(address(new Staking(exa, rewardsToken)), "")));
    staking.initialize();

    exaBalance = 1_000_000 ether;

    exa.approve(address(staking), type(uint256).max);

    initialDuration = 24 weeks;
    initialAmount = 1_000 ether;

    rewardsToken.mint(address(staking), initialAmount);

    staking.setRewardsDuration(initialDuration);
    staking.notifyRewardAmount(initialAmount);
  }

  function testInitialValues() external view {
    assertEq(staking.duration(), initialDuration);
    assertEq(staking.rewardRate(), initialAmount / initialDuration);
    assertEq(staking.finishAt(), block.timestamp + initialDuration);
    assertEq(staking.updatedAt(), block.timestamp);
    assertEq(staking.index(), 0);
    assertEq(staking.totalSupply(), 0);
    assertEq(staking.balanceOf(address(this)), 0);
  }

  function testInsufficientBalanceError(uint256 amount) external {
    amount = _bound(amount, 1e8, initialAmount * 2);
    vm.expectRevert(InsufficientBalance.selector);
    staking.notifyRewardAmount(amount);
  }

  function testZeroRateError() external {
    skip(initialDuration + 1);
    vm.expectRevert(ZeroRate.selector);
    staking.notifyRewardAmount(0);
  }

  function testSetDuration(uint256 skipTime, uint256 duration) external {
    skipTime = _bound(skipTime, 1, initialDuration * 2);
    duration = _bound(duration, 1, 200 weeks);

    skip(skipTime);
    if (skipTime < initialDuration) vm.expectRevert(NotFinished.selector);
    staking.setRewardsDuration(duration);

    if (skipTime <= initialDuration) assertEq(staking.duration(), initialDuration);
    else assertEq(staking.duration(), duration);
  }

  function testTotalSupplyStake(uint256 amount) external {
    amount = _bound(amount, 0, exaBalance);
    uint256 prevSupply = staking.totalSupply();
    exa.mint(address(this), amount);
    if (amount == 0) vm.expectRevert(ZeroAmount.selector);
    staking.stake(amount);
    assertEq(staking.totalSupply(), prevSupply + amount);
  }

  function testTotalSupplyUnstake(uint256 amount) external {
    amount = _bound(amount, 0, staking.balanceOf(address(this)));
    uint256 prevSupply = staking.totalSupply();
    if (amount == 0) vm.expectRevert(ZeroAmount.selector);

    staking.withdraw(amount);
    assertEq(staking.totalSupply(), prevSupply - amount);
  }

  function testBalanceOfStake(uint256 amount) external {
    amount = _bound(amount, 0, exaBalance);
    uint256 prevBalance = staking.balanceOf(address(this));
    exa.mint(address(this), amount);
    if (amount == 0) vm.expectRevert(ZeroAmount.selector);
    staking.stake(amount);
    assertEq(staking.balanceOf(address(this)), prevBalance + amount);
  }

  function testBalanceOfUnstake(uint256 amount) external {
    amount = _bound(amount, 0, staking.balanceOf(address(this)));
    uint256 prevBalance = staking.balanceOf(address(this));
    if (amount == 0) vm.expectRevert(ZeroAmount.selector);
    staking.withdraw(amount);
    assertEq(staking.balanceOf(address(this)), prevBalance - amount);
  }

  function testEarnedWithTime(uint256 time) external {
    uint256 prevEarned = staking.earned(address(this));

    time = _bound(time, 1, initialDuration + 1);
    skip(time);

    uint256 earned = staking.earned(address(this));

    if (staking.balanceOf(address(this)) != 0) assertGt(earned, prevEarned);
    else assertEq(earned, prevEarned);
  }

  function testGetReward() external {
    uint256 prevRewardsBalance = rewardsToken.balanceOf(address(this));
    uint256 rewards = staking.rewards(address(this));

    staking.getReward();

    assertEq(rewardsToken.balanceOf(address(this)), prevRewardsBalance + rewards);
  }

  // events
  function testStakeEvent(uint256 amount) external {
    amount = _bound(amount, 1, exaBalance);
    exa.mint(address(this), amount);
    vm.expectEmit(true, true, true, true, address(staking));
    emit Stake(address(this), amount);
    staking.stake(amount);
  }

  function testWithdrawEvent(uint256 amount) external {
    amount = _bound(amount, 1, exaBalance);
    exa.mint(address(this), amount);
    staking.stake(amount);
    vm.expectEmit(true, true, true, true, address(staking));
    emit Withdraw(address(this), amount);
    staking.withdraw(amount);
  }

  function testRewardAmountNotifiedEvent(uint256 amount) external {
    amount = _bound(amount, 1, initialAmount * 2);

    rewardsToken.mint(address(staking), amount);
    vm.expectEmit(true, true, true, true, address(staking));
    emit RewardAmountNotified(address(this), amount);
    staking.notifyRewardAmount(amount);
  }

  function testRewardPaidEvent(uint256 amount, uint256 time) external {
    amount = _bound(amount, 1, initialAmount * 2);
    time = _bound(time, 1, initialDuration + 1);

    exa.mint(address(this), amount);
    staking.stake(amount);

    skip(time);

    uint256 earned = staking.earned(address(this));

    vm.expectEmit(true, true, true, true, address(staking));
    emit RewardPaid(address(this), earned);
    staking.getReward();
  }

  function testRewardsDurationSetEvent(uint256 duration) external {
    skip(initialDuration + 1);

    duration = _bound(duration, 1, 200 weeks);
    vm.expectEmit(true, true, true, true, address(staking));
    emit RewardsDurationSet(address(this), duration);
    staking.setRewardsDuration(duration);
  }

  function testNotifyRewardAmount(uint256 amount, uint256 time) external {
    amount = _bound(amount, 1e8, initialAmount * 2);
    time = _bound(time, 1, initialDuration * 2);

    vm.warp(block.timestamp + time);

    uint256 expectedRate = 0;
    if (block.timestamp >= staking.finishAt()) {
      expectedRate = amount / staking.duration();
    } else {
      expectedRate = (amount + (staking.finishAt() - block.timestamp) * staking.rewardRate()) / staking.duration();
    }

    rewardsToken.mint(address(staking), amount);
    vm.expectEmit(true, true, true, true, address(staking));
    emit RewardAmountNotified(address(this), amount);
    staking.notifyRewardAmount(amount);

    assertEq(staking.rewardRate(), expectedRate, "rate != expected");
    assertEq(staking.finishAt(), block.timestamp + staking.duration(), "finishAt != expected");
    assertEq(staking.updatedAt(), block.timestamp, "updatedAt != expected");
  }

  function testOnlyAdminSetRewardsDuration() external {
    address nonAdmin = address(0x1);
    skip(initialDuration + 1);

    vm.prank(nonAdmin);
    vm.expectRevert(bytes(""));
    staking.setRewardsDuration(1);

    address admin = address(0x2);
    staking.grantRole(staking.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    staking.setRewardsDuration(1);

    assertEq(staking.duration(), 1);
  }

  function testOnlyAdminNotifyRewardAmount() external {
    address nonAdmin = address(0x1);

    uint256 amount = 1_000e18;

    rewardsToken.mint(address(staking), amount);

    vm.prank(nonAdmin);
    vm.expectRevert(bytes(""));
    staking.notifyRewardAmount(amount);

    address admin = address(0x2);
    staking.grantRole(staking.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(staking));
    emit RewardAmountNotified(admin, amount);
    staking.notifyRewardAmount(amount);

    assertEq(staking.finishAt(), block.timestamp + staking.duration());
    assertEq(staking.updatedAt(), block.timestamp);
  }

  event Stake(address indexed account, uint256 amount);
  event Withdraw(address indexed account, uint256 amount);
  event RewardAmountNotified(address indexed account, uint256 amount);
  event RewardPaid(address indexed account, uint256 amount);
  event RewardsDurationSet(address indexed account, uint256 duration);
}
