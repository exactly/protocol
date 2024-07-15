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
  mapping(Market => uint256) currentTotalAssets;

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

  function testPreviewTotalAssets() external {
    RatePreviewer.TotalAssets[] memory totalAssets = ratePreviewer.previewTotalAssets();

    // we simulate 20 minutes in the future
    vm.warp(block.timestamp + 20 minutes);
    for (uint256 i = 0; i < totalAssets.length; i++) {
      RatePreviewer.TotalAssets memory assets = totalAssets[i];

      uint256 elapsedAccumulator = block.timestamp - assets.lastAccumulatorAccrual;
      uint256 accumulatedEarnings = assets.earningsAccumulator.mulDivDown(
        elapsedAccumulator,
        elapsedAccumulator + assets.earningsAccumulatorSmoothFactor.mulWadDown(assets.maxFuturePools * assets.interval)
      );
      uint256 floatingRate = assets.market.interestRateModel().floatingRate(
        assets.floatingAssets != 0 ? assets.floatingDebt.divWadUp(assets.floatingAssets) : 0,
        assets.floatingAssets != 0
          ? (assets.floatingDebt + assets.floatingBackupBorrowed).divWadUp(assets.floatingAssets)
          : 0
      );
      uint256 newDebt = assets.floatingDebt.mulWadDown(
        floatingRate.mulDivDown(block.timestamp - assets.lastFloatingDebtUpdate, 365 days)
      );
      uint256 backupEarnings = fixedPoolEarnings(assets.pools);

      uint256 projectedTotalAssets = assets.floatingAssets +
        backupEarnings +
        accumulatedEarnings +
        (assets.floatingDebt + newDebt - assets.floatingDebt).mulWadDown(1e18 - assets.treasuryFeeRate);
      assertEq(projectedTotalAssets, assets.market.totalAssets());
    }
  }

  function testPreviewTotalAssetsWithSignificantElapsedTime() external {
    RatePreviewer.TotalAssets[] memory totalAssets = ratePreviewer.previewTotalAssets();

    // we simulate 6 weeks in the future
    vm.warp(block.timestamp + 6 weeks);
    for (uint256 i = 0; i < totalAssets.length; i++) {
      RatePreviewer.TotalAssets memory assets = totalAssets[i];

      uint256 elapsedAccumulator = block.timestamp - assets.lastAccumulatorAccrual;
      uint256 accumulatedEarnings = assets.earningsAccumulator.mulDivDown(
        elapsedAccumulator,
        elapsedAccumulator + assets.earningsAccumulatorSmoothFactor.mulWadDown(assets.maxFuturePools * assets.interval)
      );
      uint256 floatingRate = assets.market.interestRateModel().floatingRate(
        assets.floatingAssets != 0 ? assets.floatingDebt.divWadUp(assets.floatingAssets) : 0,
        assets.floatingAssets != 0
          ? (assets.floatingDebt + assets.floatingBackupBorrowed).divWadUp(assets.floatingAssets)
          : 0
      );
      uint256 newDebt = assets.floatingDebt.mulWadDown(
        floatingRate.mulDivDown(block.timestamp - assets.lastFloatingDebtUpdate, 365 days)
      );
      uint256 backupEarnings = fixedPoolEarnings(assets.pools);

      uint256 projectedTotalAssets = assets.floatingAssets +
        backupEarnings +
        accumulatedEarnings +
        (assets.floatingDebt + newDebt - assets.floatingDebt).mulWadDown(1e18 - assets.treasuryFeeRate);
      assertApproxEqRel(projectedTotalAssets, assets.market.totalAssets(), (10 ** assets.market.decimals()) / 10000);
    }
  }

  function testPreviewRate() external {
    RatePreviewer.TotalAssets[] memory totalAssets = ratePreviewer.previewTotalAssets();

    // we simulate 20 minutes in the future
    uint256 elapsed = 20 minutes;
    vm.warp(block.timestamp + elapsed);
    for (uint256 i = 0; i < totalAssets.length; i++) {
      RatePreviewer.TotalAssets memory assets = totalAssets[i];

      uint256 elapsedAccumulator = block.timestamp - assets.lastAccumulatorAccrual;
      uint256 accumulatedEarnings = assets.earningsAccumulator.mulDivDown(
        elapsedAccumulator,
        elapsedAccumulator + assets.earningsAccumulatorSmoothFactor.mulWadDown(assets.maxFuturePools * assets.interval)
      );
      uint256 floatingRate = assets.market.interestRateModel().floatingRate(
        assets.floatingAssets != 0 ? assets.floatingDebt.divWadUp(assets.floatingAssets) : 0,
        assets.floatingAssets != 0
          ? (assets.floatingDebt + assets.floatingBackupBorrowed).divWadUp(assets.floatingAssets)
          : 0
      );
      uint256 newDebt = assets.floatingDebt.mulWadDown(
        floatingRate.mulDivDown(block.timestamp - assets.lastFloatingDebtUpdate, 365 days)
      );
      uint256 backupEarnings = fixedPoolEarnings(assets.pools);

      uint256 projectedTotalAssets = assets.floatingAssets +
        backupEarnings +
        accumulatedEarnings +
        (assets.floatingDebt + newDebt - assets.floatingDebt).mulWadDown(1e18 - assets.treasuryFeeRate);

      uint256 totalAssetsBefore = currentTotalAssets[assets.market];
      uint256 assetsInYear = ((projectedTotalAssets - totalAssetsBefore) * 365 days) / elapsed;
      uint256 rate = (assetsInYear * 1e18) / totalAssetsBefore;
      rate;
    }
  }

  function testPreviewRateAfterFloatingDepositAndBorrow() external {
    RatePreviewer.TotalAssets[] memory totalAssets = ratePreviewer.previewTotalAssets();
    for (uint256 i = 0; i < totalAssets.length; i++) {
      RatePreviewer.TotalAssets memory assets = totalAssets[i];
      uint256 newDeposit = assets.floatingAssets / 10; // simulating a new deposit eq to 10% of pool
      uint256 newBorrow = assets.floatingAssets / 20; // simulating a new borrow eq to 5% of pool
      assets.floatingAssets += newDeposit;
      assets.floatingDebt += newBorrow;

      uint256 elapsedAccumulator = block.timestamp - assets.lastAccumulatorAccrual;
      uint256 accumulatedEarnings = assets.earningsAccumulator.mulDivDown(
        elapsedAccumulator,
        elapsedAccumulator + assets.earningsAccumulatorSmoothFactor.mulWadDown(assets.maxFuturePools * assets.interval)
      );
      uint256 floatingRate = assets.market.interestRateModel().floatingRate(
        assets.floatingDebt.divWadUp(assets.floatingAssets),
        (assets.floatingDebt + assets.floatingBackupBorrowed).divWadUp(assets.floatingAssets)
      );
      uint256 newDebt = assets.floatingDebt.mulWadDown(
        floatingRate.mulDivDown(block.timestamp - assets.lastFloatingDebtUpdate, 365 days)
      );
      uint256 backupEarnings = fixedPoolEarnings(assets.pools);

      uint256 projectedTotalAssets = assets.floatingAssets +
        backupEarnings +
        accumulatedEarnings +
        (assets.floatingDebt + newDebt - assets.floatingDebt).mulWadDown(1e18 - assets.treasuryFeeRate);
      currentTotalAssets[assets.market] = projectedTotalAssets;
    }

    // we simulate 20 minutes in the future
    uint256 elapsed = 20 minutes;
    vm.warp(block.timestamp + elapsed);
    for (uint256 i = 0; i < totalAssets.length; i++) {
      RatePreviewer.TotalAssets memory assets = totalAssets[i];

      uint256 elapsedAccumulator = block.timestamp - assets.lastAccumulatorAccrual;
      uint256 accumulatedEarnings = assets.earningsAccumulator.mulDivDown(
        elapsedAccumulator,
        elapsedAccumulator + assets.earningsAccumulatorSmoothFactor.mulWadDown(assets.maxFuturePools * assets.interval)
      );
      uint256 floatingRate = assets.market.interestRateModel().floatingRate(
        assets.floatingAssets != 0 ? assets.floatingDebt.divWadUp(assets.floatingAssets) : 0,
        assets.floatingAssets != 0
          ? (assets.floatingDebt + assets.floatingBackupBorrowed).divWadUp(assets.floatingAssets)
          : 0
      );
      uint256 newDebt = assets.floatingDebt.mulWadDown(
        floatingRate.mulDivDown(block.timestamp - assets.lastFloatingDebtUpdate, 365 days)
      );
      uint256 backupEarnings = fixedPoolEarnings(assets.pools);

      uint256 projectedTotalAssets = assets.floatingAssets +
        backupEarnings +
        accumulatedEarnings +
        (assets.floatingDebt + newDebt - assets.floatingDebt).mulWadDown(1e18 - assets.treasuryFeeRate);

      uint256 totalAssetsBefore = currentTotalAssets[assets.market];
      uint256 assetsInYear = ((projectedTotalAssets - totalAssetsBefore) * 365 days) / elapsed;
      uint256 rate = (assetsInYear * 1e18) / totalAssetsBefore;
      rate;
    }
  }

  function fixedPoolEarnings(RatePreviewer.FixedPool[] memory pools) internal view returns (uint256 backupEarnings) {
    for (uint256 i = 0; i < pools.length; i++) {
      RatePreviewer.FixedPool memory pool = pools[i];

      uint256 lastAccrual = pool.lastAccrual;
      if (pool.maturity > lastAccrual) {
        backupEarnings += block.timestamp < pool.maturity
          ? pool.unassignedEarnings.mulDivDown(block.timestamp - lastAccrual, pool.maturity - lastAccrual)
          : pool.unassignedEarnings;
      }
    }
  }
}
