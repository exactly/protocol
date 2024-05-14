// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC20, SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC6372Upgradeable } from "@openzeppelin/contracts-upgradeable/interfaces/IERC6372Upgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {
  ERC20PermitUpgradeable,
  ERC20Upgradeable,
  IERC20Upgradeable as IERC20
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract StakedEXA is
  Initializable,
  AccessControlUpgradeable,
  PausableUpgradeable,
  ERC4626Upgradeable,
  ERC20PermitUpgradeable,
  IERC6372Upgradeable
{
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;
  using SafeTransferLib for ERC20;
  using SafeCast for int256;

  /// @notice Staking token
  IERC20 public immutable exa;
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

  /// @notice Minimum time to stake and get rewards
  uint256 public minTime;
  /// @notice Reference period to stake and get full rewards
  uint256 public refTime;
  /// @notice Discount factor for excess exposure
  uint256 public excessFactor;
  /// @notice Penalty growth factor
  uint256 public penaltyGrowth;
  /// @notice Threshold penalty factor for withdrawing before the reference time
  uint256 public penaltyThreshold;

  /// @notice Average starting time with the tokens staked per account
  mapping(address account => uint256 time) public avgStart;
  /// @notice Accounts average indexes
  mapping(address account => uint256 index) public avgIndexes;

  constructor(IERC20 exa_, ERC20 rewardsToken_) {
    exa = exa_;
    rewardsToken = rewardsToken_;

    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize(
    uint256 minTime_,
    uint256 refTime_,
    uint256 excessFactor_,
    uint256 penaltyGrowth_,
    uint256 penaltyThreshold_
  ) external initializer {
    __ERC20_init("staked EXA", "stEXA");
    __ERC4626_init(exa);
    __ERC20Permit_init("staked EXA");

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    minTime = minTime_;
    refTime = refTime_;
    excessFactor = excessFactor_;
    penaltyGrowth = penaltyGrowth_;
    penaltyThreshold = penaltyThreshold_;
  }

  function lastTimeRewardApplicable() public view returns (uint256) {
    return Math.min(finishAt, block.timestamp);
  }

  function globalIndex() public view returns (uint256) {
    if (totalSupply() == 0) return index;

    return index + (rewardRate * (lastTimeRewardApplicable() - updatedAt)).divWadDown(totalSupply());
  }

  function updateIndex() internal {
    index = globalIndex();
    updatedAt = lastTimeRewardApplicable();
  }

  function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
    if (amount == 0) revert ZeroAmount();
    if (from == address(0)) {
      updateIndex();
      uint256 balance = balanceOf(to);
      uint256 weight = balance.divWadDown(balance + amount);
      avgStart[to] = avgStart[to].mulWadDown(weight) + (block.timestamp) * (1e18 - weight);
      avgIndexes[to] = avgIndexes[to].mulWadDown(weight) + index.mulWadDown(1e18 - weight);
    } else if (to == address(0)) {
      updateIndex();
      uint256 reward = claimable(from, amount);
      if (reward != 0) {
        rewardsToken.transfer(from, reward);
        emit RewardPaid(from, reward);
      }
    } else revert Untransferable();
  }

  function discountFactor(uint256 time) internal view returns (uint256) {
    uint256 memMinTime = minTime;
    if (time <= memMinTime) return 0;
    if (time >= refTime) return (1e18 - excessFactor).mulWadDown((refTime * 1e18) / time) + excessFactor;

    uint256 penalties = uint256(
      ((int256(penaltyGrowth) * int256(((time - memMinTime) * 1e18) / (refTime - memMinTime)).lnWad()) / 1e18).expWad()
    );

    return Math.min((1e18 - penaltyThreshold).mulWadDown(penalties) + penaltyThreshold, 1e18);
  }

  /// @notice Calculate the amount of rewards that an account has earned but not yet claimed.
  /// @param account The address of the user for whom to calculate the rewards.
  /// @return The total amount of earned rewards for the specified user.
  /// @dev Computes earned rewards by taking the product of the account's balance and the difference between the
  /// global reward per token and the reward per token already paid to the user.
  /// This result is then added to any rewards that have already been accumulated but not yet paid out.
  function earned(address account) external view returns (uint256) {
    return earned(account, balanceOf(account));
  }

  function claimable(address account) external view returns (uint256) {
    return claimable(account, balanceOf(account));
  }

  function earned(address account, uint256 assets) public view returns (uint256) {
    return assets.mulWadDown(globalIndex() - avgIndexes[account]);
  }

  function claimable(address account, uint256 assets) public view returns (uint256) {
    return earned(account, assets).mulWadDown(discountFactor(block.timestamp - avgStart[account] / 1e18));
  }

  function setRewardsDuration(uint256 duration_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (finishAt > block.timestamp) revert NotFinished();
    duration = duration_;

    emit RewardsDurationSet(msg.sender, duration_);
  }

  function notifyRewardAmount(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    updateIndex();
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

  function decimals() public view override(ERC4626Upgradeable, ERC20Upgradeable) returns (uint8) {
    return ERC4626Upgradeable.decimals();
  }

  function clock() public view override returns (uint48) {
    return uint48(block.timestamp);
  }

  // solhint-disable-next-line func-name-mixedcase
  function CLOCK_MODE() public pure override returns (string memory) {
    return "mode=timestamp";
  }

  event RewardAmountNotified(address indexed account, uint256 amount);
  event RewardPaid(address indexed account, uint256 amount);
  event RewardsDurationSet(address indexed account, uint256 duration);
}

error InsufficientBalance();
error NotFinished();
error Untransferable();
error ZeroAmount();
error ZeroRate();
