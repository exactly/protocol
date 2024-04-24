// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ERC20, SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

contract Staking is Initializable, AccessControlUpgradeable, PausableUpgradeable {
  using SafeTransferLib for ERC20;

  ERC20 public immutable exa;
  ERC20 public immutable rewardsToken;

  /// @notice Duration of rewards to be paid out (in seconds)
  uint256 public duration;
  /// @notice Timestamp of when the rewards finish
  uint256 public finishAt;
  /// @notice Minimum of last updated time and reward finish time
  uint256 public updatedAt;
  /// @notice Reward to be paid out per second
  uint256 public rewardRate;
  /// @notice Sum of (reward rate * dt * 1e18 / total supply)
  uint256 public rewardPerTokenStored;
  mapping(address account => uint256 rewardPerTokenStored) public userRewardPerTokenPaid;
  mapping(address account => uint256 amount) public rewards;
  uint256 public totalSupply;
  mapping(address account => uint256 amount) public balanceOf;

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

  modifier updateReward(address _account) {
    rewardPerTokenStored = rewardPerToken();
    updatedAt = lastTimeRewardApplicable();

    if (_account != address(0)) {
      rewards[_account] = earned(_account);
      userRewardPerTokenPaid[_account] = rewardPerTokenStored;
    }

    _;
  }

  function lastTimeRewardApplicable() public view returns (uint256) {
    return Math.min(finishAt, block.timestamp);
  }

  function rewardPerToken() public view returns (uint256) {
    if (totalSupply == 0) return rewardPerTokenStored;

    return rewardPerTokenStored + (rewardRate * (lastTimeRewardApplicable() - updatedAt) * 1e18) / totalSupply;
  }

  function stake(uint256 _amount) external updateReward(msg.sender) {
    require(_amount != 0, "amount = 0");
    exa.transferFrom(msg.sender, address(this), _amount);
    balanceOf[msg.sender] += _amount;
    totalSupply += _amount;
  }

  function withdraw(uint256 _amount) external updateReward(msg.sender) {
    require(_amount != 0, "amount = 0");
    balanceOf[msg.sender] -= _amount;
    totalSupply -= _amount;
    exa.transfer(msg.sender, _amount);
  }

  function earned(address _account) public view returns (uint256) {
    return ((balanceOf[_account] * (rewardPerToken() - userRewardPerTokenPaid[_account])) / 1e18) + rewards[_account];
  }

  function getReward() external updateReward(msg.sender) {
    uint256 reward = rewards[msg.sender];
    if (reward != 0) {
      rewards[msg.sender] = 0;
      rewardsToken.transfer(msg.sender, reward);
    }
  }

  function setRewardsDuration(uint256 _duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(finishAt < block.timestamp, "reward duration not finished");
    duration = _duration;
  }

  function notifyRewardAmount(uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) updateReward(address(0)) {
    if (block.timestamp >= finishAt) {
      rewardRate = _amount / duration;
    } else {
      uint256 remainingRewards = (finishAt - block.timestamp) * rewardRate;
      rewardRate = (_amount + remainingRewards) / duration;
    }

    require(rewardRate != 0, "reward rate = 0");
    require(rewardRate * duration <= rewardsToken.balanceOf(address(this)), "reward amount > balance");

    finishAt = block.timestamp + duration;
    updatedAt = block.timestamp;
  }
}
