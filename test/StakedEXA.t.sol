// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0; // solhint-disable-line one-contract-per-file

import { Test, stdError } from "forge-std/Test.sol";

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20, ERC4626, IERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import {
  AlreadyEnabled,
  IERC20,
  InsufficientBalance,
  InvalidRatio,
  InvalidRange,
  Market,
  Math,
  MaxRewardsTokensExceeded,
  NotFinished,
  NotPausingRole,
  Parameters,
  Permit,
  RewardNotListed,
  StakedEXA,
  Untransferable,
  ZeroAddress,
  ZeroAmount,
  ZeroRate
} from "../contracts/StakedEXA.sol";

contract StakedEXATest is Test {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;
  using FixedPointMathLib for uint64;

  uint256 internal constant BOB_KEY = 0x420;
  address internal BOB; // solhint-disable-line var-name-mixedcase
  StakedEXA internal stEXA;
  MockERC20 internal exa;
  MockERC20 internal rA;
  MockERC20 internal rB;
  uint256 internal initialAmount;
  uint40 internal duration;
  uint256 internal minTime;
  uint256 internal refTime;
  uint256 internal excessFactor;
  uint256 internal penaltyGrowth;
  uint256 internal penaltyThreshold;

  Market internal market;
  Market internal marketB;
  MockERC20 internal providerAsset;
  MockERC20 internal providerAssetB;
  address internal constant PROVIDER = address(0x1);
  address internal constant SAVINGS = address(0x2);
  uint256 internal providerRatio;

  address[] internal accounts;
  mapping(IERC20 reward => uint256 index) internal globalIndex;
  mapping(address account => uint256 start) internal avgStart;
  mapping(address account => mapping(IERC20 reward => uint256 index)) internal avgIndexes;
  mapping(address account => mapping(IERC20 reward => uint256 amount)) internal rawClaimable;
  mapping(address account => mapping(IERC20 reward => uint256 amount)) internal claimed;

  function setUp() external {
    vm.warp(1_704_067_200); // 01/01/2024 @ 00:00 (UTC)
    exa = new MockERC20("exactly", "EXA", 18);
    vm.label(address(exa), "EXA");
    rA = new MockERC20("reward A", "rA", 18);
    rB = new MockERC20("reward B", "rB", 6);
    vm.label(address(rA), "rA");
    vm.label(address(rB), "rB");

    duration = 24 weeks;
    initialAmount = 1_000 ether;
    minTime = 1 weeks;
    refTime = duration;
    excessFactor = 0.5e18;
    penaltyGrowth = 2e18;
    penaltyThreshold = 0.5e18;

    providerAsset = new MockERC20("Wrapped ETH", "WETH", 18);
    providerAssetB = new MockERC20("USD Coin", "USDC", 6);
    market = Market(address(new MockMarket(providerAsset)));
    marketB = Market(address(new MockMarket(providerAssetB)));
    vm.label(address(providerAsset), "WETH");
    vm.label(address(providerAssetB), "USDC");
    vm.label(address(market), "Market");
    vm.label(address(marketB), "MarketB");
    vm.label(PROVIDER, "provider");
    vm.label(SAVINGS, "savings");

    providerRatio = 0.1e18;
    stEXA = StakedEXA(address(new ERC1967Proxy(address(new StakedEXA()), "")));
    stEXA.initialize(
      Parameters({
        asset: exa,
        minTime: minTime,
        refTime: refTime,
        excessFactor: excessFactor,
        penaltyGrowth: penaltyGrowth,
        penaltyThreshold: penaltyThreshold,
        market: market,
        provider: PROVIDER,
        savings: SAVINGS,
        duration: 1 weeks,
        providerRatio: providerRatio
      })
    );
    vm.label(address(stEXA), "stEXA");
    vm.label(
      address(
        uint160(uint256(vm.load(address(stEXA), bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1))))
      ),
      "stEXA_Impl"
    );

    providerAsset.mint(PROVIDER, 1_000e18);
    providerAssetB.mint(PROVIDER, 1_000e6);

    vm.startPrank(PROVIDER);
    providerAsset.approve(address(market), type(uint256).max);
    providerAssetB.approve(address(marketB), type(uint256).max);
    market.deposit(1_000e18, PROVIDER);
    marketB.deposit(1_000e6, PROVIDER);
    market.approve(address(stEXA), type(uint256).max);
    marketB.approve(address(stEXA), type(uint256).max);
    vm.stopPrank();

    exa.approve(address(stEXA), type(uint256).max);

    exa.mint(address(stEXA), initialAmount);
    rA.mint(address(stEXA), initialAmount);
    rB.mint(address(stEXA), initialAmount);

    stEXA.enableReward(exa);
    stEXA.enableReward(rA);
    stEXA.enableReward(rB);

    stEXA.setRewardsDuration(exa, duration);
    stEXA.setRewardsDuration(rA, duration);
    stEXA.setRewardsDuration(rB, duration);
    stEXA.notifyRewardAmount(exa, initialAmount);
    stEXA.notifyRewardAmount(rA, initialAmount);
    stEXA.notifyRewardAmount(rB, initialAmount);

    BOB = vm.addr(BOB_KEY);
    vm.label(BOB, "bob");
    vm.label(address(uint160(BOB) + 1), "shadowBob");
    vm.label(address(uint160(address(this)) + 1), "shadowTest");

    accounts.push(address(this));
    accounts.push(BOB);

    targetContract(address(this));
    bytes4[] memory selectors = new bytes4[](8);
    selectors[0] = this.handlerSkip.selector;
    selectors[1] = this.testHandlerDeposit.selector;
    selectors[2] = this.testHandlerWithdraw.selector;
    selectors[3] = this.testHandlerClaim.selector;
    selectors[4] = this.testHandlerHarvest.selector;
    selectors[5] = this.testHandlerNotifyRewardAmount.selector;
    selectors[6] = this.testHandlerSetDuration.selector;
    selectors[7] = this.testHandlerSetMarket.selector;
    targetSelector(FuzzSelector(address(this), selectors));
  }

  function invariantRewardsUpOnly() external view {
    IERC20[] memory rewards = stEXA.allRewardsTokens();
    for (uint256 a = 0; a < accounts.length; ++a) {
      address account = accounts[a];
      uint256 shares = stEXA.balanceOf(account);
      uint256 time = avgStart[account] != 0 ? block.timestamp * 1e18 - avgStart[account] : 0;
      for (uint256 i = 0; i < rewards.length; ++i) {
        IERC20 reward = rewards[i];
        // TODO assert with discount factor
        assertGe(
          stEXA.rawClaimable(reward, account, shares),
          rawClaimable[account][reward].mulWadDown(discountFactor(time)),
          "claimable went down"
        );
      }
    }
  }

  function invariantIndexUpOnly() external view {
    IERC20[] memory rewards = stEXA.allRewardsTokens();
    for (uint256 i = 0; i < rewards.length; ++i) {
      for (uint256 a = 0; a < accounts.length; ++a) {
        IERC20 reward = rewards[i];
        assertGe(stEXA.globalIndex(reward), globalIndex[reward]);
      }
    }
  }

  function invariantAvgIndexUpOnly() external view {
    IERC20[] memory rewards = stEXA.allRewardsTokens();
    for (uint256 i = 0; i < rewards.length; ++i) {
      for (uint256 a = 0; a < accounts.length; ++a) {
        address account = accounts[a];
        IERC20 reward = rewards[i];
        assertGe(stEXA.avgIndex(reward, account), avgIndexes[account][reward]);
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
    IERC20[] memory rewards = stEXA.allRewardsTokens();
    for (uint256 i = 0; i < rewards.length; ++i) {
      for (uint256 j = i + 1; j < rewards.length; ++j) {
        assertNotEq(address(rewards[i]), address(rewards[j]));
      }
    }
  }

  function afterInvariant() external {
    if (stEXA.totalSupply() == 0) return;

    IERC20[] memory rewards = stEXA.allRewardsTokens();
    for (uint256 a = 0; a < accounts.length; ++a) {
      address account = accounts[a];
      address shadow = address(uint160(account) + 1);

      {
        uint256 balance = stEXA.balanceOf(account);
        assertEq(balance, stEXA.balanceOf(shadow), "balance != shadow");

        if (balance != 0) {
          vm.prank(account);
          stEXA.withdraw(balance, account, account);

          vm.prank(shadow);
          stEXA.withdraw(balance, shadow, shadow);
        }
      }

      for (uint256 i = 0; i < rewards.length; ++i) {
        IERC20 reward = rewards[i];
        uint256 balance = reward.balanceOf(account);
        uint256 shadowBalance = reward.balanceOf(shadow);
        assertGe(balance, shadowBalance, "rewards > shadow"); // TODO
      }
    }
  }

  function handlerSkip(uint32 time) external {
    IERC20[] memory rewards = stEXA.allRewardsTokens();
    for (uint256 a = 0; a < accounts.length; ++a) {
      address account = accounts[a];
      for (uint256 i = 0; i < rewards.length; ++i) {
        IERC20 reward = rewards[i];
        rawClaimable[account][reward] = stEXA.rawClaimable(reward, account, stEXA.balanceOf(account));
      }
    }
    skip(time);
  }

  function testHandlerDeposit(uint80 assets) external {
    uint256 prevAssets = stEXA.totalAssets();

    address account = accounts[uint256(keccak256(abi.encode(assets, block.timestamp))) % accounts.length];
    uint256 prevShares = stEXA.balanceOf(account);
    uint256 total = prevShares + assets;

    exa.mint(account, assets);
    vm.startPrank(account);
    exa.approve(address(stEXA), assets);
    if (assets == 0) vm.expectRevert(ZeroAmount.selector);
    // TODO assert after-refTime properties
    stEXA.deposit(assets, account);
    vm.stopPrank();
    assertEq(stEXA.totalAssets(), prevAssets + assets, "missing assets");

    if (assets == 0) return;
    address shadow = address(uint160(account) + 1);
    exa.mint(shadow, assets);
    vm.startPrank(shadow);
    exa.approve(address(stEXA), assets);
    stEXA.deposit(assets, shadow);
    vm.stopPrank();

    uint256 timestamp = block.timestamp * 1e18;
    uint256 time = timestamp - avgStart[account];

    if (time > refTime * 1e18 || avgStart[account] == 0) {
      avgStart[account] = timestamp;
    } else {
      uint256 numerator = avgStart[account] * prevShares + timestamp * assets;
      avgStart[account] = numerator == 0 ? 0 : (numerator - 1) / total + 1;
    }
    assertEq(avgStart[account], stEXA.avgStart(account), "avgStart != expected");
    uint256 newTime = timestamp - avgStart[account];

    IERC20[] memory rewards = stEXA.allRewardsTokens();
    for (uint256 i = 0; i < rewards.length; ++i) {
      IERC20 reward = rewards[i];
      if (time > refTime * 1e18) {
        // position restarts
        claimed[account][reward] = 0;
        rawClaimable[account][reward] = 0;
        avgIndexes[account][reward] = stEXA.globalIndex(reward);
      } else {
        if (prevShares != 0) {
          // claims before deposit
          uint256 prevRawClaimable = prevShares
            .mulWadDown(stEXA.globalIndex(reward) - avgIndexes[account][reward])
            .mulWadDown(discountFactor(time));
          // sum the claimable to claimed before updating the user index
          uint256 prevClaimable = prevRawClaimable > claimed[account][reward]
            ? prevRawClaimable - claimed[account][reward]
            : 0;
          claimed[account][reward] += prevClaimable;
        }
        globalIndex[reward] = stEXA.globalIndex(reward);
        uint256 numerator = avgIndexes[account][reward] * prevShares + globalIndex[reward] * assets;
        avgIndexes[account][reward] = numerator == 0 ? 0 : (numerator - 1) / total + 1;
        rawClaimable[account][reward] = total.mulWadDown(globalIndex[reward] - avgIndexes[account][reward]).mulWadDown(
          discountFactor(newTime)
        );
      }
      assertEq(rawClaimable[account][reward], stEXA.rawClaimable(reward, account, total), "rawClaimable != expected");
      assertEq(claimed[account][reward], stEXA.claimed(account, reward), "claimed != expected");
      uint256 claimableAmount = rawClaimable[account][reward] > claimed[account][reward]
        ? rawClaimable[account][reward] - claimed[account][reward]
        : 0;
      assertEq(claimableAmount, claimable(reward, account), "claimable != expected");
      assertEq(avgIndexes[account][reward], stEXA.avgIndex(reward, account), "avgIndex != expected");
    }
  }

  struct Vars {
    uint256 claimable;
    uint256 claimed;
    uint256 earned;
    uint256 numerator;
    IERC20 reward;
    uint256 shares;
    uint256 time;
  }

  function testHandlerWithdraw(uint256 assets) external {
    address account = accounts[uint256(keccak256(abi.encode(assets, block.timestamp))) % accounts.length];
    assets = _bound(assets, 0, stEXA.maxWithdraw(account));
    uint256 prevAssets = stEXA.totalAssets();
    uint256 prevShares = stEXA.balanceOf(account);

    vm.prank(account);
    if (assets == 0) vm.expectRevert(ZeroAmount.selector);
    stEXA.withdraw(assets, account, account);

    assertEq(stEXA.totalAssets(), prevAssets - assets, "missing assets");

    if (assets == 0) return;
    address shadow = address(uint160(account) + 1);
    vm.prank(shadow);
    stEXA.withdraw(assets, shadow, shadow);

    IERC20[] memory rewards = stEXA.allRewardsTokens();

    Vars memory v;
    v.shares = prevShares - assets;
    v.time = avgStart[account] == 0 ? 0 : block.timestamp * 1e18 - avgStart[account];
    for (uint256 i = 0; i < rewards.length; ++i) {
      v.reward = rewards[i];
      v.numerator = claimed[account][v.reward] * assets;
      uint256 claimedAmount = v.numerator == 0 ? 0 : (v.numerator - 1) / prevShares + 1;
      claimed[account][v.reward] -= claimedAmount;
      v.claimed = claimed[account][v.reward];
      assertApproxEqAbs(v.claimed, stEXA.claimed(account, v.reward), 10, "claimed != expected");

      globalIndex[v.reward] = stEXA.globalIndex(v.reward);
      v.earned = v.shares.mulWadDown(globalIndex[v.reward] - avgIndexes[account][v.reward]);
      rawClaimable[account][v.reward] = v.earned.mulWadDown(discountFactor(v.time));
      v.claimable = rawClaimable[account][v.reward];

      assertApproxEqAbs(
        v.claimed < v.claimable ? v.claimable - v.claimed : 0,
        stEXA.claimable(v.reward, account, v.shares),
        10,
        "claimable != expected"
      );
      assertEq(v.claimable, stEXA.rawClaimable(v.reward, account, v.shares), "rawClaimable != expected");
    }
  }

  function testHandlerClaim(uint8 index) external {
    address account = accounts[index % accounts.length];
    IERC20[] memory rewards = stEXA.allRewardsTokens();
    vm.startPrank(account);
    for (uint256 i = 0; i < rewards.length; ++i) {
      IERC20 reward = rewards[i];
      uint256 balance = reward.balanceOf(account);
      uint256 claimableAmount = claimable(reward, account);
      stEXA.claim(reward);
      assertEq(reward.balanceOf(account), balance + claimableAmount, "missing rewards");
      claimed[account][reward] += claimableAmount;
      assertEq(claimed[account][reward], stEXA.claimed(account, reward), "claimed != expected");
    }
    vm.stopPrank();
  }

  function testHandlerHarvest(uint64 assets) external {
    uint256 provider = stEXA.market().maxWithdraw(PROVIDER);
    MockERC20 asset = MockERC20(address(stEXA.market().asset()));
    if (assets != 0) {
      asset.mint(address(this), assets);
      asset.approve(address(stEXA.market()), assets);
      stEXA.market().deposit(assets, PROVIDER);
      provider += assets;
    }
    uint256 savings = stEXA.market().maxWithdraw(SAVINGS);
    stEXA.harvest();
    (uint256 rDuration, , , , ) = stEXA.rewards(asset);
    if (rDuration != 0 && assets.mulWadDown(providerRatio) >= rDuration) {
      assertEq(stEXA.market().balanceOf(PROVIDER), 0, "assets left");
      assertEq(
        stEXA.market().maxWithdraw(SAVINGS),
        savings + provider.mulWadUp(1e18 - providerRatio),
        "missing savings"
      );
    }
  }

  function testHandlerNotifyRewardAmount(uint64 assets) external {
    IERC20[] memory rewards = stEXA.allRewardsTokens();
    IERC20 reward = rewards[uint256(keccak256(abi.encode(assets, block.timestamp))) % rewards.length];

    MockERC20(address(reward)).mint(address(stEXA), assets);

    (uint40 rDuration, uint40 finishAt, , , uint256 rate) = stEXA.rewards(reward);
    if (rDuration == 0) vm.expectRevert(stdError.divisionError);
    else if (
      (
        block.timestamp >= finishAt ? assets / rDuration : (assets + ((finishAt - block.timestamp) * rate)) / rDuration
      ) == 0
    ) vm.expectRevert(ZeroRate.selector);
    stEXA.notifyRewardAmount(reward, assets);
  }

  function testHandlerSetDuration(uint32 period) external {
    IERC20[] memory rewards = stEXA.allRewardsTokens();
    IERC20 reward = rewards[uint256(keccak256(abi.encode(period, block.timestamp))) % rewards.length];

    uint256 savingsBalance = reward.balanceOf(SAVINGS);

    (, uint40 finishAt, , , uint256 rate) = stEXA.rewards(reward);

    if (finishAt > block.timestamp) {
      uint256 remainingRewards = rate * (finishAt - block.timestamp);

      stEXA.finishDistribution(reward);
      assertEq(reward.balanceOf(SAVINGS), savingsBalance + remainingRewards, "missing remaining savings");
      (, finishAt, , , ) = stEXA.rewards(reward);
      assertEq(finishAt, block.timestamp, "finish != block timestamp");
    }

    stEXA.setRewardsDuration(reward, period);
    uint256 newRate;
    (, finishAt, , , newRate) = stEXA.rewards(reward);
    assertEq(rate, newRate, "rate != new rate");
  }

  function testHandlerSetMarket() external {
    if (stEXA.market() == market) {
      stEXA.setMarket(marketB);
      assertEq(address(stEXA.market()), address(marketB));
    } else {
      stEXA.setMarket(market);
      assertEq(address(stEXA.market()), address(market));
    }
    (, uint40 finishAt, , , ) = stEXA.rewards(IERC20(address(market.asset())));
    assertGt(finishAt, 0);
    assertEq(stEXA.market().asset().allowance(address(stEXA), address(stEXA.market())), type(uint256).max);
  }

  function testInitialValues() external view {
    (uint256 duration0, uint256 finishAt0, uint256 updatedAt0, uint256 index0, uint256 rate0) = stEXA.rewards(rA);

    assertEq(duration0, duration);
    assertEq(finishAt0, block.timestamp + duration);
    assertEq(index0, 0);
    assertEq(rate0, initialAmount / duration);
    assertEq(updatedAt0, block.timestamp);

    (uint256 duration1, uint256 finishAt1, uint256 updatedAt1, uint256 index1, uint256 rate1) = stEXA.rewards(rB);

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

    (uint256 providerDuration, uint256 finishAt, uint256 updatedAt, uint256 index, uint256 rate) = stEXA.rewards(
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
    stEXA.notifyRewardAmount(rA, amount);
  }

  function testZeroRateError() external {
    skip(duration + 1);
    vm.expectRevert(ZeroRate.selector);
    stEXA.notifyRewardAmount(rA, 0);
  }

  function testUntransferable(uint80 assets) external {
    exa.mint(address(this), assets);

    if (assets == 0) vm.expectRevert(ZeroAmount.selector);
    uint256 shares = stEXA.deposit(assets, address(this));

    if (assets == 0) return;
    vm.expectRevert(Untransferable.selector);
    stEXA.transfer(address(0x1), shares);
  }

  function testSetDuration(uint256 skipTime, uint40 duration_) external {
    skipTime = uint40(_bound(skipTime, 1, duration * 2));
    duration_ = uint40(_bound(duration_, 1, type(uint40).max));

    skip(skipTime);
    if (skipTime < duration) vm.expectRevert(NotFinished.selector);
    stEXA.setRewardsDuration(rA, duration_);

    (uint256 duration0, , , , ) = stEXA.rewards(rA);

    if (skipTime < duration) assertEq(duration0, duration, "duration changed");
    else assertEq(duration0, duration_, "duration != expected");
  }

  function testTotalSupplyDeposit(uint80 assets) external {
    exa.mint(address(this), assets);
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

  function testBalanceOfDeposit(uint80 assets) external {
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
    uint256 prevEarned = earned(rA, address(this));

    time = _bound(time, 1, duration + 1);
    skip(time);

    uint256 earned_ = earned(rA, address(this));

    if (stEXA.balanceOf(address(this)) != 0) assertGt(earned_, prevEarned);
    else assertEq(earned_, prevEarned);
  }

  function testWithdrawWithRewards(uint256 assets) external {
    assets = _bound(assets, 1, type(uint80).max);

    exa.mint(address(this), assets);

    stEXA.deposit(assets, address(this));
    uint256 rate = initialAmount / duration;
    skip(duration / 2);
    uint256 earned_ = rate * (duration / 2);
    assertApproxEqAbs(earned(rA, address(this)), earned_, 2e6, "earned != expected");

    uint256 thisClaimable = claimable(rA, address(this));
    stEXA.withdraw(assets, address(this), address(this));
    assertApproxEqAbs(rA.balanceOf(address(this)), thisClaimable, 1e6, "rewards != earned");
  }

  function testDepositEvent(uint256 assets) external {
    assets = _bound(assets, 1, type(uint80).max);
    exa.mint(address(this), assets);

    uint256 shares = stEXA.previewDeposit(assets);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit IERC4626.Deposit(address(this), address(this), assets, shares);
    stEXA.deposit(assets, address(this));
  }

  function testWithdrawEvent(uint256 assets) external {
    assets = _bound(assets, 1, type(uint80).max);
    exa.mint(address(this), assets);

    uint256 shares = stEXA.deposit(assets, address(this));

    vm.expectEmit(true, true, true, true, address(stEXA));
    emit IERC4626.Withdraw(address(this), address(this), address(this), assets, shares);
    stEXA.withdraw(assets, address(this), address(this));
  }

  function testRewardAmountNotifiedEvent(uint256 amount) external {
    amount = _bound(amount, 1, initialAmount * 2);

    rA.mint(address(stEXA), amount);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.RewardAmountNotified(rA, address(this), amount);
    stEXA.notifyRewardAmount(rA, amount);
  }

  function testRewardPaidEvent(uint256 assets, uint256 time) external {
    assets = _bound(assets, 1, initialAmount * 2);
    time = _bound(time, 1, duration + 1);

    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));

    skip(time);

    uint256 thisClaimable = claimable(rA, address(this));

    if (thisClaimable != 0) {
      vm.expectEmit(true, true, true, true, address(stEXA));
      emit StakedEXA.RewardPaid(rA, address(this), thisClaimable);
    }
    stEXA.withdraw(assets, address(this), address(this));
  }

  function testRewardsDurationSetEvent(uint40 duration_) external {
    skip(duration + 1);

    duration_ = uint40(_bound(duration_, 1, type(uint40).max));
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.RewardsDurationSet(rA, address(this), duration_);
    stEXA.setRewardsDuration(rA, duration_);
  }

  function testNotifyRewardAmount(uint256 amount, uint256 time) external {
    amount = _bound(amount, 1e8, initialAmount * 2);
    time = _bound(time, 1, duration * 2);

    vm.warp(block.timestamp + time);
    (, uint256 finishAt, uint256 updatedAt, , uint256 rate) = stEXA.rewards(rA);

    uint256 expectedRate = 0;
    if (block.timestamp >= finishAt) {
      expectedRate = amount / duration;
    } else {
      expectedRate = (amount + (finishAt - block.timestamp) * rate) / duration;
    }

    rA.mint(address(stEXA), amount);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.RewardAmountNotified(rA, address(this), amount);
    stEXA.notifyRewardAmount(rA, amount);

    (, finishAt, updatedAt, , rate) = stEXA.rewards(rA);
    assertEq(rate, expectedRate, "rate != expected");
    assertEq(finishAt, block.timestamp + duration, "finishAt != expected");
    assertEq(updatedAt, block.timestamp, "updatedAt != expected");
  }

  function testOnlyAdminSetRewardsDuration() external {
    address nonAdmin = address(0x1);
    skip(duration + 1);

    vm.prank(nonAdmin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, 0));
    stEXA.setRewardsDuration(rA, 1);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    stEXA.setRewardsDuration(rA, 1);

    (uint256 duration0, , , , ) = stEXA.rewards(rA);
    assertEq(duration0, 1);
  }

  function testOnlyAdminNotifyRewardAmount() external {
    address nonAdmin = address(0x1);

    uint256 amount = 1_000e18;

    rA.mint(address(stEXA), amount);

    vm.prank(nonAdmin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, 0));
    stEXA.notifyRewardAmount(rA, amount);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.RewardAmountNotified(rA, admin, amount);
    stEXA.notifyRewardAmount(rA, amount);

    (uint256 duration0, uint256 finishAt, uint256 updatedAt, , ) = stEXA.rewards(rA);
    assertEq(finishAt, block.timestamp + duration0);
    assertEq(updatedAt, block.timestamp);
  }

  function testRewardsAmounts(uint256 assets) external {
    assets = _bound(assets, 1, type(uint80).max);

    uint256 time = 10 days;

    (, , , , uint256 rate) = stEXA.rewards(rA);
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));

    skip(time);
    uint256 thisRewards = rate * time;

    exa.mint(BOB, assets);
    vm.startPrank(BOB);
    exa.approve(address(stEXA), assets);
    stEXA.deposit(assets, BOB);
    vm.stopPrank();

    skip(time);

    uint256 bobRewards = (rate * time) / 2;
    thisRewards += bobRewards;

    assertApproxEqAbs(earned(rA, address(this)), thisRewards, 1e7, "this rewards != earned expected");
    assertApproxEqAbs(earned(rA, BOB), bobRewards, 1e7, "bob rewards != earned expected");

    uint256 thisClaimable = claimable(rA, address(this));
    stEXA.withdraw(assets, address(this), address(this));
    assertApproxEqAbs(rA.balanceOf(address(this)), thisClaimable, 1e7, "this rewards != expected");

    uint256 bobBefore = rA.balanceOf(BOB);

    uint256 bobClaimable = claimable(rA, BOB);
    vm.prank(BOB);
    stEXA.withdraw(assets, BOB, BOB);

    assertApproxEqAbs(rA.balanceOf(BOB) - bobBefore, bobClaimable, 1e7, "bob rewards != expected");
  }

  function testNoRewardsAfterPeriod(uint256 timeAfterPeriod) external {
    timeAfterPeriod = _bound(timeAfterPeriod, 1, duration * 2);
    uint256 assets = 1_000e18;

    uint256 time = duration / 2;
    uint256 rate = initialAmount / duration;
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));

    skip(time);

    uint256 thisRewards = rate * time;

    exa.mint(BOB, assets);
    vm.startPrank(BOB);
    exa.approve(address(stEXA), assets);
    stEXA.deposit(assets, BOB);
    vm.stopPrank();

    skip(time);

    uint256 bobRewards = (rate * time) / 2;
    thisRewards += bobRewards;

    assertApproxEqAbs(earned(rA, address(this)), thisRewards, 600, "this rewards != earned expected");
    assertApproxEqAbs(earned(rA, BOB), bobRewards, 200, "bob rewards != earned expected");

    skip(timeAfterPeriod);

    uint256 thisClaimable = claimable(rA, address(this));
    stEXA.withdraw(assets, address(this), address(this));
    assertApproxEqAbs(rA.balanceOf(address(this)), thisClaimable, 600, "this rewards != expected");

    uint256 bobClaimable = claimable(rA, BOB);
    vm.prank(BOB);
    stEXA.withdraw(assets, BOB, BOB);
    assertApproxEqAbs(rA.balanceOf(BOB), bobClaimable, 200, "bob rewards != expected");

    assertEq(earned(rA, address(this)), 0);
    assertEq(earned(rA, BOB), 0);

    skip(timeAfterPeriod);

    assertEq(earned(rA, address(this)), 0);
    assertEq(earned(rA, BOB), 0);
  }

  function testAvgStartTime(uint256[3] memory assets, uint256[2] memory times) external {
    assets[0] = _bound(assets[0], 1, type(uint80).max);
    assets[1] = _bound(assets[1], 1, type(uint80).max);
    assets[2] = _bound(assets[2], 1, type(uint80).max);
    times[0] = _bound(times[0], 1, duration / 2);
    times[1] = _bound(times[1], 1, duration / 2);

    uint256 avgStartTime = block.timestamp * 1e18;
    exa.mint(address(this), assets[0]);
    stEXA.deposit(assets[0], address(this));
    assertEq(stEXA.avgStart(address(this)), avgStartTime);

    skip(times[0]);

    avgStartTime = (avgStartTime * assets[0] + block.timestamp * 1e18 * assets[1]).mulDivUp(1, assets[0] + assets[1]);
    exa.mint(address(this), assets[1]);
    stEXA.deposit(assets[1], address(this));
    assertEq(stEXA.avgStart(address(this)), avgStartTime);

    skip(times[1]);

    uint256 balance = assets[0] + assets[1];
    uint256 total = assets[0] + assets[1] + assets[2];
    avgStartTime = (avgStartTime * balance + block.timestamp * 1e18 * assets[2]).mulDivUp(1, total);

    exa.mint(address(this), assets[2]);
    stEXA.deposit(assets[2], address(this));
    assertEq(stEXA.avgStart(address(this)), avgStartTime);
  }

  function testAvgIndex(uint256[3] memory assets, uint256[2] memory times) external {
    assets[0] = _bound(assets[0], 1, type(uint80).max);
    assets[1] = _bound(assets[1], 1, type(uint80).max);
    assets[2] = _bound(assets[2], 1, type(uint80).max);
    times[0] = _bound(times[0], 1, duration / 2);
    times[1] = _bound(times[1], 1, duration / 2);

    exa.mint(address(this), assets[0]);
    stEXA.deposit(assets[0], address(this));
    uint256 avgIndex = stEXA.globalIndex(rA);
    assertEq(stEXA.avgIndex(rA, address(this)), avgIndex, "avgIndex.0 != globalIndex");

    skip(times[0]);

    uint256 total = assets[0] + assets[1];
    uint256 balance = assets[0];

    exa.mint(address(this), assets[1]);
    stEXA.deposit(assets[1], address(this));
    avgIndex = (avgIndex * balance + stEXA.globalIndex(rA) * assets[1]).mulDivUp(1, total);
    assertEq(stEXA.avgIndex(rA, address(this)), avgIndex, "avgIndex.1 != globalIndex");

    skip(times[1]);

    balance += assets[1];
    total += assets[2];
    avgIndex = (avgIndex * balance + stEXA.globalIndex(rA) * assets[2]).mulDivUp(1, total);
    exa.mint(address(this), assets[2]);
    stEXA.deposit(assets[2], address(this));
    assertEq(stEXA.avgIndex(rA, address(this)), avgIndex, "avgIndex.2 != globalIndex");
  }

  function testDepositWithdrawAvgStartTimeAndIndex(
    uint256[3] memory assets,
    uint256 partialWithdraw,
    uint256[5] memory times
  ) external {
    assets[0] = _bound(assets[0], 2, type(uint80).max);
    assets[1] = _bound(assets[1], 1, type(uint80).max);
    assets[2] = _bound(assets[2], 1, type(uint80).max);
    partialWithdraw = _bound(partialWithdraw, 1, assets[0] - 1);
    times[0] = _bound(times[0], 1, duration / 5);
    times[1] = _bound(times[1], 1, duration / 5);
    times[2] = _bound(times[2], 1, duration / 5);
    times[3] = _bound(times[3], 1, duration / 5);
    times[4] = _bound(times[4], 1, duration / 5);

    skip(times[0]);
    exa.mint(address(this), assets[0]);
    stEXA.deposit(assets[0], address(this));

    uint256 avgStartTime = block.timestamp * 1e18;
    uint256 avgIndex = stEXA.globalIndex(rA);

    // skip + partial withdraw -> avg time and index shouldn't change
    skip(times[1]);
    stEXA.withdraw(partialWithdraw, address(this), address(this));
    assertEq(stEXA.avgStart(address(this)), avgStartTime, "avgStartTime != expected");
    assertEq(stEXA.avgIndex(rA, address(this)), avgIndex, "avgIndex != expected");

    // skip + new deposit -> avg time and index should change
    skip(times[2]);
    exa.mint(address(this), assets[1]);
    stEXA.deposit(assets[1], address(this));
    uint256 balance = assets[0] - partialWithdraw;
    uint256 total = balance + assets[1];
    avgStartTime = (avgStartTime * balance + block.timestamp * 1e18 * assets[1]).mulDivUp(1, total);
    avgIndex = (avgIndex * balance + stEXA.globalIndex(rA) * assets[1]).mulDivUp(1, total);

    // skip + full withdraw -> avg time and index shouldn't change
    skip(times[3]);
    uint256 fullWithdraw = assets[0] + assets[1] - partialWithdraw;
    stEXA.withdraw(fullWithdraw, address(this), address(this));
    assertEq(stEXA.avgStart(address(this)), avgStartTime, "avgStartTime != expected");
    assertEq(stEXA.avgIndex(rA, address(this)), avgIndex, "avgIndex != expected");

    // skip + new deposit -> avg time and index should be restarted
    skip(times[4]);
    exa.mint(address(this), assets[2]);
    stEXA.deposit(assets[2], address(this));
    avgStartTime = block.timestamp * 1e18;
    avgIndex = stEXA.globalIndex(rA);
    assertEq(stEXA.avgStart(address(this)), avgStartTime, "avgStartTime != expected");
    assertEq(stEXA.avgIndex(rA, address(this)), avgIndex, "avgIndex != expected");
  }

  function testWithdrawSameAmountRewardsShouldEqual(uint256 amount, uint256 time) external {
    amount = _bound(amount, 2, type(uint80).max);
    time = _bound(time, 1, duration - 1);

    exa.mint(address(this), amount);
    stEXA.deposit(amount, address(this));
    uint256 rewBalance = rA.balanceOf(address(this));

    skip(time);
    // withdraw 1/2 of the assets
    stEXA.withdraw(amount / 2, address(this), address(this));
    uint256 claimedRewards = rA.balanceOf(address(this)) - rewBalance;

    // withdraw same amount
    rewBalance = rA.balanceOf(address(this));
    stEXA.withdraw(amount / 2, address(this), address(this));
    uint256 claimedRewards2 = rA.balanceOf(address(this)) - rewBalance;

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

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        emergencyAdmin,
        stEXA.PAUSER_ROLE()
      )
    );
    stEXA.unpause();
    vm.stopPrank();
  }

  function testPausable() external {
    exa.mint(address(this), 1);
    stEXA.deposit(1, address(this));

    address pauser = address(0x1);
    stEXA.grantRole(stEXA.PAUSER_ROLE(), pauser);

    vm.prank(pauser);
    stEXA.pause();
    assertTrue(stEXA.paused());

    exa.mint(address(this), 1);
    vm.expectRevert(Pausable.EnforcedPause.selector);
    stEXA.deposit(1, address(this));

    vm.expectRevert(Pausable.EnforcedPause.selector);
    stEXA.redeem(1, address(this), address(this));

    vm.expectRevert(Pausable.EnforcedPause.selector);
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
    IERC20 notListed = new MockERC20("reward C", "rC", 18);

    address nonAdmin = address(0x1);
    vm.prank(nonAdmin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, 0));
    stEXA.enableReward(notListed);

    (, uint256 finishAt, , , ) = stEXA.rewards(notListed);
    assertEq(finishAt, 0);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.RewardListed(notListed, admin);
    stEXA.enableReward(notListed);

    (, finishAt, , , ) = stEXA.rewards(notListed);
    assertNotEq(finishAt, 0);
  }

  function testAlreadyListedError() external {
    vm.expectRevert(AlreadyEnabled.selector);
    stEXA.enableReward(rA);
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
    (uint256 providerDuration, uint256 finishAt, uint256 updatedAt, uint256 index, uint256 rate) = stEXA.rewards(
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
    emit StakedEXA.RewardAmountNotified(providerAsset, address(stEXA), assets.mulWadDown(providerRatio));
    stEXA.harvest();
  }

  function testClaimBeforeFirstHarvest() external {
    uint256 assets = market.maxWithdraw(PROVIDER);
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));
    uint256 thisClaimable = claimable(providerAsset, address(this));
    providerAsset.balanceOf(address(stEXA));
    stEXA.withdraw(assets, address(this), address(this));
    assertEq(providerAsset.balanceOf(address(this)), thisClaimable);
  }

  function testClaimAfterHarvest() external {
    uint256 assets = 1_000e18;
    uint256 harvested = market.maxWithdraw(PROVIDER).mulWadDown(providerRatio);
    stEXA.harvest();
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));
    skip(minTime);
    uint256 thisClaimable = claimable(providerAsset, address(this));
    assertEq(thisClaimable, 0);
    skip(1);
    thisClaimable = claimable(providerAsset, address(this));
    assertGt(thisClaimable, 0);

    skip(refTime - 1 weeks - 1);

    thisClaimable = claimable(providerAsset, address(this));

    stEXA.withdraw(assets, address(this), address(this));
    assertEq(providerAsset.balanceOf(address(this)), thisClaimable);
    assertApproxEqAbs(providerAsset.balanceOf(address(this)), harvested, 1e6); // no one else was in the program
  }

  function testFinishDistributionStopsEmission() external {
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets * 2);
    stEXA.deposit(assets, address(this));
    stEXA.deposit(assets, BOB);
    skip(minTime + 1);

    uint256 thisClaimable = claimable(rA, address(this));
    uint256 earned_ = earned(rA, address(this));

    stEXA.finishDistribution(rA);
    stEXA.withdraw(assets, address(this), address(this));
    assertEq(rA.balanceOf(address(this)), thisClaimable);

    // stops emission
    skip(2 weeks);

    assertEq(earned(rA, BOB), earned_);

    // lets claim
    uint256 bobClaimable = claimable(rA, BOB);
    vm.prank(BOB);
    stEXA.withdraw(assets, BOB, BOB);
    assertEq(rA.balanceOf(BOB), bobClaimable);
  }

  function testFinishDistributionLetsClaimUnclaimed() external {
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets * 2);
    stEXA.deposit(assets, address(this));
    stEXA.deposit(assets, BOB);
    skip(minTime + 1);

    uint256 thisClaimable = claimable(rA, address(this));
    uint256 earned_ = earned(rA, address(this));

    stEXA.finishDistribution(rA);
    uint256 newClaimable = claimable(rA, address(this));
    assertEq(thisClaimable, newClaimable);
    stEXA.withdraw(assets, address(this), address(this));
    assertEq(rA.balanceOf(address(this)), thisClaimable);

    // lets claim the unclaimed
    skip(2 weeks);

    assertEq(claimable(rA, address(this)), 0);
    assertEq(earned(rA, BOB), earned_);
    uint256 bobClaimable = claimable(rA, BOB);
    vm.prank(BOB);
    stEXA.withdraw(assets, BOB, BOB);
    assertEq(rA.balanceOf(BOB), bobClaimable);
  }

  function testFinishDistributionEmitEvent() external {
    harvest();
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.DistributionFinished(providerAsset, address(this));
    stEXA.finishDistribution(providerAsset);
  }

  function testOnlyAdminFinishDistribution() external {
    address nonAdmin = address(0x1);
    vm.prank(nonAdmin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, 0));
    stEXA.finishDistribution(rA);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.DistributionFinished(rA, admin);
    stEXA.finishDistribution(rA);

    (, uint256 finishAt, , , ) = stEXA.rewards(rA);
    assertNotEq(finishAt, 0);
  }

  function testCanChangeRewardsDurationWhenDisabled() external {
    vm.expectRevert(NotFinished.selector);
    stEXA.setRewardsDuration(rA, 1);

    stEXA.finishDistribution(rA);
    stEXA.setRewardsDuration(rA, 1 weeks);

    (uint256 duration0, uint256 finishAt, , , ) = stEXA.rewards(rA);

    assertEq(duration0, 1 weeks);
    assertEq(finishAt, block.timestamp);
  }

  function testFinishDistributionTransfersRemainingToSavings() external {
    uint256 savingsBalance = rA.balanceOf(SAVINGS);

    (, uint256 finishAt, , , uint256 rate) = stEXA.rewards(rA);
    uint256 remainingRewards = rate * (finishAt - block.timestamp);

    stEXA.finishDistribution(rA);
    assertEq(rA.balanceOf(SAVINGS), savingsBalance + remainingRewards);

    (, finishAt, , , ) = stEXA.rewards(rA);
    assertEq(finishAt, block.timestamp);
  }

  function testFinishDistributionThatAlreadyFinished() external {
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));
    skip(duration + 1);

    uint256 savingsBalance = rA.balanceOf(SAVINGS);

    (, uint256 finishAt, , , uint256 rate) = stEXA.rewards(rA);

    uint256 remainingRewards = finishAt > block.timestamp ? rate * (finishAt - block.timestamp) : 0;

    assertEq(remainingRewards, 0);

    stEXA.finishDistribution(rA);
    assertEq(rA.balanceOf(SAVINGS), savingsBalance);

    (, uint256 newFinishAt, , , ) = stEXA.rewards(rA);
    assertEq(finishAt, newFinishAt);
  }

  function testSetMarketOnlyAdmin() external {
    address nonAdmin = address(0x1);
    Market newMarket = Market(address(new MockMarket(exa)));

    vm.prank(nonAdmin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, 0));
    stEXA.setMarket(newMarket);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.MarketSet(newMarket, admin);
    stEXA.setMarket(newMarket);
    assertEq(address(stEXA.market()), address(newMarket));
  }

  function testSetMarketAddressZero() external {
    vm.expectRevert(ZeroAddress.selector);
    stEXA.setMarket(Market(address(0)));
  }

  function testOnlyAdminSetProvider() external {
    address nonAdmin = address(0x1);
    address newProvider = address(0x2);

    vm.prank(nonAdmin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, 0));
    stEXA.setProvider(newProvider);

    address admin = address(0x3);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.ProviderSet(newProvider, admin);
    stEXA.setProvider(newProvider);
    assertEq(stEXA.provider(), newProvider);
  }

  function testOnlyAdminSetProviderRatio() external {
    address nonAdmin = address(0x1);
    uint256 newProviderRatio = 0.5e18;

    vm.prank(nonAdmin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, 0));
    stEXA.setProviderRatio(newProviderRatio);

    address admin = address(0x2);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.ProviderRatioSet(newProviderRatio, admin);
    stEXA.setProviderRatio(newProviderRatio);
    assertEq(stEXA.providerRatio(), newProviderRatio);
  }

  function testOnlyAdminSetSavings() external {
    address nonAdmin = address(0x1);
    address newSavings = address(0x2);

    vm.prank(nonAdmin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, 0));
    stEXA.setSavings(newSavings);

    address admin = address(0x3);
    stEXA.grantRole(stEXA.DEFAULT_ADMIN_ROLE(), admin);
    assertTrue(stEXA.hasRole(stEXA.DEFAULT_ADMIN_ROLE(), admin));

    vm.prank(admin);
    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.SavingsSet(newSavings, admin);
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

  function testClaimAndUnstake() external {
    stEXA.harvest();
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets * 2);
    stEXA.deposit(assets, address(this));
    stEXA.deposit(assets, BOB);

    skip(minTime + 2 weeks);

    uint256 claimableThis = claimable(providerAsset, address(this));
    uint256 claimableBOB = claimable(providerAsset, BOB);
    assertEq(claimableThis, claimableBOB, "claimableThis != claimableBOB");

    stEXA.withdraw(assets, address(this), address(this));
    assertEq(providerAsset.balanceOf(address(this)), claimableThis, "balance != claimableThis");

    vm.prank(BOB);
    stEXA.claimAll();
    assertEq(providerAsset.balanceOf(BOB), claimableBOB, "balanceBOB != claimableBOB");

    assertEq(providerAsset.balanceOf(address(this)), providerAsset.balanceOf(BOB), "balances are not equal");
  }

  function testMultipleClaimsVsOne() external {
    stEXA.harvest();
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets * 2);
    stEXA.deposit(assets, address(this));
    stEXA.deposit(assets, BOB);

    uint256 claimableAcc = 0;
    for (uint256 i = 0; i < refTime / 1 weeks; i++) {
      skip(1 weeks);
      harvest();
      uint256 claimableAmount = claimable(providerAsset, address(this));
      claimableAcc += claimableAmount;
      stEXA.claimAll();
    }
    assertEq(providerAsset.balanceOf(address(this)), claimableAcc, "balance != claimableAcc");

    uint256 claimableBOB = claimable(providerAsset, BOB);
    assertEq(claimableBOB, claimableAcc, "claimableBOB != claimableAcc");

    vm.prank(BOB);
    stEXA.claimAll();

    assertEq(providerAsset.balanceOf(address(this)), providerAsset.balanceOf(BOB));

    for (uint256 i = 0; i < 30; i++) {
      skip(1 weeks);
      harvest();
      uint256 claimedAmount = stEXA.claimed(address(this), providerAsset);
      uint256 claimableAmount = claimable(providerAsset, address(this));

      claimableAcc += claimableAmount > claimedAmount ? claimableAmount - claimedAmount : 0;
      stEXA.claimAll();
    }

    vm.prank(BOB);
    stEXA.claimAll();

    assertEq(providerAsset.balanceOf(BOB), providerAsset.balanceOf(address(this)), "balances are not equal");
  }

  function testNotifyRewardWithUnderlyingAsset() external {
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));

    vm.expectRevert(InsufficientBalance.selector);
    stEXA.notifyRewardAmount(exa, assets);

    exa.mint(address(stEXA), 1_000e18);
    stEXA.notifyRewardAmount(exa, assets);
  }

  function testSetMinTime() external {
    uint256 time = 1 days;

    address nonAdmin = address(0x1);
    vm.prank(nonAdmin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, 0));
    stEXA.setMinTime(time);

    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.MinTimeSet(time, address(this));
    stEXA.setMinTime(time);
    assertEq(stEXA.minTime(), time);
  }

  function testSetPenaltyGrowth() external {
    uint256 growth = 1e18;

    address nonAdmin = address(0x1);
    vm.prank(nonAdmin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, 0));
    stEXA.setPenaltyGrowth(growth);

    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.PenaltyGrowthSet(growth, address(this));
    stEXA.setPenaltyGrowth(growth);
    assertEq(stEXA.penaltyGrowth(), growth);
  }

  function testSetPenaltyThreshold() external {
    uint256 threshold = 0.7e18;

    address nonAdmin = address(0x1);
    vm.prank(nonAdmin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, 0));
    stEXA.setPenaltyThreshold(threshold);

    vm.expectEmit(true, true, true, true, address(stEXA));
    emit StakedEXA.PenaltyThresholdSet(threshold, address(this));
    stEXA.setPenaltyThreshold(threshold);
    assertEq(stEXA.penaltyThreshold(), threshold);
  }

  function testResetDepositAfterRefTime(uint256 assets) external {
    assets = _bound(assets, 1, type(uint80).max);
    uint256 start = block.timestamp * 1e18;
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));

    skip(refTime + 1);

    uint256 expectedClaim = stEXA.claimable(exa, address(this), stEXA.balanceOf(address(this)));

    assertEq(stEXA.avgStart(address(this)), start);

    start = block.timestamp * 1e18;
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));

    assertEq(exa.balanceOf(address(this)), expectedClaim, "balance != expected");
    assertEq(stEXA.avgStart(address(this)), start, "avgStart != expected");
  }

  function testClaimAndWithdrawAfterRefTime() external {
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));

    skip(refTime + 1_000);

    stEXA.claimAll();
    stEXA.withdraw(assets, address(this), address(this));
  }

  function testDepositShouldClaim(uint256[2] memory assets, uint32 time) external {
    assets[0] = _bound(assets[0], 1, type(uint80).max);
    assets[1] = _bound(assets[1], 1, type(uint80).max);

    exa.mint(address(this), assets[0]);
    stEXA.deposit(assets[0], address(this));

    skip(time);

    uint256 rClaimable = stEXA.claimable(rA, address(this), stEXA.balanceOf(address(this)));
    uint256 balanceBefore = rA.balanceOf(address(this));

    exa.mint(address(this), assets[1]);
    stEXA.deposit(assets[1], address(this));

    if (time > minTime) assertTrue(rClaimable > 0, "rClaimable == 0");

    assertEq(rA.balanceOf(address(this)) - balanceBefore, rClaimable, "balanceBefore != rClaimable");
  }

  function testPenaltyGrowthRange() external {
    vm.expectRevert(InvalidRange.selector);
    stEXA.setPenaltyGrowth(100e18 + 1);

    vm.expectRevert(InvalidRange.selector);
    stEXA.setPenaltyGrowth(0.1e18 - 1);
  }

  function testPenaltyThresholdRange() external {
    vm.expectRevert(InvalidRange.selector);
    stEXA.setPenaltyThreshold(1e18 + 1);
  }

  function testPermitAndDeposit() external {
    uint256 assets = 1_000e18;
    exa.mint(BOB, assets);

    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      BOB_KEY,
      keccak256(
        abi.encodePacked(
          "\x19\x01",
          exa.DOMAIN_SEPARATOR(),
          keccak256(
            abi.encode(
              keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
              BOB,
              address(stEXA),
              assets,
              exa.nonces(BOB),
              block.timestamp
            )
          )
        )
      )
    );

    vm.prank(BOB);
    stEXA.permitAndDeposit(assets, BOB, Permit(assets, block.timestamp, v, r, s));
  }

  function testPausableClaim() external {
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));

    address pauser = address(0x1);
    stEXA.grantRole(stEXA.PAUSER_ROLE(), pauser);

    vm.prank(pauser);
    stEXA.pause();

    vm.expectRevert(Pausable.EnforcedPause.selector);
    stEXA.claimAll();

    vm.expectRevert(Pausable.EnforcedPause.selector);
    stEXA.claim(providerAsset);

    vm.prank(pauser);
    stEXA.unpause();

    stEXA.claimAll();
    stEXA.claim(providerAsset);
  }

  function testPausableHarvest() external {
    address pauser = address(0x1);
    stEXA.grantRole(stEXA.PAUSER_ROLE(), pauser);

    vm.prank(pauser);
    stEXA.pause();

    vm.expectRevert(Pausable.EnforcedPause.selector);
    stEXA.harvest();

    vm.prank(pauser);
    stEXA.unpause();

    stEXA.harvest();
  }

  function testSetMaxRewardsTokensExceeded() external {
    uint256 addRewards = stEXA.MAX_REWARDS_TOKENS() - stEXA.allRewardsTokens().length;
    for (uint256 i = 0; i < addRewards; ++i) stEXA.enableReward(new MockERC20("reward", "r", 18));

    assertEq(stEXA.allRewardsTokens().length, stEXA.MAX_REWARDS_TOKENS());

    MockERC20 r = new MockERC20("reward", "r", 18);
    vm.expectRevert(MaxRewardsTokensExceeded.selector);
    stEXA.enableReward(r);

    assertEq(stEXA.allRewardsTokens().length, stEXA.MAX_REWARDS_TOKENS());
  }

  function testMaxRewardsGasConsumption() external {
    uint256 addRewards = stEXA.MAX_REWARDS_TOKENS() - stEXA.allRewardsTokens().length;
    for (uint256 i = 0; i < addRewards; ++i) {
      MockERC20 r = new MockERC20("reward", "r", 18);
      r.mint(address(stEXA), initialAmount);
      stEXA.enableReward(r);
      stEXA.setRewardsDuration(r, duration);
      stEXA.notifyRewardAmount(r, initialAmount);
    }

    uint256 assets = 1_000e18;
    exa.mint(address(this), assets);

    stEXA.deposit(assets, address(this));
    assertLt(vm.lastCallGas().gasTotalUsed, 10_000_000);

    skip(refTime / 2);

    stEXA.claimAll();
    assertLt(vm.lastCallGas().gasTotalUsed, 10_000_000);

    skip(refTime / 2 + 1);

    stEXA.withdraw(assets, address(this), address(this));
    assertLt(vm.lastCallGas().gasTotalUsed, 10_000_000);
  }

  function testDepositClaimsRewardsToReceiver() external {
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));

    skip(minTime + 1);

    uint256 claimableAmount = claimable(rA, address(this));
    uint256 balanceBefore = rA.balanceOf(address(this));

    exa.mint(BOB, assets);
    vm.startPrank(BOB);
    exa.approve(address(stEXA), assets);
    stEXA.deposit(assets, address(this));
    vm.stopPrank();

    assertEq(claimableAmount, rA.balanceOf(address(this)) - balanceBefore);

  }

  function minMaxWithdrawAllowance() internal view returns (uint256) {
    return Math.min(market.convertToAssets(market.allowance(PROVIDER, address(stEXA))), market.maxWithdraw(PROVIDER));
  }

  function harvest() internal {
    uint256 assets = 1_000e18;
    providerAsset.mint(address(this), assets);
    providerAsset.approve(address(market), assets);
    market.deposit(assets, PROVIDER);
    stEXA.harvest();
  }

  function discountFactor(uint256 time) internal view returns (uint256) {
    uint256 memMinTime = minTime * 1e18;
    if (time <= memMinTime) return 0;
    uint256 memRefTime = refTime * 1e18;
    if (time >= memRefTime) {
      uint256 memExcessFactor = excessFactor;
      return (1e18 - memExcessFactor).mulWadDown((memRefTime * 1e18) / time) + memExcessFactor;
    }

    uint256 timeRatio = ((time - memMinTime) * 1e18) / (memRefTime - memMinTime);
    if (timeRatio == 0) return 0;

    uint256 penalties = uint256(((int256(penaltyGrowth) * int256(timeRatio).lnWad()) / 1e18).expWad());

    uint256 memPenaltyThreshold = penaltyThreshold;
    return Math.min((1e18 - memPenaltyThreshold).mulWadDown(penalties) + memPenaltyThreshold, 1e18);
  }

  function claimable(IERC20 reward, address account) internal view returns (uint256) {
    uint256 balance = stEXA.balanceOf(account);
    return stEXA.claimable(reward, account, balance);
  }

  function earned(IERC20 reward, address account) internal view returns (uint256) {
    uint256 balance = stEXA.balanceOf(account);
    return stEXA.earned(reward, account, balance);
  }
}

contract MockMarket is ERC4626 {
  // solhint-disable-next-line no-empty-blocks
  constructor(IERC20 asset_) ERC20("WETH Market", "exaWETH") ERC4626(asset_) {}

  function totalAssets() public view override returns (uint256) {
    return totalSupply();
  }

  function convertToAssets(uint256 shares) public pure override returns (uint256) {
    return shares;
  }
}

contract MockERC20 is ERC20Permit {
  uint8 internal immutable d;

  constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) ERC20Permit(name_) {
    d = decimals_;
  }

  function decimals() public view override returns (uint8) {
    return d;
  }

  function mint(address account, uint256 amount) external {
    _mint(account, amount);
  }

  function burn(address account, uint256 amount) external {
    _burn(account, amount);
  }
}
