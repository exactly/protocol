// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

import { IERC6372 } from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
  ERC20PermitUpgradeable,
  ERC20Upgradeable,
  IERC20Permit
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Market } from "./Market.sol";

/// @title StakedEXA Contract
/// @notice This contract allows users to stake EXA tokens and earn rewards.
/// The rewards are subject to a penalty if the staking duration is not optimal.
/// The optimal staking duration is defined by `refTime`.
/// Staking for a duration less than `minTime` results in no rewards,
/// the closer the staking duration is to `refTime`, the lower the penalty.
contract StakedEXA is
  Initializable,
  AccessControlUpgradeable,
  PausableUpgradeable,
  ERC4626Upgradeable,
  ERC20PermitUpgradeable,
  IERC6372
{
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;
  using SafeERC20 for IERC20;
  using SafeCast for int256;

  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  bytes32 public constant EMERGENCY_ADMIN_ROLE = keccak256("EMERGENCY_ADMIN_ROLE");

  /// @notice Rewards tokens.
  IERC20[] public rewardsTokens;
  /// @notice Maximum amount of rewards token.
  uint256 public constant MAX_REWARDS_TOKENS = 100;

  /// @notice Minimum time to stake and get rewards.
  uint256 public minTime;
  /// @notice Reference period to stake and get full rewards. Not possible to change after initilization.
  uint256 public refTime;
  /// @notice Discount factor for excess exposure. Not possible to change after initilization.
  uint256 public excessFactor;
  /// @notice Penalty growth factor.
  uint256 public penaltyGrowth;
  /// @notice Threshold penalty factor for withdrawing before the reference time.
  uint256 public penaltyThreshold;

  /// @notice market from which to harvest.
  Market public market;
  /// @notice provider of rewards when harvesting.
  address public provider;
  /// @notice savings address to send the rewards.
  address public savings;
  /// @notice ratio of withdrawn assets to provide when harvesting. The rest goes to savings
  uint256 public providerRatio;

  /// @notice Rewards data per token.
  mapping(IERC20 reward => RewardData data) public rewards;
  /// @notice Average starting time with the tokens staked per account.
  mapping(address account => uint256 time) public avgStart;
  /// @notice Accounts average indexes per reward token.
  mapping(address account => mapping(IERC20 reward => uint256 index)) public avgIndexes;
  /// @notice Accounts claimed rewards per reward token.
  mapping(address account => mapping(IERC20 reward => uint256 claimed)) public claimed;
  /// @notice Accounts saved rewards per reward token.
  mapping(address account => mapping(IERC20 reward => uint256 saved)) public saved;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  /// @param p The parameters for initialization.
  function initialize(Parameters memory p) external initializer {
    __ERC20_init("staked EXA", "stEXA");
    __ERC4626_init(p.asset);
    __ERC20Permit_init("staked EXA");

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    if (p.refTime == 0 || p.refTime <= p.minTime || p.excessFactor > 1e18) revert InvalidRange();
    setMinTime(p.minTime);
    refTime = p.refTime;
    excessFactor = p.excessFactor;
    setPenaltyGrowth(p.penaltyGrowth);
    setPenaltyThreshold(p.penaltyThreshold);

    setMarket(p.market);
    setRewardsDuration(IERC20(address(p.market.asset())), p.duration);

    setProvider(p.provider);
    setProviderRatio(p.providerRatio);
    setSavings(p.savings);
  }

  /// @notice Updates the reward index for a given reward token.
  /// @param reward The reward token to update.
  function updateIndex(IERC20 reward) internal {
    RewardData storage rewardData = rewards[reward];
    rewardData.index = globalIndex(reward);
    rewardData.updatedAt = uint40(lastTimeRewardApplicable(rewardData.finishAt));
  }

  /// @notice Hook to handle updates during token transfer.
  /// @param from The address transferring the tokens.
  /// @param to The address receiving the tokens.
  /// @param amount The amount of tokens being transferred.
  function _update(address from, address to, uint256 amount) internal override whenNotPaused {
    if (amount == 0) revert ZeroAmount();
    if (from == address(0)) {
      if (to != msg.sender && allowance(to, msg.sender) == 0) revert NotAllowed();
      uint256 start = avgStart[to];
      uint256 time = start != 0 ? block.timestamp * 1e18 - start : 0;
      uint256 memRefTime = refTime * 1e18;
      uint256 balance = balanceOf(to);
      uint256 total = amount + balance;

      uint256 length = rewardsTokens.length;
      for (uint256 i = 0; i < length; ++i) {
        IERC20 reward = rewardsTokens[i];
        updateIndex(reward);

        if (time > memRefTime) {
          if (balance != 0) claimWithdraw(reward, to, balance);
          avgIndexes[to][reward] = rewards[reward].index;
        } else {
          if (balance != 0) claim_(reward, to);
          uint256 numerator = avgIndexes[to][reward] * balance + rewards[reward].index * amount;
          avgIndexes[to][reward] = numerator == 0 ? 0 : (numerator - 1) / total + 1;
        }
      }
      if (time > memRefTime) avgStart[to] = block.timestamp * 1e18;
      else {
        uint256 numerator = start * balance + block.timestamp * 1e18 * amount;
        avgStart[to] = numerator == 0 ? 0 : (numerator - 1) / total + 1;
      }
      try this.harvest() {} catch {} // solhint-disable-line no-empty-blocks
    } else if (to == address(0)) {
      uint256 length = rewardsTokens.length;
      for (uint256 i = 0; i < length; ++i) {
        IERC20 reward = rewardsTokens[i];
        updateIndex(reward);
        claimWithdraw(reward, from, amount);
      }
    } else revert Untransferable();

    super._update(from, to, amount);
  }

  /// @notice Permits a spender and deposits assets in a single transaction.
  /// @param assets The amount of assets to deposit.
  /// @param receiver The address receiving the deposited assets.
  /// @param p The permit parameters.
  /// @return The number of shares received.
  function permitAndDeposit(uint256 assets, address receiver, Permit calldata p) external returns (uint256) {
    // solhint-disable-next-line no-empty-blocks
    try IERC20Permit(asset()).permit(receiver, address(this), p.value, p.deadline, p.v, p.r, p.s) {} catch {}

    uint256 maxAssets = maxDeposit(receiver);
    if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);

    uint256 shares = previewDeposit(assets);
    _deposit(receiver, receiver, assets, shares);

    return shares;
  }

  /// @notice Resets msg.sender's position by withdrawing and depositing the same assets.
  function reset() external returns (uint256) {
    uint256 assets = redeem(balanceOf(msg.sender), msg.sender, msg.sender);
    return deposit(assets, msg.sender);
  }

  /// @notice Claims unclaimed rewards when withdrawing an amount of assets.
  /// @param reward The reward token to claim.
  /// @param account The account receiving the withdrawn assets and rewards.
  /// @param amount The amount of assets being withdrawn.
  function claimWithdraw(IERC20 reward, address account, uint256 amount) internal {
    uint256 balance = balanceOf(account);
    uint256 numerator = claimed[account][reward] * amount;
    uint256 claimedAmount = numerator == 0 ? 0 : (numerator - 1) / balance + 1;
    claimed[account][reward] -= claimedAmount;

    numerator = saved[account][reward] * amount;
    uint256 savedAmount = numerator == 0 ? 0 : (numerator - 1) / balance + 1;
    saved[account][reward] -= savedAmount;

    uint256 claimableAmount = Math.max(rawClaimable(reward, account, amount), claimedAmount); // due to excess exposure
    uint256 claimAmount = claimableAmount - claimedAmount;
    if (claimAmount != 0) {
      reward.safeTransfer(account, claimAmount);
      emit RewardPaid(reward, account, claimAmount);
    }

    uint256 rawEarned = earned(reward, account, amount);
    // due to rounding
    uint256 saveAmount = rawEarned <= claimableAmount + savedAmount ? 0 : rawEarned - claimableAmount - savedAmount;
    if (saveAmount != 0) reward.safeTransfer(savings, saveAmount);
  }

  /// @notice Notifies the contract about a reward amount.
  /// @param reward The reward token.
  /// @param amount The amount of reward tokens.
  /// @param notifier The address notifying the reward amount.
  function notifyRewardAmount(IERC20 reward, uint256 amount, address notifier) internal onlyReward(reward) {
    updateIndex(reward);
    RewardData storage rewardData = rewards[reward];
    if (block.timestamp >= rewardData.finishAt) {
      rewardData.rate = amount / rewardData.duration;
    } else {
      uint256 remainingRewards = (rewardData.finishAt - block.timestamp) * rewardData.rate;
      rewardData.rate = (amount + remainingRewards) / rewardData.duration;
    }

    if (rewardData.rate == 0) revert ZeroRate();
    if (
      rewardData.rate * rewardData.duration >
      reward.balanceOf(address(this)) - (address(reward) == asset() ? totalAssets() : 0)
    ) revert InsufficientBalance();

    rewardData.finishAt = uint40(block.timestamp) + rewardData.duration;
    rewardData.updatedAt = uint40(block.timestamp);

    emit RewardAmountNotified(reward, notifier, amount);
  }

  /// @notice Calculates the discount factor based on the staked time.
  /// @param time The time staked, represented with 18 decimals.
  /// @return The discount factor, which is always between 0 and 1e18.
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

  /// @notice Ensures the caller has pausing roles.
  /// @dev Throws if the caller is not an `EMERGENCY_ADMIN_ROLE` or `PAUSER_ROLE`.
  function requirePausingRoles() internal view {
    if (!hasRole(EMERGENCY_ADMIN_ROLE, msg.sender) && !hasRole(PAUSER_ROLE, msg.sender)) {
      revert NotPausingRole();
    }
  }

  /// @dev Modifier to restrict functions to pausing roles.
  modifier onlyPausingRoles() {
    requirePausingRoles();
    _;
  }

  /// @notice Modifier to restrict functions to enabled reward tokens.
  /// @param reward The reward token.
  modifier onlyReward(IERC20 reward) {
    if (rewards[reward].finishAt == 0) revert RewardNotListed();
    _;
  }

  /// @notice Returns the last time rewards are applicable.
  /// @param finishAt The time when the reward period finishes.
  /// @return The last applicable time.
  function lastTimeRewardApplicable(uint256 finishAt) public view returns (uint256) {
    return uint40(Math.min(finishAt, block.timestamp));
  }

  /// @notice Returns the global index for a reward token.
  /// @param reward The reward token.
  /// @return The global index.
  function globalIndex(IERC20 reward) public view returns (uint256) {
    RewardData storage rewardData = rewards[reward];
    if (totalSupply() == 0) return rewardData.index;

    return
      rewardData.index +
      (rewardData.rate * (lastTimeRewardApplicable(rewardData.finishAt) - rewardData.updatedAt)).divWadDown(
        totalSupply()
      );
  }

  /// @notice Returns the average index for a reward token and account.
  /// @param reward The reward token.
  /// @param account The account.
  /// @return The average index.
  function avgIndex(IERC20 reward, address account) public view returns (uint256) {
    return avgIndexes[account][reward];
  }

  /// @notice Calculates the earned rewards for an account, without considering penalties.
  /// @param reward The reward token.
  /// @param account The account.
  /// @param shares The amount of shares.
  /// @return The earned rewards.
  function earned(IERC20 reward, address account, uint256 shares) public view returns (uint256) {
    return shares.mulWadDown(globalIndex(reward) - avgIndexes[account][reward]);
  }

  /// @notice Calculates the raw claimable rewards for an account, without considering already claimed rewards.
  /// @param reward The reward token.
  /// @param account The account.
  /// @param shares The amount of shares of the account involved.
  /// @return The raw claimable rewards.
  function rawClaimable(IERC20 reward, address account, uint256 shares) public view returns (uint256) {
    uint256 start = avgStart[account];
    if (start == 0) return 0;
    return earned(reward, account, shares).mulWadDown(discountFactor(block.timestamp * 1e18 - start));
  }

  /// @notice Calculates the claimable rewards for an account.
  /// @param reward The reward token.
  /// @param account The account.
  /// @param shares The amount of shares of the account involved.
  /// @return The claimable rewards.
  function claimable(IERC20 reward, address account, uint256 shares) public view returns (uint256) {
    uint256 start = avgStart[account];
    if (start == 0 || block.timestamp * 1e18 - start <= minTime * 1e18) return 0;

    uint256 rawClaimable_ = rawClaimable(reward, account, shares);
    uint256 balance = balanceOf(account);
    if (balance == 0) return 0;

    uint256 numerator = claimed[account][reward] * shares;
    uint256 claimedAmountProportion = numerator == 0 ? 0 : (numerator - 1) / balance + 1;
    return rawClaimable_ > claimedAmountProportion ? rawClaimable_ - claimedAmountProportion : 0;
  }

  /// @notice Harvests provider's market assets as rewards to be distributed among stakers.
  /// @dev This function withdraws the maximum allowable assets from the provider's market,
  /// calculates the portion to be distributed as rewards based on `providerRatio`,
  /// deposits any remaining assets back into savings, and notifies the contract of the new reward amount.
  function harvest() external whenNotPaused {
    Market memMarket = market;
    address memProvider = provider;
    uint256 shares = Math.min(memMarket.allowance(memProvider, address(this)), memMarket.maxRedeem(memProvider));
    uint256 sharesReward = shares.mulWadDown(providerRatio);

    uint256 amount = memMarket.redeem(sharesReward, address(this), memProvider);
    uint256 save = shares - sharesReward;
    if (save != 0) memMarket.transferFrom(memProvider, savings, save);

    notifyRewardAmount(IERC20(address(memMarket.asset())), amount, address(this));
  }

  /// @notice Returns all reward tokens.
  /// @return The list of reward tokens.
  function allRewardsTokens() external view returns (IERC20[] memory) {
    return rewardsTokens;
  }

  /// @notice Internal function to claim rewards.
  /// @param reward The reward token.
  function claim_(IERC20 reward, address account) internal whenNotPaused {
    uint256 time = block.timestamp * 1e18 - avgStart[account];
    if (time <= minTime * 1e18) return;

    uint256 claimedAmount = claimed[account][reward];
    // due to excess exposure
    uint256 claimableAmount = Math.max(rawClaimable(reward, account, balanceOf(account)), claimedAmount);
    uint256 claimAmount = claimableAmount - claimedAmount;

    if (claimAmount != 0) claimed[account][reward] = claimedAmount + claimAmount;

    if (time > refTime * 1e18) {
      uint256 rawEarned = earned(reward, account, balanceOf(account));
      uint256 savedAmount = saved[account][reward];
      uint256 maxClaimed = Math.min(rawEarned, claimableAmount);
      uint256 saveAmount = rawEarned > maxClaimed + savedAmount ? rawEarned - maxClaimed - savedAmount : 0;

      if (saveAmount != 0) {
        saved[account][reward] = savedAmount + saveAmount;
        reward.safeTransfer(savings, saveAmount);
      }
    }
    if (claimAmount != 0) {
      reward.safeTransfer(account, claimAmount);
      emit RewardPaid(reward, account, claimAmount);
    }
  }

  /// @notice Claims rewards for a specific reward token.
  /// @param reward The reward token.
  function claim(IERC20 reward) external {
    claim_(reward, msg.sender);
  }

  /// @notice Claims rewards for all reward tokens.
  function claimAll() external {
    for (uint256 i = 0; i < rewardsTokens.length; ++i) {
      claim_(rewardsTokens[i], msg.sender);
    }
  }

  /// @notice Withdraws `amount` of `reward` from contract to `savings`.
  /// @param reward The reward token.
  /// @param amount The amount of reward tokens to withdraw.
  function withdrawRewards(IERC20 reward, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) onlyReward(reward) {
    if (address(reward) == asset() && amount > reward.balanceOf(address(this)) - totalAssets()) {
      revert InsufficientBalance();
    }
    address memSavings = savings;
    reward.safeTransfer(memSavings, amount);
    emit RewardsWithdrawn(msg.sender, memSavings, reward, amount);
  }

  /// @notice Enables a new reward token.
  /// @param reward The reward token.
  function enableReward(IERC20 reward) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (rewardsTokens.length >= MAX_REWARDS_TOKENS) revert MaxRewardsTokensExceeded();
    if (rewards[reward].finishAt != 0) revert AlreadyEnabled();

    rewards[reward].finishAt = uint40(block.timestamp);
    rewardsTokens.push(reward);

    emit RewardListed(reward, msg.sender);
  }

  /// @notice Finishes the distribution of a reward token.
  /// @param reward The reward token.
  function finishDistribution(IERC20 reward) public onlyRole(DEFAULT_ADMIN_ROLE) onlyReward(reward) {
    updateIndex(reward);

    if (block.timestamp < rewards[reward].finishAt) {
      uint256 finishAt = rewards[reward].finishAt;
      rewards[reward].finishAt = uint40(block.timestamp);
      reward.safeTransfer(savings, (finishAt - block.timestamp) * rewards[reward].rate);
    }

    if (reward == IERC20(address(market.asset()))) setProvider(address(0));

    emit DistributionFinished(reward, msg.sender);
  }

  /// @notice Sets the rewards duration for a reward token.
  /// @dev Can only change the duration if the reward is finished.
  /// @param reward The reward token.
  /// @param duration The new duration.
  function setRewardsDuration(IERC20 reward, uint40 duration) public onlyRole(DEFAULT_ADMIN_ROLE) {
    RewardData storage rewardData = rewards[reward];
    if (rewardData.finishAt > block.timestamp) revert NotFinished();

    rewardData.duration = duration;

    emit RewardsDurationSet(reward, msg.sender, duration);
  }

  /// @notice Notifies the contract about a reward amount.
  /// @param reward The reward token.
  /// @param amount The amount of reward tokens.
  function notifyRewardAmount(IERC20 reward, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    notifyRewardAmount(reward, amount, msg.sender);
  }

  /// @notice Sets the market.
  /// @param market_ The new market.
  function setMarket(Market market_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (address(market_) == address(0)) revert ZeroAddress();
    market = market_;

    IERC20 providerAsset = IERC20(address(market_.asset()));
    if (rewards[providerAsset].finishAt == 0) enableReward(providerAsset);

    emit MarketSet(market_, msg.sender);
  }

  /// @notice Sets the provider address.
  /// @param provider_ The new provider address.
  function setProvider(address provider_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    provider = provider_;
    emit ProviderSet(provider_, msg.sender);
  }

  /// @notice Sets the provider ratio.
  /// @param providerRatio_ The new provider ratio.
  function setProviderRatio(uint256 providerRatio_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (providerRatio_ > 1e18) revert InvalidRatio();
    providerRatio = providerRatio_;
    emit ProviderRatioSet(providerRatio_, msg.sender);
  }

  /// @notice Sets the savings address.
  /// @param savings_ The new savings address.
  function setSavings(address savings_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (savings_ == address(0)) revert ZeroAddress();
    savings = savings_;
    emit SavingsSet(savings_, msg.sender);
  }

  /// @notice Sets the minimum time to stake for rewards.
  /// @param minTime_ The new minimum time.
  function setMinTime(uint256 minTime_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    minTime = minTime_;
    emit MinTimeSet(minTime_, msg.sender);
  }

  /// @notice Sets the penalty growth factor.
  /// @param penaltyGrowth_ The new penalty growth factor.
  function setPenaltyGrowth(uint256 penaltyGrowth_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (penaltyGrowth_ < 0.1e18 || penaltyGrowth_ > 100e18) revert InvalidRange();
    penaltyGrowth = penaltyGrowth_;
    emit PenaltyGrowthSet(penaltyGrowth_, msg.sender);
  }

  /// @notice Sets the penalty threshold.
  /// @param penaltyThreshold_ The new penalty threshold.
  function setPenaltyThreshold(uint256 penaltyThreshold_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (penaltyThreshold_ > 1e18) revert InvalidRange();
    penaltyThreshold = penaltyThreshold_;
    emit PenaltyThresholdSet(penaltyThreshold_, msg.sender);
  }

  /// @notice Sets the pause state to true in case of emergency, triggered by an authorized account.
  function pause() external onlyPausingRoles {
    _pause();
  }

  /// @notice Sets the pause state to false when threat is gone, triggered by an authorized account.
  function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  /// @notice Returns the total assets of the contract.
  /// @return The total assets.
  function totalAssets() public view override returns (uint256) {
    return totalSupply();
  }

  /// @notice Returns the number of decimals used by the token.
  /// @return The number of decimals.
  function decimals() public view override(ERC4626Upgradeable, ERC20Upgradeable) returns (uint8) {
    return ERC4626Upgradeable.decimals();
  }

  /// @notice Returns the current timepoint of stEXA, as per ERC-6372.
  function clock() public view override returns (uint48) {
    return uint48(block.timestamp);
  }

  /// @notice Returns the current clock mode of stEXA, as per ERC-6372.
  // solhint-disable-next-line func-name-mixedcase
  function CLOCK_MODE() public pure override returns (string memory) {
    return "mode=timestamp";
  }

  event DistributionFinished(IERC20 indexed reward, address indexed account);
  event MarketSet(Market indexed market, address indexed account);
  event MinTimeSet(uint256 minTime, address indexed account);
  event PenaltyGrowthSet(uint256 penaltyGrowth, address indexed account);
  event PenaltyThresholdSet(uint256 penaltyThreshold, address indexed account);
  event ProviderRatioSet(uint256 providerRatio, address indexed account);
  event ProviderSet(address indexed provider, address indexed account);
  event RefTimeSet(uint256 refTime, address indexed account);
  event RewardAmountNotified(IERC20 indexed reward, address indexed notifier, uint256 amount);
  event RewardListed(IERC20 indexed reward, address indexed account);
  event RewardPaid(IERC20 indexed reward, address indexed account, uint256 amount);
  event RewardsDurationSet(IERC20 indexed reward, address indexed account, uint256 duration);
  event RewardsWithdrawn(address indexed account, address indexed receiver, IERC20 indexed reward, uint256 amount);
  event SavingsSet(address indexed savings, address indexed account);
}

error AlreadyEnabled();
error InsufficientBalance();
error InvalidRange();
error InvalidRatio();
error MaxRewardsTokensExceeded();
error NotAllowed();
error NotFinished();
error NotPausingRole();
error RewardNotListed();
error Untransferable();
error ZeroAddress();
error ZeroRate();
error ZeroAmount();

struct Parameters {
  IERC20 asset;
  uint256 minTime;
  uint256 refTime;
  uint256 excessFactor;
  uint256 penaltyGrowth;
  uint256 penaltyThreshold;
  Market market;
  address provider;
  address savings;
  uint40 duration;
  uint256 providerRatio;
}

struct RewardData {
  uint40 duration;
  uint40 finishAt;
  uint40 updatedAt;
  uint256 index;
  uint256 rate;
}

struct Permit {
  uint256 value;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}
