// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { Market } from "./Market.sol";

/**
 * @title RewardsController
 * @notice Abstract contract template to build Distributors contracts for ERC20 rewards to protocol participants
 **/
contract RewardsController is AccessControl {
  using SafeTransferLib for ERC20;

  // Map of rewarded operations and their data
  mapping(Market => mapping(Operation => mapping(uint256 => MarketOperationData))) internal distributionData;
  // Map of reward assets
  mapping(address => bool) internal isRewardEnabled;
  // Rewards list
  address[] internal rewardList;
  // Map of operations by account
  mapping(address => OperationData[]) public accountOperations;

  constructor() {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }

  function handleOperation(Operation operation, address account, uint256 totalSupply, uint256 accountBalance) external {
    _updateData(Market(msg.sender), operation, 0, account, accountBalance, totalSupply);
  }

  function handleOperationAtMaturity(
    Operation operation,
    uint256 maturity,
    address account,
    uint256 totalSupply,
    uint256 accountBalance
  ) external {
    _updateData(Market(msg.sender), operation, maturity, account, accountBalance, totalSupply);
  }

  function claimRewards(address to) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    rewardsList = new address[](rewardList.length);
    claimedAmounts = new uint256[](rewardList.length);
    OperationData[] memory operations = accountOperations[msg.sender];

    _updateDataMultiple(msg.sender, getAccountOperationBalances(operations, msg.sender));

    for (uint256 i = 0; i < operations.length; i++) {
      for (uint256 j = 0; j < rewardList.length; j++) {
        if (rewardsList[j] == address(0)) {
          rewardsList[j] = rewardList[j];
        }
        uint256 rewardAmount = distributionData[operations[i].market][operations[i].operation][operations[i].maturity]
          .rewards[rewardsList[j]]
          .accountsData[msg.sender]
          .accrued;
        if (rewardAmount != 0) {
          claimedAmounts[j] += rewardAmount;
          distributionData[operations[i].market][operations[i].operation][operations[i].maturity]
            .rewards[rewardsList[j]]
            .accountsData[msg.sender]
            .accrued = 0;
        }
      }
    }
    for (uint256 i = 0; i < rewardList.length; i++) {
      ERC20(rewardsList[i]).safeTransfer(to, claimedAmounts[i]);
      emit RewardsClaimed(msg.sender, rewardsList[i], to, claimedAmounts[i]);
    }
    return (rewardsList, claimedAmounts);
  }

  function getRewardsData(
    Market market,
    Operation operation,
    uint256 maturity,
    address reward
  ) external view returns (uint256, uint256, uint256, uint256) {
    return (
      distributionData[market][operation][maturity].rewards[reward].index,
      distributionData[market][operation][maturity].rewards[reward].emissionPerSecond,
      distributionData[market][operation][maturity].rewards[reward].lastUpdateTimestamp,
      distributionData[market][operation][maturity].rewards[reward].distributionEnd
    );
  }

  function getOperationDecimals(Market market, Operation operation, uint256 maturity) external view returns (uint8) {
    return distributionData[market][operation][maturity].decimals;
  }

  function getOperationIndex(
    Market market,
    Operation operation,
    uint256 maturity,
    address reward
  ) external view returns (uint256, uint256) {
    RewardData storage rewardData = distributionData[market][operation][maturity].rewards[reward];
    return
      _getOperationIndex(
        rewardData,
        getTotalSupplyByOperation(market, operation, maturity),
        10 ** distributionData[market][operation][maturity].decimals
      );
  }

  function getDistributionEnd(
    Market market,
    Operation operation,
    uint256 maturity,
    address reward
  ) external view returns (uint256) {
    return distributionData[market][operation][maturity].rewards[reward].distributionEnd;
  }

  function getRewardsByOperation(
    Market market,
    Operation operation,
    uint256 maturity
  ) external view returns (address[] memory) {
    uint128 rewardsCount = distributionData[market][operation][maturity].availableRewardsCount;
    address[] memory availableRewards = new address[](rewardsCount);

    for (uint128 i = 0; i < rewardsCount; i++) {
      availableRewards[i] = distributionData[market][operation][maturity].availableRewards[i];
    }
    return availableRewards;
  }

  function getRewardsList() external view returns (address[] memory) {
    return rewardList;
  }

  function allAccountOperations(address account) external view returns (OperationData[] memory) {
    return accountOperations[account];
  }

  function getAccountOperationIndex(
    address account,
    Market market,
    Operation operation,
    uint256 maturity,
    address reward
  ) external view returns (uint256) {
    return distributionData[market][operation][maturity].rewards[reward].accountsData[account].index;
  }

  function getAccountAccruedRewards(address account, address reward) external view returns (uint256 totalAccrued) {
    OperationData[] memory operations = accountOperations[account];
    for (uint256 i = 0; i < operations.length; i++) {
      totalAccrued += distributionData[operations[i].market][operations[i].operation][operations[i].maturity]
        .rewards[reward]
        .accountsData[account]
        .accrued;
    }
  }

  function getAccountRewards(address account, address reward) external view returns (uint256 unclaimedRewards) {
    OperationData[] memory operations = accountOperations[account];
    AccountOperationBalance[] memory accountOperationBalances = getAccountOperationBalances(operations, account);
    for (uint256 i = 0; i < accountOperationBalances.length; i++) {
      if (accountOperationBalances[i].accountBalance == 0) {
        unclaimedRewards += distributionData[accountOperationBalances[i].market][accountOperationBalances[i].operation][
          accountOperationBalances[i].maturity
        ].rewards[reward].accountsData[account].accrued;
      } else {
        unclaimedRewards +=
          _getPendingRewards(account, reward, accountOperationBalances[i]) +
          distributionData[accountOperationBalances[i].market][accountOperationBalances[i].operation][
            accountOperationBalances[i].maturity
          ].rewards[reward].accountsData[account].accrued;
      }
    }
  }

  function getAllAccountRewards(
    OperationData[] calldata operations,
    address account
  ) external view returns (address[] memory rewardsList, uint256[] memory unclaimedAmounts) {
    AccountOperationBalance[] memory accountOperationBalances = getAccountOperationBalances(operations, account);
    rewardsList = new address[](rewardList.length);
    unclaimedAmounts = new uint256[](rewardsList.length);

    // Add unrealized rewards from account to unclaimedRewards
    for (uint256 i = 0; i < accountOperationBalances.length; i++) {
      for (uint256 r = 0; r < rewardsList.length; r++) {
        rewardsList[r] = rewardList[r];
        unclaimedAmounts[r] += distributionData[accountOperationBalances[i].market][
          accountOperationBalances[i].operation
        ][accountOperationBalances[i].maturity].rewards[rewardsList[r]].accountsData[account].accrued;

        if (accountOperationBalances[i].accountBalance == 0) {
          continue;
        }
        unclaimedAmounts[r] += _getPendingRewards(account, rewardsList[r], accountOperationBalances[i]);
      }
    }
    return (rewardsList, unclaimedAmounts);
  }

  function getTotalSupplyByOperation(
    Market market,
    Operation operation,
    uint256 maturity
  ) internal view returns (uint256 totalSupply) {
    if (operation == Operation.Deposit && maturity == 0) {
      totalSupply = market.totalSupply();
    } else if (operation == Operation.Borrow && maturity == 0) {
      totalSupply = market.totalFloatingBorrowShares();
    } else if (operation == Operation.Deposit) {
      (, totalSupply, , ) = market.fixedPools(maturity);
    } else if (operation == Operation.Borrow) {
      (totalSupply, , , ) = market.fixedPools(maturity);
    }
  }

  /**
   * @dev Updates the state of the distribution for the specified reward
   * @param rewardData Storage pointer to the distribution reward config
   * @param totalSupply Total balance of the operation's pool
   * @param assetUnit One unit of asset (10**decimals)
   * @return The new distribution index
   * @return True if the index was updated, false otherwise
   **/
  function _updateRewardData(
    RewardData storage rewardData,
    uint256 totalSupply,
    uint256 assetUnit
  ) internal returns (uint256, bool) {
    (uint256 oldIndex, uint256 newIndex) = _getOperationIndex(rewardData, totalSupply, assetUnit);
    bool indexUpdated;
    if (newIndex != oldIndex) {
      if (newIndex > type(uint104).max) revert IndexOverflow();
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
   * @dev Updates the state of the distribution for the specific account
   * @param rewardData Storage pointer to the distribution reward config
   * @param account The address of the account
   * @param accountBalance The account's balance in the operation's pool
   * @param newOperationIndex The new index of the operation distribution
   * @param assetUnit One unit of asset (10**decimals)
   * @return The rewards accrued since the last update
   **/
  function _updateAccountData(
    RewardData storage rewardData,
    address account,
    uint256 accountBalance,
    uint256 newOperationIndex,
    uint256 assetUnit
  ) internal returns (uint256, bool) {
    uint256 accountIndex = rewardData.accountsData[account].index;
    uint256 rewardsAccrued;
    bool dataUpdated;
    if ((dataUpdated = accountIndex != newOperationIndex)) {
      // already checked for overflow in _updateRewardData
      rewardData.accountsData[account].index = uint104(newOperationIndex);
      if (accountBalance != 0) {
        rewardsAccrued = _getRewards(accountBalance, newOperationIndex, accountIndex, assetUnit);

        rewardData.accountsData[account].accrued += uint128(rewardsAccrued);
      }
    }
    return (rewardsAccrued, dataUpdated);
  }

  /**
   * @dev Iterates and accrues all the rewards for the operations of the specific account
   * @param market The address of the reference Market of the distribution
   * @param account The account address
   * @param accountBalance The account's balance in the operation's pool
   * @param totalSupply Total balance of the operation's pool
   **/
  function _updateData(
    Market market,
    Operation operation,
    uint256 maturity,
    address account,
    uint256 accountBalance,
    uint256 totalSupply
  ) internal {
    uint256 assetUnit;
    unchecked {
      assetUnit = 10 ** distributionData[market][operation][maturity].decimals;
    }

    if (distributionData[market][operation][maturity].availableRewardsCount == 0) {
      return;
    }
    unchecked {
      for (uint128 r = 0; r < distributionData[market][operation][maturity].availableRewardsCount; r++) {
        address reward = distributionData[market][operation][maturity].availableRewards[r];
        RewardData storage rewardData = distributionData[market][operation][maturity].rewards[reward];

        (uint256 newOperationIndex, bool rewardDataUpdated) = _updateRewardData(rewardData, totalSupply, assetUnit);

        if (accountBalance == 0 && rewardData.accountsData[account].index == 0) {
          accountOperations[account].push(OperationData(market, operation, maturity));
        }
        (uint256 rewardsAccrued, bool accountDataUpdated) = _updateAccountData(
          rewardData,
          account,
          accountBalance,
          newOperationIndex,
          assetUnit
        );

        if (rewardDataUpdated || accountDataUpdated) {
          emit Accrued(market, reward, account, newOperationIndex, newOperationIndex, rewardsAccrued);
        }
      }
    }
  }

  /**
   * @dev Accrues all rewards of the operations specified in the accountOperationBalances list
   * @param account The address of the account
   * @param accountOperationBalances List of structs with the account balance and total supply of a set of operations
   **/
  function _updateDataMultiple(address account, AccountOperationBalance[] memory accountOperationBalances) internal {
    for (uint256 i = 0; i < accountOperationBalances.length; i++) {
      _updateData(
        accountOperationBalances[i].market,
        accountOperationBalances[i].operation,
        accountOperationBalances[i].maturity,
        account,
        accountOperationBalances[i].accountBalance,
        accountOperationBalances[i].totalSupply
      );
    }
  }

  /**
   * @dev Calculates the pending (not yet accrued) rewards since the last account action
   * @param account The address of the account
   * @param reward The address of the reward token
   * @param accountOperationBalance Struct with the account balance and total balance of the operation's pool
   * @return The pending rewards for the account since the last account action
   **/
  function _getPendingRewards(
    address account,
    address reward,
    AccountOperationBalance memory accountOperationBalance
  ) internal view returns (uint256) {
    RewardData storage rewardData = distributionData[accountOperationBalance.market][accountOperationBalance.operation][
      accountOperationBalance.maturity
    ].rewards[reward];
    uint256 assetUnit = 10 **
      distributionData[accountOperationBalance.market][accountOperationBalance.operation][
        accountOperationBalance.maturity
      ].decimals;
    (, uint256 nextIndex) = _getOperationIndex(rewardData, accountOperationBalance.totalSupply, assetUnit);

    return
      _getRewards(accountOperationBalance.accountBalance, nextIndex, rewardData.accountsData[account].index, assetUnit);
  }

  /**
   * @dev Internal function for the calculation of account's rewards on a distribution
   * @param accountBalance The account's balance in the operation's pool
   * @param reserveIndex Current index of the distribution
   * @param accountIndex Index stored for the account, representation his staking moment
   * @param assetUnit One unit of asset (10**decimals)
   * @return The rewards
   **/
  function _getRewards(
    uint256 accountBalance,
    uint256 reserveIndex,
    uint256 accountIndex,
    uint256 assetUnit
  ) internal pure returns (uint256) {
    uint256 result = accountBalance * (reserveIndex - accountIndex);
    assembly {
      result := div(result, assetUnit)
    }
    return result;
  }

  /**
   * @dev Calculates the next value of an specific distribution index, with validations
   * @param rewardData Storage pointer to the distribution reward config
   * @param totalSupply Total balance of the operation's pool
   * @param assetUnit One unit of asset (10**decimals)
   * @return The new index.
   **/
  function _getOperationIndex(
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

  /**
   * @dev Get account balances and total supply of all the operations specified by the markets and operations parameters
   * @param operations List of operations to retrieve account balance and total supply
   * @param account Address of the account
   * @return accountOperationBalances contains a list of structs with account balance and total amount of the
   * operation's pool
   */
  function getAccountOperationBalances(
    OperationData[] memory operations,
    address account
  ) internal view returns (AccountOperationBalance[] memory accountOperationBalances) {
    accountOperationBalances = new AccountOperationBalance[](operations.length);
    for (uint256 i = 0; i < operations.length; i++) {
      if (operations[i].operation == Operation.Deposit && operations[i].maturity == 0) {
        accountOperationBalances[i] = AccountOperationBalance({
          market: operations[i].market,
          operation: operations[i].operation,
          maturity: 0,
          accountBalance: operations[i].market.balanceOf(account),
          totalSupply: operations[i].market.totalSupply()
        });
      } else if (operations[i].operation == Operation.Borrow && operations[i].maturity == 0) {
        (, , uint256 floatingBorrowShares) = operations[i].market.accounts(account);
        accountOperationBalances[i] = AccountOperationBalance({
          market: operations[i].market,
          operation: operations[i].operation,
          maturity: 0,
          accountBalance: floatingBorrowShares,
          totalSupply: operations[i].market.totalFloatingBorrowShares()
        });
      } else if (operations[i].operation == Operation.Deposit) {
        (uint256 principal, ) = operations[i].market.fixedDepositPositions(operations[i].maturity, account);
        (, uint256 supplied, , ) = operations[i].market.fixedPools(operations[i].maturity);
        accountOperationBalances[i] = AccountOperationBalance({
          market: operations[i].market,
          operation: operations[i].operation,
          maturity: operations[i].maturity,
          accountBalance: principal,
          totalSupply: supplied
        });
      } else if (operations[i].operation == Operation.Borrow) {
        (uint256 principal, ) = operations[i].market.fixedBorrowPositions(operations[i].maturity, account);
        (uint256 borrowed, , , ) = operations[i].market.fixedPools(operations[i].maturity);
        accountOperationBalances[i] = AccountOperationBalance({
          market: operations[i].market,
          operation: operations[i].operation,
          maturity: operations[i].maturity,
          accountBalance: principal,
          totalSupply: borrowed
        });
      }
    }
  }

  function setDistributionOperations(RewardsConfigInput[] memory configs) external onlyRole(DEFAULT_ADMIN_ROLE) {
    for (uint256 i = 0; i < configs.length; i++) {
      configs[i].totalSupply = getTotalSupplyByOperation(configs[i].market, configs[i].operation, configs[i].maturity);
    }
    for (uint256 i = 0; i < configs.length; i++) {
      uint256 decimals = distributionData[configs[i].market][configs[i].operation][configs[i].maturity]
        .decimals = configs[i].market.decimals();

      RewardData storage rewardConfig = distributionData[configs[i].market][configs[i].operation][configs[i].maturity]
        .rewards[configs[i].reward];

      // Add reward address to distribution data's available rewards if latestUpdateTimestamp is zero
      if (rewardConfig.lastUpdateTimestamp == 0) {
        distributionData[configs[i].market][configs[i].operation][configs[i].maturity].availableRewards[
          distributionData[configs[i].market][configs[i].operation][configs[i].maturity].availableRewardsCount
        ] = configs[i].reward;
        distributionData[configs[i].market][configs[i].operation][configs[i].maturity].availableRewardsCount++;
      }

      // Add reward address to global rewards list if still not enabled
      if (isRewardEnabled[configs[i].reward] == false) {
        isRewardEnabled[configs[i].reward] = true;
        rewardList.push(configs[i].reward);
      }

      // Due emissions is still zero, updates only latestUpdateTimestamp
      (uint256 newIndex, ) = _updateRewardData(rewardConfig, configs[i].totalSupply, 10 ** decimals);

      // Configure emission and distribution end of the reward per operation
      uint88 oldEmissionsPerSecond = rewardConfig.emissionPerSecond;
      uint32 oldDistributionEnd = rewardConfig.distributionEnd;
      rewardConfig.emissionPerSecond = configs[i].emissionPerSecond;
      rewardConfig.distributionEnd = configs[i].distributionEnd;

      emit OperationConfigUpdated(
        configs[i].market,
        configs[i].reward,
        oldEmissionsPerSecond,
        configs[i].emissionPerSecond,
        oldDistributionEnd,
        configs[i].distributionEnd,
        newIndex
      );
    }
  }

  function setDistributionEnd(
    Market market,
    Operation operation,
    uint256 maturity,
    address reward,
    uint32 newDistributionEnd
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 oldDistributionEnd = distributionData[market][operation][maturity].rewards[reward].distributionEnd;
    distributionData[market][operation][maturity].rewards[reward].distributionEnd = newDistributionEnd;

    emit OperationConfigUpdated(
      market,
      reward,
      distributionData[market][operation][maturity].rewards[reward].emissionPerSecond,
      distributionData[market][operation][maturity].rewards[reward].emissionPerSecond,
      oldDistributionEnd,
      newDistributionEnd,
      distributionData[market][operation][maturity].rewards[reward].index
    );
  }

  function setEmissionPerSecond(
    Market market,
    Operation operation,
    uint256 maturity,
    address[] calldata rewards,
    uint88[] calldata newEmissionsPerSecond
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (rewards.length != newEmissionsPerSecond.length) revert InvalidInput();
    for (uint256 i = 0; i < rewards.length; i++) {
      MarketOperationData storage operationData = distributionData[market][operation][maturity];
      RewardData storage rewardConfig = distributionData[market][operation][maturity].rewards[rewards[i]];
      uint256 decimals = operationData.decimals;
      if (decimals == 0 || rewardConfig.lastUpdateTimestamp == 0) revert InvalidDistributionData();

      (uint256 newIndex, ) = _updateRewardData(
        rewardConfig,
        getTotalSupplyByOperation(market, operation, maturity),
        10 ** decimals
      );

      uint256 oldEmissionPerSecond = rewardConfig.emissionPerSecond;
      rewardConfig.emissionPerSecond = newEmissionsPerSecond[i];

      emit OperationConfigUpdated(
        market,
        rewards[i],
        oldEmissionPerSecond,
        newEmissionsPerSecond[i],
        rewardConfig.distributionEnd,
        rewardConfig.distributionEnd,
        newIndex
      );
    }
  }

  enum Operation {
    Deposit,
    Borrow
  }

  struct OperationData {
    Market market;
    Operation operation;
    uint256 maturity;
  }

  struct RewardsConfigInput {
    uint88 emissionPerSecond;
    uint256 totalSupply;
    uint32 distributionEnd;
    Market market;
    Operation operation;
    uint256 maturity;
    address reward;
  }

  struct AccountOperationBalance {
    Market market;
    Operation operation;
    uint256 maturity;
    uint256 accountBalance;
    uint256 totalSupply;
  }

  struct AccountData {
    // Liquidity index of the reward distribution for the account
    uint104 index;
    // Amount of accrued rewards for the account since last account index update
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
    // Map of account addresses and their rewards data (accountAddress => accountData)
    mapping(address => AccountData) accountsData;
  }

  struct MarketOperationData {
    // Map of reward token addresses and their data (rewardTokenAddress => rewardData)
    mapping(address => RewardData) rewards;
    // List of reward asset addresses for the operation
    mapping(uint128 => address) availableRewards;
    // Count of reward tokens for the operation
    uint128 availableRewardsCount;
    // Number of decimals of the operation's asset
    uint8 decimals;
  }

  event Accrued(
    Market indexed market,
    address indexed reward,
    address indexed account,
    uint256 operationIndex,
    uint256 accountIndex,
    uint256 rewardsAccrued
  );
  event OperationConfigUpdated(
    Market indexed market,
    address indexed reward,
    uint256 oldEmission,
    uint256 newEmission,
    uint256 oldDistributionEnd,
    uint256 newDistributionEnd,
    uint256 operationIndex
  );
  event RewardsClaimed(address indexed account, address indexed reward, address indexed to, uint256 amount);
}
error InvalidInput();
error InvalidDistributionData();
error IndexOverflow();
