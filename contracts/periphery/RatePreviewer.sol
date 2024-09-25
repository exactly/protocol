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

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;

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
    uint256 totalAssets;
    uint256 floatingRate;
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
  function snapshot() external view returns (Snapshot[] memory values) {
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
        interval: FixedLib.INTERVAL,
        totalAssets: market.totalAssets(),
        floatingRate: market.interestRateModel().floatingRate(
          market.floatingDebt().divWadUp(market.floatingAssets()),
          (market.floatingDebt() + market.floatingBackupBorrowed()).divWadUp(market.floatingAssets())
        )
      });
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
}
