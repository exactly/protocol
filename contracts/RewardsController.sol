// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { IPriceFeed } from "./utils/IPriceFeed.sol";
import { FixedLib } from "./utils/FixedLib.sol";
import { Auditor } from "./Auditor.sol";
import { Market } from "./Market.sol";

contract RewardsController is Initializable, AccessControlUpgradeable {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint64;
  using FixedPointMathLib for int256;
  using SafeTransferLib for ERC20;

  /// @notice Tracks the reward distribution data for a given market.
  mapping(Market => Distribution) public distribution;
  /// @notice Tracks enabled asset rewards.
  mapping(ERC20 => bool) public rewardEnabled;
  /// @notice Stores registered asset rewards.
  ERC20[] public rewardList;
  /// @notice Stores Markets with distributions set.
  Market[] public marketList;

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

  /// @notice Handles the deposit operation for a given account.
  /// @param account The account to handle the deposit operation for.
  function handleDeposit(address account) external {
    Market market = Market(msg.sender);
    AccountOperation[] memory ops = new AccountOperation[](1);
    ops[0] = AccountOperation({ operation: false, balance: market.balanceOf(account) });

    uint256 rewardsCount = distribution[market].availableRewardsCount;
    for (uint128 r = 0; r < rewardsCount; ) {
      update(account, market, distribution[market].availableRewards[r], ops);
      unchecked {
        ++r;
      }
    }
  }

  /// @notice Handles the borrow operation for a given account.
  /// @param account The account to handle the borrow operation for.
  function handleBorrow(address account) external {
    Market market = Market(msg.sender);
    AccountOperation[] memory ops = new AccountOperation[](1);
    (, , uint256 accountFloatingBorrowShares) = market.accounts(account);

    uint256 rewardsCount = distribution[market].availableRewardsCount;
    for (uint128 r = 0; r < rewardsCount; ) {
      ERC20 reward = distribution[market].availableRewards[r];
      ops[0] = AccountOperation({
        operation: true,
        balance: accountFloatingBorrowShares +
          accountFixedBorrowShares(market, account, distribution[market].rewards[reward].start)
      });
      update(account, Market(msg.sender), reward, ops);
      unchecked {
        ++r;
      }
    }
  }

  /// @notice Gets all account operations of msg.sender and transfers rewards to a given account.
  /// @param to The address to send the rewards to.
  /// @return rewardsList The list of rewards assets.
  /// @return claimedAmounts The list of claimed amounts.
  function claimAll(address to) external returns (ERC20[] memory rewardsList, uint256[] memory claimedAmounts) {
    return claim(allMarketsOperations(), to, rewardList);
  }

  /// @notice Claims msg.sender's specified rewards for the given operations to a given account.
  /// @param marketOps The operations to claim rewards for.
  /// @param to The address to send the rewards to.
  /// @param rewardsList The list of rewards assets to claim.
  /// @return rewardsList The list of rewards assets.
  /// @return claimedAmounts The list of claimed amounts.
  function claim(
    MarketOperation[] memory marketOps,
    address to,
    ERC20[] memory rewardsList
  ) public returns (ERC20[] memory, uint256[] memory claimedAmounts) {
    uint256 rewardsCount = rewardsList.length;
    claimedAmounts = new uint256[](rewardsCount);
    for (uint256 i = 0; i < marketOps.length; ) {
      Distribution storage dist = distribution[marketOps[i].market];
      for (uint128 r = 0; r < dist.availableRewardsCount; ) {
        update(
          msg.sender,
          marketOps[i].market,
          dist.availableRewards[r],
          accountBalanceOperations(
            marketOps[i].market,
            marketOps[i].operations,
            msg.sender,
            dist.rewards[dist.availableRewards[r]].start
          )
        );
        unchecked {
          ++r;
        }
      }
      for (uint256 r = 0; r < rewardsCount; ) {
        for (uint256 o = 0; o < marketOps[i].operations.length; ) {
          uint256 rewardAmount = dist.rewards[rewardsList[r]].accounts[msg.sender][marketOps[i].operations[o]].accrued;
          if (rewardAmount != 0) {
            claimedAmounts[r] += rewardAmount;
            dist.rewards[rewardsList[r]].accounts[msg.sender][marketOps[i].operations[o]].accrued = 0;
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
      if (claimedAmounts[r] > 0) {
        rewardsList[r].safeTransfer(to, claimedAmounts[r]);
        emit Claim(msg.sender, rewardsList[r], to, claimedAmounts[r]);
      }
      unchecked {
        ++r;
      }
    }
    return (rewardsList, claimedAmounts);
  }

  /// @notice Gets the configuration of a given distribution.
  /// @param market The market to get the distribution configuration for.
  /// @param reward The reward asset to get the distribution configuration for.
  /// @return The distribution configuration.
  function rewardConfig(Market market, ERC20 reward) external view returns (Config memory) {
    RewardData storage rewardData = distribution[market].rewards[reward];
    return
      Config({
        market: market,
        reward: reward,
        priceFeed: rewardData.priceFeed,
        targetDebt: rewardData.targetDebt,
        totalDistribution: rewardData.totalDistribution,
        distributionPeriod: rewardData.end - rewardData.start,
        undistributedFactor: rewardData.undistributedFactor,
        flipSpeed: rewardData.flipSpeed,
        compensationFactor: rewardData.compensationFactor,
        transitionFactor: rewardData.transitionFactor,
        borrowAllocationWeightFactor: rewardData.borrowAllocationWeightFactor,
        depositAllocationWeightAddend: rewardData.depositAllocationWeightAddend,
        depositAllocationWeightFactor: rewardData.depositAllocationWeightFactor
      });
  }

  /// @notice Gets the amount of available rewards for a given market.
  /// @param market The market to get the available rewards for.
  /// @return availableRewardsCount The amount of available rewards.
  function availableRewardsCount(Market market) external view returns (uint256) {
    return distribution[market].availableRewardsCount;
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
    bool operation,
    ERC20 reward
  ) external view returns (uint256, uint256) {
    return (
      distribution[market].rewards[reward].accounts[account][operation].accrued,
      distribution[market].rewards[reward].accounts[account][operation].index
    );
  }

  /// @notice Gets the distribution start, end, lastUpdate and lastUndistributed value of a given market and reward.
  /// @param market The market to get the distribution times and lastUndistributed for.
  /// @return The distribution start, end, lastUpdate time and lastUndistributed value.
  function distributionTime(Market market, ERC20 reward) external view returns (uint32, uint32, uint32, uint256) {
    return (
      distribution[market].rewards[reward].start,
      distribution[market].rewards[reward].end,
      distribution[market].rewards[reward].lastUpdate,
      distribution[market].rewards[reward].lastUndistributed
    );
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
  /// @param reward The reward asset to get the claimable amount for.
  /// @return unclaimedRewards The claimable amount for the given reward asset.
  function allClaimable(address account, ERC20 reward) external view returns (uint256 unclaimedRewards) {
    return claimable(allMarketsOperations(), account, reward);
  }

  /// @notice Gets the claimable amount of rewards for a given account, market operations and reward asset.
  /// @param marketOps The list of market operations to search for accrued and pending rewards.
  /// @param account The account to get the claimable amount for.
  /// @param reward The reward asset to get the claimable amount for.
  /// @return unclaimedRewards The claimable amount for the given reward asset.
  function claimable(
    MarketOperation[] memory marketOps,
    address account,
    ERC20 reward
  ) public view returns (uint256 unclaimedRewards) {
    for (uint256 i = 0; i < marketOps.length; ) {
      if (distribution[marketOps[i].market].availableRewardsCount == 0) {
        unchecked {
          ++i;
        }
        continue;
      }

      AccountOperation[] memory ops = accountBalanceOperations(
        marketOps[i].market,
        marketOps[i].operations,
        account,
        distribution[marketOps[i].market].rewards[reward].start
      );
      uint256 balance;
      for (uint256 o = 0; o < ops.length; ) {
        unclaimedRewards += distribution[marketOps[i].market]
        .rewards[reward]
        .accounts[account][ops[o].operation].accrued;
        balance += ops[o].balance;
        unchecked {
          ++o;
        }
      }
      if (balance > 0) {
        unclaimedRewards += pendingRewards(
          account,
          reward,
          AccountMarketOperation({ market: marketOps[i].market, accountOperations: ops })
        );
      }
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Iterates and accrues all the rewards for the operations of the given account in the given market.
  /// @param account The account to accrue the rewards for.
  /// @param market The market to accrue the rewards for.
  /// @param ops The operations to accrue the rewards for.
  function update(address account, Market market, ERC20 reward, AccountOperation[] memory ops) internal {
    uint256 baseUnit = distribution[market].baseUnit;
    RewardData storage rewardData = distribution[market].rewards[reward];
    {
      (uint256 borrowIndex, uint256 depositIndex, uint256 newUndistributed) = previewAllocation(
        rewardData,
        market,
        block.timestamp - rewardData.lastUpdate
      );
      if (borrowIndex > type(uint128).max || depositIndex > type(uint128).max) revert IndexOverflow();
      rewardData.borrowIndex = uint128(borrowIndex);
      rewardData.depositIndex = uint128(depositIndex);
      rewardData.lastUpdate = uint32(block.timestamp);
      rewardData.lastUndistributed = newUndistributed;
      emit IndexUpdate(market, reward, borrowIndex, depositIndex, newUndistributed, block.timestamp);
    }

    for (uint256 i = 0; i < ops.length; ) {
      uint256 accountIndex = rewardData.accounts[account][ops[i].operation].index;
      uint256 newAccountIndex;
      if (ops[i].operation) {
        newAccountIndex = rewardData.borrowIndex;
      } else {
        newAccountIndex = rewardData.depositIndex;
      }
      if (accountIndex != newAccountIndex) {
        rewardData.accounts[account][ops[i].operation].index = uint128(newAccountIndex);
        if (ops[i].balance != 0) {
          uint256 rewardsAccrued = accountRewards(ops[i].balance, newAccountIndex, accountIndex, baseUnit);
          rewardData.accounts[account][ops[i].operation].accrued += uint128(rewardsAccrued);
          emit Accrue(market, reward, account, ops[i].operation, accountIndex, newAccountIndex, rewardsAccrued);
        }
      }
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Gets the equivalent of borrow shares from fixed pool principal borrows of an account.
  /// @param market The market to get the fixed borrows from.
  /// @param account The account that borrowed from fixed pools.
  /// @return fixedDebt The fixed borrow shares.
  function accountFixedBorrowShares(
    Market market,
    address account,
    uint32 start
  ) internal view returns (uint256 fixedDebt) {
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
    uint256 baseUnit = distribution[ops.market].baseUnit;
    (uint256 borrowIndex, uint256 depositIndex, ) = previewAllocation(
      rewardData,
      ops.market,
      block.timestamp - rewardData.lastUpdate
    );
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
  /// @param globalIndex Current index of the distribution
  /// @param accountIndex Index stored for the account, representation his staking moment
  /// @param baseUnit One unit of the market's asset (10**decimals)
  /// @return The rewards
  function accountRewards(
    uint256 balance,
    uint256 globalIndex,
    uint256 accountIndex,
    uint256 baseUnit
  ) internal pure returns (uint256) {
    return balance.mulDivDown(globalIndex - accountIndex, baseUnit);
  }

  /// @notice Retrieves updated distribution indexes.
  /// @param market The market to calculate the indexes for.
  /// @param reward The reward asset to calculate the indexes for.
  /// @param deltaTime The elapsed time since the last update.
  /// @return borrowIndex The index for the borrow operation.
  /// @return depositIndex The index for the deposit operation.
  /// @return newUndistributed The undistributed rewards for the distribution.
  function previewAllocation(
    Market market,
    ERC20 reward,
    uint256 deltaTime
  ) external view returns (uint256 borrowIndex, uint256 depositIndex, uint256 newUndistributed) {
    return previewAllocation(distribution[market].rewards[reward], market, deltaTime);
  }

  /// @notice Internal function for the calculation of the distribution's indexes.
  /// @param rewardData The distribution's data.
  /// @param market The market to calculate the indexes for.
  /// @param deltaTime The elapsed time since the last update.
  /// @return borrowIndex The index for the borrow operation.
  /// @return depositIndex The index for the deposit operation.
  /// @return newUndistributed The undistributed rewards for the distribution.
  function previewAllocation(
    RewardData storage rewardData,
    Market market,
    uint256 deltaTime
  ) internal view returns (uint256 borrowIndex, uint256 depositIndex, uint256 newUndistributed) {
    TotalMarketBalance memory m;
    m.debt = market.totalFloatingBorrowAssets();
    m.supply = market.totalAssets();
    m.baseUnit = distribution[market].baseUnit;
    uint256 fixedBorrowShares;
    {
      uint256 start = rewardData.start;
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
    uint256 rewards;
    {
      m.rewardMintingRate = rewardData.mintingRate;
      uint256 lastUndistributed = rewardData.lastUndistributed;
      uint256 distributionFactor = rewardData.undistributedFactor.mulWadDown(target);
      if (block.timestamp <= rewardData.end) {
        if (distributionFactor > 0) {
          uint256 exponential = uint256((-int256(distributionFactor * deltaTime)).expWad());
          newUndistributed =
            lastUndistributed +
            m.rewardMintingRate.mulWadDown(1e18 - target).divWadDown(distributionFactor).mulWadDown(
              1e18 - exponential
            ) -
            lastUndistributed.mulWadDown(1e18 - exponential);
        } else {
          newUndistributed = lastUndistributed + m.rewardMintingRate.mulWadDown(1e18 - target) * deltaTime;
        }
        rewards = rewardData.targetDebt.mulDivDown(
          uint256(int256(m.rewardMintingRate * deltaTime) - (int256(newUndistributed) - int256(lastUndistributed))),
          m.baseUnit
        );
      } else if (rewardData.lastUpdate > rewardData.end) {
        newUndistributed =
          lastUndistributed -
          lastUndistributed.mulWadDown(
            1e18 - uint256((-int256(distributionFactor * (block.timestamp - rewardData.lastUpdate))).expWad())
          );
        rewards = rewardData.targetDebt.mulDivDown(
          uint256(-(int256(newUndistributed) - int256(lastUndistributed))),
          m.baseUnit
        );
      } else {
        uint256 exponential;
        deltaTime = rewardData.end - rewardData.lastUpdate;
        if (distributionFactor > 0) {
          exponential = uint256((-int256(distributionFactor * deltaTime)).expWad());
          newUndistributed =
            lastUndistributed +
            m.rewardMintingRate.mulWadDown(1e18 - target).divWadDown(distributionFactor).mulWadDown(
              1e18 - exponential
            ) -
            lastUndistributed.mulWadDown(1e18 - exponential);
        } else {
          newUndistributed = lastUndistributed + m.rewardMintingRate.mulWadDown(1e18 - target) * deltaTime;
        }
        exponential = uint256((-int256(distributionFactor * (block.timestamp - rewardData.end))).expWad());
        newUndistributed = newUndistributed - newUndistributed.mulWadDown(1e18 - exponential);
        rewards = rewardData.targetDebt.mulDivDown(
          uint256(int256(m.rewardMintingRate * deltaTime) - (int256(newUndistributed) - int256(lastUndistributed))),
          m.baseUnit
        );
      }
      if (rewards == 0) return (rewardData.borrowIndex, rewardData.depositIndex, newUndistributed);
    }
    {
      AllocationVars memory v;
      v.utilization = m.supply > 0 ? m.debt.divWadDown(m.supply) : 0;
      v.transitionFactor = rewardData.transitionFactor;
      v.flipSpeed = rewardData.flipSpeed;
      v.borrowAllocationWeightFactor = rewardData.borrowAllocationWeightFactor;
      v.sigmoid = v.utilization > 0
        ? uint256(1e18).divWadDown(
          1e18 +
            uint256(
              (-(v.flipSpeed *
                (int256(v.utilization.divWadDown(1e18 - v.utilization)).lnWad() -
                  int256(v.transitionFactor.divWadDown(1e18 - v.transitionFactor)).lnWad())) / 1e18).expWad()
            )
        )
        : 0;
      v.borrowRewardRule = rewardData
        .compensationFactor
        .mulWadDown(
          market.interestRateModel().floatingRate(v.utilization).mulWadDown(
            1e18 - v.utilization.mulWadDown(1e18 - target)
          ) + v.borrowAllocationWeightFactor
        )
        .mulWadDown(1e18 - v.sigmoid);
      v.depositRewardRule =
        rewardData.depositAllocationWeightAddend.mulWadDown(1e18 - v.sigmoid) +
        rewardData.depositAllocationWeightFactor.mulWadDown(v.borrowAllocationWeightFactor).mulWadDown(v.sigmoid);
      v.borrowAllocation = v.borrowRewardRule.divWadDown(v.borrowRewardRule + v.depositRewardRule);
      v.depositAllocation = 1e18 - v.borrowAllocation;
      {
        uint256 totalDepositSupply = market.totalSupply();
        uint256 totalBorrowSupply = market.totalFloatingBorrowShares() + fixedBorrowShares;
        borrowIndex =
          rewardData.borrowIndex +
          (
            totalBorrowSupply > 0 ? rewards.mulWadDown(v.borrowAllocation).mulDivDown(m.baseUnit, totalBorrowSupply) : 0
          );
        depositIndex =
          rewardData.depositIndex +
          (
            totalDepositSupply > 0
              ? rewards.mulWadDown(v.depositAllocation).mulDivDown(m.baseUnit, totalDepositSupply)
              : 0
          );
      }
    }
  }

  /// @notice Get account balances and total supply of all the operations specified by the markets and operations
  /// parameters
  /// @param market The address of the market
  /// @param ops List of operations to retrieve account balance and total supply
  /// @param account Address of the account
  /// @return accountBalanceOps contains a list of structs with account balance and total amount of the
  /// operation's pool
  function accountBalanceOperations(
    Market market,
    bool[] memory ops,
    address account,
    uint32 distributionStart
  ) internal view returns (AccountOperation[] memory accountBalanceOps) {
    accountBalanceOps = new AccountOperation[](ops.length);
    for (uint256 i = 0; i < ops.length; ) {
      if (ops[i]) {
        (, , uint256 floatingBorrowShares) = market.accounts(account);
        accountBalanceOps[i] = AccountOperation({
          operation: ops[i],
          balance: floatingBorrowShares + accountFixedBorrowShares(market, account, distributionStart)
        });
      } else {
        accountBalanceOps[i] = AccountOperation({ operation: ops[i], balance: market.balanceOf(account) });
      }
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Withdraws the contract's balance of the given asset to the given address.
  /// @param asset The asset to withdraw.
  /// @param to The address to withdraw the asset to.
  function withdraw(ERC20 asset, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
    asset.safeTransfer(to, asset.balanceOf(address(this)));
  }

  /// @notice Updates the RewardData with the given configs
  /// @param configs The config to update the RewardData with
  function config(Config[] memory configs) external onlyRole(DEFAULT_ADMIN_ROLE) {
    for (uint256 i = 0; i < configs.length; ) {
      if (distribution[configs[i].market].baseUnit == 0) {
        // never initialized before, adding to the list of markets
        marketList.push(configs[i].market);
      }
      RewardData storage rewardData = distribution[configs[i].market].rewards[configs[i].reward];

      // add reward address to distribution data's available rewards if lastUpdate is zero
      if (rewardData.lastUpdate == 0) {
        distribution[configs[i].market].availableRewards[
          distribution[configs[i].market].availableRewardsCount
        ] = configs[i].reward;
        distribution[configs[i].market].availableRewardsCount++;
        distribution[configs[i].market].baseUnit = 10 ** configs[i].market.decimals();
        rewardData.lastUpdate = uint32(block.timestamp);
      } else {
        // update global indexes before setting new config
        bool[] memory ops = new bool[](1);
        ops[0] = true;
        update(
          address(0),
          configs[i].market,
          configs[i].reward,
          accountBalanceOperations(configs[i].market, ops, address(0), rewardData.start)
        );
      }
      // add reward address to global rewards list if still not enabled
      if (rewardEnabled[configs[i].reward] == false) {
        rewardEnabled[configs[i].reward] = true;
        rewardList.push(configs[i].reward);
      }

      uint32 start = rewardData.start;
      if (start == 0) {
        start = uint32(block.timestamp);
        rewardData.start = start;
      }
      rewardData.end = start + uint32(configs[i].distributionPeriod);
      rewardData.priceFeed = configs[i].priceFeed;
      // set emission and distribution parameters
      rewardData.targetDebt = configs[i].targetDebt;
      rewardData.undistributedFactor = configs[i].undistributedFactor;
      rewardData.flipSpeed = configs[i].flipSpeed;
      rewardData.compensationFactor = configs[i].compensationFactor;
      rewardData.transitionFactor = configs[i].transitionFactor;
      rewardData.borrowAllocationWeightFactor = configs[i].borrowAllocationWeightFactor;
      rewardData.depositAllocationWeightAddend = configs[i].depositAllocationWeightAddend;
      rewardData.depositAllocationWeightFactor = configs[i].depositAllocationWeightFactor;
      rewardData.totalDistribution = configs[i].totalDistribution;
      rewardData.mintingRate = configs[i]
        .totalDistribution
        .mulDivDown(distribution[configs[i].market].baseUnit, configs[i].targetDebt)
        .mulWadDown(1e18 / configs[i].distributionPeriod);

      emit DistributionSet(configs[i].market, configs[i].reward, configs[i]);
      unchecked {
        ++i;
      }
    }
  }

  struct TotalMarketBalance {
    uint256 debt;
    uint256 supply;
    uint256 baseUnit;
    uint256 rewardMintingRate;
  }

  struct AllocationVars {
    uint256 utilization;
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
    uint256 targetDebt;
    uint256 totalDistribution;
    uint256 distributionPeriod;
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
    uint256 mintingRate;
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

  event Accrue(
    Market indexed market,
    ERC20 indexed reward,
    address indexed account,
    bool operation,
    uint256 accountIndex,
    uint256 operationIndex,
    uint256 rewardsAccrued
  );
  event Claim(address indexed account, ERC20 indexed reward, address indexed to, uint256 amount);
  event DistributionSet(Market indexed market, ERC20 indexed reward, Config config);
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
