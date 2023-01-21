// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { FixedLib } from "./utils/FixedLib.sol";
import { Auditor } from "./Auditor.sol";
import { Market } from "./Market.sol";

contract RewardsController is Initializable, AccessControlUpgradeable {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;
  using SafeTransferLib for ERC20;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;
  /// @notice Tracks the reward distribution data for a given market.
  mapping(Market => Distribution) public distribution;
  /// @notice Tracks enabled asset rewards.
  mapping(ERC20 => bool) public rewardEnabled;
  /// @notice Stores registered asset rewards.
  ERC20[] public rewardList;

  /// @notice Tracks the operations for a given account on a given market.
  mapping(address => mapping(Market => Operation[])) public accountOperations;
  /// @notice Tracks enabled operations for a given account on a given market.
  mapping(address => mapping(Market => mapping(Operation => bool))) public accountOperationEnabled;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_) {
    auditor = auditor_;

    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev Can only be called once.
  function initialize() external initializer {
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }

  /// @notice Handles the deposit operation for a given account.
  /// @param account The account to handle the deposit operation for.
  function handleDeposit(address account) external {
    AccountOperation[] memory ops = new AccountOperation[](1);
    ops[0] = AccountOperation({ operation: Operation.Deposit, balance: Market(msg.sender).balanceOf(account) });
    update(account, Market(msg.sender), ops);
  }

  /// @notice Handles the borrow operation for a given account.
  /// @param account The account to handle the borrow operation for.
  function handleBorrow(address account) external {
    AccountOperation[] memory ops = new AccountOperation[](1);
    (, , uint256 accountFloatingBorrowShares) = Market(msg.sender).accounts(account);
    ops[0] = AccountOperation({
      operation: Operation.Borrow,
      balance: accountFloatingBorrowShares + accountFixedBorrowShares(Market(msg.sender), account)
    });
    update(account, Market(msg.sender), ops);
  }

  /// @notice Gets all account operations of msg.sender and transfers rewards to a given account.
  /// @param to The address to send the rewards to.
  /// @return rewardsList The list of rewards assets.
  /// @return claimedAmounts The list of claimed amounts.
  function claimAll(address to) external returns (ERC20[] memory rewardsList, uint256[] memory claimedAmounts) {
    return claim(allAccountOperations(msg.sender), to);
  }

  /// @notice Claims msg.sender's rewards for the given operations to a given account.
  /// @param operations The operations to claim rewards for.
  /// @param to The address to send the rewards to.
  /// @return rewardsList The list of rewards assets.
  /// @return claimedAmounts The list of claimed amounts.
  function claim(
    MarketOperation[] memory operations,
    address to
  ) public returns (ERC20[] memory rewardsList, uint256[] memory claimedAmounts) {
    rewardsList = new ERC20[](rewardList.length);
    claimedAmounts = new uint256[](rewardList.length);

    for (uint256 i = 0; i < operations.length; ) {
      update(
        msg.sender,
        operations[i].market,
        accountBalanceOperations(operations[i].market, operations[i].operations, msg.sender)
      );
      for (uint256 r = 0; r < rewardList.length; ) {
        if (address(rewardsList[r]) == address(0)) rewardsList[r] = rewardList[r];

        for (uint256 o = 0; o < operations[i].operations.length; ) {
          uint256 rewardAmount = distribution[operations[i].market]
          .rewards[rewardsList[r]]
          .accounts[msg.sender][operations[i].operations[o]].accrued;
          if (rewardAmount != 0) {
            claimedAmounts[r] += rewardAmount;
            distribution[operations[i].market]
            .rewards[rewardsList[r]]
            .accounts[msg.sender][operations[i].operations[o]].accrued = 0;
          }
          unchecked {
            ++o;
          }
        }
        unchecked {
          ++r;
        }
      }
      unchecked {
        ++i;
      }
    }
    for (uint256 r = 0; r < rewardsList.length; ) {
      rewardsList[r].safeTransfer(to, claimedAmounts[r]);
      emit Claim(msg.sender, rewardsList[r], to, claimedAmounts[r]);
      unchecked {
        ++r;
      }
    }
    return (rewardsList, claimedAmounts);
  }

  /// @notice Gets the data of the rewards' distribution model for a given market and reward asset.
  /// @param market The market to get the distribution model for.
  /// @param reward The reward asset to get the distribution model for.
  /// @return lastUpdate The last time the rewardsData was updated.
  /// @return targetDebt The target debt.
  /// @return mintingRate The minting rate.
  /// @return undistributedFactor The undistributed factor.
  /// @return lastUndistributed The last undistributed amount.
  function rewardsData(
    Market market,
    ERC20 reward
  ) external view returns (uint256, uint256, uint256, uint256, uint256) {
    return (
      distribution[market].rewards[reward].lastUpdate,
      distribution[market].rewards[reward].targetDebt,
      distribution[market].rewards[reward].mintingRate,
      distribution[market].rewards[reward].undistributedFactor,
      distribution[market].rewards[reward].lastUndistributed
    );
  }

  /// @notice Gets the data of the rewards' allocation model for a given market and reward asset.
  /// @param market The market to get the allocation model for.
  /// @param reward The reward asset to get the allocation model for.
  /// @return flipSpeed The flip speed.
  /// @return compensationFactor The compensation factor.
  /// @return transitionFactor The transition factor.
  /// @return borrowConstantReward The borrow constant reward.
  /// @return depositConstantReward The deposit constant reward.
  /// @return depositConstantRewardHighU The deposit constant reward for high utilization.
  function rewardAllocationParams(
    Market market,
    ERC20 reward
  ) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
    return (
      distribution[market].rewards[reward].flipSpeed,
      distribution[market].rewards[reward].compensationFactor,
      distribution[market].rewards[reward].transitionFactor,
      distribution[market].rewards[reward].borrowConstantReward,
      distribution[market].rewards[reward].depositConstantReward,
      distribution[market].rewards[reward].depositConstantRewardHighU
    );
  }

  /// @notice Gets the decimals of a given market.
  /// @param market The market to get the decimals for.
  /// @return decimals The decimals of the market.
  function decimals(Market market) external view returns (uint8) {
    return distribution[market].decimals;
  }

  /// @notice Gets the distribution start time of a given market.
  /// @param market The market to get the distribution start time for.
  /// @return The distribution start and end time.
  function distributionTime(Market market) external view returns (uint256, uint256) {
    return (distribution[market].start, distribution[market].end);
  }

  /// @notice Gets the amount of available rewards for a given market.
  /// @param market The market to get the available rewards for.
  /// @return availableRewardsCount The amount of available rewards.
  function availableRewardsCount(Market market) external view returns (uint256) {
    return distribution[market].availableRewardsCount;
  }

  /// @notice Gets all operations for a given account.
  /// @param account The account to get the operations for.
  /// @return marketOps The list of market operations.
  function allAccountOperations(address account) public view returns (MarketOperation[] memory marketOps) {
    Market[] memory marketList = auditor.allMarkets();
    marketOps = new MarketOperation[](marketList.length);
    for (uint256 i = 0; i < marketList.length; ) {
      Operation[] memory ops = accountOperations[account][marketList[i]];
      marketOps[i] = MarketOperation({ market: marketList[i], operations: ops });
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Gets the operation data for a given account, market, operation and reward asset.
  /// @param account The account to get the operation data for.
  /// @param market The market to get the operation data for.
  /// @param operation The operation to get the operation data for.
  /// @param reward The reward asset to get the operation data for.
  /// @return accrued The accrued amount.
  /// @return index The account index.
  function accountOperation(
    address account,
    Market market,
    Operation operation,
    ERC20 reward
  ) external view returns (uint256, uint256) {
    return (
      distribution[market].rewards[reward].accounts[account][operation].accrued,
      distribution[market].rewards[reward].accounts[account][operation].index
    );
  }

  /// @notice Gets the claimable amount of rewards for a given account and reward asset.
  /// @param account The account to get the claimable amount for.
  /// @param reward The reward asset to get the claimable amount for.
  /// @return unclaimedRewards The claimable amount for the given reward asset.
  function claimable(address account, ERC20 reward) external view returns (uint256 unclaimedRewards) {
    MarketOperation[] memory marketOps = allAccountOperations(account);
    for (uint256 i = 0; i < marketOps.length; ) {
      if (distribution[marketOps[i].market].availableRewardsCount == 0) {
        unchecked {
          ++i;
        }
        continue;
      }

      AccountOperation[] memory ops = accountBalanceOperations(marketOps[i].market, marketOps[i].operations, account);
      for (uint256 o = 0; o < ops.length; ) {
        unclaimedRewards += distribution[marketOps[i].market]
        .rewards[reward]
        .accounts[account][ops[o].operation].accrued;
        unchecked {
          ++o;
        }
      }
      unclaimedRewards += pendingRewards(
        account,
        reward,
        AccountMarketOperation({ market: marketOps[i].market, accountOperations: ops })
      );
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Iterates and accrues all the rewards for the operations of the given account in the given market.
  /// @param account The account to accrue the rewards for.
  /// @param market The market to accrue the rewards for.
  /// @param ops The operations to accrue the rewards for.
  function update(address account, Market market, AccountOperation[] memory ops) internal {
    uint256 baseUnit;
    unchecked {
      baseUnit = 10 ** distribution[market].decimals;
    }

    if (distribution[market].availableRewardsCount == 0) return;
    for (uint128 r = 0; r < distribution[market].availableRewardsCount; ) {
      ERC20 reward = distribution[market].availableRewards[r];
      RewardData storage rewardData = distribution[market].rewards[reward];
      {
        (uint256 borrowIndex, uint256 depositIndex, uint256 newUndistributed) = previewAllocation(rewardData, market);
        rewardData.lastUpdate = uint32(block.timestamp);
        rewardData.lastUndistributed = newUndistributed;
        rewardData.borrowIndex = borrowIndex;
        rewardData.depositIndex = depositIndex;
      }

      for (uint256 i = 0; i < ops.length; ) {
        uint256 accountIndex = rewardData.accounts[account][ops[i].operation].index;
        uint256 newAccountIndex;

        if (!accountOperationEnabled[account][market][ops[i].operation]) {
          accountOperations[account][market].push(ops[i].operation);
          accountOperationEnabled[account][market][ops[i].operation] = true;
        }
        if (ops[i].operation == Operation.Borrow) {
          newAccountIndex = rewardData.borrowIndex;
        } else {
          newAccountIndex = rewardData.depositIndex;
        }
        if (accountIndex != newAccountIndex) {
          rewardData.accounts[account][ops[i].operation].index = uint104(newAccountIndex);
          if (ops[i].balance != 0) {
            uint256 rewardsAccrued = accountRewards(ops[i].balance, newAccountIndex, accountIndex, baseUnit);
            rewardData.accounts[account][ops[i].operation].accrued += uint128(rewardsAccrued);
            emit Accrue(market, reward, account, newAccountIndex, newAccountIndex, rewardsAccrued);
          }
        }
        unchecked {
          ++i;
        }
      }
      unchecked {
        ++r;
      }
    }
  }

  function accountFixedBorrowShares(Market market, address account) internal view returns (uint256 fixedDebt) {
    uint256 start = distribution[market].start;
    uint256 firstMaturity = start - (start % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    uint256 maxMaturity = block.timestamp -
      (block.timestamp % FixedLib.INTERVAL) +
      (FixedLib.INTERVAL * market.maxFuturePools());

    for (uint256 maturity = firstMaturity; maturity <= maxMaturity; ) {
      (uint256 principal, ) = market.fixedBorrowPositions(maturity, account);
      fixedDebt += principal;
      unchecked {
        maturity += FixedLib.INTERVAL;
      }
    }
    fixedDebt = market.previewRepay(fixedDebt);
  }

  /// @notice Gets the reward indexes for a given market and reward asset.
  /// @param market The market to get the reward indexes for.
  /// @param reward The reward asset to get the reward indexes for.
  /// @return borrowIndex The index for the floating borrow operation.
  /// @return depositIndex The index for the floating deposit operation.
  function rewardIndexes(Market market, ERC20 reward) external view returns (uint256, uint256) {
    return (distribution[market].rewards[reward].borrowIndex, distribution[market].rewards[reward].depositIndex);
  }

  /// @notice Calculates the rewards not accrued yet for the given operations of a given account and reward asset.
  /// @param account The account to get the pending rewards for.
  /// @param reward The reward asset to get the pending rewards for.
  /// @param ops The operations to get the pending rewards for.
  /// @return rewards The pending rewards for the given operations.
  function pendingRewards(
    address account,
    ERC20 reward,
    AccountMarketOperation memory ops
  ) internal view returns (uint256 rewards) {
    RewardData storage rewardData = distribution[ops.market].rewards[reward];
    uint256 baseUnit;
    unchecked {
      baseUnit = 10 ** distribution[ops.market].decimals;
    }
    (uint256 borrowIndex, uint256 depositIndex, ) = previewAllocation(rewardData, ops.market);
    for (uint256 o = 0; o < ops.accountOperations.length; ) {
      uint256 nextIndex;
      if (ops.accountOperations[o].operation == Operation.Borrow) {
        nextIndex = borrowIndex;
      } else {
        nextIndex = depositIndex;
      }

      rewards += accountRewards(
        ops.accountOperations[o].balance,
        nextIndex,
        rewardData.accounts[account][ops.accountOperations[o].operation].index,
        baseUnit
      );
      unchecked {
        ++o;
      }
    }
  }

  /// @notice Internal function for the calculation of account's rewards on a distribution
  /// @param balance The account's balance in the operation's pool
  /// @param reserveIndex Current index of the distribution
  /// @param accountIndex Index stored for the account, representation his staking moment
  /// @param baseUnit One unit of the market's asset (10**decimals)
  /// @return The rewards
  function accountRewards(
    uint256 balance,
    uint256 reserveIndex,
    uint256 accountIndex,
    uint256 baseUnit
  ) internal pure returns (uint256) {
    return balance.mulDivDown(reserveIndex - accountIndex, baseUnit);
  }

  /// @notice Internal function for the calculation of the distribution's indexes.
  /// @param rewardData The distribution's data.
  /// @param market The market to calculate the indexes for.
  /// @return borrowIndex The index for the borrow operation.
  /// @return depositIndex The index for the deposit operation.
  /// @return newUndistributed The undistributed rewards for the distribution
  function previewAllocation(
    RewardData storage rewardData,
    Market market
  ) internal view returns (uint256 borrowIndex, uint256 depositIndex, uint256 newUndistributed) {
    TotalMarketBalance memory m;
    m.debt = market.totalFloatingBorrowAssets();
    m.supply = market.totalAssets();
    uint256 fixedBorrowShares;
    {
      uint256 start = distribution[market].start;
      uint256 firstMaturity = start - (start % FixedLib.INTERVAL) + FixedLib.INTERVAL;
      uint256 maxMaturity = block.timestamp -
        (block.timestamp % FixedLib.INTERVAL) +
        (FixedLib.INTERVAL * market.maxFuturePools());
      uint256 fixedDebt;
      for (uint256 maturity = firstMaturity; maturity <= maxMaturity; ) {
        (uint256 borrowed, uint256 supplied) = market.fixedPoolBalance(maturity);
        fixedDebt += borrowed;
        m.supply += supplied;
        unchecked {
          maturity += FixedLib.INTERVAL;
        }
      }
      m.debt += fixedDebt;
      fixedBorrowShares = market.previewRepay(fixedDebt);
    }
    uint256 target;
    {
      uint256 targetDebt = rewardData.targetDebt;
      target = m.debt < targetDebt ? m.debt.divWadDown(targetDebt) : 1e18;
    }
    uint256 distributionFactor = rewardData.undistributedFactor.mulWadDown(target);
    if (distributionFactor > 0) {
      uint256 rewards;
      {
        uint256 lastUndistributed = rewardData.lastUndistributed;
        if (block.timestamp <= distribution[market].end) {
          uint256 mintingRate = rewardData.mintingRate;
          uint256 deltaTime = block.timestamp - rewardData.lastUpdate;
          uint256 exponential = uint256((-int256(distributionFactor * deltaTime)).expWad());
          newUndistributed =
            lastUndistributed +
            mintingRate.mulWadDown(1e18 - target).divWadDown(distributionFactor).mulWadDown(1e18 - exponential) -
            lastUndistributed.mulWadDown(1e18 - exponential);
          rewards = rewardData.targetDebt.mulWadDown(
            uint256(int256(mintingRate * deltaTime) - (int256(newUndistributed) - int256(lastUndistributed)))
          );
        } else if (rewardData.lastUpdate > distribution[market].end) {
          newUndistributed =
            lastUndistributed -
            lastUndistributed.mulWadDown(
              1e18 - uint256((-int256(distributionFactor * (block.timestamp - rewardData.lastUpdate))).expWad())
            );
          rewards = rewardData.targetDebt.mulWadDown(uint256(-(int256(newUndistributed) - int256(lastUndistributed))));
        } else {
          uint256 mintingRate = rewardData.mintingRate;
          uint256 deltaTime = distribution[market].end - rewardData.lastUpdate;
          uint256 exponential = uint256((-int256(distributionFactor * deltaTime)).expWad());
          newUndistributed =
            lastUndistributed +
            mintingRate.mulWadDown(1e18 - target).divWadDown(distributionFactor).mulWadDown(1e18 - exponential) -
            lastUndistributed.mulWadDown(1e18 - exponential);
          exponential = uint256((-int256(distributionFactor * (block.timestamp - distribution[market].end))).expWad());
          newUndistributed = newUndistributed - newUndistributed.mulWadDown(1e18 - exponential);
          rewards = rewardData.targetDebt.mulWadDown(
            uint256(int256(mintingRate * deltaTime) - (int256(newUndistributed) - int256(lastUndistributed)))
          );
        }
      }
      {
        AllocationVars memory v;
        v.utilization = m.supply > 0 ? m.debt.divWadDown(m.supply) : 0;
        v.transitionFactor = rewardData.transitionFactor;
        v.flipSpeed = rewardData.flipSpeed;
        v.borrowConstantReward = rewardData.borrowConstantReward;
        v.sigmoid = v.utilization > 0
          ? uint256(1e18).divWadDown(
            1e18 +
              (
                v.transitionFactor.mulWadDown(1e18 - v.utilization).divWadDown(
                  v.utilization.mulWadDown(1e18 - v.transitionFactor)
                )
              ) **
                v.flipSpeed /
              1e18 ** (v.flipSpeed - 1)
          )
          : 0;
        v.borrowRewardRule = rewardData
          .compensationFactor
          .mulWadDown(
            market.interestRateModel().floatingRate(v.utilization).mulWadDown(
              1e18 - v.utilization.mulWadDown(1e18 - target)
            ) + v.borrowConstantReward
          )
          .mulWadDown(1e18 - v.sigmoid);
        v.depositRewardRule =
          rewardData.depositConstantReward.mulWadDown(1e18 - v.sigmoid) +
          rewardData.depositConstantRewardHighU.mulWadDown(v.borrowConstantReward).mulWadDown(v.sigmoid);
        v.borrowAllocation = v.borrowRewardRule.divWadDown(v.borrowRewardRule + v.depositRewardRule);
        v.depositAllocation = 1e18 - v.borrowAllocation;
        {
          uint256 totalDepositSupply = market.totalSupply();
          uint256 totalBorrowSupply = market.totalFloatingBorrowShares() + fixedBorrowShares;
          uint256 baseUnit;
          unchecked {
            baseUnit = 10 ** distribution[market].decimals;
          }
          borrowIndex =
            rewardData.borrowIndex +
            (
              totalBorrowSupply > 0 ? rewards.mulWadDown(v.borrowAllocation).mulDivDown(baseUnit, totalBorrowSupply) : 0
            );
          depositIndex =
            rewardData.depositIndex +
            (
              totalDepositSupply > 0
                ? rewards.mulWadDown(v.depositAllocation).mulDivDown(baseUnit, totalDepositSupply)
                : 0
            );
        }
      }
    } else {
      borrowIndex = rewardData.borrowIndex;
      depositIndex = rewardData.depositIndex;
      newUndistributed = rewardData.lastUndistributed;
    }
  }

  /// @notice Get account balances and total supply of all the operations specified by the markets and operations
  /// parameters
  /// @param market The address of the market
  /// @param ops List of operations to retrieve account balance and total supply
  /// @param account Address of the account
  /// @return accountMaturityOps contains a list of structs with account balance and total amount of the
  /// operation's pool
  function accountBalanceOperations(
    Market market,
    Operation[] memory ops,
    address account
  ) internal view returns (AccountOperation[] memory accountMaturityOps) {
    accountMaturityOps = new AccountOperation[](ops.length);
    for (uint256 i = 0; i < ops.length; ) {
      if (ops[i] == Operation.Borrow) {
        (, , uint256 floatingBorrowShares) = market.accounts(account);
        accountMaturityOps[i] = AccountOperation({
          operation: ops[i],
          balance: floatingBorrowShares + accountFixedBorrowShares(market, account)
        });
      } else {
        accountMaturityOps[i] = AccountOperation({ operation: ops[i], balance: market.balanceOf(account) });
      }
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Updates the RewardData with the given configs
  /// @param configs The config to update the RewardData with
  function config(Config[] memory configs) external onlyRole(DEFAULT_ADMIN_ROLE) {
    for (uint256 i = 0; i < configs.length; ) {
      RewardData storage rewardConfig = distribution[configs[i].market].rewards[configs[i].reward];

      // Add reward address to distribution data's available rewards if latestUpdateTimestamp is zero
      if (rewardConfig.lastUpdate == 0) {
        distribution[configs[i].market].availableRewards[
          distribution[configs[i].market].availableRewardsCount
        ] = configs[i].reward;
        distribution[configs[i].market].availableRewardsCount++;
        distribution[configs[i].market].decimals = configs[i].market.decimals();
        rewardConfig.lastUpdate = uint32(block.timestamp);
      }
      if (distribution[configs[i].market].start == 0) {
        distribution[configs[i].market].start = uint32(block.timestamp);
      }
      distribution[configs[i].market].end = uint32(block.timestamp + configs[i].distributionPeriod);

      // Add reward address to global rewards list if still not enabled
      if (rewardEnabled[configs[i].reward] == false) {
        rewardEnabled[configs[i].reward] = true;
        rewardList.push(configs[i].reward);
      }

      // Configure emission and distribution end of the reward per operation
      rewardConfig.targetDebt = configs[i].targetDebt;
      rewardConfig.undistributedFactor = configs[i].undistributedFactor;
      rewardConfig.flipSpeed = configs[i].flipSpeed;
      rewardConfig.compensationFactor = configs[i].compensationFactor;
      rewardConfig.transitionFactor = configs[i].transitionFactor;
      rewardConfig.borrowConstantReward = configs[i].borrowConstantReward;
      rewardConfig.depositConstantReward = configs[i].depositConstantReward;
      rewardConfig.depositConstantRewardHighU = configs[i].depositConstantRewardHighU;
      rewardConfig.mintingRate = configs[i].totalDistribution.divWadDown(configs[i].targetDebt).mulWadDown(
        1e18 / configs[i].distributionPeriod
      );

      emit DistributionSet(configs[i].market, configs[i].reward, 0);
      unchecked {
        ++i;
      }
    }
  }

  enum Operation {
    Borrow,
    Deposit
  }

  struct TotalMarketBalance {
    uint256 debt;
    uint256 supply;
  }

  struct AllocationVars {
    uint256 utilization;
    uint256 sigmoid;
    uint256 borrowRewardRule;
    uint256 depositRewardRule;
    uint256 borrowAllocation;
    uint256 depositAllocation;
    uint256 transitionFactor;
    uint256 flipSpeed;
    uint256 borrowConstantReward;
  }

  struct AccountOperation {
    Operation operation;
    uint256 balance;
  }

  struct MarketOperation {
    Market market;
    Operation[] operations;
  }

  struct AccountMarketOperation {
    Market market;
    AccountOperation[] accountOperations;
  }

  struct Account {
    // Liquidity index of the reward distribution for the account
    uint104 index;
    // Amount of accrued rewards for the account since last account index update
    uint128 accrued;
  }

  struct Config {
    Market market;
    ERC20 reward;
    uint256 targetDebt;
    uint256 totalDistribution;
    uint256 distributionPeriod;
    uint256 undistributedFactor;
    uint256 flipSpeed;
    uint256 compensationFactor;
    uint256 transitionFactor;
    uint256 borrowConstantReward;
    uint256 depositConstantReward;
    uint256 depositConstantRewardHighU;
  }

  struct RewardData {
    // distribution model
    uint256 targetDebt;
    uint256 mintingRate;
    uint256 undistributedFactor;
    uint256 lastUndistributed;
    uint32 lastUpdate;
    // allocation model
    uint256 flipSpeed;
    uint256 compensationFactor;
    uint256 transitionFactor;
    uint256 borrowConstantReward;
    uint256 depositConstantReward;
    uint256 depositConstantRewardHighU;
    // Liquidity index of the reward distribution
    uint256 borrowIndex;
    uint256 depositIndex;
    // Map of account addresses and their rewards data (accountAddress => accounts)
    mapping(address => mapping(Operation => Account)) accounts;
  }

  struct Distribution {
    // Map of reward token addresses and their data (rewardTokenAddress => rewardData)
    mapping(ERC20 => RewardData) rewards;
    // List of reward asset addresses for the operation
    mapping(uint128 => ERC20) availableRewards;
    // Count of reward tokens for the operation
    uint128 availableRewardsCount;
    // Number of decimals of the operation's asset
    uint8 decimals;
    uint32 start;
    uint32 end;
  }

  event Accrue(
    Market indexed market,
    ERC20 indexed reward,
    address indexed account,
    uint256 operationIndex,
    uint256 accountIndex,
    uint256 rewardsAccrued
  );
  event Claim(address indexed account, ERC20 indexed reward, address indexed to, uint256 amount);
  event DistributionSet(Market indexed market, ERC20 indexed reward, uint256 operationIndex);
}
