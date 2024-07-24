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

  function testPreviewTotalAssets() external {
    RatePreviewer.TotalAssets[] memory totalAssets = ratePreviewer.previewTotalAssets();

    // we simulate 20 minutes in the future
    skip(20 minutes);
    for (uint256 i = 0; i < totalAssets.length; i++) {
      RatePreviewer.TotalAssets memory assets = totalAssets[i];

      assertEq(projectTotalAssets(assets, block.timestamp), assets.market.totalAssets());
    }
  }

  function testPreviewTotalAssetsWithSignificantElapsedTime() external {
    RatePreviewer.TotalAssets[] memory totalAssets = ratePreviewer.previewTotalAssets();

    // we simulate 6 weeks in the future
    skip(6 weeks);
    for (uint256 i = 0; i < totalAssets.length; i++) {
      RatePreviewer.TotalAssets memory assets = totalAssets[i];

      assertApproxEqRel(
        projectTotalAssets(assets, block.timestamp),
        assets.market.totalAssets(),
        (10 ** assets.market.decimals()) / 10000
      );
    }
  }

  function testPreviewRate() external {
    RatePreviewer.TotalAssets[] memory totalAssets = ratePreviewer.previewTotalAssets();

    // we simulate 20 minutes in the future
    uint256 elapsed = 20 minutes;
    skip(elapsed);
    for (uint256 i = 0; i < totalAssets.length; i++) {
      RatePreviewer.TotalAssets memory assets = totalAssets[i];

      uint256 projectedTotalAssets = projectTotalAssets(assets, block.timestamp);
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
      currentTotalAssets[assets.market] = projectTotalAssets(assets, block.timestamp);
    }

    // we simulate 20 minutes in the future
    uint256 elapsed = 20 minutes;
    skip(elapsed);
    for (uint256 i = 0; i < totalAssets.length; i++) {
      RatePreviewer.TotalAssets memory assets = totalAssets[i];
      uint256 projectedTotalAssets = projectTotalAssets(assets, block.timestamp);

      uint256 totalAssetsBefore = currentTotalAssets[assets.market];
      uint256 assetsInYear = ((projectedTotalAssets - totalAssetsBefore) * 365 days) / elapsed;
      uint256 rate = (assetsInYear * 1e18) / totalAssetsBefore;
      rate;
    }
  }

  function projectTotalAssets(
    RatePreviewer.TotalAssets memory assets,
    uint256 timestamp
  ) internal view returns (uint256 projectedTotalAssets) {
    uint256 elapsedAccumulator = timestamp - assets.lastAccumulatorAccrual;
    uint256 accumulatedEarnings = assets.earningsAccumulator.mulDivDown(
      elapsedAccumulator,
      elapsedAccumulator + assets.earningsAccumulatorSmoothFactor.mulWadDown(assets.maxFuturePools * assets.interval)
    );
    uint256 floatingRate = assets.market.interestRateModel().floatingRate(
      assets.floatingDebt.divWadUp(assets.floatingAssets),
      (assets.floatingDebt + assets.floatingBackupBorrowed).divWadUp(assets.floatingAssets)
    );
    uint256 newDebt = assets.floatingDebt.mulWadDown(
      floatingRate.mulDivDown(timestamp - assets.lastFloatingDebtUpdate, 365 days)
    );
    uint256 backupEarnings = fixedPoolEarnings(assets.pools, timestamp);

    projectedTotalAssets =
      assets.floatingAssets +
      backupEarnings +
      accumulatedEarnings +
      (assets.floatingDebt + newDebt - assets.floatingDebt).mulWadDown(1e18 - assets.treasuryFeeRate);
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
