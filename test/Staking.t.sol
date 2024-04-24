// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Test } from "forge-std/Test.sol";

import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

import { Staking } from "../contracts/Staking.sol";

contract StakingTest is Test {
  Staking internal staking;
  MockERC20 internal exa;
  MockERC20 internal rewardsToken;
  uint256 internal exaBalance;
  uint256 internal initialAmount;
  uint256 internal initialDuration;

  function setUp() external {
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
    assertEq(staking.rewardPerTokenStored(), 0);
    assertEq(staking.totalSupply(), 0);
    assertEq(staking.balanceOf(address(this)), 0);
  }

  function testTotalSupplyStake(uint256 amount) external {
    amount = _bound(amount, 0, exaBalance);
    uint256 prevSupply = staking.totalSupply();
    exa.mint(address(this), amount);
    if (amount == 0) vm.expectRevert(bytes("")); // TODO expect custom error
    staking.stake(amount);
    assertEq(staking.totalSupply(), prevSupply + amount);
  }

  function testTotalSupplyUnstake(uint256 amount) external {
    amount = _bound(amount, 0, staking.balanceOf(address(this)));
    uint256 prevSupply = staking.totalSupply();
    if (amount == 0) vm.expectRevert(bytes("")); // TODO expect custom error

    staking.withdraw(amount);
    assertEq(staking.totalSupply(), prevSupply - amount);
  }

  function testBalanceOfStake(uint256 amount) external {
    amount = _bound(amount, 0, exaBalance);
    uint256 prevBalance = staking.balanceOf(address(this));
    exa.mint(address(this), amount);
    if (amount == 0) vm.expectRevert(bytes("")); // TODO expect custom error
    staking.stake(amount);
    assertEq(staking.balanceOf(address(this)), prevBalance + amount);
  }

  function testBalanceOfUnstake(uint256 amount) external {
    amount = _bound(amount, 0, staking.balanceOf(address(this)));
    uint256 prevBalance = staking.balanceOf(address(this));
    if (amount == 0) vm.expectRevert(bytes("")); // TODO expect custom error
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
}
