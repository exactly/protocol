// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { RatePreviewer, Auditor, Market } from "../contracts/periphery/RatePreviewer.sol";
import { ForkTest } from "./Fork.t.sol";

contract RatePreviewerTest is ForkTest {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;

  Auditor internal auditor;
  RatePreviewer internal ratePreviewer;
  mapping(Market => uint256) internal currentTotalAssets;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 122_565_907);

    auditor = Auditor(deployment("Auditor"));
    ratePreviewer = RatePreviewer(address(new ERC1967Proxy(address(new RatePreviewer(auditor)), "")));

    Market[] memory markets = auditor.allMarkets();
    for (uint256 i = 0; i < markets.length; i++) {
      Market market = markets[i];
      currentTotalAssets[market] = market.totalAssets();
    }
  }

  function testSnapshot() external {
    RatePreviewer.Snapshot[] memory snapshots = ratePreviewer.snapshot();

    // we simulate 20 minutes in the future
    skip(20 minutes);
    for (uint256 i = 0; i < snapshots.length; i++) {
      RatePreviewer.Snapshot memory snapshot = snapshots[i];

      assertEq(projectTotalAssets(snapshot, block.timestamp), snapshot.market.totalAssets());
    }
  }

  function testSnapshotWithSignificantElapsedTime() external {
    RatePreviewer.Snapshot[] memory snapshots = ratePreviewer.snapshot();

    // we simulate 6 weeks in the future
    skip(6 weeks);
    for (uint256 i = 0; i < snapshots.length; i++) {
      RatePreviewer.Snapshot memory snapshot = snapshots[i];

      assertApproxEqRel(
        projectTotalAssets(snapshot, block.timestamp),
        snapshot.market.totalAssets(),
        (10 ** snapshot.market.decimals()) / 10000
      );
    }
  }

  function testPreviewRate() external {
    RatePreviewer.Snapshot[] memory snapshots = ratePreviewer.snapshot();

    // we simulate 20 minutes in the future
    uint256 elapsed = 20 minutes;
    skip(elapsed);
    for (uint256 i = 0; i < snapshots.length; i++) {
      RatePreviewer.Snapshot memory snapshot = snapshots[i];

      uint256 projectedTotalAssets = projectTotalAssets(snapshot, block.timestamp);
      uint256 totalAssetsBefore = currentTotalAssets[snapshot.market];
      uint256 assetsInYear = ((projectedTotalAssets - totalAssetsBefore) * 365 days) / elapsed;
      uint256 rate = (assetsInYear * 1e18) / totalAssetsBefore;
      rate;
    }
  }

  function testPreviewRateAfterFloatingDepositAndBorrow() external {
    RatePreviewer.Snapshot[] memory snapshots = ratePreviewer.snapshot();
    for (uint256 i = 0; i < snapshots.length; i++) {
      RatePreviewer.Snapshot memory snapshot = snapshots[i];
      uint256 newDeposit = snapshot.floatingAssets / 10; // simulating a new deposit eq to 10% of pool
      uint256 newBorrow = snapshot.floatingAssets / 20; // simulating a new borrow eq to 5% of pool
      snapshot.floatingAssets += newDeposit;
      snapshot.floatingDebt += newBorrow;
      currentTotalAssets[snapshot.market] = projectTotalAssets(snapshot, block.timestamp);
    }

    // we simulate 20 minutes in the future
    uint256 elapsed = 20 minutes;
    skip(elapsed);
    for (uint256 i = 0; i < snapshots.length; i++) {
      RatePreviewer.Snapshot memory snapshot = snapshots[i];
      uint256 projectedTotalAssets = projectTotalAssets(snapshot, block.timestamp);

      uint256 totalAssetsBefore = currentTotalAssets[snapshot.market];
      uint256 assetsInYear = ((projectedTotalAssets - totalAssetsBefore) * 365 days) / elapsed;
      uint256 rate = (assetsInYear * 1e18) / totalAssetsBefore;
      rate;
    }
  }

  function projectTotalAssets(
    RatePreviewer.Snapshot memory snapshot,
    uint256 timestamp
  ) internal view returns (uint256 projectedTotalAssets) {
    uint256 elapsedAccumulator = timestamp - snapshot.lastAccumulatorAccrual;
    uint256 accumulatedEarnings = snapshot.earningsAccumulator.mulDivDown(
      elapsedAccumulator,
      elapsedAccumulator +
        snapshot.earningsAccumulatorSmoothFactor.mulWadDown(snapshot.maxFuturePools * snapshot.interval)
    );
    uint256 floatingRate = snapshot.market.interestRateModel().floatingRate(
      snapshot.floatingDebt.divWadUp(snapshot.floatingAssets),
      (snapshot.floatingDebt + snapshot.floatingBackupBorrowed).divWadUp(snapshot.floatingAssets)
    );
    uint256 newDebt = snapshot.floatingDebt.mulWadDown(
      floatingRate.mulDivDown(timestamp - snapshot.lastFloatingDebtUpdate, 365 days)
    );
    uint256 backupEarnings = fixedPoolEarnings(snapshot.pools, timestamp);

    projectedTotalAssets =
      snapshot.floatingAssets +
      backupEarnings +
      accumulatedEarnings +
      (snapshot.floatingDebt + newDebt - snapshot.floatingDebt).mulWadDown(1e18 - snapshot.treasuryFeeRate);
  }

  function fixedPoolEarnings(
    RatePreviewer.FixedPool[] memory pools,
    uint256 timestamp
  ) internal pure returns (uint256 backupEarnings) {
    for (uint256 i = 0; i < pools.length; i++) {
      RatePreviewer.FixedPool memory pool = pools[i];

      uint256 lastAccrual = pool.lastAccrual;
      if (pool.maturity > lastAccrual) {
        backupEarnings += timestamp < pool.maturity
          ? pool.unassignedEarnings.mulDivDown(timestamp - lastAccrual, pool.maturity - lastAccrual)
          : pool.unassignedEarnings;
      }
    }
  }
}
