// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts-v4/utils/math/Math.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";

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

  /// @notice Returns the health factor of an `account` across supported markets.
  /// @dev Uses `auditor.accountLiquidity` with no delta to obtain adjusted collateral and debt.
  /// If the account has no debt, returns `type(uint256).max`.
  /// Health factor is expressed in WAD (1e18 = 1.0).
  /// @param account The account whose health factor is being queried.
  /// @return healthFactor The account health factor in WAD, or max when there is no debt.
  function healthFactor(address account) external view returns (uint256) {
    (uint256 adjustedCollateral, uint256 adjustedDebt) = auditor.accountLiquidity(account, Market(address(0)), 0);
    if (adjustedDebt == 0) return type(uint256).max;
    return adjustedCollateral.divWad(adjustedDebt);
  }

  /// @notice Returns the maximum additional amount of underlying assets the `account` can
  /// borrow from `market` so that its health factor becomes `targetHealthFactor`.
  /// @dev Computes the limit from current adjusted collateral and debt, applying the market
  /// adjust factor and oracle price. All arithmetic is rounded down for safety.
  /// Returns 0 if the account is already at or past the target.
  /// @param account The borrower address to evaluate.
  /// @param market The market from which additional assets would be borrowed.
  /// @param targetHealthFactor The desired health factor in WAD (1e18 = 1.0).
  /// @return maxAssets The maximum extra underlying assets that can be borrowed safely.
  function borrowLimit(address account, Market market, uint256 targetHealthFactor) external view returns (uint256) {
    (uint256 adjustedCollateral, uint256 adjustedDebt) = auditor.accountLiquidity(account, market, 0);
    (uint256 adjustFactor, uint256 decimals, , , IPriceFeed priceFeed) = auditor.markets(market);
    uint256 maxAdjustedDebt = adjustedCollateral.divWad(targetHealthFactor);
    if (adjustedDebt >= maxAdjustedDebt) return 0;
    uint256 maxExtraDebt = maxAdjustedDebt - adjustedDebt;
    return maxExtraDebt.mulWad(adjustFactor).mulDiv(10 ** decimals, auditor.assetPrice(priceFeed));
  }

  /// @notice Preview the amount of underlying `assets` required to repay `positionAssets`
  /// of a fixed-rate borrow position for `account` at `maturity` in `market`.
  /// @dev Caps `positionAssets` to the total position (principal + fee). If the position
  /// is past maturity, applies a linear penalty proportional to the elapsed time.
  /// Before maturity, uses pool state and `calculateDeposit` to account for unassigned
  /// earnings and backup fee rate; result is rounded down.
  /// @param account The borrower whose fixed position is being repaid.
  /// @param market The market that holds the fixed-rate position.
  /// @param maturity The UNIX timestamp identifying the fixed-rate pool.
  /// @param positionAssets The amount of position (principal + fee) to repay.
  /// @return assets The required amount of underlying assets to transfer for the repay.
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
      return positionAssets + positionAssets.mulWad((block.timestamp - maturity) * market.penaltyRate());
    }
    FixedLib.Pool memory pool;
    (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
    if (maturity > pool.lastAccrual) {
      pool.unassignedEarnings -= pool.unassignedEarnings.mulDiv(
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

  /// @notice Preview the portion of the fixed-rate position that can be covered with `assets`
  /// provided by `account` in `market` at `maturity`.
  /// @dev Bounded by the total position (principal + fee). If the pool is past maturity,
  /// accounts for the linear penalty. Before maturity, estimates based on pool
  /// unassigned earnings and backup-supplied liquidity, using an unsaturated guess
  /// with a saturated fallback when assumptions do not hold. All arithmetic rounds down.
  /// @param account The borrower whose fixed position is being repaid.
  /// @param market The market that holds the fixed-rate position.
  /// @param maturity The UNIX timestamp identifying the fixed-rate pool.
  /// @param assets The amount of underlying assets provided to cover the position.
  /// @return positionAssets The portion of the position (principal + fee) that would be covered.
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
      return Math.min(assets.divWad(1e18 + (block.timestamp - maturity) * market.penaltyRate()), totalPosition);
    }
    if (assets >= totalPosition) return totalPosition;
    (uint256 borrowed, uint256 supplied, uint256 unassignedEarnings, uint256 lastAccrual) = market.fixedPools(maturity);
    if (maturity > lastAccrual) {
      unassignedEarnings -= unassignedEarnings.mulDiv(block.timestamp - lastAccrual, maturity - lastAccrual);
    }
    if (unassignedEarnings == 0) return assets;
    uint256 backupSupplied = borrowed - Math.min(borrowed, supplied);
    if (backupSupplied == 0) return assets;
    // k = principal / (principal + fee)
    uint256 k = principal.divWad(totalPosition);
    if (k == 0) return assets;
    // r = (netUnassignedEarnings / backupSupplied) * k
    uint256 netUnassignedEarnings = unassignedEarnings.mulWad(1e18 - market.backupFeeRate());
    if (netUnassignedEarnings == 0) return assets;
    uint256 r = netUnassignedEarnings.mulDiv(k, backupSupplied);
    // if r >= 1, unsaturated formula breaks; use saturated fallback
    if (r >= 1e18) return Math.min(assets + netUnassignedEarnings, totalPosition);
    // unsaturated guess: x ≈ assets / (1 - r)
    uint256 x = assets.divWad(1e18 - r);
    // validate unsaturated assumptions: k * x <= backupSupplied and x <= totalPosition
    if (k.mulWad(x) <= backupSupplied && x <= totalPosition) return x;
    // saturated fallback: x ≈ assets + netUnassignedEarnings, capped by total (safe add)
    return assets + Math.min(netUnassignedEarnings, totalPosition - assets);
  }

  /// @notice Returns a snapshot of pool and position parameters used for fixed repay previews.
  /// @dev Reads pool aggregates and the borrower's position at `maturity`; does not mutate state.
  /// Useful for off-chain simulations and UI previews.
  /// @param account The borrower whose position is queried.
  /// @param market The market to query.
  /// @param maturity The UNIX timestamp identifying the fixed-rate pool.
  /// @return snapshot A `FixedRepaySnapshot` with penalty/fee rates, pool, and position data.
  function fixedRepaySnapshot(
    address account,
    Market market,
    uint256 maturity
  ) external view returns (FixedRepaySnapshot memory snapshot) {
    (uint256 borrowed, uint256 supplied, uint256 unassignedEarnings, uint256 lastAccrual) = market.fixedPools(maturity);
    (uint256 principal, uint256 fee) = market.fixedBorrowPositions(maturity, account);
    snapshot = FixedRepaySnapshot({
      penaltyRate: market.penaltyRate(),
      backupFeeRate: market.backupFeeRate(),
      borrowed: borrowed,
      supplied: supplied,
      unassignedEarnings: unassignedEarnings,
      lastAccrual: lastAccrual,
      principal: principal,
      fee: fee
    });
  }

  /// @notice Aggregated pool and position data used to preview fixed-position repayments.
  struct FixedRepaySnapshot {
    /// @notice Late repayment penalty rate applied after maturity (WAD per second).
    uint256 penaltyRate;
    /// @notice Backup fee rate kept by the protocol when using backup liquidity (WAD fraction).
    uint256 backupFeeRate;
    /// @notice Total borrowed in the fixed pool at `maturity` (underlying asset units).
    uint256 borrowed;
    /// @notice Total supplied in the fixed pool at `maturity` (underlying asset units).
    uint256 supplied;
    /// @notice Unassigned earnings of the pool at snapshot (underlying asset units).
    uint256 unassignedEarnings;
    /// @notice Last timestamp when the pool accrued earnings (UNIX seconds).
    uint256 lastAccrual;
    /// @notice Borrower's principal outstanding for the fixed position (underlying asset units).
    uint256 principal;
    /// @notice Borrower's fee outstanding for the fixed position (underlying asset units).
    uint256 fee;
  }
}
