// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable-v4/utils/math/MathUpgradeable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { AlreadyMatured } from "../InterestRateModel.sol";
import { PreviewerLib } from "../utils/PreviewerLib.sol";
import { FixedLib } from "../utils/FixedLib.sol";
import { Market } from "../Market.sol";

/// @title FixedPreviewer
/// @notice Contract to be consumed by Exactly's front-end dApp.
contract FixedPreviewer {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;
  using FixedLib for FixedLib.Position;
  using FixedLib for FixedLib.Pool;
  using PreviewerLib for Market;

  struct FixedPreview {
    uint256 maturity;
    uint256 assets;
    uint256 utilization;
  }

  /// @notice Gets the assets plus yield offered by a maturity when depositing a certain amount.
  /// @param market address of the market.
  /// @param maturity maturity date/pool where the assets will be deposited.
  /// @param assets amount of assets that will be deposited.
  /// @return amount plus yield that the depositor will receive after maturity.
  function previewDepositAtMaturity(
    Market market,
    uint256 maturity,
    uint256 assets
  ) public view returns (FixedPreview memory) {
    if (block.timestamp > maturity) revert AlreadyMatured();
    FixedLib.Pool memory pool;
    (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
    uint256 floatingAssets = market.floatingAssets();

    return
      FixedPreview({
        maturity: maturity,
        assets: assets + fixedDepositYield(market, maturity, assets),
        utilization: (floatingAssets > 0 && pool.borrowed > pool.supplied + assets)
          ? (pool.borrowed - assets - pool.supplied).divWadUp(floatingAssets)
          : 0
      });
  }

  /// @notice Gets the assets plus yield offered by all VALID maturities when depositing a certain amount.
  /// @param market address of the market.
  /// @param assets amount of assets that will be deposited.
  /// @return previews array containing amount plus yield that account will receive after each maturity.
  function previewDepositAtAllMaturities(
    Market market,
    uint256 assets
  ) external view returns (FixedPreview[] memory previews) {
    uint256 maxFuturePools = market.maxFuturePools();
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    previews = new FixedPreview[](maxFuturePools);
    for (uint256 i = 0; i < maxFuturePools; ) {
      previews[i] = previewDepositAtMaturity(market, maturity, assets);
      maturity += FixedLib.INTERVAL;
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Gets the amount plus fees to be repaid at maturity when borrowing certain amount of assets.
  /// @param market address of the market.
  /// @param maturity maturity date/pool where the assets will be borrowed.
  /// @param assets amount of assets that will be borrowed.
  /// @return positionAssets amount plus fees that the depositor will repay at maturity.
  function previewBorrowAtMaturity(
    Market market,
    uint256 maturity,
    uint256 assets
  ) public view returns (FixedPreview memory) {
    FixedLib.Pool memory pool;
    (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
    uint256 floatingAssets = market.floatingAssets() +
      (
        maturity > pool.lastAccrual
          ? pool.unassignedEarnings.mulDivDown(block.timestamp - pool.lastAccrual, maturity - pool.lastAccrual)
          : pool.unassignedEarnings
      ) +
      market.newFloatingDebt();

    return
      FixedPreview({
        maturity: maturity,
        assets: assets +
          assets.mulWadUp(
            fixedRate(market, maturity, pool, floatingAssets, assets).mulDivDown(
              block.timestamp <= maturity ? maturity - block.timestamp : 0,
              365 days
            )
          ),
        utilization: (floatingAssets > 0 && pool.borrowed + assets > pool.supplied)
          ? (pool.borrowed + assets - pool.supplied).divWadUp(floatingAssets)
          : 0
      });
  }

  /// @notice Gets the assets plus fees offered by all VALID maturities when borrowing a certain amount.
  /// @param market address of the market.
  /// @param assets amount of assets that will be borrowed.
  /// @return previews array containing amount plus yield that account will receive after each maturity.
  function previewBorrowAtAllMaturities(
    Market market,
    uint256 assets
  ) external view returns (FixedPreview[] memory previews) {
    uint256 maxFuturePools = market.maxFuturePools();
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    previews = new FixedPreview[](maxFuturePools);
    for (uint256 i = 0; i < maxFuturePools; ) {
      try this.previewBorrowAtMaturity(market, maturity, assets) returns (FixedPreview memory preview) {
        previews[i] = preview;
      } catch {
        previews[i] = FixedPreview({ maturity: maturity, assets: type(uint256).max, utilization: type(uint256).max });
      }
      maturity += FixedLib.INTERVAL;
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Gets the amount to be withdrawn for a certain positionAmount of assets at maturity.
  /// @param market address of the market.
  /// @param maturity maturity date/pool where the assets will be withdrawn.
  /// @param positionAssets amount of assets that will be tried to withdraw.
  /// @return withdrawAssets amount that will be withdrawn.
  function previewWithdrawAtMaturity(
    Market market,
    uint256 maturity,
    uint256 positionAssets,
    address owner
  ) public view returns (FixedPreview memory) {
    (FixedLib.Pool memory pool, uint256 principal) = previewData(market, maturity, positionAssets, owner, false);
    uint256 floatingAssets = market.floatingAssets() + market.newFloatingDebt();

    return
      FixedPreview({
        maturity: maturity,
        assets: block.timestamp < maturity
          ? positionAssets.divWadDown(
            1e18 +
              market.interestRateModel().fixedBorrowRate(
                maturity,
                positionAssets,
                pool.borrowed,
                pool.supplied,
                floatingAssets
              )
          )
          : positionAssets,
        utilization: floatingAssets > 0 && pool.borrowed > pool.supplied + principal
          ? (pool.borrowed - principal - pool.supplied).divWadUp(floatingAssets)
          : 0
      });
  }

  /// @notice Gets the assets that will be repaid when repaying a certain amount at the current maturity.
  /// @param market address of the market.
  /// @param maturity maturity date/pool where the assets will be repaid.
  /// @param positionAssets amount of assets that will be subtracted from the position.
  /// @param borrower address of the borrower.
  /// @return repayAssets amount of assets that will be repaid.
  function previewRepayAtMaturity(
    Market market,
    uint256 maturity,
    uint256 positionAssets,
    address borrower
  ) public view returns (FixedPreview memory) {
    (FixedLib.Pool memory pool, uint256 principal) = previewData(market, maturity, positionAssets, borrower, true);
    uint256 floatingAssets = market.floatingAssets() + market.newFloatingDebt();

    return
      FixedPreview({
        maturity: maturity,
        assets: block.timestamp < maturity
          ? positionAssets - fixedDepositYield(market, maturity, principal)
          : positionAssets + positionAssets.mulWadDown((block.timestamp - maturity) * market.penaltyRate()),
        utilization: floatingAssets > 0 && pool.borrowed > pool.supplied + principal
          ? (pool.borrowed - principal - pool.supplied).divWadUp(floatingAssets)
          : 0
      });
  }

  function previewData(
    Market market,
    uint256 maturity,
    uint256 positionAssets,
    address account,
    bool isRepay
  ) internal view returns (FixedLib.Pool memory pool, uint256) {
    (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
    FixedLib.Position memory position;
    (position.principal, position.fee) = isRepay
      ? market.fixedBorrowPositions(maturity, account)
      : market.fixedDepositPositions(maturity, account);
    return (pool, position.scaleProportionally(positionAssets).principal);
  }

  function fixedRate(
    Market market,
    uint256 maturity,
    FixedLib.Pool memory pool,
    uint256 floatingAssets,
    uint256 assets
  ) internal view returns (uint256) {
    uint256 globalUtilization = floatingAssets != 0
      ? (market.totalFloatingBorrowAssets() +
        market.floatingBackupBorrowed() +
        pool.borrowed +
        assets -
        Math.min(Math.max(pool.borrowed, pool.supplied), pool.borrowed + assets)).divWadUp(floatingAssets)
      : 0;
    uint256 uGlobalAverage;
    {
      uint256 averageFactor = uint256(
        1e18 -
          (
            -int256(
              globalUtilization < market.globalUtilizationAverage()
                ? market.uDampSpeedDown()
                : market.uDampSpeedUp() * (block.timestamp - market.lastAverageUpdate())
            )
          ).expWad()
      );
      uGlobalAverage =
        market.globalUtilizationAverage().mulWadDown(1e18 - averageFactor) +
        averageFactor.mulWadDown(globalUtilization);
    }
    uint256 memMaturityDuration = maturityDebtDuration(market, maturity, assets);
    return
      market.interestRateModel().fixedRate(
        maturity,
        market.maxFuturePools(),
        floatingAssets != 0 && pool.borrowed + assets > pool.supplied
          ? (pool.borrowed + assets - pool.supplied).divWadUp(floatingAssets)
          : 0,
        floatingAssets != 0 ? market.totalFloatingBorrowAssets().divWadUp(floatingAssets) : 0,
        globalUtilization,
        uGlobalAverage,
        memMaturityDuration
      );
  }

  function fixedDepositYield(Market market, uint256 maturity, uint256 assets) internal view returns (uint256 yield) {
    FixedLib.Pool memory pool;
    (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
    if (maturity > pool.lastAccrual) {
      pool.unassignedEarnings -= pool.unassignedEarnings.mulDivDown(
        block.timestamp - pool.lastAccrual,
        maturity - pool.lastAccrual
      );
    }
    (yield, ) = pool.calculateDeposit(assets, market.backupFeeRate());
  }

  function maturityDebtDuration(
    Market market,
    uint256 maturity,
    uint256 assets
  ) internal view returns (uint256 duration) {
    uint256 memFloatingAssetsAverage = market.previewFloatingAssetsAverage();
    if (memFloatingAssetsAverage != 0) {
      uint256 latestMaturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL);
      uint256 maxMaturity = latestMaturity + (market.maxFuturePools()) * FixedLib.INTERVAL;
      for (uint256 i = latestMaturity + FixedLib.INTERVAL; i <= maxMaturity; i += FixedLib.INTERVAL) {
        (uint256 borrowed, uint256 supplied, , ) = market.fixedPools(i);
        if (i == maturity) borrowed += assets;
        uint256 borrows = borrowed > supplied ? borrowed - supplied : 0;
        duration += borrows.mulDivDown(maturity - block.timestamp, 365 days).divWadDown(memFloatingAssetsAverage);
      }
    }
  }
}
