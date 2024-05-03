// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC20, SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

contract Staking is Initializable, AccessControlUpgradeable, PausableUpgradeable {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;

  /// @notice Staking token
  ERC20 public immutable exa;
  /// @notice Rewards token
  ERC20 public immutable rewardsToken;

  /// @notice Duration of rewards to be paid out (in seconds)
  uint256 public duration;
  /// @notice Timestamp of when the rewards finish
  uint256 public finishAt;
  /// @notice Minimum of last updated time and reward finish time
  uint256 public updatedAt;
  /// @notice Reward to be paid out per second
  uint256 public rewardRate;
  /// @notice Global index. Sum of (reward rate * dt * 1e18 / total supply)
  uint256 public index;

  /// @notice Accounts indexes
  mapping(address account => uint256 index) public indexes;
  /// @notice Rewards accrued per account
  mapping(address account => uint256 amount) public rewards;
  /// @notice Total amount of tokens staked
  uint256 public totalSupply;
  /// @notice Staked amount per account
  mapping(address account => uint256 amount) public balanceOf;

  /// @notice Penalty for early unstake
  uint256 public discountFactor;
  /// @notice Reference period to stake and get full rewards
  uint256 public refTime;
  /// @notice Average starting time with the tokens staked per account
  mapping(address account => uint256 time) public avgStart;

  constructor(ERC20 exa_, ERC20 rewardsToken_) {
    exa = exa_;
    rewardsToken = rewardsToken_;
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize() external initializer {
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }

  modifier updateReward(address account) {
    index = globalIndex();
    updatedAt = lastTimeRewardApplicable();

    if (account != address(0)) {
      rewards[account] = earned(account);
      indexes[account] = index;
    }

    _;
  }

  function lastTimeRewardApplicable() public view returns (uint256) {
    return Math.min(finishAt, block.timestamp);
  }

  function globalIndex() public view returns (uint256) {
    if (totalSupply == 0) return index;

    return index + (rewardRate * (lastTimeRewardApplicable() - updatedAt)).divWadDown(totalSupply);
  }

  function stake(uint256 amount) external updateReward(msg.sender) {
    if (amount == 0) revert ZeroAmount();
    exa.transferFrom(msg.sender, address(this), amount);
    uint256 balance = balanceOf[msg.sender];
    uint256 weight = balance.divWadDown(balance + amount);
    avgStart[msg.sender] = avgStart[msg.sender] * weight + (block.timestamp) * (1 - weight);

    balanceOf[msg.sender] += amount;
    totalSupply += amount;

    emit Stake(msg.sender, amount);
  }

  function withdraw(uint256 amount) external updateReward(msg.sender) {
    if (amount == 0) revert ZeroAmount();
    balanceOf[msg.sender] -= amount;
    totalSupply -= amount;
    exa.transfer(msg.sender, amount);

    emit Withdraw(msg.sender, amount);
  }

  /// @notice Calculate the amount of rewards that an account has earned but not yet claimed.
  /// @param account The address of the user for whom to calculate the rewards.
  /// @return The total amount of earned rewards for the specified user.
  /// @dev Computes earned rewards by taking the product of the account's balance and the difference between the
  /// global reward per token and the reward per token already paid to the user.
  /// This result is then added to any rewards that have already been accumulated but not yet paid out.
  function earned(address account) public view returns (uint256) {
    return balanceOf[account].mulWadDown(globalIndex() - indexes[account]) + rewards[account];
  }

  function getReward() external updateReward(msg.sender) {
    uint256 reward = rewards[msg.sender];
    if (reward != 0) {
      rewards[msg.sender] = 0;
      rewardsToken.transfer(msg.sender, reward);

      emit RewardPaid(msg.sender, reward);
    }
  }

  function setRewardsDuration(uint256 duration_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (finishAt > block.timestamp) revert NotFinished();
    duration = duration_;

    emit RewardsDurationSet(msg.sender, duration_);
  }

  function notifyRewardAmount(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) updateReward(address(0)) {
    if (block.timestamp >= finishAt) {
      rewardRate = amount / duration;
    } else {
      uint256 remainingRewards = (finishAt - block.timestamp) * rewardRate;
      rewardRate = (amount + remainingRewards) / duration;
    }

    if (rewardRate == 0) revert ZeroRate();
    if (rewardRate * duration > rewardsToken.balanceOf(address(this))) revert InsufficientBalance();

    finishAt = block.timestamp + duration;
    updatedAt = block.timestamp;

    emit RewardAmountNotified(msg.sender, amount);
  }

  event Stake(address indexed account, uint256 amount);
  event Withdraw(address indexed account, uint256 amount);
  event RewardAmountNotified(address indexed account, uint256 amount);
  event RewardPaid(address indexed account, uint256 amount);
  event RewardsDurationSet(address indexed account, uint256 duration);
}

error InsufficientBalance();
error NotFinished();
error ZeroAmount();
error ZeroRate();
