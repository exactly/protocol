// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20, Parameters, StakedEXA } from "../StakedEXA.sol";

/// @title StakingPreviewer
/// @notice Contract to be consumed as a helper for `StakedEXA`
contract StakingPreviewer {
  StakedEXA public immutable stEXA;

  constructor(StakedEXA stEXA_) {
    stEXA = stEXA_;
  }

  /// @notice Returns the staking model parameters and account details for a given account.
  function staking() external view returns (StakingAccount memory) {
    uint256 start = stEXA.avgStart(msg.sender);
    return
      StakingAccount({
        parameters: parameters(),
        totalAssets: stEXA.totalAssets(),
        balance: stEXA.balanceOf(msg.sender),
        start: start,
        time: start != 0 ? block.timestamp * 1e18 - start : 0,
        rewards: allRewards(msg.sender)
      });
  }

  function allRewards(address account) public view returns (RewardAccount[] memory rewards) {
    IERC20[] memory rewardTokens = stEXA.allRewardsTokens();
    rewards = new RewardAccount[](rewardTokens.length);
    for (uint256 i = 0; i < rewardTokens.length; ++i) {
      IERC20 reward = rewardTokens[i];
      (, uint40 finishAt, , , uint256 rate) = stEXA.rewards(reward);
      rewards[i] = RewardAccount({
        reward: reward,
        rate: rate,
        finishAt: finishAt,
        claimable: claimable(reward, account),
        claimed: stEXA.claimed(account, reward),
        earned: earned(reward, account)
      });
    }
  }

  /// @notice Returns the rewards and amounts that an account can currently claim.
  /// @param account The address of the user for whom to calculate the claimable rewards.
  /// @return claimableRewards An array of `RewardAmount`, with the reward token and the amount.
  function allClaimable(address account) public view returns (RewardAmount[] memory claimableRewards) {
    IERC20[] memory rewards = stEXA.allRewardsTokens();
    claimableRewards = new RewardAmount[](rewards.length);
    for (uint256 i = 0; i < rewards.length; ++i) {
      claimableRewards[i] = RewardAmount({ reward: rewards[i], amount: claimable(rewards[i], account) });
    }
  }

  /// @notice Calculates the amount of rewards that an account can claim.
  /// @param reward The reward token for which to calculate the claimable rewards.
  /// @param account The address of the user for whom to calculate the claimable rewards.
  /// @return The total amount of claimable rewards for the specified user.
  function claimable(IERC20 reward, address account) public view returns (uint256) {
    return stEXA.claimable(reward, account, stEXA.balanceOf(account));
  }

  /// @notice Returns the rewards and amounts that an account can currently claim for the given shares.
  /// @param account The address of the user for whom to calculate the claimable rewards.
  /// @param shares The number of shares for which to calculate the claimable rewards.
  /// @return claimableRewards An array of `RewardAmount`, with the reward token and the amount.
  function allClaimable(address account, uint256 shares) public view returns (RewardAmount[] memory claimableRewards) {
    IERC20[] memory rewards = stEXA.allRewardsTokens();
    claimableRewards = new RewardAmount[](rewards.length);
    for (uint256 i = 0; i < rewards.length; ++i) {
      claimableRewards[i] = RewardAmount({ reward: rewards[i], amount: stEXA.claimable(rewards[i], account, shares) });
    }
  }

  /// @notice Returns the rewards and amounts that an account has generated.
  /// @param account The address of the user for whom to calculate the earned rewards.
  /// @return earnedRewards An array of `RewardAmount`, with the reward token and the amount.
  function allEarned(address account) public view returns (RewardAmount[] memory earnedRewards) {
    IERC20[] memory rewards = stEXA.allRewardsTokens();
    earnedRewards = new RewardAmount[](rewards.length);
    for (uint256 i = 0; i < rewards.length; ++i) {
      earnedRewards[i] = RewardAmount({ reward: rewards[i], amount: earned(rewards[i], account) });
    }
  }

  /// @notice Calculates the amount of rewards that an account has earned.
  /// @param account The address of the user for whom to calculate the rewards.
  /// @return The total amount of earned rewards for the specified user.
  /// @dev Computes earned rewards by taking the product of the account's balance and the difference between the
  /// global reward per token and the reward per token already paid to the user.
  /// This result is then added to any rewards that have already been accumulated but not yet paid out.
  function earned(IERC20 reward, address account) public view returns (uint256) {
    return stEXA.earned(reward, account, stEXA.balanceOf(account));
  }

  /// @notice Returns the rewards and amounts that an account has already claimed.
  /// @param account The address of the user for whom to calculate the claimed rewards.
  /// @return claimedRewards An array of `RewardAmount`, with the reward token and the amount.
  function allClaimed(address account) public view returns (RewardAmount[] memory claimedRewards) {
    IERC20[] memory rewards = stEXA.allRewardsTokens();
    claimedRewards = new RewardAmount[](rewards.length);
    for (uint256 i = 0; i < rewards.length; ++i) {
      claimedRewards[i] = RewardAmount({ reward: rewards[i], amount: stEXA.claimed(account, rewards[i]) });
    }
  }

  /// @notice Returns the staking model parameters.
  function parameters() public view returns (Parameters memory) {
    (uint40 duration, , , , ) = stEXA.rewards(IERC20(address(stEXA.market().asset())));
    return
      Parameters({
        asset: IERC20(stEXA.asset()),
        minTime: stEXA.minTime(),
        refTime: stEXA.refTime(),
        excessFactor: stEXA.excessFactor(),
        penaltyGrowth: stEXA.penaltyGrowth(),
        penaltyThreshold: stEXA.penaltyThreshold(),
        market: stEXA.market(),
        provider: stEXA.provider(),
        savings: stEXA.savings(),
        duration: duration,
        providerRatio: stEXA.providerRatio()
      });
  }
}

struct StakingAccount {
  // staking
  Parameters parameters;
  uint256 totalAssets;
  // account
  RewardAccount[] rewards;
  uint256 balance;
  uint256 start;
  uint256 time;
}

struct RewardAccount {
  IERC20 reward;
  uint256 rate;
  uint256 finishAt;
  uint256 claimable;
  uint256 claimed;
  uint256 earned;
}

struct RewardAmount {
  IERC20 reward;
  uint256 amount;
}
