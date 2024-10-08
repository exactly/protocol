// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Initializable } from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";
import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable-v4/utils/math/MathUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/access/AccessControlUpgradeable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { IPriceFeed } from "./utils/IPriceFeed.sol";
import { FixedLib } from "./utils/FixedLib.sol";
import { Market } from "./Market.sol";

contract RewardsController is Initializable, AccessControlUpgradeable {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint64;
  using FixedPointMathLib for int256;
  using SafeTransferLib for ERC20;

  /// @notice Max utilization supported by the sigmoid function not to cause a division by zero (1e18 = WAD).
  uint256 public constant UTILIZATION_CAP = 1e18 - 1;
  /// @notice Tracks the reward distribution data for a given market.
  mapping(Market => Distribution) public distribution;
  /// @notice Tracks enabled asset rewards.
  mapping(ERC20 => bool) public rewardEnabled;
  /// @notice Stores registered asset rewards.
  ERC20[] public rewardList;
  /// @notice Stores Markets with distributions set.
  Market[] public marketList;
  /// @notice Tracks the owner nonces for the claim permit.
  mapping(address => uint256) public nonces;
  /// @notice Temporarily stores the claim permit owner or `msg.sender` of the claim call.
  address private _claimSender;
  /// @notice Tracks the allowed `keeper` to claim on behalf of `account`.
  mapping(address account => address keeper) public keepers;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev Can only be called once.
  function initialize() external initializer {
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }

  /// @notice Hook to be called by the Market to update the index of the account that made a rewarded deposit.
  /// @dev There's no need to check that `msg.sender` is a valid Market as it won't have available rewards if it's not.
  /// @param account The account to which the index is updated.
  function handleDeposit(address account) external {
    Market market = Market(msg.sender);
    AccountOperation[] memory ops = new AccountOperation[](1);
    (uint256 fixedDeposits, ) = market.accountsFixedConsolidated(account);
    ops[0] = AccountOperation({
      operation: false,
      balance: market.balanceOf(account) + market.previewWithdraw(fixedDeposits)
    });

    Distribution storage dist = distribution[market];
    uint256 available = dist.availableRewardsCount;
    for (uint128 r = 0; r < available; ) {
      update(account, market, dist.availableRewards[r], ops);
      unchecked {
        ++r;
      }
    }
  }

  /// @notice Hook to be called by the Market to update the index of the account that made a rewarded borrow.
  /// @dev There's no need to check that `msg.sender` is a valid Market as it won't have available rewards if it's not.
  /// @param account The account to which the index is updated.
  function handleBorrow(address account) external {
    Market market = Market(msg.sender);
    AccountOperation[] memory ops = new AccountOperation[](1);
    (, , uint256 accountFloatingBorrowShares) = market.accounts(account);
    (, uint256 fixedBorrows) = market.accountsFixedConsolidated(account);
    ops[0] = AccountOperation({
      operation: true,
      balance: accountFloatingBorrowShares + market.previewRepay(fixedBorrows)
    });

    Distribution storage dist = distribution[market];
    uint256 available = dist.availableRewardsCount;
    for (uint128 r = 0; r < available; ) {
      update(account, Market(msg.sender), dist.availableRewards[r], ops);
      unchecked {
        ++r;
      }
    }
  }

  /// @notice Claims `account` rewards for the given operations and reward assets.
  /// @param marketOps The operations to claim rewards for.
  /// @param account The account to claim the rewards for.
  /// @param rewardsList The list of rewards assets to claim.
  /// @return rewardsList The list of rewards assets.
  /// @return claimedAmounts The list of claimed amounts.
  function claimOnBehalfOf(
    MarketOperation[] memory marketOps,
    address account,
    ERC20[] memory rewardsList
  ) external returns (ERC20[] memory, uint256[] memory) {
    if (keepers[account] != msg.sender) revert NotKeeper();
    return claim(marketOps, account, account, rewardsList);
  }

  /// @notice Claims all `msg.sender` rewards to the given account.
  /// @param to The address to send the rewards to.
  /// @return rewardsList The list of rewards assets.
  /// @return claimedAmounts The list of claimed amounts.
  function claimAll(address to) external returns (ERC20[] memory rewardsList, uint256[] memory claimedAmounts) {
    return claim(allMarketsOperations(), to, rewardList);
  }

  /// @notice Claims `msg.sender` rewards for the given operations and reward assets to the given account.
  /// @param marketOps The operations to claim rewards for.
  /// @param to The address to send the rewards to.
  /// @param rewardsList The list of rewards assets to claim.
  /// @return rewardsList The list of rewards assets.
  /// @return claimedAmounts The list of claimed amounts.
  function claim(
    MarketOperation[] memory marketOps,
    address to,
    ERC20[] memory rewardsList
  ) public claimSender returns (ERC20[] memory, uint256[] memory) {
    return claim(marketOps, _claimSender, to, rewardsList);
  }

  function claim(
    MarketOperation[] memory marketOps,
    address account,
    address to,
    ERC20[] memory rewardsList
  ) internal returns (ERC20[] memory, uint256[] memory claimedAmounts) {
    claimedAmounts = new uint256[](rewardsList.length);
    for (uint256 i = 0; i < marketOps.length; ) {
      MarketOperation memory marketOperation = marketOps[i];
      Distribution storage dist = distribution[marketOperation.market];
      AccountOperation[] memory accountBalanceOps = accountBalanceOperations(
        marketOperation.market,
        marketOperation.operations,
        account
      );
      for (uint128 r = 0; r < dist.availableRewardsCount; ) {
        update(account, marketOperation.market, dist.availableRewards[r], accountBalanceOps);
        unchecked {
          ++r;
        }
      }
      for (uint256 r = 0; r < rewardsList.length; ) {
        RewardData storage rewardData = dist.rewards[rewardsList[r]];
        for (uint256 o = 0; o < marketOperation.operations.length; ) {
          uint256 rewardAmount = rewardData.accounts[account][marketOperation.operations[o]].accrued;
          if (rewardAmount != 0) {
            claimedAmounts[r] += rewardAmount;
            rewardData.accounts[account][marketOperation.operations[o]].accrued = 0;
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
      uint256 claimedAmount = claimedAmounts[r];
      if (claimedAmount > 0) {
        rewardsList[r].safeTransfer(to, claimedAmount);
        emit Claim(account, rewardsList[r], to, claimedAmount);
      }
      unchecked {
        ++r;
      }
    }
    return (rewardsList, claimedAmounts);
  }

  /// @notice Claims `permit.owner` rewards for the given operations and reward assets to the given account.
  /// @param marketOps The operations to claim rewards for.
  /// @param permit Arguments and signature from `permit.owner`.
  /// @return rewardsList The list of rewards assets.
  /// @return claimedAmounts The list of claimed amounts.
  function claim(
    MarketOperation[] memory marketOps,
    ClaimPermit calldata permit
  ) external permitSender(permit) returns (ERC20[] memory, uint256[] memory claimedAmounts) {
    return claim(marketOps, msg.sender, permit.assets);
  }

  /// @notice Gets the configuration of a given distribution.
  /// @param market The market to get the distribution configuration for.
  /// @param reward The reward asset.
  /// @return The distribution configuration.
  function rewardConfig(Market market, ERC20 reward) external view returns (Config memory) {
    RewardData storage rewardData = distribution[market].rewards[reward];
    return
      Config({
        market: market,
        reward: reward,
        priceFeed: rewardData.priceFeed,
        start: rewardData.start,
        distributionPeriod: rewardData.end - rewardData.start,
        targetDebt: rewardData.targetDebt,
        totalDistribution: rewardData.totalDistribution,
        undistributedFactor: rewardData.undistributedFactor,
        flipSpeed: rewardData.flipSpeed,
        compensationFactor: rewardData.compensationFactor,
        transitionFactor: rewardData.transitionFactor,
        borrowAllocationWeightFactor: rewardData.borrowAllocationWeightFactor,
        depositAllocationWeightAddend: rewardData.depositAllocationWeightAddend,
        depositAllocationWeightFactor: rewardData.depositAllocationWeightFactor
      });
  }

  /// @notice Gets the amount of reward assets that are being distributed for a Market.
  /// @param market Market to get the number of available rewards to distribute.
  /// @return The amount reward assets set to a Market.
  function availableRewardsCount(Market market) external view returns (uint256) {
    return distribution[market].availableRewardsCount;
  }

  /// @notice Gets the account data of a given account, Market, operation and reward asset.
  /// @param account The account to get the operation data from.
  /// @param market The market in which the operation was made.
  /// @param operation True if the operation was a borrow, false if it was a deposit.
  /// @param reward The reward asset.
  /// @return accrued The accrued amount.
  /// @return index The account index.
  function accountOperation(
    address account,
    Market market,
    bool operation,
    ERC20 reward
  ) external view returns (uint256, uint256) {
    Account storage operationAccount = distribution[market].rewards[reward].accounts[account][operation];
    return (operationAccount.accrued, operationAccount.index);
  }

  /// @notice Gets the distribution `start`, `end` and `lastUpdate` value of a given market and reward.
  /// @param market The market to get the distribution times.
  /// @param reward The reward asset.
  /// @return The distribution `start`, `end` and `lastUpdate` time.
  function distributionTime(Market market, ERC20 reward) external view returns (uint32, uint32, uint32) {
    RewardData storage rewardData = distribution[market].rewards[reward];
    return (rewardData.start, rewardData.end, rewardData.lastUpdate);
  }

  /// @notice Retrieves all rewards addresses.
  function allRewards() external view returns (ERC20[] memory) {
    return rewardList;
  }

  /// @notice Gets all market and operations.
  /// @return marketOps The list of market operations.
  function allMarketsOperations() public view returns (MarketOperation[] memory marketOps) {
    Market[] memory markets = marketList;
    marketOps = new MarketOperation[](markets.length);
    for (uint256 m = 0; m < markets.length; ) {
      bool[] memory ops = new bool[](2);
      ops[0] = true;
      ops[1] = false;
      marketOps[m] = MarketOperation({ market: markets[m], operations: ops });
      unchecked {
        ++m;
      }
    }
  }

  /// @notice Gets the claimable amount of rewards for a given account and reward asset.
  /// @param account The account to get the claimable amount for.
  /// @param reward The reward asset.
  /// @return unclaimedRewards The claimable amount for the given account.
  function allClaimable(address account, ERC20 reward) external view returns (uint256 unclaimedRewards) {
    return claimable(allMarketsOperations(), account, reward);
  }

  /// @notice Gets the claimable amount of rewards for a given account, Market operations and reward asset.
  /// @param marketOps The list of Market operations to get the accrued and pending rewards from.
  /// @param account The account to get the claimable amount for.
  /// @param reward The reward asset.
  /// @return unclaimedRewards The claimable amount for the given account.
  function claimable(
    MarketOperation[] memory marketOps,
    address account,
    ERC20 reward
  ) public view returns (uint256 unclaimedRewards) {
    for (uint256 i = 0; i < marketOps.length; ) {
      MarketOperation memory marketOperation = marketOps[i];
      Distribution storage dist = distribution[marketOperation.market];
      RewardData storage rewardData = dist.rewards[reward];
      if (dist.availableRewardsCount == 0) {
        unchecked {
          ++i;
        }
        continue;
      }

      AccountOperation[] memory ops = accountBalanceOperations(
        marketOperation.market,
        marketOperation.operations,
        account
      );
      uint256 balance;
      for (uint256 o = 0; o < ops.length; ) {
        unclaimedRewards += rewardData.accounts[account][ops[o].operation].accrued;
        balance += ops[o].balance;
        unchecked {
          ++o;
        }
      }
      if (balance > 0) {
        unclaimedRewards += pendingRewards(
          account,
          reward,
          AccountMarketOperation({ market: marketOperation.market, accountOperations: ops })
        );
      }
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Iterates and accrues all rewards for the operations of the given account in the given market.
  /// @param account The account to accrue the rewards for.
  /// @param market The Market in which the operations where made.
  /// @param reward The reward asset.
  /// @param ops The operations to accrue the rewards for.
  function update(address account, Market market, ERC20 reward, AccountOperation[] memory ops) internal {
    uint256 baseUnit = distribution[market].baseUnit;
    RewardData storage rewardData = distribution[market].rewards[reward];
    {
      uint256 lastUpdate = rewardData.lastUpdate;
      // `lastUpdate` can be greater than `block.timestamp` if distribution is set to start on a future date
      if (block.timestamp > lastUpdate && (lastUpdate < rewardData.end || rewardData.lastUndistributed != 0)) {
        (uint256 borrowIndex, uint256 depositIndex, uint256 newUndistributed) = previewAllocation(
          rewardData,
          market,
          block.timestamp - lastUpdate
        );
        if (borrowIndex > type(uint128).max || depositIndex > type(uint128).max) revert IndexOverflow();
        rewardData.borrowIndex = uint128(borrowIndex);
        rewardData.depositIndex = uint128(depositIndex);
        rewardData.lastUpdate = uint32(block.timestamp);
        rewardData.lastUndistributed = newUndistributed;
        emit IndexUpdate(market, reward, borrowIndex, depositIndex, newUndistributed, block.timestamp);
      }
    }

    mapping(bool => Account) storage operationAccount = rewardData.accounts[account];
    for (uint256 i = 0; i < ops.length; ) {
      AccountOperation memory op = ops[i];
      Account storage accountData = operationAccount[op.operation];
      uint256 accountIndex = accountData.index;
      uint256 newAccountIndex;
      if (op.operation) {
        newAccountIndex = rewardData.borrowIndex;
      } else {
        newAccountIndex = rewardData.depositIndex;
      }
      if (accountIndex != newAccountIndex) {
        accountData.index = uint128(newAccountIndex);
        if (op.balance != 0) {
          uint256 rewardsAccrued = accountRewards(op.balance, newAccountIndex, accountIndex, baseUnit);
          accountData.accrued += uint128(rewardsAccrued);
          emit Accrue(market, reward, account, op.operation, accountIndex, newAccountIndex, rewardsAccrued);
        }
      }
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Gets the reward indexes and last amount of undistributed rewards for a given market and reward asset.
  /// @param market The market to get the reward indexes for.
  /// @param reward The reward asset to get the reward indexes for.
  /// @return borrowIndex The index for the floating and fixed borrow operation.
  /// @return depositIndex The index for the floating deposit operation.
  /// @return lastUndistributed The last amount of undistributed rewards.
  function rewardIndexes(Market market, ERC20 reward) external view returns (uint256, uint256, uint256) {
    RewardData storage rewardData = distribution[market].rewards[reward];
    return (rewardData.borrowIndex, rewardData.depositIndex, rewardData.lastUndistributed);
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
    uint256 baseUnit = distribution[ops.market].baseUnit;
    uint256 lastUpdate = rewardData.lastUpdate;
    (uint256 borrowIndex, uint256 depositIndex, ) = previewAllocation(
      rewardData,
      ops.market,
      block.timestamp > lastUpdate ? block.timestamp - lastUpdate : 0
    );
    mapping(bool => Account) storage operationAccount = rewardData.accounts[account];
    for (uint256 o = 0; o < ops.accountOperations.length; ) {
      uint256 nextIndex;
      if (ops.accountOperations[o].operation) {
        nextIndex = borrowIndex;
      } else {
        nextIndex = depositIndex;
      }

      rewards += accountRewards(
        ops.accountOperations[o].balance,
        nextIndex,
        operationAccount[ops.accountOperations[o].operation].index,
        baseUnit
      );
      unchecked {
        ++o;
      }
    }
  }

  /// @notice Calculates and returns the new amount of rewards given by the difference between the `accountIndex` and
  /// the `globalIndex`.
  /// @param balance The account's balance in the operation's pool.
  /// @param globalIndex Current index of the distribution.
  /// @param accountIndex Last index stored for the account.
  /// @param baseUnit One unit of the Market's asset (10**decimals).
  /// @return The amount of new rewards to be accrued by the account.
  function accountRewards(
    uint256 balance,
    uint256 globalIndex,
    uint256 accountIndex,
    uint256 baseUnit
  ) internal pure returns (uint256) {
    return balance.mulDivDown(globalIndex - accountIndex, baseUnit);
  }

  /// @notice Retrieves projected distribution indexes and new undistributed amount for a given `deltaTime`.
  /// @param market The market to calculate the indexes for.
  /// @param reward The reward asset to calculate the indexes for.
  /// @param deltaTime The elapsed time since the last update.
  /// @return borrowIndex The index for the borrow operation.
  /// @return depositIndex The index for the deposit operation.
  /// @return newUndistributed The new undistributed rewards of the distribution.
  function previewAllocation(
    Market market,
    ERC20 reward,
    uint256 deltaTime
  ) external view returns (uint256 borrowIndex, uint256 depositIndex, uint256 newUndistributed) {
    return previewAllocation(distribution[market].rewards[reward], market, deltaTime);
  }

  /// @notice Calculates and returns the distribution indexes and new undistributed tokens for a given `rewardData`.
  /// @param rewardData The distribution's data.
  /// @param market The market to calculate the indexes for.
  /// @param deltaTime The elapsed time since the last update.
  /// @return borrowIndex The index for the borrow operation.
  /// @return depositIndex The index for the deposit operation.
  /// @return newUndistributed The new undistributed rewards of the distribution.
  function previewAllocation(
    RewardData storage rewardData,
    Market market,
    uint256 deltaTime
  ) internal view returns (uint256 borrowIndex, uint256 depositIndex, uint256 newUndistributed) {
    TotalMarketBalance memory m;
    m.floatingDebt = market.floatingDebt();
    m.floatingAssets = market.floatingAssets();
    TimeVars memory t;
    t.start = rewardData.start;
    t.end = rewardData.end;
    {
      (uint256 fixedDeposits, uint256 fixedDebt) = market.fixedConsolidated();
      m.debt = m.floatingDebt + fixedDebt;
      m.fixedBorrowShares = market.previewRepay(fixedDebt);
      m.fixedDepositShares = market.previewWithdraw(fixedDeposits);
    }
    uint256 target;
    {
      uint256 targetDebt = rewardData.targetDebt;
      target = m.debt < targetDebt ? m.debt.divWadDown(targetDebt) : 1e18;
    }
    uint256 rewards;
    {
      uint256 releaseRate = rewardData.releaseRate;
      uint256 lastUndistributed = rewardData.lastUndistributed;
      t.period = t.end - t.start;
      uint256 distributionFactor = t.period > 0
        ? rewardData.undistributedFactor.mulDivDown(target, t.period * 1e18)
        : 0;
      if (block.timestamp <= t.end) {
        if (distributionFactor > 0) {
          uint256 exponential = uint256((-int256(distributionFactor * deltaTime)).expWad());
          newUndistributed =
            lastUndistributed.mulWadDown(exponential) +
            releaseRate.mulDivDown(1e18 - target, distributionFactor).mulWadUp(1e18 - exponential);
        } else {
          newUndistributed = lastUndistributed + releaseRate.mulWadDown(1e18 - target) * deltaTime;
        }
        rewards = uint256(int256(releaseRate * deltaTime) - (int256(newUndistributed) - int256(lastUndistributed)));
      } else if (rewardData.lastUpdate > t.end) {
        newUndistributed =
          lastUndistributed -
          lastUndistributed.mulWadUp(1e18 - uint256((-int256(distributionFactor * deltaTime)).expWad()));
        rewards = uint256(-(int256(newUndistributed) - int256(lastUndistributed)));
      } else {
        uint256 exponential;
        deltaTime = t.end - rewardData.lastUpdate;
        if (distributionFactor > 0) {
          exponential = uint256((-int256(distributionFactor * deltaTime)).expWad());
          newUndistributed =
            lastUndistributed.mulWadDown(exponential) +
            releaseRate.mulDivDown(1e18 - target, distributionFactor).mulWadUp(1e18 - exponential);
        } else {
          newUndistributed = lastUndistributed + releaseRate.mulWadDown(1e18 - target) * deltaTime;
        }
        exponential = uint256((-int256(distributionFactor * (block.timestamp - t.end))).expWad());
        newUndistributed = newUndistributed - newUndistributed.mulWadUp(1e18 - exponential);
        rewards = uint256(int256(releaseRate * deltaTime) - (int256(newUndistributed) - int256(lastUndistributed)));
      }
      if (rewards == 0) return (rewardData.borrowIndex, rewardData.depositIndex, newUndistributed);
    }
    {
      AllocationVars memory v;
      v.globalUtilization = Math.min(
        m.floatingAssets != 0
          ? 1e18 - (m.floatingAssets - m.floatingDebt - market.floatingBackupBorrowed()).divWadDown(m.floatingAssets)
          : 0,
        UTILIZATION_CAP
      );
      v.transitionFactor = rewardData.transitionFactor;
      v.flipSpeed = rewardData.flipSpeed;
      v.borrowAllocationWeightFactor = rewardData.borrowAllocationWeightFactor;
      v.sigmoid = v.globalUtilization > 0
        ? uint256(1e18).divWadDown(
          1e18 +
            uint256(
              (-(v.flipSpeed *
                (int256(v.globalUtilization.divWadDown(1e18 - v.globalUtilization)).lnWad() -
                  int256(v.transitionFactor.divWadDown(1e18 - v.transitionFactor)).lnWad())) / 1e18).expWad()
            )
        )
        : 0;
      v.borrowRewardRule = rewardData
        .compensationFactor
        .mulWadDown(
          market
            .interestRateModel()
            .floatingRate(m.floatingAssets != 0 ? m.floatingDebt.divWadDown(m.floatingAssets) : 0, v.globalUtilization)
            .mulWadDown(1e18 - v.globalUtilization.mulWadUp(1e18 - market.treasuryFeeRate())) +
            v.borrowAllocationWeightFactor
        )
        .mulWadDown(1e18 - v.sigmoid);
      v.depositRewardRule =
        rewardData.depositAllocationWeightAddend.mulWadDown(1e18 - v.sigmoid) +
        rewardData.depositAllocationWeightFactor.mulWadDown(v.sigmoid);
      v.borrowAllocation = v.borrowRewardRule.divWadDown(v.borrowRewardRule + v.depositRewardRule);
      v.depositAllocation = 1e18 - v.borrowAllocation;
      {
        uint256 totalDepositSupply = market.totalSupply() + m.fixedDepositShares;
        uint256 totalBorrowSupply = market.totalFloatingBorrowShares() + m.fixedBorrowShares;
        uint256 baseUnit = distribution[market].baseUnit;
        borrowIndex =
          rewardData.borrowIndex +
          (totalBorrowSupply > 0 ? rewards.mulWadDown(v.borrowAllocation).mulDivDown(baseUnit, totalBorrowSupply) : 0);
        depositIndex =
          rewardData.depositIndex +
          (
            totalDepositSupply > 0
              ? rewards.mulWadDown(v.depositAllocation).mulDivDown(baseUnit, totalDepositSupply)
              : 0
          );
      }
    }
  }

  /// @notice Get account balances of the given Market operations.
  /// @param market The address of the Market.
  /// @param ops List of operations to retrieve account balance.
  /// @param account Account to get the balance from.
  /// @return accountBalanceOps contains a list with account balance per each operation.
  function accountBalanceOperations(
    Market market,
    bool[] memory ops,
    address account
  ) internal view returns (AccountOperation[] memory accountBalanceOps) {
    accountBalanceOps = new AccountOperation[](ops.length);
    (uint256 fixedDeposits, uint256 fixedBorrows) = market.accountsFixedConsolidated(account);
    for (uint256 i = 0; i < ops.length; ) {
      if (ops[i]) {
        (, , uint256 floatingBorrowShares) = market.accounts(account);
        accountBalanceOps[i] = AccountOperation({
          operation: true,
          balance: floatingBorrowShares + market.previewRepay(fixedBorrows)
        });
      } else {
        accountBalanceOps[i] = AccountOperation({
          operation: false,
          balance: market.balanceOf(account) + market.previewWithdraw(fixedDeposits)
        });
      }
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Sets the `keeper` address for the given `account`.
  /// @param account The account to set the `keeper` for.
  /// @param keeper The address to set as the `keeper`.
  function setKeeper(address account, address keeper) external onlyRole(DEFAULT_ADMIN_ROLE) {
    keepers[account] = keeper;
  }

  /// @notice Withdraws the contract's balance of the given asset to the given address.
  /// @param asset The asset to withdraw.
  /// @param to The address to withdraw the asset to.
  function withdraw(ERC20 asset, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
    asset.safeTransfer(to, asset.balanceOf(address(this)));
  }

  /// @notice Enables or updates the reward distribution for the given markets and rewards.
  /// @param configs The configurations to update each RewardData with.
  function config(Config[] memory configs) external onlyRole(DEFAULT_ADMIN_ROLE) {
    for (uint256 i = 0; i < configs.length; ) {
      // transitionFactor cannot be eq or higher than 1e18 to avoid division by zero or underflow
      if (configs[i].transitionFactor >= 1e18) revert InvalidConfig();
      // depositAllocationWeightFactor cannot be zero to avoid division by zero when sigmoid equals 1e18
      if (configs[i].depositAllocationWeightFactor == 0) revert InvalidConfig();

      Distribution storage dist = distribution[configs[i].market];
      RewardData storage rewardData = dist.rewards[configs[i].reward];

      if (dist.baseUnit == 0) {
        // never initialized before, adding to the list of markets
        marketList.push(configs[i].market);
      }
      if (!rewardEnabled[configs[i].reward]) {
        // add reward address to global rewards list if still not enabled
        rewardEnabled[configs[i].reward] = true;
        rewardList.push(configs[i].reward);
      }
      if (rewardData.lastUpdate == 0) {
        // add reward address to distribution data's available rewards if distribution is new
        dist.availableRewards[dist.availableRewardsCount++] = configs[i].reward;
        dist.baseUnit = 10 ** configs[i].market.decimals();
        // set initial parameters if distribution is new
        rewardData.start = configs[i].start;
        rewardData.lastUpdate = configs[i].start;
        rewardData.releaseRate = configs[i].totalDistribution / configs[i].distributionPeriod;
      } else {
        uint32 start = rewardData.start;
        uint32 end = rewardData.end;
        // update global indexes before updating distribution values
        bool[] memory ops = new bool[](1);
        ops[0] = true;
        update(
          address(0),
          configs[i].market,
          configs[i].reward,
          accountBalanceOperations(configs[i].market, ops, address(0))
        );
        // properly update release rate
        if (block.timestamp < end) {
          uint256 released = 0;
          uint256 elapsed = 0;
          if (block.timestamp > start) {
            released =
              rewardData.lastConfigReleased +
              rewardData.releaseRate *
              (block.timestamp - Math.max(rewardData.lastConfig, start));
            elapsed = block.timestamp - start;
            if (configs[i].totalDistribution <= released || configs[i].distributionPeriod <= elapsed) {
              revert InvalidConfig();
            }
            rewardData.lastConfigReleased = released;
          }

          rewardData.releaseRate =
            (configs[i].totalDistribution - released) /
            (configs[i].distributionPeriod - elapsed);
        } else if (rewardData.start != configs[i].start) {
          rewardData.start = configs[i].start;
          rewardData.lastUpdate = configs[i].start;
          rewardData.releaseRate = configs[i].totalDistribution / configs[i].distributionPeriod;
          rewardData.lastConfigReleased = 0;
        }
      }
      rewardData.lastConfig = uint32(block.timestamp);
      rewardData.end = rewardData.start + uint32(configs[i].distributionPeriod);
      rewardData.priceFeed = configs[i].priceFeed;
      // set emission and distribution parameters
      rewardData.totalDistribution = configs[i].totalDistribution;
      rewardData.targetDebt = configs[i].targetDebt;
      rewardData.undistributedFactor = configs[i].undistributedFactor;
      rewardData.flipSpeed = configs[i].flipSpeed;
      rewardData.compensationFactor = configs[i].compensationFactor;
      rewardData.borrowAllocationWeightFactor = configs[i].borrowAllocationWeightFactor;
      rewardData.depositAllocationWeightAddend = configs[i].depositAllocationWeightAddend;
      rewardData.transitionFactor = configs[i].transitionFactor;
      rewardData.depositAllocationWeightFactor = configs[i].depositAllocationWeightFactor;

      emit DistributionSet(configs[i].market, configs[i].reward, configs[i]);
      unchecked {
        ++i;
      }
    }
  }

  // solhint-disable-next-line func-name-mixedcase
  function DOMAIN_SEPARATOR() public view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
          keccak256("RewardsController"),
          keccak256("1"),
          block.chainid,
          address(this)
        )
      );
  }

  modifier claimSender() {
    if (_claimSender == address(0)) _claimSender = msg.sender;
    _;
    delete _claimSender;
  }

  modifier permitSender(ClaimPermit calldata permit) {
    assert(_claimSender == address(0));
    assert(permit.deadline >= block.timestamp);
    unchecked {
      address recoveredAddress = ecrecover(
        keccak256(
          abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR(),
            keccak256(
              abi.encode(
                keccak256("ClaimPermit(address owner,address spender,address[] assets,uint256 deadline)"),
                permit.owner,
                msg.sender,
                permit.assets,
                nonces[permit.owner]++,
                permit.deadline
              )
            )
          )
        ),
        permit.v,
        permit.r,
        permit.s
      );
      assert(recoveredAddress != address(0) && recoveredAddress == permit.owner);
      _claimSender = permit.owner;
    }
    _;
    assert(_claimSender == address(0));
  }

  struct TotalMarketBalance {
    uint256 debt;
    uint256 fixedBorrowShares;
    uint256 fixedDepositShares;
    uint256 floatingDebt;
    uint256 floatingAssets;
  }

  struct TimeVars {
    uint256 start;
    uint256 end;
    uint256 period;
  }

  struct AllocationVars {
    uint256 globalUtilization;
    uint256 sigmoid;
    uint256 borrowRewardRule;
    uint256 depositRewardRule;
    uint256 borrowAllocation;
    uint256 depositAllocation;
    uint256 transitionFactor;
    int256 flipSpeed;
    uint256 borrowAllocationWeightFactor;
  }

  struct AccountOperation {
    bool operation;
    uint256 balance;
  }

  struct MarketOperation {
    Market market;
    bool[] operations;
  }

  struct AccountMarketOperation {
    Market market;
    AccountOperation[] accountOperations;
  }

  struct Account {
    // liquidity index of the reward distribution for the account
    uint128 index;
    // amount of accrued rewards for the account since last account index update
    uint128 accrued;
  }

  struct Config {
    Market market;
    ERC20 reward;
    IPriceFeed priceFeed;
    uint32 start;
    uint256 distributionPeriod;
    uint256 targetDebt;
    uint256 totalDistribution;
    uint256 undistributedFactor;
    int128 flipSpeed;
    uint64 compensationFactor;
    uint64 transitionFactor;
    uint64 borrowAllocationWeightFactor;
    uint64 depositAllocationWeightAddend;
    uint64 depositAllocationWeightFactor;
  }

  struct RewardData {
    // distribution model
    uint256 targetDebt;
    uint256 releaseRate;
    uint256 totalDistribution;
    uint256 undistributedFactor;
    uint256 lastUndistributed;
    // allocation model
    int128 flipSpeed;
    uint64 compensationFactor;
    uint64 transitionFactor;
    uint64 borrowAllocationWeightFactor;
    uint64 depositAllocationWeightAddend;
    uint64 depositAllocationWeightFactor;
    // liquidity indexes of the reward distribution
    uint128 borrowIndex;
    uint128 depositIndex;
    // distribution timestamps
    uint32 start;
    uint32 end;
    uint32 lastUpdate;
    // config helpers
    uint32 lastConfig;
    uint256 lastConfigReleased;
    // price feed
    IPriceFeed priceFeed;
    // account addresses and their rewards data (index & accrued)
    mapping(address => mapping(bool => Account)) accounts;
  }

  struct Distribution {
    // reward assets and their data
    mapping(ERC20 => RewardData) rewards;
    // list of reward asset addresses for the market
    mapping(uint128 => ERC20) availableRewards;
    // count of reward tokens for the market
    uint8 availableRewardsCount;
    // base unit of the market
    uint256 baseUnit;
  }

  /// @notice Emitted when rewards are accrued by an account.
  /// @param market Market where the operation was made.
  /// @param reward reward asset.
  /// @param account account that accrued the rewards.
  /// @param operation true if the operation was a borrow, false if it was a deposit.
  /// @param accountIndex previous account index.
  /// @param operationIndex new operation index that is assigned to the `accountIndex`.
  /// @param rewardsAccrued amount of rewards accrued.
  event Accrue(
    Market indexed market,
    ERC20 indexed reward,
    address indexed account,
    bool operation,
    uint256 accountIndex,
    uint256 operationIndex,
    uint256 rewardsAccrued
  );

  /// @notice Emitted when rewards are claimed by an account.
  /// @param account account that claimed the rewards.
  /// @param reward reward asset.
  /// @param to account that received the rewards.
  /// @param amount amount of rewards claimed.
  event Claim(address indexed account, ERC20 indexed reward, address indexed to, uint256 amount);

  /// @notice Emitted when a distribution is set.
  /// @param market Market whose distribution was set.
  /// @param reward reward asset to be distributed when operating with the Market.
  /// @param config configuration struct containing the distribution parameters.
  event DistributionSet(Market indexed market, ERC20 indexed reward, Config config);

  /// @notice Emitted when the distribution indexes are updated.
  /// @param market Market of the distribution.
  /// @param reward reward asset.
  /// @param borrowIndex index of the borrow operations of a distribution.
  /// @param depositIndex index of the deposit operations of a distribution.
  /// @param newUndistributed amount of undistributed rewards.
  /// @param lastUpdate current timestamp.
  event IndexUpdate(
    Market indexed market,
    ERC20 indexed reward,
    uint256 borrowIndex,
    uint256 depositIndex,
    uint256 newUndistributed,
    uint256 lastUpdate
  );
}

error IndexOverflow();
error InvalidConfig();
error NotKeeper();

struct ClaimPermit {
  address owner;
  ERC20[] assets;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}
