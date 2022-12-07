// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { Market } from "./Market.sol";

/**
 * @title RewardsController
 * @notice Abstract contract template to build Distributors contracts for ERC20 rewards to protocol participants
 **/
contract RewardsController {
  ERC20 public rewardsAsset;

  address internal manager;

  // Map of rewarded asset addresses and their data (assetAddress => marketOperationData)
  mapping(address => mapping(Operation => MarketOperationData)) internal _assets;
  // Map of reward assets (rewardAddress => enabled)
  mapping(address => bool) internal _isRewardEnabled;
  // Rewards list
  address[] internal _rewardsList;
  // Assets list
  address[] internal _assetsList;

  constructor() {
    manager = msg.sender;
  }

  modifier onlyEmissionManager() {
    require(msg.sender == manager, "RewardsController: only manager");
    _;
  }

  function getRewardsData(
    address asset,
    Operation operation,
    address reward
  ) public view returns (uint256, uint256, uint256, uint256) {
    return (
      _assets[asset][operation].rewards[reward].index,
      _assets[asset][operation].rewards[reward].emissionPerSecond,
      _assets[asset][operation].rewards[reward].lastUpdateTimestamp,
      _assets[asset][operation].rewards[reward].distributionEnd
    );
  }

  function getAssetIndex(address asset, Operation operation, address reward) external view returns (uint256, uint256) {
    RewardData storage rewardData = _assets[asset][operation].rewards[reward];
    return _getAssetIndex(rewardData, ERC20(asset).totalSupply(), 10 ** _assets[asset][operation].decimals);
  }

  function getDistributionEnd(address asset, Operation operation, address reward) external view returns (uint256) {
    return _assets[asset][operation].rewards[reward].distributionEnd;
  }

  function getRewardsByAsset(address asset, Operation operation) external view returns (address[] memory) {
    uint128 rewardsCount = _assets[asset][operation].availableRewardsCount;
    address[] memory availableRewards = new address[](rewardsCount);

    for (uint128 i = 0; i < rewardsCount; i++) {
      availableRewards[i] = _assets[asset][operation].availableRewards[i];
    }
    return availableRewards;
  }

  function getRewardsList() external view returns (address[] memory) {
    return _rewardsList;
  }

  function getUserAssetIndex(
    address user,
    address asset,
    Operation operation,
    address reward
  ) public view returns (uint256) {
    return _assets[asset][operation].rewards[reward].usersData[user].index;
  }

  function getUserAccruedRewards(address user, Operation operation, address reward) external view returns (uint256) {
    uint256 totalAccrued;
    for (uint256 i = 0; i < _assetsList.length; i++) {
      totalAccrued += _assets[_assetsList[i]][operation].rewards[reward].usersData[user].accrued;
    }

    return totalAccrued;
  }

  function getUserRewards(
    address[] calldata assets,
    Operation[] calldata operations,
    address user,
    address reward
  ) external view returns (uint256) {
    return _getUserReward(user, reward, _getUserAssetBalances(assets, operations, user));
  }

  function getAllUserRewards(
    address[] calldata assets,
    Operation[] calldata operations,
    address user
  ) external view returns (address[] memory rewardsList, uint256[] memory unclaimedAmounts) {
    UserAssetBalance[] memory userAssetBalances = _getUserAssetBalances(assets, operations, user);
    rewardsList = new address[](_rewardsList.length);
    unclaimedAmounts = new uint256[](rewardsList.length);

    // Add unrealized rewards from user to unclaimedRewards
    for (uint256 i = 0; i < userAssetBalances.length; i++) {
      for (uint256 r = 0; r < rewardsList.length; r++) {
        rewardsList[r] = _rewardsList[r];
        unclaimedAmounts[r] += _assets[userAssetBalances[i].asset][userAssetBalances[i].operation]
          .rewards[rewardsList[r]]
          .usersData[user]
          .accrued;

        if (userAssetBalances[i].userBalance == 0) {
          continue;
        }
        unclaimedAmounts[r] += _getPendingRewards(user, rewardsList[r], userAssetBalances[i]);
      }
    }
    return (rewardsList, unclaimedAmounts);
  }

  function setDistributionEnd(
    address asset,
    Operation operation,
    address reward,
    uint32 newDistributionEnd
  ) external onlyEmissionManager {
    uint256 oldDistributionEnd = _assets[asset][operation].rewards[reward].distributionEnd;
    _assets[asset][operation].rewards[reward].distributionEnd = newDistributionEnd;

    emit AssetConfigUpdated(
      asset,
      reward,
      _assets[asset][operation].rewards[reward].emissionPerSecond,
      _assets[asset][operation].rewards[reward].emissionPerSecond,
      oldDistributionEnd,
      newDistributionEnd,
      _assets[asset][operation].rewards[reward].index
    );
  }

  function setEmissionPerSecond(
    address asset,
    Operation operation,
    address[] calldata rewards,
    uint88[] calldata newEmissionsPerSecond
  ) external onlyEmissionManager {
    require(rewards.length == newEmissionsPerSecond.length, "INVALID_INPUT");
    for (uint256 i = 0; i < rewards.length; i++) {
      MarketOperationData storage assetConfig = _assets[asset][operation];
      RewardData storage rewardConfig = _assets[asset][operation].rewards[rewards[i]];
      uint256 decimals = assetConfig.decimals;
      require(decimals != 0 && rewardConfig.lastUpdateTimestamp != 0, "DISTRIBUTION_DOES_NOT_EXIST");

      (uint256 newIndex, ) = _updateRewardData(rewardConfig, ERC20(asset).totalSupply(), 10 ** decimals);

      uint256 oldEmissionPerSecond = rewardConfig.emissionPerSecond;
      rewardConfig.emissionPerSecond = newEmissionsPerSecond[i];

      emit AssetConfigUpdated(
        asset,
        rewards[i],
        oldEmissionPerSecond,
        newEmissionsPerSecond[i],
        rewardConfig.distributionEnd,
        rewardConfig.distributionEnd,
        newIndex
      );
    }
  }

  /**
   * @dev Configure the _assets for a specific emission
   * @param rewardsInput The array of each asset configuration
   **/
  function _configureAssets(RewardsConfigInput[] memory rewardsInput) internal {
    for (uint256 i = 0; i < rewardsInput.length; i++) {
      if (_assets[rewardsInput[i].asset][rewardsInput[i].operation].decimals == 0) {
        //never initialized before, adding to the list of assets
        _assetsList.push(rewardsInput[i].asset);
      }

      uint256 decimals = _assets[rewardsInput[i].asset][rewardsInput[i].operation].decimals = ERC20(
        rewardsInput[i].asset
      ).decimals();

      RewardData storage rewardConfig = _assets[rewardsInput[i].asset][rewardsInput[i].operation].rewards[
        rewardsInput[i].reward
      ];

      // Add reward address to asset available rewards if latestUpdateTimestamp is zero
      if (rewardConfig.lastUpdateTimestamp == 0) {
        _assets[rewardsInput[i].asset][rewardsInput[i].operation].availableRewards[
          _assets[rewardsInput[i].asset][rewardsInput[i].operation].availableRewardsCount
        ] = rewardsInput[i].reward;
        _assets[rewardsInput[i].asset][rewardsInput[i].operation].availableRewardsCount++;
      }

      // Add reward address to global rewards list if still not enabled
      if (_isRewardEnabled[rewardsInput[i].reward] == false) {
        _isRewardEnabled[rewardsInput[i].reward] = true;
        _rewardsList.push(rewardsInput[i].reward);
      }

      // Due emissions is still zero, updates only latestUpdateTimestamp
      (uint256 newIndex, ) = _updateRewardData(rewardConfig, rewardsInput[i].totalSupply, 10 ** decimals);

      // Configure emission and distribution end of the reward per asset
      uint88 oldEmissionsPerSecond = rewardConfig.emissionPerSecond;
      uint32 oldDistributionEnd = rewardConfig.distributionEnd;
      rewardConfig.emissionPerSecond = rewardsInput[i].emissionPerSecond;
      rewardConfig.distributionEnd = rewardsInput[i].distributionEnd;

      emit AssetConfigUpdated(
        rewardsInput[i].asset,
        rewardsInput[i].reward,
        oldEmissionsPerSecond,
        rewardsInput[i].emissionPerSecond,
        oldDistributionEnd,
        rewardsInput[i].distributionEnd,
        newIndex
      );
    }
  }

  /**
   * @dev Updates the state of the distribution for the specified reward
   * @param rewardData Storage pointer to the distribution reward config
   * @param totalSupply Current total of underlying assets for this distribution
   * @param assetUnit One unit of asset (10**decimals)
   * @return The new distribution index
   * @return True if the index was updated, false otherwise
   **/
  function _updateRewardData(
    RewardData storage rewardData,
    uint256 totalSupply,
    uint256 assetUnit
  ) internal returns (uint256, bool) {
    (uint256 oldIndex, uint256 newIndex) = _getAssetIndex(rewardData, totalSupply, assetUnit);
    bool indexUpdated;
    if (newIndex != oldIndex) {
      require(newIndex <= type(uint104).max, "INDEX_OVERFLOW");
      indexUpdated = true;

      //optimization: storing one after another saves one SSTORE
      rewardData.index = uint104(newIndex);
      rewardData.lastUpdateTimestamp = uint32(block.timestamp);
    } else {
      rewardData.lastUpdateTimestamp = uint32(block.timestamp);
    }

    return (newIndex, indexUpdated);
  }

  /**
   * @dev Updates the state of the distribution for the specific user
   * @param rewardData Storage pointer to the distribution reward config
   * @param user The address of the user
   * @param userBalance The user balance of the asset
   * @param newAssetIndex The new index of the asset distribution
   * @param assetUnit One unit of asset (10**decimals)
   * @return The rewards accrued since the last update
   **/
  function _updateUserData(
    RewardData storage rewardData,
    address user,
    uint256 userBalance,
    uint256 newAssetIndex,
    uint256 assetUnit
  ) internal returns (uint256, bool) {
    uint256 userIndex = rewardData.usersData[user].index;
    uint256 rewardsAccrued;
    bool dataUpdated;
    if ((dataUpdated = userIndex != newAssetIndex)) {
      // already checked for overflow in _updateRewardData
      rewardData.usersData[user].index = uint104(newAssetIndex);
      if (userBalance != 0) {
        rewardsAccrued = _getRewards(userBalance, newAssetIndex, userIndex, assetUnit);

        rewardData.usersData[user].accrued += uint128(rewardsAccrued);
      }
    }
    return (rewardsAccrued, dataUpdated);
  }

  /**
   * @dev Iterates and accrues all the rewards for asset of the specific user
   * @param asset The address of the reference asset of the distribution
   * @param user The user address
   * @param userBalance The current user asset balance
   * @param totalSupply Total supply of the asset
   **/
  function _updateData(
    address asset,
    Operation operation,
    address user,
    uint256 userBalance,
    uint256 totalSupply
  ) internal {
    uint256 assetUnit;
    uint256 numAvailableRewards = _assets[asset][operation].availableRewardsCount;
    unchecked {
      assetUnit = 10 ** _assets[asset][operation].decimals;
    }

    if (numAvailableRewards == 0) {
      return;
    }
    unchecked {
      for (uint128 r = 0; r < numAvailableRewards; r++) {
        address reward = _assets[asset][operation].availableRewards[r];
        RewardData storage rewardData = _assets[asset][operation].rewards[reward];

        (uint256 newAssetIndex, bool rewardDataUpdated) = _updateRewardData(rewardData, totalSupply, assetUnit);

        (uint256 rewardsAccrued, bool userDataUpdated) = _updateUserData(
          rewardData,
          user,
          userBalance,
          newAssetIndex,
          assetUnit
        );

        if (rewardDataUpdated || userDataUpdated) {
          emit Accrued(asset, reward, user, newAssetIndex, newAssetIndex, rewardsAccrued);
        }
      }
    }
  }

  /**
   * @dev Accrues all the rewards of the assets specified in the userAssetBalances list
   * @param user The address of the user
   * @param userAssetBalances List of structs with the user balance and total supply of a set of assets
   **/
  function _updateDataMultiple(address user, UserAssetBalance[] memory userAssetBalances) internal {
    for (uint256 i = 0; i < userAssetBalances.length; i++) {
      _updateData(
        userAssetBalances[i].asset,
        userAssetBalances[i].operation,
        user,
        userAssetBalances[i].userBalance,
        userAssetBalances[i].totalSupply
      );
    }
  }

  /**
   * @dev Return the accrued unclaimed amount of a reward from a user over a list of distribution
   * @param user The address of the user
   * @param reward The address of the reward token
   * @param userAssetBalances List of structs with the user balance and total supply of a set of assets
   * @return unclaimedRewards The accrued rewards for the user until the moment
   **/
  function _getUserReward(
    address user,
    address reward,
    UserAssetBalance[] memory userAssetBalances
  ) internal view returns (uint256 unclaimedRewards) {
    // Add unrealized rewards
    for (uint256 i = 0; i < userAssetBalances.length; i++) {
      if (userAssetBalances[i].userBalance == 0) {
        unclaimedRewards += _assets[userAssetBalances[i].asset][userAssetBalances[i].operation]
          .rewards[reward]
          .usersData[user]
          .accrued;
      } else {
        unclaimedRewards +=
          _getPendingRewards(user, reward, userAssetBalances[i]) +
          _assets[userAssetBalances[i].asset][userAssetBalances[i].operation].rewards[reward].usersData[user].accrued;
      }
    }

    return unclaimedRewards;
  }

  /**
   * @dev Calculates the pending (not yet accrued) rewards since the last user action
   * @param user The address of the user
   * @param reward The address of the reward token
   * @param userAssetBalance struct with the user balance and total supply of the incentivized asset
   * @return The pending rewards for the user since the last user action
   **/
  function _getPendingRewards(
    address user,
    address reward,
    UserAssetBalance memory userAssetBalance
  ) internal view returns (uint256) {
    RewardData storage rewardData = _assets[userAssetBalance.asset][userAssetBalance.operation].rewards[reward];
    uint256 assetUnit = 10 ** _assets[userAssetBalance.asset][userAssetBalance.operation].decimals;
    (, uint256 nextIndex) = _getAssetIndex(rewardData, userAssetBalance.totalSupply, assetUnit);

    return _getRewards(userAssetBalance.userBalance, nextIndex, rewardData.usersData[user].index, assetUnit);
  }

  /**
   * @dev Internal function for the calculation of user's rewards on a distribution
   * @param userBalance Balance of the user asset on a distribution
   * @param reserveIndex Current index of the distribution
   * @param userIndex Index stored for the user, representation his staking moment
   * @param assetUnit One unit of asset (10**decimals)
   * @return The rewards
   **/
  function _getRewards(
    uint256 userBalance,
    uint256 reserveIndex,
    uint256 userIndex,
    uint256 assetUnit
  ) internal pure returns (uint256) {
    uint256 result = userBalance * (reserveIndex - userIndex);
    assembly {
      result := div(result, assetUnit)
    }
    return result;
  }

  /**
   * @dev Calculates the next value of an specific distribution index, with validations
   * @param rewardData Storage pointer to the distribution reward config
   * @param totalSupply of the asset being rewarded
   * @param assetUnit One unit of asset (10**decimals)
   * @return The new index.
   **/
  function _getAssetIndex(
    RewardData storage rewardData,
    uint256 totalSupply,
    uint256 assetUnit
  ) internal view returns (uint256, uint256) {
    uint256 oldIndex = rewardData.index;
    uint256 distributionEnd = rewardData.distributionEnd;
    uint256 emissionPerSecond = rewardData.emissionPerSecond;
    uint256 lastUpdateTimestamp = rewardData.lastUpdateTimestamp;

    if (
      emissionPerSecond == 0 ||
      totalSupply == 0 ||
      lastUpdateTimestamp == block.timestamp ||
      lastUpdateTimestamp >= distributionEnd
    ) {
      return (oldIndex, oldIndex);
    }

    uint256 currentTimestamp = block.timestamp > distributionEnd ? distributionEnd : block.timestamp;
    uint256 timeDelta = currentTimestamp - lastUpdateTimestamp;
    uint256 firstTerm = emissionPerSecond * timeDelta * assetUnit;
    assembly {
      firstTerm := div(firstTerm, totalSupply)
    }
    return (oldIndex, (firstTerm + oldIndex));
  }

  function getAssetDecimals(address asset, Operation operation) external view returns (uint8) {
    return _assets[asset][operation].decimals;
  }

  function configureAssets(RewardsConfigInput[] memory config) external onlyEmissionManager {
    for (uint256 i = 0; i < config.length; i++) {
      config[i].totalSupply = ERC20(config[i].asset).totalSupply();
    }
    _configureAssets(config);
  }

  function handleAction(Operation operation, address user, uint256 totalSupply, uint256 userBalance) external {
    _updateData(msg.sender, operation, user, userBalance, totalSupply);
  }

  function claimAllRewards(
    address[] calldata assets,
    Operation[] calldata operations,
    address to
  ) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    require(to != address(0), "INVALID_TO_ADDRESS");
    return _claimAllRewards(assets, operations, msg.sender, msg.sender, to);
  }

  function claimAllRewardsToSelf(
    address[] calldata assets,
    Operation[] calldata operations
  ) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    return _claimAllRewards(assets, operations, msg.sender, msg.sender, msg.sender);
  }

  function _claimAllRewards(
    address[] calldata assets,
    Operation[] calldata operations,
    address claimer,
    address user,
    address to
  ) internal returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    uint256 rewardsListLength = _rewardsList.length;
    rewardsList = new address[](rewardsListLength);
    claimedAmounts = new uint256[](rewardsListLength);

    _updateDataMultiple(user, _getUserAssetBalances(assets, operations, user));

    for (uint256 i = 0; i < assets.length; i++) {
      address asset = assets[i];
      for (uint256 j = 0; j < rewardsListLength; j++) {
        for (uint256 k = 0; k < operations.length; k++) {
          if (rewardsList[j] == address(0)) {
            rewardsList[j] = _rewardsList[j];
          }
          uint256 rewardAmount = _assets[asset][operations[k]].rewards[rewardsList[j]].usersData[user].accrued;
          if (rewardAmount != 0) {
            claimedAmounts[j] += rewardAmount;
            _assets[asset][operations[k]].rewards[rewardsList[j]].usersData[user].accrued = 0;
          }
        }
      }
    }
    for (uint256 i = 0; i < rewardsListLength; i++) {
      _transferRewards(to, rewardsList[i], claimedAmounts[i]);
      emit RewardsClaimed(user, rewardsList[i], to, claimer, claimedAmounts[i]);
    }
    return (rewardsList, claimedAmounts);
  }

  /**
   * @dev Get user balances and total supply of all the assets specified by the assets parameter
   * @param assets List of assets to retrieve user balance and total supply
   * @param user Address of the user
   * @return userAssetBalances contains a list of structs with user balance and total supply of the given assets
   */
  function _getUserAssetBalances(
    address[] calldata assets,
    Operation[] calldata operations,
    address user
  ) internal view returns (UserAssetBalance[] memory userAssetBalances) {
    userAssetBalances = new UserAssetBalance[](assets.length * operations.length);
    for (uint256 i = 0; i < assets.length; i++) {
      for (uint256 j = 0; j < operations.length; j++) {
        if (operations[j] == Operation.FloatingDeposit) {
          userAssetBalances[i + j] = UserAssetBalance({
            asset: assets[i],
            operation: operations[j],
            userBalance: Market(assets[i]).balanceOf(user),
            totalSupply: Market(assets[i]).totalSupply()
          });
        } else if (operations[j] == Operation.FloatingBorrow) {
          (, , uint256 floatingBorrowShares) = Market(assets[i]).accounts(user);
          userAssetBalances[i + j] = UserAssetBalance({
            asset: assets[i],
            operation: operations[j],
            userBalance: floatingBorrowShares,
            totalSupply: Market(assets[i]).totalFloatingBorrowShares()
          });
        }
      }
    }
    return userAssetBalances;
  }

  /**
   * @dev Function to transfer rewards to the desired account using delegatecall and
   * @param to Account address to send the rewards
   * @param reward Address of the reward token
   * @param amount Amount of rewards to transfer
   */
  function _transferRewards(address to, address reward, uint256 amount) internal {
    bool success = ERC20(reward).transfer(to, amount);

    require(success == true, "TRANSFER_ERROR");
  }

  enum Operation {
    FloatingDeposit,
    FloatingBorrow,
    FixedDeposit,
    FixedBorrow
  }

  struct RewardsConfigInput {
    uint88 emissionPerSecond;
    uint256 totalSupply;
    uint32 distributionEnd;
    address asset;
    Operation operation;
    address reward;
  }

  struct UserAssetBalance {
    address asset;
    Operation operation;
    uint256 userBalance;
    uint256 totalSupply;
  }

  struct UserData {
    // Liquidity index of the reward distribution for the user
    uint104 index;
    // Amount of accrued rewards for the user since last user index update
    uint128 accrued;
  }

  struct RewardData {
    // Liquidity index of the reward distribution
    uint104 index;
    // Amount of reward tokens distributed per second
    uint88 emissionPerSecond;
    // Timestamp of the last reward index update
    uint32 lastUpdateTimestamp;
    // The end of the distribution of rewards (in seconds)
    uint32 distributionEnd;
    // Map of user addresses and their rewards data (userAddress => userData)
    mapping(address => UserData) usersData;
  }

  struct MarketOperationData {
    // Map of reward token addresses and their data (rewardTokenAddress => rewardData)
    mapping(address => RewardData) rewards;
    // List of reward token addresses for the asset
    mapping(uint128 => address) availableRewards;
    // Count of reward tokens for the asset
    uint128 availableRewardsCount;
    // Number of decimals of the asset
    uint8 decimals;
  }
  event Accrued(
    address indexed asset,
    address indexed reward,
    address indexed user,
    uint256 assetIndex,
    uint256 userIndex,
    uint256 rewardsAccrued
  );
  event AssetConfigUpdated(
    address indexed asset,
    address indexed reward,
    uint256 oldEmission,
    uint256 newEmission,
    uint256 oldDistributionEnd,
    uint256 newDistributionEnd,
    uint256 assetIndex
  );
  event RewardsClaimed(
    address indexed user,
    address indexed reward,
    address indexed to,
    address claimer,
    uint256 amount
  );
}
