// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts-v4/utils/math/Math.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

import { Auditor, Market, IPriceFeed } from "../Auditor.sol";
import { FixedLib } from "../utils/FixedLib.sol";

contract IntegrationPreviewer {
  using FixedPointMathLib for uint256;
  using FixedLib for FixedLib.Position;
  using FixedLib for FixedLib.Pool;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_) {
    auditor = auditor_;
  }

  function healthFactor(address account) external view returns (uint256) {
    (uint256 adjustedCollateral, uint256 adjustedDebt) = auditor.accountLiquidity(account, Market(address(0)), 0);
    if (adjustedDebt == 0) return type(uint256).max;
    return adjustedCollateral.divWadDown(adjustedDebt);
  }

  function borrowLimit(address account, Market market, uint256 targetHealthFactor) external view returns (uint256) {
    (uint256 adjustedCollateral, uint256 adjustedDebt) = auditor.accountLiquidity(account, market, 0);
    (uint256 adjustFactor, uint256 decimals, , , IPriceFeed priceFeed) = auditor.markets(market);
    uint256 maxAdjustedDebt = adjustedCollateral.divWadDown(targetHealthFactor);
    if (adjustedDebt >= maxAdjustedDebt) return 0;
    uint256 maxExtraDebt = maxAdjustedDebt - adjustedDebt;
    return maxExtraDebt.mulWadDown(adjustFactor).mulDivDown(10 ** decimals, auditor.assetPrice(priceFeed));
  }

  function fixedRepayAssets(
    address account,
    Market market,
    uint256 maturity,
    uint256 positionAssets
  ) external view returns (uint256 assets) {
    FixedLib.Position memory position;
    (position.principal, position.fee) = market.fixedBorrowPositions(maturity, account);
    uint256 totalPosition = position.principal + position.fee;
    if (totalPosition == 0) return 0;
    if (positionAssets > totalPosition) positionAssets = totalPosition;
    if (block.timestamp >= maturity) {
      return positionAssets + positionAssets.mulWadDown((block.timestamp - maturity) * market.penaltyRate());
    }
    FixedLib.Pool memory pool;
    (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
    if (maturity > pool.lastAccrual) {
      pool.unassignedEarnings -= pool.unassignedEarnings.mulDivDown(
        block.timestamp - pool.lastAccrual,
        maturity - pool.lastAccrual
      );
    }
    (uint256 yield, ) = pool.calculateDeposit(
      position.scaleProportionally(positionAssets).principal,
      market.backupFeeRate()
    );
    return positionAssets - yield;
  }

  function fixedRepayPosition(
    address account,
    Market market,
    uint256 maturity,
    uint256 assets
  ) external view returns (uint256 positionAssets) {
    (uint256 principal, uint256 fee) = market.fixedBorrowPositions(maturity, account);
    uint256 totalPosition = principal + fee;
    if (totalPosition == 0) return 0;
    if (assets > type(uint256).max / 1e18) return totalPosition;
    if (block.timestamp >= maturity) {
      return Math.min(assets.divWadDown(1e18 + (block.timestamp - maturity) * market.penaltyRate()), totalPosition);
    }
    if (assets >= totalPosition) return totalPosition;
    (uint256 borrowed, uint256 supplied, uint256 unassignedEarnings, uint256 lastAccrual) = market.fixedPools(maturity);
    if (maturity > lastAccrual) {
      unassignedEarnings -= unassignedEarnings.mulDivDown(block.timestamp - lastAccrual, maturity - lastAccrual);
    }
    if (unassignedEarnings == 0) return assets;
    uint256 backupSupplied = borrowed - Math.min(borrowed, supplied);
    if (backupSupplied == 0) return assets;
    // k = principal / (principal + fee)
    uint256 k = principal.divWadDown(totalPosition);
    if (k == 0) return assets;
    // r = (netUnassignedEarnings / backupSupplied) * k
    uint256 netUnassignedEarnings = unassignedEarnings.mulWadDown(1e18 - market.backupFeeRate());
    if (netUnassignedEarnings == 0) return assets;
    uint256 r = netUnassignedEarnings.mulDivDown(k, backupSupplied);
    // if r >= 1, unsaturated formula breaks; use saturated fallback
    if (r >= 1e18) return Math.min(assets + netUnassignedEarnings, totalPosition);
    // unsaturated guess: x ≈ assets / (1 - r)
    uint256 x = assets.divWadDown(1e18 - r);
    // validate unsaturated assumptions: k * x <= backupSupplied and x <= totalPosition
    if (k.mulWadDown(x) <= backupSupplied && x <= totalPosition) return x;
    // saturated fallback: x ≈ assets + netUnassignedEarnings, capped by total (safe add)
    return assets + Math.min(netUnassignedEarnings, totalPosition - assets);
  }
}
