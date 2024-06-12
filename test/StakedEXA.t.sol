// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0; // solhint-disable-line one-contract-per-file

import { ERC4626 } from "solmate/src/mixins/ERC4626.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
  IERC20Upgradeable as IERC20
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import { Test, stdError } from "forge-std/Test.sol";

import {
  ERC20,
  Market,
  StakedEXA,
  ClaimableReward,
  AlreadyListed,
  InsufficientBalance,
  InvalidRatio,
  NotFinished,
  NotPausingRole,
  RewardNotListed,
  Untransferable,
  ZeroAddress,
  ZeroAmount,
  ZeroRate
} from "../contracts/StakedEXA.sol";

contract StakedEXATest is Test {
  using FixedPointMathLib for uint256;

  address internal constant BOB = address(0x420);
  StakedEXA internal stEXA;
  MockERC20 internal exa;
  MockERC20[] internal rewardsTokens;
  uint256 internal exaBalance;
  uint256 internal initialAmount;
  uint256 internal duration;
  uint256 internal minTime;
  uint256 internal refTime;
  uint256 internal excessFactor;
  uint256 internal penaltyGrowth;
  uint256 internal penaltyThreshold;

  Market internal market;
  MockERC20 internal providerAsset;
  address internal constant PROVIDER = address(0x1);
  address internal constant SAVINGS = address(0x2);
  uint256 internal providerRatio;

  address[] internal accounts;
  mapping(address account => uint256 start) public avgStart;
  mapping(MockERC20 reward => uint256 index) internal globalIndex;
  mapping(address account => mapping(MockERC20 reward => uint256 index)) public avgIndexes;
  mapping(MockERC20 reward => mapping(address account => uint256 amount)) internal claimable;

  function setUp() external {
    vm.warp(1_704_067_200); // 01/01/2024 @ 00:00 (UTC)
    exa = new MockERC20("Exactly token", "EXA", 18);
    vm.label(address(exa), "EXA");
    rewardsTokens = new MockERC20[](2);
    rewardsTokens[0] = new MockERC20("reward A", "rA", 18);
    rewardsTokens[1] = new MockERC20("reward B", "rB", 6);
    vm.label(address(rewardsTokens[0]), "rA");
    vm.label(address(rewardsTokens[1]), "rB");

    duration = 24 weeks;
    initialAmount = 1_000 ether;
    minTime = 1 weeks;
    refTime = duration;
    excessFactor = 0.5e18;
    penaltyGrowth = 2e18;
    penaltyThreshold = 0.5e18;

    providerAsset = new MockERC20("Wrapped ETH", "WETH", 18);
    market = Market(address(new MockMarket(providerAsset)));
    vm.label(address(providerAsset), "WETH");
    vm.label(address(market), "Market");
    vm.label(PROVIDER, "provider");
    vm.label(SAVINGS, "savings");

    providerRatio = 0.1e18;
    stEXA = StakedEXA(address(new ERC1967Proxy(address(new StakedEXA(IERC20(address(exa)))), "")));
    stEXA.initialize(
      minTime,
      refTime,
      excessFactor,
      penaltyGrowth,
      penaltyThreshold,
      market,
      PROVIDER,
      SAVINGS,
      1 weeks,
      providerRatio
    );
    vm.label(address(stEXA), "stEXA");
    vm.label(
      address(
        uint160(uint256(vm.load(address(stEXA), bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1))))
      ),
      "stEXA_Impl"
    );

    providerAsset.mint(PROVIDER, 1_000e18);

    vm.startPrank(PROVIDER);
    providerAsset.approve(address(market), type(uint256).max);
    market.deposit(1_000e18, PROVIDER);
    market.approve(address(stEXA), type(uint256).max);
    vm.stopPrank();

    exaBalance = 1_000_000 ether;
    exa.mint(address(this), exaBalance);

    exa.approve(address(stEXA), type(uint256).max);

    rewardsTokens[0].mint(address(stEXA), initialAmount);
    rewardsTokens[1].mint(address(stEXA), initialAmount);

    stEXA.enableReward(exa);
    stEXA.enableReward(rewardsTokens[0]);
    stEXA.enableReward(rewardsTokens[1]);

    stEXA.setRewardsDuration(exa, duration);
    stEXA.setRewardsDuration(rewardsTokens[0], duration);
    stEXA.setRewardsDuration(rewardsTokens[1], duration);
    stEXA.notifyRewardAmount(rewardsTokens[0], initialAmount);
    stEXA.notifyRewardAmount(rewardsTokens[1], initialAmount);

    vm.label(BOB, "bob");
    exa.mint(BOB, exaBalance);

    accounts.push(address(this));
    accounts.push(BOB);

    targetContract(address(this));
    bytes4[] memory selectors = new bytes4[](5);
    selectors[0] = this.handlerSkip.selector;
    selectors[1] = this.testHandlerDeposit.selector;
    selectors[2] = this.testHandlerWithdraw.selector;
    selectors[3] = this.testHandlerNotifyRewardAmount.selector;
    selectors[4] = this.testHandlerSetDuration.selector;
    targetSelector(FuzzSelector(address(this), selectors));
  }

  function invariantRewardsUpOnly() external view {
    for (uint256 i = 0; i < rewardsTokens.length; ++i) {
      for (uint256 a = 0; a < accounts.length; ++a) {
        // TODO assert excess exposure
        if (refTime * 1e18 + stEXA.avgStart(accounts[a]) > block.timestamp * 1e18) continue;
        assertGe(stEXA.claimable(rewardsTokens[i], accounts[a]), claimable[rewardsTokens[i]][accounts[a]]);
      }
    }
  }

  function invariantIndexUpOnly() external view {
    for (uint256 i = 0; i < rewardsTokens.length; ++i) {
      for (uint256 a = 0; a < accounts.length; ++a) {
        MockERC20 reward = rewardsTokens[i];
        assertGe(stEXA.globalIndex(reward), globalIndex[reward]);
      }
    }
  }

  function invariantAvgIndexUpOnly() external view {
    for (uint256 i = 0; i < rewardsTokens.length; ++i) {
      for (uint256 a = 0; a < accounts.length; ++a) {
        address account = accounts[a];
        MockERC20 reward = rewardsTokens[i];
        assertGe(stEXA.avgIndex(reward, account) + 10, avgIndexes[account][reward]); // TODO precision issue
      }
    }
  }

  function invariantAvgStartUpOnly() external view {
    for (uint256 a = 0; a < accounts.length; ++a) {
      address account = accounts[a];
      assertGe(stEXA.avgStart(account), avgStart[account]);
    }
  }

  function invariantShareValueIsOne() external view {
    assertEq(stEXA.totalSupply(), stEXA.totalAssets());
  }

  function invariantNoDuplicatedReward() external view {
    ERC20[] memory rewards = stEXA.allRewardsTokens();
    for (uint256 i = 0; i < rewards.length; ++i) {
      for (uint256 j = i + 1; j < rewards.length; ++j) {
        assertNotEq(address(rewards[i]), address(rewards[j]));
      }
    }
  }

  function handlerSkip(uint16 time) external {
    for (uint256 i = 0; i < rewardsTokens.length; ++i) {
      for (uint256 a = 0; a < accounts.length; ++a) {
        avgStart[accounts[a]] = stEXA.avgStart(accounts[a]);
        globalIndex[rewardsTokens[i]] = stEXA.globalIndex(rewardsTokens[i]);
        avgIndexes[accounts[a]][rewardsTokens[i]] = stEXA.avgIndex(rewardsTokens[i], accounts[a]);
        claimable[rewardsTokens[i]][accounts[a]] = stEXA.claimable(rewardsTokens[i], accounts[a]);
      }
    }
    skip(time);
  }

  function testHandlerDeposit(uint256 assets) external {
    assets = _bound(assets, 0, exaBalance);
    uint256 prevAssets = stEXA.totalAssets();

    address account = accounts[uint256(keccak256(abi.encode(assets, block.timestamp))) % accounts.length];
    vm.startPrank(account);
    exa.mint(account, exaBalance);
    exa.approve(address(stEXA), assets);
    if (assets == 0) vm.expectRevert(ZeroAmount.selector);
    stEXA.deposit(assets, account);
    vm.stopPrank();
    assertEq(stEXA.totalAssets(), prevAssets + assets, "missing assets");
  }

  function testHandlerWithdraw(uint256 assets) external {
    address account = accounts[uint256(keccak256(abi.encode(assets, block.timestamp))) % accounts.length];
    assets = _bound(assets, 0, stEXA.maxWithdraw(account));
    uint256 prevAssets = stEXA.totalAssets();

    vm.prank(account);
    if (assets == 0) vm.expectRevert(ZeroAmount.selector);
    stEXA.withdraw(assets, account, account);

    assertEq(stEXA.totalAssets(), prevAssets - assets, "missing assets");
  }

  function testHandlerNotifyRewardAmount(uint64 assets) external {
    ERC20[] memory rewards = stEXA.allRewardsTokens();
    ERC20 reward = rewards[uint256(keccak256(abi.encode(assets, block.timestamp))) % rewards.length];

    MockERC20(address(reward)).mint(address(stEXA), assets);

    (uint256 rDuration, uint256 finishAt, , uint256 rate, ) = stEXA.rewards(reward);
    if (rDuration == 0) vm.expectRevert(stdError.divisionError);
    else if (
      (
        block.timestamp >= finishAt ? assets / rDuration : (assets + ((finishAt - block.timestamp) * rate)) / rDuration
      ) == 0
    ) vm.expectRevert(ZeroRate.selector);
    stEXA.notifyRewardAmount(reward, assets);
  }

  function testHandlerSetDuration(uint24 period) external {
    ERC20[] memory rewards = stEXA.allRewardsTokens();
    ERC20 reward = rewards[uint256(keccak256(abi.encode(period, block.timestamp))) % rewards.length];

    uint256 savingsBalance = reward.balanceOf(SAVINGS);

    (, uint256 finishAt, , uint256 rate, ) = stEXA.rewards(reward);

    if (finishAt > block.timestamp) {
      uint256 remainingRewards = rate * (finishAt - block.timestamp);

      stEXA.disableReward(reward);
      assertEq(reward.balanceOf(SAVINGS), savingsBalance + remainingRewards, "missing remaining savings");
      (, finishAt, , , ) = stEXA.rewards(reward);
      assertEq(finishAt, block.timestamp, "finish != block timestamp");
    }

    stEXA.setRewardsDuration(reward, period);
    uint256 newRate;
    (, finishAt, , newRate, ) = stEXA.rewards(reward);
    assertEq(rate, newRate, "rate != new rate");
  }

  function testInitialValues() external view {
    (uint256 duration0, uint256 finishAt0, uint256 index0, uint256 rate0, uint256 updatedAt0) = stEXA.rewards(
      rewardsTokens[0]
    );

    assertEq(duration0, duration);
    assertEq(finishAt0, block.timestamp + duration);
    assertEq(index0, 0);
    assertEq(rate0, initialAmount / duration);
    assertEq(updatedAt0, block.timestamp);

    (uint256 duration1, uint256 finishAt1, uint256 index1, uint256 rate1, uint256 updatedAt1) = stEXA.rewards(
      rewardsTokens[1]
    );

    assertEq(duration1, duration);
    assertEq(finishAt1, block.timestamp + duration);
    assertEq(index1, 0);
    assertEq(rate1, initialAmount / duration);
    assertEq(updatedAt1, block.timestamp);

    assertEq(stEXA.totalSupply(), 0);
    assertEq(stEXA.balanceOf(address(this)), 0);

    assertEq(stEXA.minTime(), minTime);
    assertEq(stEXA.refTime(), refTime);
    assertEq(stEXA.penaltyGrowth(), penaltyGrowth);
    assertEq(stEXA.penaltyThreshold(), penaltyThreshold);

    assertFalse(stEXA.paused());

    (uint256 providerDuration, uint256 finishAt, uint256 index, uint256 rate, uint256 updatedAt) = stEXA.rewards(
      providerAsset
    );
    assertEq(providerDuration, 1 weeks);
    assertEq(finishAt, block.timestamp);
    assertEq(index, 0);
    assertEq(rate, 0);
    assertEq(updatedAt, 0);
  }

  function testInsufficientBalanceError(uint256 amount) external {
    amount = _bound(amount, 1e8, initialAmount * 2);
    vm.expectRevert(InsufficientBalance.selector);
    stEXA.notifyRewardAmount(rewardsTokens[0], amount);
  }

  function testZeroRateError() external {
    skip(duration + 1);
    vm.expectRevert(ZeroRate.selector);
    stEXA.notifyRewardAmount(rewardsTokens[0], 0);
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
    stEXA.setRewardsDuration(rewardsTokens[0], duration_);

    (uint256 duration0, , , , ) = stEXA.rewards(rewardsTokens[0]);

    if (skipTime <= duration) assertEq(duration0, duration);
    else assertEq(duration0, duration_);
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
    uint256 prevEarned = stEXA.earned(rewardsTokens[0], address(this));

    time = _bound(time, 1, duration + 1);
    skip(time);

    uint256 earned = stEXA.earned(rewardsTokens[0], address(this));

    if (stEXA.balanceOf(address(this)) != 0) assertGt(earned, prevEarned);
    else assertEq(earned, prevEarned);
  }

  function testWithdrawWithRewards(uint256 assets) external {
    assets = _bound(assets, 1, exaBalance);

    stEXA.deposit(assets, address(this));
    uint256 rate = initialAmount / duration;
    skip(duration / 2);
    uint256 earned = rate * (duration / 2);
    assertApproxEqAbs(stEXA.earned(rewardsTokens[0], address(this)), earned, 1e6);

    uint256 thisClaimable = stEXA.claimable(rewardsTokens[0], address(this));
    stEXA.withdraw(assets, address(this), address(this));
    assertApproxEqAbs(rewardsTokens[0].balanceOf(address(this)), thisClaimable, 1e6, "rewards != earned");
  }

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

    rewardsTokens[0].mint(address(stEXA), amount);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardAmountNotified(rewardsTokens[0], address(this), amount);
    stEXA.notifyRewardAmount(rewardsTokens[0], amount);
  }

  function testRewardPaidEvent(uint256 assets, uint256 time) external {
    assets = _bound(assets, 1, initialAmount * 2);
    time = _bound(time, 1, duration + 1);

    stEXA.deposit(assets, address(this));

    skip(time);

    uint256 thisClaimable = stEXA.claimable(rewardsTokens[0], address(this));

    if (thisClaimable != 0) {
      vm.expectEmit(true, true, true, true, address(stEXA));
      emit RewardPaid(rewardsTokens[0], address(this), thisClaimable);
    }
    stEXA.withdraw(assets, address(this), address(this));
  }

  function testRewardsDurationSetEvent(uint256 duration_) external {
    skip(duration + 1);

    duration_ = _bound(duration_, 1, 200 weeks);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardsDurationSet(rewardsTokens[0], address(this), duration_);
    stEXA.setRewardsDuration(rewardsTokens[0], duration_);
  }

  function testNotifyRewardAmount(uint256 amount, uint256 time) external {
    amount = _bound(amount, 1e8, initialAmount * 2);
    time = _bound(time, 1, duration * 2);

    vm.warp(block.timestamp + time);
    (, uint256 finishAt, , uint256 rate, uint256 updatedAt) = stEXA.rewards(rewardsTokens[0]);

    uint256 expectedRate = 0;
    if (block.timestamp >= finishAt) {
      expectedRate = amount / duration;
    } else {
      expectedRate = (amount + (finishAt - block.timestamp) * rate) / duration;
    }

    rewardsTokens[0].mint(address(stEXA), amount);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardAmountNotified(rewardsTokens[0], address(this), amount);
    stEXA.notifyRewardAmount(rewardsTokens[0], amount);

    (, finishAt, , rate, updatedAt) = stEXA.rewards(rewardsTokens[0]);
    assertEq(rate, expectedRate, "rate != expected");
    assertEq(finishAt, block.timestamp + duration, "finishAt != expected");
    assertEq(updatedAt, block.timestamp, "updatedAt != expected");
  }

  function testOnlyAdminSetRewardsDuration() external {
    address nonAdmin = address(0x1);
    skip(duration + 1);

    vm.prank(nonAdmin);
    vm.expectRevert(bytes(""));
    stEXA.setRewardsDuration(rewardsTokens[0], 1);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    stEXA.setRewardsDuration(rewardsTokens[0], 1);

    (uint256 duration0, , , , ) = stEXA.rewards(rewardsTokens[0]);
    assertEq(duration0, 1);
  }

  function testOnlyAdminNotifyRewardAmount() external {
    address nonAdmin = address(0x1);

    uint256 amount = 1_000e18;

    rewardsTokens[0].mint(address(stEXA), amount);

    vm.prank(nonAdmin);
    vm.expectRevert(bytes(""));
    stEXA.notifyRewardAmount(rewardsTokens[0], amount);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardAmountNotified(rewardsTokens[0], admin, amount);
    stEXA.notifyRewardAmount(rewardsTokens[0], amount);

    (uint256 duration0, uint256 finishAt, , , uint256 updatedAt) = stEXA.rewards(rewardsTokens[0]);
    assertEq(finishAt, block.timestamp + duration0);
    assertEq(updatedAt, block.timestamp);
  }

  function testRewardsAmounts(uint256 assets) external {
    assets = _bound(assets, 1, exaBalance);

    uint256 time = 10 days;

    (, , , uint256 rate, ) = stEXA.rewards(rewardsTokens[0]);
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

    assertApproxEqAbs(
      stEXA.earned(rewardsTokens[0], address(this)),
      thisRewards,
      1e7,
      "this rewards != earned expected"
    );
    assertApproxEqAbs(stEXA.earned(rewardsTokens[0], BOB), bobRewards, 1e7, "bob rewards != earned expected");

    uint256 thisClaimable = stEXA.claimable(rewardsTokens[0], address(this));
    stEXA.withdraw(assets, address(this), address(this));
    assertApproxEqAbs(rewardsTokens[0].balanceOf(address(this)), thisClaimable, 1e7, "this rewards != expected");

    uint256 bobBefore = rewardsTokens[0].balanceOf(BOB);

    uint256 bobClaimable = stEXA.claimable(rewardsTokens[0], BOB);
    vm.prank(BOB);
    stEXA.withdraw(assets, BOB, BOB);

    assertApproxEqAbs(rewardsTokens[0].balanceOf(BOB) - bobBefore, bobClaimable, 1e7, "bob rewards != expected");
  }

  function testNoRewardsAfterPeriod(uint256 timeAfterPeriod) external {
    timeAfterPeriod = _bound(timeAfterPeriod, 1, duration * 2);
    uint256 assets = 1_000e18;

    uint256 time = duration / 2;
    uint256 rate = initialAmount / duration;
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

    assertApproxEqAbs(
      stEXA.earned(rewardsTokens[0], address(this)),
      thisRewards,
      600,
      "this rewards != earned expected"
    );
    assertApproxEqAbs(stEXA.earned(rewardsTokens[0], BOB), bobRewards, 200, "bob rewards != earned expected");

    skip(timeAfterPeriod);

    uint256 thisClaimable = stEXA.claimable(rewardsTokens[0], address(this));
    stEXA.withdraw(assets, address(this), address(this));
    assertApproxEqAbs(rewardsTokens[0].balanceOf(address(this)), thisClaimable, 600, "this rewards != expected");

    uint256 bobClaimable = stEXA.claimable(rewardsTokens[0], BOB);
    vm.prank(BOB);
    stEXA.withdraw(assets, BOB, BOB);
    assertApproxEqAbs(rewardsTokens[0].balanceOf(BOB), bobClaimable, 200, "bob rewards != expected");

    assertEq(stEXA.earned(rewardsTokens[0], address(this)), 0);
    assertEq(stEXA.earned(rewardsTokens[0], BOB), 0);

    skip(timeAfterPeriod);

    assertEq(stEXA.earned(rewardsTokens[0], address(this)), 0);
    assertEq(stEXA.earned(rewardsTokens[0], BOB), 0);
  }

  function testAvgStartTime(uint256[3] memory assets, uint256[2] memory times) external {
    assets[0] = _bound(assets[0], 1, exaBalance / 3);
    assets[1] = _bound(assets[1], 1, exaBalance / 3);
    assets[2] = _bound(assets[2], 1, exaBalance / 3);
    times[0] = _bound(times[0], 1, duration / 2);
    times[1] = _bound(times[1], 1, duration / 2);

    uint256 avgStartTime = block.timestamp * 1e18;
    stEXA.deposit(assets[0], address(this));
    assertEq(stEXA.avgStart(address(this)), avgStartTime);

    skip(times[0]);

    uint256 opWeight = assets[0].divWadDown(assets[0] + assets[1]);
    avgStartTime = avgStartTime.mulWadUp(opWeight) + (block.timestamp) * (1e18 - opWeight);
    stEXA.deposit(assets[1], address(this));
    assertEq(stEXA.avgStart(address(this)), avgStartTime);

    skip(times[1]);

    uint256 balance = assets[0] + assets[1];
    opWeight = balance.divWadDown(balance + assets[2]);
    avgStartTime = avgStartTime.mulWadUp(opWeight) + (block.timestamp) * (1e18 - opWeight);

    stEXA.deposit(assets[2], address(this));
    assertEq(stEXA.avgStart(address(this)), avgStartTime);
  }

  function testAvgIndex(uint256[3] memory assets, uint256[2] memory times) external {
    assets[0] = _bound(assets[0], 1, exaBalance / 3);
    assets[1] = _bound(assets[1], 1, exaBalance / 3);
    assets[2] = _bound(assets[2], 1, exaBalance / 3);
    times[0] = _bound(times[0], 1, duration / 2);
    times[1] = _bound(times[1], 1, duration / 2);

    stEXA.deposit(assets[0], address(this));
    uint256 avgIndex = stEXA.globalIndex(rewardsTokens[0]);
    assertEq(stEXA.avgIndex(rewardsTokens[0], address(this)), avgIndex, "avgIndex.0 != globalIndex");

    skip(times[0]);

    uint256 opWeight = assets[0].divWadDown(assets[0] + assets[1]);
    stEXA.deposit(assets[1], address(this));
    avgIndex = avgIndex.mulWadUp(opWeight) + stEXA.globalIndex(rewardsTokens[0]).mulWadUp(1e18 - opWeight);
    assertEq(stEXA.avgIndex(rewardsTokens[0], address(this)), avgIndex, "avgIndex.1 != globalIndex");

    skip(times[1]);

    uint256 balance = assets[0] + assets[1];
    opWeight = balance.divWadDown(balance + assets[2]);
    avgIndex = avgIndex.mulWadUp(opWeight) + stEXA.globalIndex(rewardsTokens[0]).mulWadUp(1e18 - opWeight);
    stEXA.deposit(assets[2], address(this));
    assertEq(stEXA.avgIndex(rewardsTokens[0], address(this)), avgIndex, "avgIndex.2 != globalIndex");
  }

  function testDepositWithdrawAvgStartTimeAndIndex(
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

    uint256 avgStartTime = block.timestamp * 1e18;
    uint256 avgIndex = stEXA.globalIndex(rewardsTokens[0]);

    // skip + partial withdraw -> avg time and index shouldn't change
    skip(times[1]);
    stEXA.withdraw(partialWithdraw, address(this), address(this));
    assertEq(stEXA.avgStart(address(this)), avgStartTime, "avgStartTime != expected");
    assertEq(stEXA.avgIndex(rewardsTokens[0], address(this)), avgIndex, "avgIndex != expected");

    // skip + new deposit -> avg time and index should change
    skip(times[2]);
    stEXA.deposit(assets[1], address(this));
    uint256 balance = assets[0] - partialWithdraw;
    uint256 opWeight = balance.divWadDown(balance + assets[1]);
    avgStartTime = avgStartTime.mulWadUp(opWeight) + (block.timestamp) * (1e18 - opWeight);
    avgIndex = avgIndex.mulWadUp(opWeight) + stEXA.globalIndex(rewardsTokens[0]).mulWadUp(1e18 - opWeight);

    // skip + full withdraw -> avg time and index shouldn't change
    skip(times[3]);
    uint256 fullWithdraw = assets[0] + assets[1] - partialWithdraw;
    stEXA.withdraw(fullWithdraw, address(this), address(this));
    assertEq(stEXA.avgStart(address(this)), avgStartTime, "avgStartTime != expected");
    assertEq(stEXA.avgIndex(rewardsTokens[0], address(this)), avgIndex, "avgIndex != expected");

    // skip + new deposit -> avg time and index should be restarted
    skip(times[4]);
    stEXA.deposit(assets[2], address(this));
    avgStartTime = block.timestamp * 1e18;
    avgIndex = stEXA.globalIndex(rewardsTokens[0]);
    assertEq(stEXA.avgStart(address(this)), avgStartTime, "avgStartTime != expected");
    assertEq(stEXA.avgIndex(rewardsTokens[0], address(this)), avgIndex, "avgIndex != expected");
  }

  function testWithdrawSameAmountRewardsShouldEqual(uint256 amount, uint256 time) external {
    amount = _bound(amount, 2, exaBalance);
    time = _bound(time, 1, duration - 1);

    stEXA.deposit(amount, address(this));
    uint256 rewBalance = rewardsTokens[0].balanceOf(address(this));

    skip(time);
    // withdraw 1/2 of the assets
    stEXA.withdraw(amount / 2, address(this), address(this));
    uint256 claimedRewards = rewardsTokens[0].balanceOf(address(this)) - rewBalance;

    // withdraw same amount
    rewBalance = rewardsTokens[0].balanceOf(address(this));
    stEXA.withdraw(amount / 2, address(this), address(this));
    uint256 claimedRewards2 = rewardsTokens[0].balanceOf(address(this)) - rewBalance;

    assertEq(claimedRewards, claimedRewards2, "claimed rewards != expected");
  }

  function testGrantRevokePauser() external {
    address pauser = address(0x1);
    stEXA.grantRole(stEXA.PAUSER_ROLE(), pauser);
    assertTrue(stEXA.hasRole(stEXA.PAUSER_ROLE(), pauser));

    stEXA.revokeRole(stEXA.PAUSER_ROLE(), pauser);
    assertFalse(stEXA.hasRole(stEXA.PAUSER_ROLE(), pauser));
  }

  function testPauserCanPauseUnpause() external {
    address pauser = address(0x1);
    stEXA.grantRole(stEXA.PAUSER_ROLE(), pauser);
    assertTrue(stEXA.hasRole(stEXA.PAUSER_ROLE(), pauser));

    vm.startPrank(pauser);
    stEXA.pause();
    assertTrue(stEXA.paused());

    stEXA.unpause();
    assertFalse(stEXA.paused());
    vm.stopPrank();
  }

  function testGrantRevokeEmergencyAdmin() external {
    address emergencyAdmin = address(0x1);
    stEXA.grantRole(stEXA.EMERGENCY_ADMIN_ROLE(), emergencyAdmin);
    assertTrue(stEXA.hasRole(stEXA.EMERGENCY_ADMIN_ROLE(), emergencyAdmin));

    stEXA.revokeRole(stEXA.EMERGENCY_ADMIN_ROLE(), emergencyAdmin);
    assertFalse(stEXA.hasRole(stEXA.EMERGENCY_ADMIN_ROLE(), emergencyAdmin));
  }

  function testEmergencyAdminCanPauseNotUnpause() external {
    address emergencyAdmin = address(0x1);
    stEXA.grantRole(stEXA.EMERGENCY_ADMIN_ROLE(), emergencyAdmin);
    assertTrue(stEXA.hasRole(stEXA.EMERGENCY_ADMIN_ROLE(), emergencyAdmin));

    vm.startPrank(emergencyAdmin);
    stEXA.pause();
    assertTrue(stEXA.paused());

    vm.expectRevert(bytes(""));
    stEXA.unpause();
    vm.stopPrank();
  }

  function testPausable() external {
    stEXA.deposit(1, address(this));

    address pauser = address(0x1);
    stEXA.grantRole(stEXA.PAUSER_ROLE(), pauser);

    vm.prank(pauser);
    stEXA.pause();
    assertTrue(stEXA.paused());

    vm.expectRevert(bytes(""));
    stEXA.deposit(1, address(this));

    vm.expectRevert(bytes(""));
    stEXA.redeem(1, address(this), address(this));

    vm.expectRevert(bytes(""));
    stEXA.withdraw(1, address(this), address(this));

    vm.prank(pauser);
    stEXA.unpause();
    assertFalse(stEXA.paused());

    stEXA.deposit(1, address(this));

    stEXA.redeem(1, address(this), address(this));
    stEXA.withdraw(1, address(this), address(this));
  }

  function testNotPausingRoleError() external {
    address nonPauser = address(0x1);
    vm.expectRevert(NotPausingRole.selector);
    vm.prank(nonPauser);
    stEXA.pause();
  }

  function testOnlyAdminEnableReward() external {
    ERC20 notListed = new MockERC20("reward C", "rC", 18);

    address nonAdmin = address(0x1);
    vm.prank(nonAdmin);
    vm.expectRevert(bytes(""));
    stEXA.enableReward(notListed);

    (, uint256 finishAt, , , ) = stEXA.rewards(notListed);
    assertEq(finishAt, 0);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardListed(notListed, admin);
    stEXA.enableReward(notListed);

    (, finishAt, , , ) = stEXA.rewards(notListed);
    assertNotEq(finishAt, 0);
  }

  function testAlreadyListedError() external {
    vm.expectRevert(AlreadyListed.selector);
    stEXA.enableReward(rewardsTokens[0]);
  }

  function testRewardNotListedError() external {
    MockERC20 notListed = new MockERC20("reward C", "rC", 18);
    uint256 amount = 1;
    notListed.mint(address(stEXA), amount);

    vm.expectRevert(RewardNotListed.selector);
    stEXA.notifyRewardAmount(notListed, amount);
  }

  function testHarvest() external {
    uint256 assets = market.maxWithdraw(PROVIDER); // 1_000e18

    stEXA.harvest();

    assertEq(market.maxWithdraw(PROVIDER), 0);
    assertEq(minMaxWithdrawAllowance(), 0);
    assertEq(providerAsset.balanceOf(address(stEXA)), assets.mulWadDown(providerRatio));
    assertEq(market.maxWithdraw(SAVINGS), assets.mulWadDown(1e18 - providerRatio));
  }

  function testHarvestEffectOnRewardData() external {
    uint256 assets = market.maxWithdraw(PROVIDER);
    stEXA.harvest();
    (uint256 providerDuration, uint256 finishAt, uint256 index, uint256 rate, uint256 updatedAt) = stEXA.rewards(
      providerAsset
    );
    assertEq(providerDuration, 1 weeks);
    assertEq(finishAt, block.timestamp + 1 weeks);
    assertEq(index, 0);
    assertEq(rate, assets.mulWadDown(providerRatio) / 1 weeks);
    assertEq(updatedAt, block.timestamp);
  }

  function testHarvestZero() external {
    stEXA.harvest();
    uint256 remaining = market.maxWithdraw(PROVIDER);
    uint256 savingsBal = market.maxWithdraw(SAVINGS);
    uint256 harvested = providerAsset.balanceOf(address(stEXA));
    assertEq(remaining, 0);
    stEXA.harvest();
    assertEq(savingsBal, market.maxWithdraw(SAVINGS), "savings didn't stay the same");
    assertEq(providerAsset.balanceOf(address(stEXA)), harvested, "providerAsset balance changed");
  }

  function testHarvestAmountWithReducedAllowance() external {
    uint256 allowance = 500e18;

    vm.prank(PROVIDER);
    market.approve(address(stEXA), allowance);

    stEXA.harvest();
    uint256 harvested = providerAsset.balanceOf(address(stEXA));
    assertEq(allowance.mulWadDown(providerRatio), harvested);
  }

  function testHarvestSetters() external {
    // TODO
  }

  function testMultipleHarvests() external {
    uint256 assets = market.maxWithdraw(PROVIDER);
    stEXA.harvest();

    uint256 amount = 1_000e18;
    providerAsset.mint(address(this), amount);
    providerAsset.approve(address(market), type(uint256).max);
    market.deposit(amount, PROVIDER);
    stEXA.harvest();

    assertEq(providerAsset.balanceOf(address(stEXA)), (assets + amount).mulWadDown(providerRatio));
  }

  function testHarvestEmitsRewardAmountNotified() external {
    uint256 assets = market.maxWithdraw(PROVIDER);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardAmountNotified(providerAsset, address(stEXA), assets.mulWadDown(providerRatio));
    stEXA.harvest();
  }

  function testClaimBeforeFirstHarvest() external {
    uint256 assets = market.maxWithdraw(PROVIDER);
    stEXA.deposit(assets, address(this));
    uint256 thisClaimable = stEXA.claimable(providerAsset, address(this));
    providerAsset.balanceOf(address(stEXA));
    stEXA.withdraw(assets, address(this), address(this));
    assertEq(providerAsset.balanceOf(address(this)), thisClaimable);
  }

  function testClaimAfterHarvest() external {
    uint256 assets = 1_000e18;
    uint256 harvested = market.maxWithdraw(PROVIDER).mulWadDown(providerRatio);
    stEXA.harvest();
    stEXA.deposit(assets, address(this));
    skip(minTime);
    uint256 thisClaimable = stEXA.claimable(providerAsset, address(this));
    assertEq(thisClaimable, 0);
    skip(1);
    thisClaimable = stEXA.claimable(providerAsset, address(this));
    assertGt(thisClaimable, 0);

    skip(refTime - 1 weeks - 1);

    thisClaimable = stEXA.claimable(providerAsset, address(this));

    stEXA.withdraw(assets, address(this), address(this));
    assertEq(providerAsset.balanceOf(address(this)), thisClaimable);
    assertApproxEqAbs(providerAsset.balanceOf(address(this)), harvested, 1e6); // no one else was in the program
  }

  function testDisableRewardStopsEmission() external {
    uint256 assets = 1_000e18;
    stEXA.deposit(assets, address(this));
    stEXA.deposit(assets, BOB);
    skip(minTime + 1);

    uint256 thisClaimable = stEXA.claimable(rewardsTokens[0], address(this));
    uint256 earned = stEXA.earned(rewardsTokens[0], address(this));

    stEXA.disableReward(rewardsTokens[0]);
    stEXA.withdraw(assets, address(this), address(this));
    assertEq(rewardsTokens[0].balanceOf(address(this)), thisClaimable);

    // stops emission
    skip(2 weeks);

    assertEq(stEXA.earned(rewardsTokens[0], BOB), earned);

    // lets claim
    uint256 bobClaimable = stEXA.claimable(rewardsTokens[0], BOB);
    vm.prank(BOB);
    stEXA.withdraw(assets, BOB, BOB);
    assertEq(rewardsTokens[0].balanceOf(BOB), bobClaimable);
  }

  function testDisableRewardLetsClaimUnclaimed() external {
    uint256 assets = 1_000e18;
    stEXA.deposit(assets, address(this));
    stEXA.deposit(assets, BOB);
    skip(minTime + 1);

    uint256 thisClaimable = stEXA.claimable(rewardsTokens[0], address(this));
    uint256 earned = stEXA.earned(rewardsTokens[0], address(this));

    stEXA.disableReward(rewardsTokens[0]);
    uint256 newClaimable = stEXA.claimable(rewardsTokens[0], address(this));
    assertEq(thisClaimable, newClaimable);
    stEXA.withdraw(assets, address(this), address(this));
    assertEq(rewardsTokens[0].balanceOf(address(this)), thisClaimable);

    // lets claim the unclaimed
    skip(2 weeks);

    assertEq(stEXA.claimable(rewardsTokens[0], address(this)), 0);
    assertEq(stEXA.earned(rewardsTokens[0], BOB), earned);
    uint256 bobClaimable = stEXA.claimable(rewardsTokens[0], BOB);
    vm.prank(BOB);
    stEXA.withdraw(assets, BOB, BOB);
    assertEq(rewardsTokens[0].balanceOf(BOB), bobClaimable);
  }

  function testDisableRewardEmitEvent() external {
    harvest();
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardDisabled(providerAsset, address(this));
    stEXA.disableReward(providerAsset);
  }

  function testOnlyAdminDisableReward() external {
    vm.prank(BOB);
    vm.expectRevert(bytes(""));
    stEXA.disableReward(rewardsTokens[0]);

    address admin = address(0x1);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit RewardDisabled(rewardsTokens[0], admin);
    stEXA.disableReward(rewardsTokens[0]);

    (, uint256 finishAt, , , ) = stEXA.rewards(rewardsTokens[0]);
    assertNotEq(finishAt, 0);
  }

  function testCanChangeRewardsDurationWhenDisabled() external {
    vm.expectRevert(NotFinished.selector);
    stEXA.setRewardsDuration(rewardsTokens[0], 1);

    stEXA.disableReward(rewardsTokens[0]);
    stEXA.setRewardsDuration(rewardsTokens[0], 1 weeks);

    (uint256 duration0, uint256 finishAt, , , ) = stEXA.rewards(rewardsTokens[0]);

    assertEq(duration0, 1 weeks);
    assertEq(finishAt, block.timestamp);
  }

  function testDisableRewardTransfersRemainingToSavings() external {
    uint256 savingsBalance = rewardsTokens[0].balanceOf(SAVINGS);

    (, uint256 finishAt, , uint256 rate, ) = stEXA.rewards(rewardsTokens[0]);
    uint256 remainingRewards = rate * (finishAt - block.timestamp);

    stEXA.disableReward(rewardsTokens[0]);
    assertEq(rewardsTokens[0].balanceOf(SAVINGS), savingsBalance + remainingRewards);

    (, finishAt, , , ) = stEXA.rewards(rewardsTokens[0]);
    assertEq(finishAt, block.timestamp);
  }

  function testDisableRewardThatAlreadyFinished() external {
    stEXA.deposit(1_000e18, address(this));
    skip(duration + 1);

    uint256 savingsBalance = rewardsTokens[0].balanceOf(SAVINGS);

    (, uint256 finishAt, , uint256 rate, ) = stEXA.rewards(rewardsTokens[0]);

    uint256 remainingRewards = finishAt > block.timestamp ? rate * (finishAt - block.timestamp) : 0;

    assertEq(remainingRewards, 0);

    stEXA.disableReward(rewardsTokens[0]);
    assertEq(rewardsTokens[0].balanceOf(SAVINGS), savingsBalance);

    (, uint256 newFinishAt, , , ) = stEXA.rewards(rewardsTokens[0]);
    assertEq(finishAt, newFinishAt);
  }

  function testSetMarketOnlyAdmin() external {
    address nonAdmin = address(0x1);
    Market newMarket = Market(address(new MockMarket(exa)));

    vm.prank(nonAdmin);
    vm.expectRevert(bytes(""));
    stEXA.setMarket(newMarket);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit MarketSet(newMarket, admin);
    stEXA.setMarket(newMarket);
    assertEq(address(stEXA.market()), address(newMarket));
  }

  function testOnlyAdminSetProvider() external {
    address nonAdmin = address(0x1);
    address newProvider = address(0x2);

    vm.prank(nonAdmin);
    vm.expectRevert(bytes(""));
    stEXA.setProvider(newProvider);

    address admin = address(0x3);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit ProviderSet(newProvider, admin);
    stEXA.setProvider(newProvider);
    assertEq(stEXA.provider(), newProvider);
  }

  function testOnlyAdminSetProviderRatio() external {
    address nonAdmin = address(0x1);
    uint256 newProviderRatio = 0.5e18;

    vm.prank(nonAdmin);
    vm.expectRevert(bytes(""));
    stEXA.setProviderRatio(newProviderRatio);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit ProviderRatioSet(newProviderRatio, admin);
    stEXA.setProviderRatio(newProviderRatio);
    assertEq(stEXA.providerRatio(), newProviderRatio);
  }

  function testOnlyAdminSetSavings() external {
    address nonAdmin = address(0x1);
    address newSavings = address(0x2);

    vm.prank(nonAdmin);
    vm.expectRevert(bytes(""));
    stEXA.setSavings(newSavings);

    address admin = address(0x3);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit SavingsSet(newSavings, admin);
    stEXA.setSavings(newSavings);
    assertEq(stEXA.savings(), newSavings);
  }

  function testSetProviderZeroAddressError() external {
    vm.expectRevert(ZeroAddress.selector);
    stEXA.setProvider(address(0));
  }

  function testSetSavingsZeroAddressError() external {
    vm.expectRevert(ZeroAddress.selector);
    stEXA.setSavings(address(0));
  }

  function testSetProviderRatioOverOneError() external {
    vm.expectRevert(InvalidRatio.selector);
    stEXA.setProviderRatio(1e18 + 1);
  }

  function testAllClaimable() external {
    uint256 assets = 1_000e18;
    stEXA.deposit(assets, address(this));
    skip(minTime);

    ClaimableReward[] memory claimableRewards = stEXA.allClaimable(address(this));
    assertEq(claimableRewards.length, stEXA.allRewardsTokens().length);

    for (uint256 i = 0; i < claimableRewards.length; i++) {
      assertEq(claimableRewards[i].amount, 0);
    }

    skip(1);

    claimableRewards = stEXA.allClaimable(address(this));
    assertEq(claimableRewards.length, stEXA.allRewardsTokens().length);

    for (uint256 i = 0; i < claimableRewards.length; i++) {
      ClaimableReward memory claimableReward = claimableRewards[i];
      assertEq(claimableRewards[i].amount, stEXA.claimable(ERC20(claimableReward.reward), address(this)));
    }
  }

  function testAllEarned() external {
    uint256 assets = 1_000e18;
    stEXA.deposit(assets, address(this));
    skip(minTime + 1);

    ClaimableReward[] memory earnedRewards = stEXA.allEarned(address(this));
    assertEq(earnedRewards.length, stEXA.allRewardsTokens().length);

    for (uint256 i = 0; i < earnedRewards.length; i++) {
      ClaimableReward memory earnedReward = earnedRewards[i];
      assertEq(earnedRewards[i].amount, stEXA.earned(ERC20(earnedReward.reward), address(this)));
    }
  }

  function minMaxWithdrawAllowance() internal view returns (uint256) {
    return Math.min(market.convertToAssets(market.allowance(PROVIDER, address(stEXA))), market.maxWithdraw(PROVIDER));
  }

  function harvest() internal {
    providerAsset.mint(PROVIDER, 1_000e18);
    stEXA.harvest();
  }

  event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
  event Withdraw(
    address indexed sender,
    address indexed receiver,
    address indexed owner,
    uint256 assets,
    uint256 shares
  );
  event MarketSet(Market indexed market, address indexed account);
  event ProviderRatioSet(uint256 providerRatio, address indexed account);
  event ProviderSet(address indexed provider, address indexed account);
  event RewardAmountNotified(ERC20 indexed reward, address indexed account, uint256 amount);
  event RewardDisabled(ERC20 indexed reward, address indexed account);
  event RewardPaid(ERC20 indexed reward, address indexed account, uint256 amount);
  event RewardListed(ERC20 indexed reward, address indexed account);
  event RewardsDurationSet(ERC20 indexed reward, address indexed account, uint256 duration);
  event SavingsSet(address indexed savings, address indexed account);
}

contract MockMarket is ERC4626 {
  constructor(ERC20 asset_) ERC4626(asset_, "WETH Market", "exaWETH") {
    asset = asset_;
  }

  // solhint-disable-next-line no-empty-blocks
  function totalAssets() public view override returns (uint256) {
    return totalSupply;
  }

  function convertToAssets(uint256 shares) public pure override returns (uint256) {
    return shares;
  }
}
