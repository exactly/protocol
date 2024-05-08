// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Test } from "forge-std/Test.sol";

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import {
  IERC20Upgradeable as IERC20
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {
  StakedEXA,
  InsufficientBalance,
  NotFinished,
  Untransferable,
  ZeroAmount,
  ZeroRate
} from "../contracts/StakedEXA.sol";

contract StakedEXATest is Test {
  StakedEXA internal stEXA;
  MockERC20 internal exa;
  MockERC20 internal rewardsToken;
  uint256 internal exaBalance;
  uint256 internal initialAmount;
  uint256 internal initialDuration;

  function setUp() external {
    vm.warp(1_704_067_200); // 01/01/2024 @ 00:00 (UTC)
    exa = new MockERC20("Exactly token", "EXA", 18);
    rewardsToken = new MockERC20("Rewards token", "REW", 18);

    stEXA = StakedEXA(address(new ERC1967Proxy(address(new StakedEXA(IERC20(address(exa)), rewardsToken)), "")));
    stEXA.initialize();

    exaBalance = 1_000_000 ether;

    exa.approve(address(stEXA), type(uint256).max);

    initialDuration = 24 weeks;
    initialAmount = 1_000 ether;

    rewardsToken.mint(address(stEXA), initialAmount);

    stEXA.setRewardsDuration(initialDuration);
    stEXA.notifyRewardAmount(initialAmount);
  }

  function testInitialValues() external view {
    assertEq(stEXA.duration(), initialDuration);
    assertEq(stEXA.rewardRate(), initialAmount / initialDuration);
    assertEq(stEXA.finishAt(), block.timestamp + initialDuration);
    assertEq(stEXA.updatedAt(), block.timestamp);
    assertEq(stEXA.index(), 0);
    assertEq(stEXA.totalSupply(), 0);
    assertEq(stEXA.balanceOf(address(this)), 0);
  }

  function testInsufficientBalanceError(uint256 amount) external {
    amount = _bound(amount, 1e8, initialAmount * 2);
    vm.expectRevert(InsufficientBalance.selector);
    stEXA.notifyRewardAmount(amount);
  }

  function testZeroRateError() external {
    skip(initialDuration + 1);
    vm.expectRevert(ZeroRate.selector);
    stEXA.notifyRewardAmount(0);
  }

  function testUntransferable(uint256 assets) external {
    assets = _bound(assets, 1, exaBalance);

    exa.mint(address(this), assets);
    uint256 shares = stEXA.deposit(assets, address(this));

    vm.expectRevert(Untransferable.selector);
    stEXA.transfer(address(0x1), shares);
  }

  function testSetDuration(uint256 skipTime, uint256 duration) external {
    skipTime = _bound(skipTime, 1, initialDuration * 2);
    duration = _bound(duration, 1, 200 weeks);

    skip(skipTime);
    if (skipTime < initialDuration) vm.expectRevert(NotFinished.selector);
    stEXA.setRewardsDuration(duration);

    if (skipTime <= initialDuration) assertEq(stEXA.duration(), initialDuration);
    else assertEq(stEXA.duration(), duration);
  }

  function testTotalSupplyDeposit(uint256 assets) external {
    assets = _bound(assets, 0, exaBalance);
    uint256 prevSupply = stEXA.totalSupply();
    exa.mint(address(this), assets);
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
    exa.mint(address(this), assets);
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

    time = _bound(time, 1, initialDuration + 1);
    skip(time);

    uint256 earned = stEXA.earned(address(this));

    if (stEXA.balanceOf(address(this)) != 0) assertGt(earned, prevEarned);
    else assertEq(earned, prevEarned);
  }

  function testGetReward() external {
    uint256 prevRewardsBalance = rewardsToken.balanceOf(address(this));
    uint256 rewards = stEXA.rewards(address(this));

    stEXA.getReward();

    assertEq(rewardsToken.balanceOf(address(this)), prevRewardsBalance + rewards);
  }

  // events
  function testDepositEvent(uint256 assets) external {
    assets = _bound(assets, 1, exaBalance);
    exa.mint(address(this), assets);
    uint256 shares = stEXA.previewDeposit(assets);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit Deposit(address(this), address(this), assets, shares);
    stEXA.deposit(assets, address(this));
  }

  function testWithdrawEvent(uint256 assets) external {
    assets = _bound(assets, 1, exaBalance);
    exa.mint(address(this), assets);
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
    time = _bound(time, 1, initialDuration + 1);

    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));

    skip(time);

    uint256 earned = stEXA.earned(address(this));

    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardPaid(address(this), earned);
    stEXA.getReward();
  }

  function testRewardsDurationSetEvent(uint256 duration) external {
    skip(initialDuration + 1);

    duration = _bound(duration, 1, 200 weeks);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardsDurationSet(address(this), duration);
    stEXA.setRewardsDuration(duration);
  }

  function testNotifyRewardAmount(uint256 amount, uint256 time) external {
    amount = _bound(amount, 1e8, initialAmount * 2);
    time = _bound(time, 1, initialDuration * 2);

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
    skip(initialDuration + 1);

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
