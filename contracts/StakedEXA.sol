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

import { Market } from "./Market.sol";

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

  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  bytes32 public constant EMERGENCY_ADMIN_ROLE = keccak256("EMERGENCY_ADMIN_ROLE");

  /// @notice Staking token
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IERC20 public immutable exa;
  /// @notice Rewards tokens
  ERC20[] public rewardsTokens;

  /// @notice Rewards data per token
  mapping(ERC20 reward => RewardData data) public rewards;

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
  /// @notice Accounts average indexes per reward token
  mapping(address account => mapping(ERC20 reward => uint256 index)) public avgIndexes;

  Market public market;
  address public provider;
  address public savings;
  uint256 public providerRatio;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(IERC20 exa_) {
    exa = exa_;

    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize(
    uint256 minTime_,
    uint256 refTime_,
    uint256 excessFactor_,
    uint256 penaltyGrowth_,
    uint256 penaltyThreshold_,
    Market market_,
    address provider_,
    address savings_,
    uint256 duration_,
    uint256 providerRatio_
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

    market = market_;

    enableReward(market_.asset());
    setRewardsDuration(market_.asset(), duration_);

    market_.asset().approve(address(market), type(uint256).max);

    setProvider(provider_);
    setProviderRatio(providerRatio_);
    setSavings(savings_);
  }

  function updateIndex(ERC20 reward) internal {
    RewardData storage rewardData = rewards[reward];
    rewardData.index = globalIndex(reward);
    rewardData.updatedAt = lastTimeRewardApplicable(rewardData.finishAt);
  }

  function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenNotPaused {
    if (amount == 0) revert ZeroAmount();
    if (from == address(0)) {
      uint256 balance = balanceOf(to);
      uint256 weight = balance.divWadDown(balance + amount);
      for (uint256 i = 0; i < rewardsTokens.length; ++i) {
        ERC20 reward = rewardsTokens[i];
        updateIndex(reward);
        avgIndexes[to][reward] =
          avgIndexes[to][reward].mulWadUp(weight) +
          rewards[reward].index.mulWadUp(1e18 - weight);
      }
      avgStart[to] = avgStart[to].mulWadUp(weight) + (block.timestamp) * (1e18 - weight);
    } else if (to == address(0)) {
      for (uint256 i = 0; i < rewardsTokens.length; ++i) {
        ERC20 reward = rewardsTokens[i];
        updateIndex(reward);
        uint256 claimableAmount = claimable(reward, from, amount);
        if (claimableAmount != 0) {
          reward.transfer(from, claimableAmount);
          emit RewardPaid(reward, from, claimableAmount);
        }
      }
    } else revert Untransferable();
  }

  function notifyRewardAmount(ERC20 reward, uint256 amount, address notifier) internal onlyReward(reward) {
    updateIndex(reward);
    RewardData storage rewardData = rewards[reward];
    if (block.timestamp >= rewardData.finishAt) {
      rewardData.rate = amount / rewardData.duration;
    } else {
      uint256 remainingRewards = (rewardData.finishAt - block.timestamp) * rewardData.rate;
      rewardData.rate = (amount + remainingRewards) / rewardData.duration;
    }

    if (rewardData.rate == 0) revert ZeroRate();
    if (rewardData.rate * rewardData.duration > reward.balanceOf(address(this))) revert InsufficientBalance();

    rewardData.finishAt = block.timestamp + rewardData.duration;
    rewardData.updatedAt = block.timestamp;

    emit RewardAmountNotified(reward, notifier, amount);
  }

  // NOTE time with 18 decimals
  function discountFactor(uint256 time) internal view returns (uint256) {
    uint256 memMinTime = minTime * 1e18;
    if (time <= memMinTime) return 0;
    uint256 memRefTime = refTime * 1e18;
    if (time >= memRefTime) {
      uint256 memExcessFactor = excessFactor;
      return (1e18 - memExcessFactor).mulWadDown((memRefTime * 1e18) / time) + memExcessFactor;
    }

    uint256 penalties = uint256(
      ((int256(penaltyGrowth) * int256(((time - memMinTime) * 1e18) / (memRefTime - memMinTime)).lnWad()) / 1e18)
        .expWad()
    );

    uint256 memPenaltyThreshold = penaltyThreshold;
    return Math.min((1e18 - memPenaltyThreshold).mulWadDown(penalties) + memPenaltyThreshold, 1e18);
  }

  /// @dev Throws if the caller is not an `EMERGENCY_ADMIN_ROLE` or `PAUSER_ROLE`.
  function requirePausingRoles() internal view {
    if (!hasRole(EMERGENCY_ADMIN_ROLE, msg.sender) && !hasRole(PAUSER_ROLE, msg.sender)) {
      revert NotPausingRole();
    }
  }

  /// @dev Modifier to make a function callable only by pausing roles.
  modifier onlyPausingRoles() {
    requirePausingRoles();
    _;
  }

  modifier onlyReward(ERC20 reward) {
    if (rewards[reward].finishAt == 0) revert RewardNotListed();
    _;
  }

  function lastTimeRewardApplicable(uint256 finishAt) public view returns (uint256) {
    return Math.min(finishAt, block.timestamp);
  }

  function globalIndex(ERC20 reward) public view returns (uint256) {
    RewardData memory rewardData = rewards[reward];
    if (totalSupply() == 0) return rewardData.index;

    return
      rewardData.index +
      (rewardData.rate * (lastTimeRewardApplicable(rewardData.finishAt) - rewardData.updatedAt)).divWadDown(
        totalSupply()
      );
  }

  function avgIndex(ERC20 reward, address account) public view returns (uint256) {
    return avgIndexes[account][reward];
  }

  function earned(ERC20 reward, address account, uint256 assets) public view returns (uint256) {
    uint256 index = globalIndex(reward);
    uint256 accIndex = avgIndexes[account][reward];
    if (index <= accIndex) return 0;
    return assets.mulWadDown(index - accIndex);
  }

  function claimable(ERC20 reward, address account, uint256 assets) public view returns (uint256) {
    return earned(reward, account, assets).mulWadDown(discountFactor(block.timestamp * 1e18 - avgStart[account]));
  }

  /// @notice Calculates the amount of rewards that an account has earned.
  /// @param account The address of the user for whom to calculate the rewards.
  /// @return The total amount of earned rewards for the specified user.
  /// @dev Computes earned rewards by taking the product of the account's balance and the difference between the
  /// global reward per token and the reward per token already paid to the user.
  /// This result is then added to any rewards that have already been accumulated but not yet paid out.
  function earned(ERC20 reward, address account) external view returns (uint256) {
    return earned(reward, account, balanceOf(account));
  }

  function claimable(ERC20 reward, address account) external view returns (uint256) {
    return claimable(reward, account, balanceOf(account));
  }

  function allClaimable(address account) external view returns (ClaimableReward[] memory) {
    ClaimableReward[] memory claimableRewards = new ClaimableReward[](rewardsTokens.length);
    for (uint256 i = 0; i < rewardsTokens.length; ++i) {
      ERC20 reward = rewardsTokens[i];
      claimableRewards[i] = ClaimableReward({
        reward: address(reward),
        rewardName: reward.name(),
        rewardSymbol: reward.symbol(),
        amount: claimable(reward, account, balanceOf(account))
      });
    }
    return claimableRewards;
  }

  function allEarned(address account) external view returns (ClaimableReward[] memory) {
    ClaimableReward[] memory earnedRewards = new ClaimableReward[](rewardsTokens.length);
    for (uint256 i = 0; i < rewardsTokens.length; ++i) {
      ERC20 reward = rewardsTokens[i];
      earnedRewards[i] = ClaimableReward({
        reward: address(reward),
        rewardName: reward.name(),
        rewardSymbol: reward.symbol(),
        amount: earned(reward, account, balanceOf(account))
      });
    }
    return earnedRewards;
  }

  function harvest() external {
    Market memMarket = market;
    address memProvider = provider;
    uint256 assets = Math.min(
      memMarket.convertToAssets(memMarket.allowance(memProvider, address(this))),
      memMarket.maxWithdraw(memProvider)
    );

    memMarket.withdraw(assets, address(this), memProvider);
    uint256 amount = assets.mulWadDown(providerRatio);
    uint256 save = assets - amount;
    if (save != 0) memMarket.deposit(save, savings);

    if (amount != 0) notifyRewardAmount(memMarket.asset(), amount, address(this));
  }

  function allRewardsTokens() external view returns (ERC20[] memory) {
    return rewardsTokens;
  }

  // restricted functions
  function enableReward(ERC20 reward) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (rewards[reward].finishAt != 0) revert AlreadyListed();

    rewards[reward].finishAt = block.timestamp;
    rewardsTokens.push(reward);

    emit RewardListed(reward, msg.sender);
  }

  function disableReward(ERC20 reward) public onlyRole(DEFAULT_ADMIN_ROLE) onlyReward(reward) {
    updateIndex(reward);

    if (block.timestamp < rewards[reward].finishAt) {
      uint256 finishAt = rewards[reward].finishAt;
      rewards[reward].finishAt = block.timestamp;
      reward.transfer(savings, (finishAt - block.timestamp) * rewards[reward].rate);
    }

    emit RewardDisabled(reward, msg.sender);
  }

  // notice - can only change the duration if the reward is finished
  function setRewardsDuration(ERC20 reward, uint256 duration) public onlyRole(DEFAULT_ADMIN_ROLE) {
    RewardData storage rewardData = rewards[reward];
    if (rewardData.finishAt > block.timestamp) revert NotFinished();

    rewardData.duration = duration;

    emit RewardsDurationSet(reward, msg.sender, duration);
  }

  function notifyRewardAmount(ERC20 reward, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    updateIndex(reward);
    notifyRewardAmount(reward, amount, msg.sender);
  }

  function setMarket(Market market_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    market = market_;
    emit MarketSet(market_, msg.sender);
  }

  function setProvider(address provider_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (provider_ == address(0)) revert ZeroAddress();
    provider = provider_;
    emit ProviderSet(provider_, msg.sender);
  }

  function setProviderRatio(uint256 providerRatio_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (providerRatio_ > 1e18) revert InvalidRatio();
    providerRatio = providerRatio_;
    emit ProviderRatioSet(providerRatio_, msg.sender);
  }

  function setSavings(address savings_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (savings_ == address(0)) revert ZeroAddress();
    savings = savings_;
    emit SavingsSet(savings_, msg.sender);
  }

  /// @notice Sets the pause state to true in case of emergency, triggered by an authorized account.
  function pause() external onlyPausingRoles {
    _pause();
  }

  /// @notice Sets the pause state to false when threat is gone, triggered by an authorized account.
  function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  function totalAssets() public view override returns (uint256) {
    return totalSupply();
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

  event MarketSet(Market indexed market, address indexed account);
  event ProviderRatioSet(uint256 providerRatio, address indexed account);
  event ProviderSet(address indexed provider, address indexed account);
  event RewardAmountNotified(ERC20 indexed reward, address indexed notifier, uint256 amount);
  event RewardDisabled(ERC20 indexed reward, address indexed account);
  event RewardPaid(ERC20 indexed reward, address indexed account, uint256 amount);
  event RewardListed(ERC20 indexed reward, address indexed account);
  event RewardsDurationSet(ERC20 indexed reward, address indexed account, uint256 duration);
  event SavingsSet(address indexed savings, address indexed account);
}

error AlreadyListed();
error InvalidRatio();
error InsufficientBalance();
error NotFinished();
error NotPausingRole();
error RewardNotListed();
error Untransferable();
error ZeroAddress();
error ZeroRate();
error ZeroAmount();

// TODO: optimize size
struct RewardData {
  uint256 duration;
  uint256 finishAt;
  uint256 index;
  uint256 rate;
  uint256 updatedAt;
}

struct ClaimableReward {
  address reward;
  string rewardName;
  string rewardSymbol;
  uint256 amount;
}
