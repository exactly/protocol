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

  /// @notice Rewards tokens
  IERC20[] public rewardsTokens;

  /// @notice Rewards data per token
  mapping(IERC20 reward => RewardData data) public rewards;

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
  mapping(address account => mapping(IERC20 reward => uint256 index)) public avgIndexes;
  mapping(address account => mapping(IERC20 reward => uint256 claimed)) public claimed;
  mapping(address account => mapping(IERC20 reward => uint256 saved)) public saved;

  Market public market;
  address public provider;
  address public savings;
  uint256 public providerRatio;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize(Parameters memory p) external initializer {
    __ERC20_init("staked EXA", "stEXA");
    __ERC4626_init(p.asset);
    __ERC20Permit_init("staked EXA");

    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setMinTime(p.minTime);
    setRefTime(p.refTime);
    setExcessFactor(p.excessFactor);
    setPenaltyGrowth(p.penaltyGrowth);
    setPenaltyThreshold(p.penaltyThreshold);

    market = p.market;

    IERC20 providerAsset = IERC20(address(p.market.asset()));
    enableReward(providerAsset);
    setRewardsDuration(providerAsset, p.duration);

    providerAsset.approve(address(market), type(uint256).max);

    setProvider(p.provider);
    setProviderRatio(p.providerRatio);
    setSavings(p.savings);
  }

  function updateIndex(IERC20 reward) internal {
    RewardData storage rewardData = rewards[reward];
    rewardData.index = globalIndex(reward);
    rewardData.updatedAt = uint40(lastTimeRewardApplicable(rewardData.finishAt));
  }

  function _update(address from, address to, uint256 amount) internal override whenNotPaused {
    if (amount == 0) revert ZeroAmount();
    if (from == address(0)) {
      uint256 start = avgStart[to];
      uint256 time = start != 0 ? block.timestamp * 1e18 - start : 0;
      uint256 memRefTime = refTime * 1e18;
      uint256 balance = balanceOf(to);
      uint256 total = amount + balance;

      for (uint256 i = 0; i < rewardsTokens.length; ++i) {
        IERC20 reward = rewardsTokens[i];
        updateIndex(reward);

        if (time > memRefTime) {
          if (balance != 0) claimWithdraw(reward, to, balance);
          avgIndexes[to][reward] = rewards[reward].index;
        } else {
          if (balance != 0) claim_(reward);
          uint256 numerator = avgIndexes[to][reward] * balance + rewards[reward].index * amount;
          avgIndexes[to][reward] = numerator == 0 ? 0 : (numerator - 1) / total + 1;
        }
      }
      if (time > memRefTime) avgStart[to] = block.timestamp * 1e18;
      else {
        uint256 numerator = start * balance + block.timestamp * 1e18 * amount;
        avgStart[to] = numerator == 0 ? 0 : (numerator - 1) / total + 1;
      }
      harvest();
    } else if (to == address(0)) {
      for (uint256 i = 0; i < rewardsTokens.length; ++i) {
        IERC20 reward = rewardsTokens[i];
        updateIndex(reward);
        claimWithdraw(reward, from, amount);
      }
    } else revert Untransferable();

    super._update(from, to, amount);
  }

  function permitAndDeposit(uint256 assets, address receiver, Permit calldata p) external returns (uint256) {
    IERC20Permit(asset()).permit(msg.sender, address(this), p.value, p.deadline, p.v, p.r, p.s);
    return deposit(assets, receiver);
  }

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
      reward.transfer(account, claimAmount);
      emit RewardPaid(reward, account, claimAmount);
    }

    uint256 rawEarned = earned(reward, account, amount);
    // due to rounding
    uint256 saveAmount = rawEarned <= claimableAmount + savedAmount ? 0 : rawEarned - claimableAmount - savedAmount;
    if (saveAmount != 0) reward.transfer(savings, saveAmount);
  }

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

  // NOTE time with 18 decimals
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

  modifier onlyReward(IERC20 reward) {
    if (rewards[reward].finishAt == 0) revert RewardNotListed();
    _;
  }

  function lastTimeRewardApplicable(uint256 finishAt) public view returns (uint256) {
    return uint40(Math.min(finishAt, block.timestamp));
  }

  function globalIndex(IERC20 reward) public view returns (uint256) {
    RewardData storage rewardData = rewards[reward];
    if (totalSupply() == 0) return rewardData.index;

    return
      rewardData.index +
      (rewardData.rate * (lastTimeRewardApplicable(rewardData.finishAt) - rewardData.updatedAt)).divWadDown(
        totalSupply()
      );
  }

  function avgIndex(IERC20 reward, address account) public view returns (uint256) {
    return avgIndexes[account][reward];
  }

  function earned(IERC20 reward, address account, uint256 shares) public view returns (uint256) {
    return shares.mulWadDown(globalIndex(reward) - avgIndexes[account][reward]);
  }

  function rawClaimable(IERC20 reward, address account, uint256 shares) public view returns (uint256) {
    uint256 start = avgStart[account];
    if (start == 0) return 0;
    return earned(reward, account, shares).mulWadDown(discountFactor(block.timestamp * 1e18 - start));
  }

  // NOTE - returns the amount of rewards that can be claimed by an account
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

  function harvest() public {
    Market memMarket = market;
    address memProvider = provider;
    uint256 assets = Math.min(
      memMarket.convertToAssets(memMarket.allowance(memProvider, address(this))),
      memMarket.maxWithdraw(memProvider)
    );
    uint256 amount = assets.mulWadDown(providerRatio);
    IERC20 providerAsset = IERC20(address(memMarket.asset()));
    uint256 duration = rewards[providerAsset].duration;
    if (duration == 0 || amount < rewards[providerAsset].duration) return;

    memMarket.withdraw(assets, address(this), memProvider);
    uint256 save = assets - amount;
    if (save != 0) memMarket.deposit(save, savings);

    notifyRewardAmount(providerAsset, amount, address(this));
  }

  function allRewardsTokens() external view returns (IERC20[] memory) {
    return rewardsTokens;
  }

  function claim_(IERC20 reward) internal {
    uint256 time = block.timestamp * 1e18 - avgStart[msg.sender];
    if (time <= minTime * 1e18) return;

    uint256 claimedAmount = claimed[msg.sender][reward];
    // due to excess exposure
    uint256 claimableAmount = Math.max(rawClaimable(reward, msg.sender, balanceOf(msg.sender)), claimedAmount);
    uint256 claimAmount = claimableAmount - claimedAmount;

    if (claimAmount != 0) claimed[msg.sender][reward] = claimedAmount + claimAmount;

    if (time > refTime * 1e18) {
      uint256 rawEarned = earned(reward, msg.sender, balanceOf(msg.sender));
      uint256 savedAmount = saved[msg.sender][reward];
      uint256 maxClaimed = Math.min(rawEarned, claimableAmount);
      uint256 saveAmount = rawEarned > maxClaimed + savedAmount ? rawEarned - maxClaimed - savedAmount : 0;

      if (saveAmount != 0) {
        saved[msg.sender][reward] = savedAmount + saveAmount;
        reward.transfer(savings, saveAmount);
      }
    }
    if (claimAmount != 0) {
      reward.transfer(msg.sender, claimAmount);
      emit RewardPaid(reward, msg.sender, claimAmount);
    }
  }

  function claim(IERC20 reward) external {
    claim_(reward);
  }

  function claimAll() external {
    for (uint256 i = 0; i < rewardsTokens.length; ++i) {
      claim_(rewardsTokens[i]);
    }
  }

  // restricted functions
  function enableReward(IERC20 reward) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (rewards[reward].finishAt != 0) revert AlreadyListed();

    rewards[reward].finishAt = uint40(block.timestamp);
    rewardsTokens.push(reward);

    emit RewardListed(reward, msg.sender);
  }

  function disableReward(IERC20 reward) public onlyRole(DEFAULT_ADMIN_ROLE) onlyReward(reward) {
    updateIndex(reward);

    if (block.timestamp < rewards[reward].finishAt) {
      uint256 finishAt = rewards[reward].finishAt;
      rewards[reward].finishAt = uint40(block.timestamp);
      reward.transfer(savings, (finishAt - block.timestamp) * rewards[reward].rate);
    }

    emit RewardDisabled(reward, msg.sender);
  }

  // notice - can only change the duration if the reward is finished
  function setRewardsDuration(IERC20 reward, uint40 duration) public onlyRole(DEFAULT_ADMIN_ROLE) {
    RewardData storage rewardData = rewards[reward];
    if (rewardData.finishAt > block.timestamp) revert NotFinished();

    rewardData.duration = duration;

    emit RewardsDurationSet(reward, msg.sender, duration);
  }

  function notifyRewardAmount(IERC20 reward, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
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

  function setMinTime(uint256 minTime_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    minTime = minTime_;
    emit MinTimeSet(minTime_, msg.sender);
  }

  function setRefTime(uint256 refTime_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (refTime_ < minTime || refTime_ == 0) revert InvalidRange();
    refTime = refTime_;
    emit RefTimeSet(refTime_, msg.sender);
  }

  function setExcessFactor(uint256 excessFactor_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (excessFactor_ > 1e18) revert InvalidRange();
    excessFactor = excessFactor_;
    emit ExcessFactorSet(excessFactor_, msg.sender);
  }
  function setPenaltyGrowth(uint256 penaltyGrowth_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (penaltyGrowth_ < 0.1e18 || penaltyGrowth_ > 100e18) revert InvalidRange();
    penaltyGrowth = penaltyGrowth_;
    emit PenaltyGrowthSet(penaltyGrowth_, msg.sender);
  }
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

  event ExcessFactorSet(uint256 excessFactor, address indexed account);
  event MarketSet(Market indexed market, address indexed account);
  event MinTimeSet(uint256 minTime, address indexed account);
  event PenaltyGrowthSet(uint256 penaltyGrowth, address indexed account);
  event PenaltyThresholdSet(uint256 penaltyThreshold, address indexed account);
  event ProviderRatioSet(uint256 providerRatio, address indexed account);
  event ProviderSet(address indexed provider, address indexed account);
  event RefTimeSet(uint256 refTime, address indexed account);
  event RewardAmountNotified(IERC20 indexed reward, address indexed notifier, uint256 amount);
  event RewardDisabled(IERC20 indexed reward, address indexed account);
  event RewardPaid(IERC20 indexed reward, address indexed account, uint256 amount);
  event RewardListed(IERC20 indexed reward, address indexed account);
  event RewardsDurationSet(IERC20 indexed reward, address indexed account, uint256 duration);
  event SavingsSet(address indexed savings, address indexed account);
}

error AlreadyListed();
error InsufficientBalance();
error InvalidRange();
error InvalidRatio();
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
