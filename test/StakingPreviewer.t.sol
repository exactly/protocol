// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
  StakingPreviewer,
  StakedEXA,
  RewardAmount,
  Parameters,
  StakingAccount
} from "../contracts/periphery/StakingPreviewer.sol";
import { Market, MockERC20, MockMarket } from "./StakedEXA.t.sol";

contract StakingPreviewerTest is Test {
  StakedEXA internal stEXA;
  StakingPreviewer internal previewer;

  MockERC20 internal exa;
  MockERC20 internal rA;
  MockERC20 internal rB;
  Parameters internal p;
  MockERC20 internal providerAsset;

  function setUp() external {
    vm.warp(1_704_067_200); // 01/01/2024 @ 00:00 (UTC)
    exa = new MockERC20("exactly", "EXA", 18);
    rA = new MockERC20("reward A", "rA", 18);
    rB = new MockERC20("reward B", "rB", 6);
    vm.label(address(exa), "EXA");
    vm.label(address(rA), "rA");
    vm.label(address(rB), "rB");

    providerAsset = new MockERC20("Wrapped ETH", "WETH", 18);

    p = Parameters({
      asset: exa,
      minTime: 1 weeks,
      refTime: 24 weeks,
      excessFactor: 0.5e18,
      penaltyGrowth: 2e18,
      penaltyThreshold: 0.5e18,
      market: Market(address(new MockMarket(providerAsset))),
      provider: address(0x2),
      savings: address(0x3),
      duration: 1 weeks,
      providerRatio: 0.1e18
    });

    stEXA = StakedEXA(address(new ERC1967Proxy(address(new StakedEXA()), "")));
    stEXA.initialize(p);
    exa.approve(address(stEXA), type(uint256).max);

    // configure multiple rewards
    uint256 duration = p.refTime;
    uint256 initialAmount = 1_000e18;
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

    //
    previewer = new StakingPreviewer(stEXA);
  }

  function testAllClaimable() external {
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));
    skip(p.minTime);

    RewardAmount[] memory claimableRewards = previewer.allClaimable(address(this));
    assertEq(claimableRewards.length, stEXA.allRewardsTokens().length);

    for (uint256 i = 0; i < claimableRewards.length; i++) {
      assertEq(claimableRewards[i].amount, 0);
    }

    skip(p.minTime);

    claimableRewards = previewer.allClaimable(address(this));
    assertEq(claimableRewards.length, stEXA.allRewardsTokens().length);

    for (uint256 i = 0; i < claimableRewards.length; i++) {
      RewardAmount memory claimableReward = claimableRewards[i];
      assertEq(
        claimableRewards[i].amount,
        stEXA.claimable(claimableReward.reward, address(this), stEXA.balanceOf(address(this)))
      );
    }

    claimableRewards = previewer.allClaimable(address(0));
    assertEq(claimableRewards.length, stEXA.allRewardsTokens().length);

    for (uint256 i = 0; i < claimableRewards.length; i++) {
      assertEq(claimableRewards[i].amount, 0);
    }
  }

  function testAllClaimed() external {
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));
    skip(p.minTime + 1);

    RewardAmount[] memory claimedRewards = previewer.allClaimed(address(this));
    assertEq(claimedRewards.length, stEXA.allRewardsTokens().length);

    for (uint256 i = 0; i < claimedRewards.length; i++) {
      assertEq(claimedRewards[i].amount, 0);
    }

    stEXA.claimAll();

    claimedRewards = previewer.allClaimed(address(this));
    assertEq(claimedRewards.length, stEXA.allRewardsTokens().length);

    for (uint256 i = 0; i < claimedRewards.length; i++) {
      RewardAmount memory claimedReward = claimedRewards[i];
      assertEq(claimedRewards[i].amount, stEXA.claimed(address(this), claimedReward.reward));
    }

    claimedRewards = previewer.allClaimed(address(0));
    assertEq(claimedRewards.length, stEXA.allRewardsTokens().length);

    for (uint256 i = 0; i < claimedRewards.length; i++) {
      assertEq(claimedRewards[i].amount, 0);
    }
  }

  function testAllEarned() external {
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));
    skip(p.minTime + 1);

    RewardAmount[] memory earnedRewards = previewer.allEarned(address(this));
    assertEq(earnedRewards.length, stEXA.allRewardsTokens().length);

    for (uint256 i = 0; i < earnedRewards.length; i++) {
      RewardAmount memory earnedReward = earnedRewards[i];
      assertEq(
        earnedRewards[i].amount,
        stEXA.earned(earnedReward.reward, address(this), stEXA.balanceOf(address(this)))
      );
    }
  }

  function testExactly() external {
    uint256 assets = 1_000e18;
    exa.mint(address(this), assets);
    stEXA.deposit(assets, address(this));
    skip(p.minTime * 2);

    StakingAccount memory data = previewer.exactly();

    assertEq(address(data.parameters.asset), address(p.asset));
    assertEq(data.parameters.minTime, p.minTime);
    assertEq(data.parameters.refTime, p.refTime);
    assertEq(data.parameters.excessFactor, p.excessFactor);
    assertEq(data.parameters.penaltyGrowth, p.penaltyGrowth);
    assertEq(data.parameters.penaltyThreshold, p.penaltyThreshold);
    assertEq(address(data.parameters.market), address(p.market));
    assertEq(data.parameters.provider, p.provider);
    assertEq(data.parameters.savings, p.savings);
    assertEq(data.parameters.duration, p.duration);
    assertEq(data.parameters.providerRatio, p.providerRatio);

    assertEq(data.totalAssets, stEXA.totalAssets());
    assertEq(data.balance, stEXA.balanceOf(address(this)));

    assertEq(data.start, stEXA.avgStart(address(this)));
    assertEq(data.time, block.timestamp * 1e18 - data.start);

    assertEq(data.claimableRewards.length, 4);
    for (uint256 i = 0; i < data.claimableRewards.length; i++) {
      assertEq(
        data.claimableRewards[i].amount,
        stEXA.claimable(data.claimableRewards[i].reward, address(this), stEXA.balanceOf(address(this)))
      );
    }

    assertEq(data.claimedRewards.length, 4);
    for (uint256 i = 0; i < data.claimedRewards.length; i++) {
      assertEq(data.claimedRewards[i].amount, stEXA.claimed(address(this), data.claimedRewards[i].reward));
    }

    assertEq(data.earnedRewards.length, 4);
    for (uint256 i = 0; i < data.earnedRewards.length; i++) {
      assertEq(
        data.earnedRewards[i].amount,
        stEXA.earned(data.earnedRewards[i].reward, address(this), stEXA.balanceOf(address(this)))
      );
    }
  }
}
