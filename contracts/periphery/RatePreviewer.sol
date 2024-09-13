// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { FixedLib } from "../utils/FixedLib.sol";
import { Auditor } from "../Auditor.sol";
import { Market } from "../Market.sol";

/// @title RatePreviewer
/// @notice Contract to be consumed as a helper to calculate Exactly's pool rates
contract RatePreviewer {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;

  struct MarketRate {
    Market market;
    uint256 floatingDepositRate;
  }

  struct Snapshot {
    Market market;
    uint256 floatingDebt;
    uint256 floatingBackupBorrowed;
    FixedPool[] pools;
    uint256 floatingAssets;
    uint256 treasuryFeeRate;
    uint256 earningsAccumulator;
    uint128 earningsAccumulatorSmoothFactor;
    uint32 lastFloatingDebtUpdate;
    uint32 lastAccumulatorAccrual;
    uint8 maxFuturePools;
    uint256 interval;
  }

  struct FixedPool {
    uint256 maturity;
    uint256 lastAccrual;
    uint256 unassignedEarnings;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_) {
    auditor = auditor_;
  }

  /// @notice Gets a snapshot of `totalAssets()` values for all markets
  /// @return values An array of values to calculate `totalAssets()` for each market
  function snapshot() public view returns (Snapshot[] memory values) {
    Market[] memory markets = auditor.allMarkets();
    values = new Snapshot[](markets.length);

    for (uint256 i = 0; i < markets.length; ++i) {
      Market market = markets[i];
      values[i] = Snapshot({
        market: market,
        floatingDebt: market.floatingDebt(),
        floatingBackupBorrowed: market.floatingBackupBorrowed(),
        pools: fixedPools(market),
        floatingAssets: market.floatingAssets(),
        treasuryFeeRate: market.treasuryFeeRate(),
        earningsAccumulator: market.earningsAccumulator(),
        earningsAccumulatorSmoothFactor: market.earningsAccumulatorSmoothFactor(),
        lastFloatingDebtUpdate: market.lastFloatingDebtUpdate(),
        lastAccumulatorAccrual: market.lastAccumulatorAccrual(),
        maxFuturePools: market.maxFuturePools(),
        interval: FixedLib.INTERVAL
      });
    }
  }

  function floatingDepositRates(uint256 timeWindow) external view returns (MarketRate[] memory marketRates) {
    Snapshot[] memory snapshots = snapshot();
    marketRates = new MarketRate[](snapshots.length);

    for (uint256 i = 0; i < snapshots.length; ++i) {
      uint256 projectedTotalAssets = projectTotalAssets(snapshots[i], block.timestamp + timeWindow);
      uint256 totalAssetsBefore = snapshots[i].market.totalAssets();
      uint256 assetsInYear = ((projectedTotalAssets - totalAssetsBefore) * 365 days) / timeWindow;
      marketRates[i].market = snapshots[i].market;
      marketRates[i].floatingDepositRate = (assetsInYear * 1e18) / totalAssetsBefore;
    }
  }

  function fixedPools(Market market) internal view returns (FixedPool[] memory pools) {
    uint256 firstMaturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL);
    pools = new FixedPool[](market.maxFuturePools() + 1);
    for (uint256 i = 0; i < pools.length; ++i) {
      uint256 maturity = firstMaturity + FixedLib.INTERVAL * i;
      (, , uint256 unassignedEarnings, uint256 lastAccrual) = market.fixedPools(maturity);
      pools[i] = FixedPool({ maturity: maturity, lastAccrual: lastAccrual, unassignedEarnings: unassignedEarnings });
    }
  }

  function fixedPoolEarnings(
    FixedPool[] memory pools,
    uint256 timestamp
  ) internal pure returns (uint256 backupEarnings) {
    for (uint256 i = 0; i < pools.length; i++) {
      FixedPool memory pool = pools[i];

      uint256 lastAccrual = pool.lastAccrual;
      if (pool.maturity > lastAccrual) {
        backupEarnings += timestamp < pool.maturity
          ? pool.unassignedEarnings.mulDivDown(timestamp - lastAccrual, pool.maturity - lastAccrual)
          : pool.unassignedEarnings;
      }
    }
  }

  function projectTotalAssets(
    Snapshot memory marketSnapshot,
    uint256 timestamp
  ) internal view returns (uint256 projectedTotalAssets) {
    uint256 elapsedAccumulator = timestamp - marketSnapshot.lastAccumulatorAccrual;
    uint256 accumulatedEarnings = marketSnapshot.earningsAccumulator.mulDivDown(
      elapsedAccumulator,
      elapsedAccumulator +
        marketSnapshot.earningsAccumulatorSmoothFactor.mulWadDown(
          marketSnapshot.maxFuturePools * marketSnapshot.interval
        )
    );
    uint256 floatingRate = marketSnapshot.market.interestRateModel().floatingRate(
      marketSnapshot.floatingDebt.divWadUp(marketSnapshot.floatingAssets),
      (marketSnapshot.floatingDebt + marketSnapshot.floatingBackupBorrowed).divWadUp(marketSnapshot.floatingAssets)
    );
    uint256 newDebt = marketSnapshot.floatingDebt.mulWadDown(
      floatingRate.mulDivDown(timestamp - marketSnapshot.lastFloatingDebtUpdate, 365 days)
    );
    uint256 backupEarnings = fixedPoolEarnings(marketSnapshot.pools, timestamp);

    projectedTotalAssets =
      marketSnapshot.floatingAssets +
      backupEarnings +
      accumulatedEarnings +
      (marketSnapshot.floatingDebt + newDebt - marketSnapshot.floatingDebt).mulWadDown(
        1e18 - marketSnapshot.treasuryFeeRate
      );
  }
}
