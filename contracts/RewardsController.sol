// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { FixedLib } from "./utils/FixedLib.sol";
import { Auditor } from "./Auditor.sol";
import { Market } from "./Market.sol";

contract RewardsController is AccessControl {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;
  using SafeTransferLib for ERC20;

  /// @custom:oz-upgrades-unsafe-allow  state-variable-immutable
  Auditor public immutable auditor;
  // Map of rewarded operations and their distribution data
  mapping(Market => Distribution) internal distribution;
  // Map of reward assets
  mapping(address => bool) internal isRewardEnabled;
  // Rewards list
  address[] internal rewardList;
  // Map of operations by account
  mapping(address => mapping(Market => MaturityOperation[])) public accountOperations;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_) {
    auditor = auditor_;

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
  }

  function handleOperation(Operation operation, address account, uint256 balance) external {
    AccountMaturityOperation[] memory ops = new AccountMaturityOperation[](1);
    ops[0] = AccountMaturityOperation({ operation: operation, maturity: 0, balance: balance });
    update(account, Market(msg.sender), ops);
  }

  function handleOperationAtMaturity(Operation operation, uint256 maturity, address account, uint256 balance) external {
    AccountMaturityOperation[] memory ops = new AccountMaturityOperation[](1);
    ops[0] = AccountMaturityOperation({ operation: operation, maturity: maturity, balance: balance });
    update(account, Market(msg.sender), ops);
  }

  function claimAll(address to) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    return claim(allAccountOperations(msg.sender), to);
  }

  function claim(
    MarketOperation[] memory operations,
    address to
  ) public returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
    rewardsList = new address[](rewardList.length);
    claimedAmounts = new uint256[](rewardList.length);

    for (uint256 i = 0; i < operations.length; ++i) {
      update(
        msg.sender,
        operations[i].market,
        accountMaturityOperations(operations[i].market, operations[i].operations, msg.sender)
      );
      for (uint256 r = 0; r < rewardList.length; ++r) {
        if (rewardsList[r] == address(0)) rewardsList[r] = rewardList[r];

        for (uint256 o = 0; o < operations[i].operations.length; ++o) {
          uint256 rewardAmount = distribution[operations[i].market]
          .rewards[rewardsList[r]]
          .accounts[msg.sender][operations[i].operations[o].operation][operations[i].operations[o].maturity].accrued;
          if (rewardAmount != 0) {
            claimedAmounts[r] += rewardAmount;
            distribution[operations[i].market]
            .rewards[rewardsList[r]]
            .accounts[msg.sender][operations[i].operations[o].operation][operations[i].operations[o].maturity]
              .accrued = 0;
          }
        }
      }
    }
    for (uint256 r = 0; r < rewardsList.length; ++r) {
      ERC20(rewardsList[r]).safeTransfer(to, claimedAmounts[r]);
      emit Claim(msg.sender, rewardsList[r], to, claimedAmounts[r]);
    }
    return (rewardsList, claimedAmounts);
  }

  function rewardsData(
    Market market,
    address reward
  ) external view returns (uint256, uint256, uint256, uint256, uint256) {
    return (
      distribution[market].rewards[reward].lastUpdate,
      distribution[market].rewards[reward].targetDebt,
      distribution[market].rewards[reward].mintingRate,
      distribution[market].rewards[reward].undistributedFactor,
      distribution[market].rewards[reward].lastUndistributed
    );
  }

  function decimals(Market market) external view returns (uint8) {
    return distribution[market].decimals;
  }

  function availableRewardsCount(Market market) external view returns (uint256) {
    return distribution[market].availableRewardsCount;
  }

  function allRewards() external view returns (address[] memory) {
    return rewardList;
  }

  function allAccountOperations(address account) public view returns (MarketOperation[] memory marketOps) {
    Market[] memory marketList = auditor.allMarkets();
    marketOps = new MarketOperation[](marketList.length);
    for (uint256 i = 0; i < marketList.length; ++i) {
      MaturityOperation[] memory ops = accountOperations[account][marketList[i]];
      marketOps[i] = MarketOperation({ market: marketList[i], operations: ops });
    }
  }

  function accountOperation(
    address account,
    Market market,
    Operation operation,
    uint256 maturity,
    address reward
  ) external view returns (uint256, uint256) {
    return (
      distribution[market].rewards[reward].accounts[account][operation][maturity].accrued,
      distribution[market].rewards[reward].accounts[account][operation][maturity].index
    );
  }

  function claimable(address account, address reward) external view returns (uint256 unclaimedRewards) {
    MarketOperation[] memory marketOps = allAccountOperations(account);
    for (uint256 i = 0; i < marketOps.length; ++i) {
      if (distribution[marketOps[i].market].availableRewardsCount == 0) continue;

      AccountMaturityOperation[] memory ops = accountMaturityOperations(
        marketOps[i].market,
        marketOps[i].operations,
        account
      );
      for (uint256 o = 0; o < ops.length; ++o) {
        unclaimedRewards += distribution[marketOps[i].market]
        .rewards[reward]
        .accounts[account][ops[o].operation][ops[o].maturity].accrued;
      }
      unclaimedRewards += pendingRewards(
        account,
        reward,
        AccountMarketOperation({ market: marketOps[i].market, operations: ops })
      );
    }
  }

  /// @notice Iterates and accrues all the rewards for the operations of the specific account
  /// @param account The account address
  /// @param market The market address
  /// @param ops The account's balance in the operation's pool
  function update(address account, Market market, AccountMaturityOperation[] memory ops) internal {
    uint256 baseUnit;
    unchecked {
      baseUnit = 10 ** distribution[market].decimals;
    }

    if (distribution[market].availableRewardsCount == 0) return;
    unchecked {
      for (uint128 r = 0; r < distribution[market].availableRewardsCount; ++r) {
        address reward = distribution[market].availableRewards[r];
        RewardData storage rewardData = distribution[market].rewards[reward];
        updateRewardIndexes(rewardData, market, baseUnit);

        for (uint256 i = 0; i < ops.length; ++i) {
          uint256 accountIndex = rewardData.accounts[account][ops[i].operation][ops[i].maturity].index;
          uint256 newAccountIndex;
          if (ops[i].balance == 0 && accountIndex == 0) {
            accountOperations[account][market].push(MaturityOperation(ops[i].operation, ops[i].maturity));
          }
          if (ops[i].operation == Operation.Deposit && ops[i].maturity == 0) {
            newAccountIndex = rewardData.floatingDepositIndex;
          } else if (ops[i].operation == Operation.Borrow && ops[i].maturity == 0) {
            newAccountIndex = rewardData.floatingBorrowIndex;
          } else if (ops[i].operation == Operation.Deposit) {
            newAccountIndex = rewardData.fixedDepositIndex;
          } else {
            newAccountIndex = rewardData.fixedBorrowIndex;
          }
          if (accountIndex != newAccountIndex) {
            rewardData.accounts[account][ops[i].operation][ops[i].maturity].index = uint104(newAccountIndex);
            if (ops[i].balance != 0) {
              uint256 rewardsAccrued = accountRewards(ops[i].balance, newAccountIndex, accountIndex, baseUnit);
              rewardData.accounts[account][ops[i].operation][ops[i].maturity].accrued += uint128(rewardsAccrued);
              emit Accrue(market, reward, account, newAccountIndex, newAccountIndex, rewardsAccrued);
            }
          }
        }
      }
    }
  }

  function updateRewardIndexes(RewardData storage rewardData, Market market, uint256 baseUnit) internal {
    (uint256 rewards, uint256 newUndistributed) = deltaRewards(rewardData, market);
    rewardData.lastUndistributed = newUndistributed;
    rewardData.lastUpdate = uint32(block.timestamp);

    (
      uint256 floatingBorrowIndex,
      uint256 floatingDepositIndex,
      uint256 fixedBorrowIndex,
      uint256 fixedDepositIndex
    ) = previewRewardIndexes(rewardData, rewards, market, baseUnit);
    rewardData.floatingBorrowIndex = floatingBorrowIndex;
    rewardData.floatingDepositIndex = floatingDepositIndex;
    rewardData.fixedBorrowIndex = fixedBorrowIndex;
    rewardData.fixedDepositIndex = fixedDepositIndex;
  }

  function previewRewardIndexes(
    RewardData storage rewardData,
    uint256 rewards,
    Market market,
    uint256 baseUnit
  ) internal view returns (uint256 floatingBorrow, uint256 floatingDeposit, uint256 fixedBorrow, uint256 fixedDeposit) {
    floatingBorrow =
      rewardData.floatingBorrowIndex +
      (
        market.totalFloatingBorrowShares() > 0
          ? (rewards / 2).mulDivDown(baseUnit, market.totalFloatingBorrowShares())
          : 0
      );
    floatingDeposit =
      rewardData.floatingDepositIndex +
      (market.totalSupply() > 0 ? (rewards / 2).mulDivDown(baseUnit, market.totalSupply()) : 0);
    fixedBorrow = rewardData.fixedBorrowIndex;
    fixedDeposit = rewardData.fixedDepositIndex;
  }

  function rewardIndexes(Market market, address reward) external view returns (uint256, uint256, uint256, uint256) {
    return (
      distribution[market].rewards[reward].floatingBorrowIndex,
      distribution[market].rewards[reward].floatingDepositIndex,
      distribution[market].rewards[reward].fixedBorrowIndex,
      distribution[market].rewards[reward].fixedDepositIndex
    );
  }

  /// @notice Calculates the pending (not yet accrued) rewards since the last account action
  /// @param account The address of the account
  /// @param reward The address of the reward token
  /// @param ops Struct with the account balance and total balance of the operation's pool
  /// @return rewards The pending rewards for the account since the last account action
  function pendingRewards(
    address account,
    address reward,
    AccountMarketOperation memory ops
  ) internal view returns (uint256 rewards) {
    RewardData storage rewardData = distribution[ops.market].rewards[reward];
    uint256 baseUnit = 10 ** distribution[ops.market].decimals;
    (uint256 r, ) = deltaRewards(rewardData, ops.market);
    Indexes memory i;
    (i.floatingBorrow, i.floatingDeposit, i.fixedBorrow, i.fixedDeposit) = previewRewardIndexes(
      rewardData,
      r,
      ops.market,
      baseUnit
    );
    for (uint256 o = 0; o < ops.operations.length; ++o) {
      uint256 nextIndex;
      if (ops.operations[o].operation == Operation.Borrow && ops.operations[o].maturity == 0) {
        nextIndex = i.floatingBorrow;
      } else if (ops.operations[o].operation == Operation.Deposit && ops.operations[o].maturity == 0) {
        nextIndex = i.floatingDeposit;
      } else if (ops.operations[o].operation == Operation.Borrow) {
        nextIndex = i.fixedBorrow;
      } else {
        nextIndex = i.fixedDeposit;
      }

      rewards += accountRewards(
        ops.operations[o].balance,
        nextIndex,
        rewardData.accounts[account][ops.operations[o].operation][ops.operations[o].maturity].index,
        baseUnit
      );
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

  function deltaRewards(
    RewardData storage rewardData,
    Market market
  ) internal view returns (uint256 rewards, uint256 newUndistributed) {
    uint256 totalDebt = market.totalFloatingBorrowShares();
    {
      uint256 fixedBorrowAssets;
      uint256 memMaxFuturePools = market.maxFuturePools();
      uint256 latestMaturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL);
      uint256 maxMaturity = latestMaturity + memMaxFuturePools * FixedLib.INTERVAL;
      for (uint256 m = latestMaturity; m <= maxMaturity; m += FixedLib.INTERVAL) {
        (uint256 borrowed, , , ) = market.fixedPools(m);
        fixedBorrowAssets += borrowed;
      }
      totalDebt += market.previewBorrow(fixedBorrowAssets);
    }
    uint256 undistributedFactor = rewardData.undistributedFactor;
    uint256 lastUndistributed = rewardData.lastUndistributed;
    uint256 mintingRate = rewardData.mintingRate;
    uint256 targetDebt = rewardData.targetDebt;

    uint256 target = totalDebt < targetDebt ? totalDebt.divWadDown(targetDebt) : 1e18;
    uint256 distributionFactor = undistributedFactor.mulWadDown(target);
    if (distributionFactor > 0) {
      uint256 deltaTime = block.timestamp - rewardData.lastUpdate;
      uint256 mintingFactor = mintingRate.mulWadDown(1e18 - target);
      uint256 exponential = uint256((-int256(distributionFactor * deltaTime)).expWad());
      newUndistributed =
        lastUndistributed +
        mintingFactor.divWadDown(distributionFactor).mulWadDown(1e18 - exponential) -
        lastUndistributed.mulWadDown(1e18 - exponential);
      rewards = targetDebt.mulWadDown(
        uint256(int256(mintingRate * deltaTime) - (int256(newUndistributed) - int256(lastUndistributed)))
      );
    } else {
      newUndistributed = lastUndistributed;
    }
  }

  /// @notice Get account balances and total supply of all the operations specified by the markets and operations
  /// parameters
  /// @param market The address of the market
  /// @param ops List of operations to retrieve account balance and total supply
  /// @param account Address of the account
  /// @return accountMaturityOps contains a list of structs with account balance and total amount of the
  /// operation's pool
  function accountMaturityOperations(
    Market market,
    MaturityOperation[] memory ops,
    address account
  ) internal view returns (AccountMaturityOperation[] memory accountMaturityOps) {
    accountMaturityOps = new AccountMaturityOperation[](ops.length);
    for (uint256 i = 0; i < ops.length; ++i) {
      if (ops[i].operation == Operation.Deposit && ops[i].maturity == 0) {
        accountMaturityOps[i] = AccountMaturityOperation({
          operation: ops[i].operation,
          maturity: 0,
          balance: market.balanceOf(account)
        });
      } else if (ops[i].operation == Operation.Borrow && ops[i].maturity == 0) {
        (, , uint256 floatingBorrowShares) = market.accounts(account);
        accountMaturityOps[i] = AccountMaturityOperation({
          operation: ops[i].operation,
          maturity: 0,
          balance: floatingBorrowShares
        });
      } else if (ops[i].operation == Operation.Deposit) {
        (uint256 principal, ) = market.fixedDepositPositions(ops[i].maturity, account);
        accountMaturityOps[i] = AccountMaturityOperation({
          operation: ops[i].operation,
          maturity: ops[i].maturity,
          balance: principal
        });
      } else {
        (uint256 principal, ) = market.fixedBorrowPositions(ops[i].maturity, account);
        accountMaturityOps[i] = AccountMaturityOperation({
          operation: ops[i].operation,
          maturity: ops[i].maturity,
          balance: principal
        });
      }
    }
  }

  function config(Config[] memory configs) external onlyRole(DEFAULT_ADMIN_ROLE) {
    for (uint256 i = 0; i < configs.length; ++i) {
      RewardData storage rewardConfig = distribution[configs[i].market].rewards[configs[i].reward];
      rewardConfig.floatingDepositIndex = 1;
      rewardConfig.floatingBorrowIndex = 1;
      rewardConfig.fixedDepositIndex = 1;
      rewardConfig.fixedBorrowIndex = 1;

      // Add reward address to distribution data's available rewards if latestUpdateTimestamp is zero
      if (rewardConfig.lastUpdate == 0) {
        distribution[configs[i].market].availableRewards[
          distribution[configs[i].market].availableRewardsCount
        ] = configs[i].reward;
        distribution[configs[i].market].availableRewardsCount++;
        distribution[configs[i].market].decimals = configs[i].market.decimals();
        rewardConfig.lastUpdate = uint32(block.timestamp);
      }

      // Add reward address to global rewards list if still not enabled
      if (isRewardEnabled[configs[i].reward] == false) {
        isRewardEnabled[configs[i].reward] = true;
        rewardList.push(configs[i].reward);
      }

      // Configure emission and distribution end of the reward per operation
      rewardConfig.targetDebt = configs[i].targetDebt;
      rewardConfig.undistributedFactor = configs[i].undistributedFactor;
      rewardConfig.mintingRate = configs[i].totalDistribution.divWadDown(configs[i].targetDebt).mulWadDown(
        uint256(1e18) / configs[i].distributionPeriod
      );

      emit DistributionSet(configs[i].market, configs[i].reward, 0);
    }
  }

  enum Operation {
    Deposit,
    Borrow
  }

  struct Indexes {
    uint256 floatingBorrow;
    uint256 floatingDeposit;
    uint256 fixedBorrow;
    uint256 fixedDeposit;
  }

  struct MaturityOperation {
    Operation operation;
    uint256 maturity;
  }

  struct AccountMaturityOperation {
    Operation operation;
    uint256 maturity;
    uint256 balance;
  }

  struct MarketOperation {
    Market market;
    MaturityOperation[] operations;
  }

  struct AccountMarketOperation {
    Market market;
    AccountMaturityOperation[] operations;
  }

  struct Account {
    // Liquidity index of the reward distribution for the account
    uint104 index;
    // Amount of accrued rewards for the account since last account index update
    uint128 accrued;
  }

  struct Config {
    Market market;
    address reward;
    uint256 targetDebt;
    uint256 totalDistribution;
    uint256 distributionPeriod;
    uint256 undistributedFactor;
  }

  struct RewardData {
    uint256 targetDebt;
    uint256 mintingRate;
    uint256 undistributedFactor;
    uint256 lastUndistributed;
    // Liquidity index of the reward distribution
    uint256 floatingBorrowIndex;
    uint256 floatingDepositIndex;
    uint256 fixedBorrowIndex;
    uint256 fixedDepositIndex;
    // Timestamp of the last reward index update
    uint32 lastUpdate;
    // Map of account addresses and their rewards data (accountAddress => accounts)
    mapping(address => mapping(Operation => mapping(uint256 => Account))) accounts;
  }

  struct Distribution {
    // Map of reward token addresses and their data (rewardTokenAddress => rewardData)
    mapping(address => RewardData) rewards;
    // List of reward asset addresses for the operation
    mapping(uint128 => address) availableRewards;
    // Count of reward tokens for the operation
    uint128 availableRewardsCount;
    // Number of decimals of the operation's asset
    uint8 decimals;
  }

  event Accrue(
    Market indexed market,
    address indexed reward,
    address indexed account,
    uint256 operationIndex,
    uint256 accountIndex,
    uint256 rewardsAccrued
  );
  event Claim(address indexed account, address indexed reward, address indexed to, uint256 amount);
  event DistributionSet(Market indexed market, address indexed reward, uint256 operationIndex);
}
