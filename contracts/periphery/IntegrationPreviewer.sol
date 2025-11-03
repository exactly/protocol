// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts-v4/utils/math/Math.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";

import { Auditor, Market, IPriceFeed } from "../Auditor.sol";
import { FixedLib } from "../utils/FixedLib.sol";

contract IntegrationPreviewer {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;
  using FixedLib for FixedLib.Position;
  using FixedLib for FixedLib.Pool;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_) {
    auditor = auditor_;
  }

  // #region health factor

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

  /// @notice Previews the health factor of an account after applying collateral and debt deltas.
  /// @dev Calculates the health factor by adjusting current collateral and debt with the provided deltas.
  /// Uses market-specific adjust factors and oracle prices for accurate calculations.
  /// @param account The account whose health factor is being previewed.
  /// @param market The market to apply the deltas to.
  /// @param collateralDelta The change in collateral (positive for deposit, negative for withdraw).
  /// @param debtDelta The change in debt (positive for borrow, negative for repay).
  /// @return The previewed health factor in WAD, or max uint256 if no debt.
  function previewHealthFactor(
    address account,
    Market market,
    int256 collateralDelta,
    int256 debtDelta
  ) public view returns (uint256) {
    (uint256 adjustedCollateral, uint256 adjustedDebt) = auditor.accountLiquidity(account, market, 0);
    (uint256 adjustFactor, uint256 decimals, , , IPriceFeed priceFeed) = auditor.markets(market);
    uint256 price = auditor.assetPrice(priceFeed);
    uint256 absAdjustedCollateralDelta = collateralDelta.abs().mulDiv(price, 10 ** decimals).mulWad(adjustFactor);
    if (collateralDelta < 0) adjustedCollateral -= absAdjustedCollateralDelta;
    else adjustedCollateral += absAdjustedCollateralDelta;
    uint256 absAdjustedDebtDelta = debtDelta.abs().mulDivUp(price, 10 ** decimals).divWadUp(adjustFactor);
    if (debtDelta < 0) adjustedDebt -= absAdjustedDebtDelta;
    else adjustedDebt += absAdjustedDebtDelta;
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
  // #endregion

  // #region preview operations

  /// @notice Previews the result of depositing assets into a market.
  /// @dev Calculates the shares that would be minted and the resulting health factor.
  /// @param account The account performing the deposit.
  /// @param market The market to deposit into.
  /// @param assets The amount of assets to deposit.
  /// @return preview A struct containing the shares to be minted and resulting health factor.
  function previewDeposit(address account, Market market, uint256 assets) external view returns (SharesPreview memory) {
    uint256 shares = market.previewDeposit(assets);
    uint256 sharesPre = market.balanceOf(account);
    uint256 interest = market.totalFloatingBorrowAssets() - market.floatingDebt();
    uint256 treasuryFeeRate = market.treasuryFeeRate();
    uint256 totalSupplyPlus = market.totalSupply() + shares;
    uint256 totalAssetsPost = market.totalAssets() - interest.mulWad(1e18 - treasuryFeeRate) + assets + interest;
    uint256 totalSupplyPost = totalSupplyPlus +
      interest.mulWad(treasuryFeeRate).mulDiv(totalSupplyPlus, totalAssetsPost - interest.mulWad(treasuryFeeRate));
    return
      SharesPreview({
        shares: shares,
        healthFactor: previewHealthFactor(
          account,
          market,
          int256((sharesPre + shares).mulDiv(totalAssetsPost, totalSupplyPost) - market.previewRedeem(sharesPre)),
          0
        )
      });
  }

  /// @notice Previews the result of withdrawing assets from a market.
  /// @dev Calculates the shares that would be burned and the resulting health factor.
  /// @param account The account performing the withdrawal.
  /// @param market The market to withdraw from.
  /// @param assets The amount of assets to withdraw.
  /// @return preview A struct containing the shares to be burned and resulting health factor.
  function previewWithdraw(
    address account,
    Market market,
    uint256 assets
  ) external view returns (SharesPreview memory) {
    uint256 shares = market.previewWithdraw(assets);
    uint256 sharesPre = market.balanceOf(account);
    uint256 interest = market.totalFloatingBorrowAssets() - market.floatingDebt();
    uint256 treasuryFeeRate = market.treasuryFeeRate();
    uint256 totalSupplyPre = market.totalSupply();
    uint256 totalAssetsPost = market.totalAssets() - interest.mulWad(1e18 - treasuryFeeRate) + interest - assets;
    uint256 fee = interest.mulWad(treasuryFeeRate);
    uint256 preTreasuryAssets = totalAssetsPost + assets - fee;
    int256 collateralDelta = int256(
      (sharesPre - shares).mulDiv(
        totalAssetsPost,
        totalSupplyPre + fee.mulDiv(totalSupplyPre, preTreasuryAssets) - shares
      )
    ) - int256(market.previewRedeem(sharesPre));
    return SharesPreview({ shares: shares, healthFactor: previewHealthFactor(account, market, collateralDelta, 0) });
  }

  /// @notice Previews the result of borrowing assets at a fixed maturity.
  /// @dev Calculates the total assets owed (principal + interest) and resulting health factor.
  /// @param account The account performing the borrow.
  /// @param market The market to borrow from.
  /// @param maturity The maturity timestamp for the fixed-rate loan.
  /// @param assets The amount of assets to borrow.
  /// @return preview A struct containing the total assets owed and resulting health factor.
  function previewBorrowAtMaturity(
    address account,
    Market market,
    uint256 maturity,
    uint256 assets
  ) public view returns (AssetsPreview memory) {
    (uint256 borrowed, uint256 supplied, , ) = market.fixedPools(maturity);
    uint256 rate = market.interestRateModel().fixedBorrowRate(maturity, assets, borrowed, supplied, 0);
    uint256 fee = assets.mulWadUp(rate);
    uint256 assetsOwed = assets + fee;
    return
      AssetsPreview({ assets: assetsOwed, healthFactor: previewHealthFactor(account, market, 0, int256(assetsOwed)) });
  }

  /// @notice Previews the result of repaying a fixed-rate position.
  /// @dev Calculates the assets required to repay the position and resulting health factor.
  /// @param account The account performing the repayment.
  /// @param market The market containing the position.
  /// @param maturity The maturity timestamp of the fixed-rate position.
  /// @param positionAssets The amount of position (principal + fee) to repay.
  /// @return preview A struct containing the assets required and resulting health factor.
  function previewRepayAtMaturity(
    address account,
    Market market,
    uint256 maturity,
    uint256 positionAssets
  ) public view returns (AssetsPreview memory) {
    return
      AssetsPreview({
        assets: fixedRepayAssets(account, market, maturity, positionAssets),
        healthFactor: previewHealthFactor(account, market, 0, -int256(positionAssets))
      });
  }

  /// @notice Preview result for ERC-4626 operations (deposit/withdraw).
  struct SharesPreview {
    /// @notice The number of shares that would be minted or burned.
    uint256 shares;
    /// @notice The resulting health factor after the operation.
    uint256 healthFactor;
  }

  /// @notice Preview result for assets operations.
  struct AssetsPreview {
    /// @notice The total assets involved in the operation.
    uint256 assets;
    /// @notice The resulting health factor after the operation.
    uint256 healthFactor;
  }
  // #endregion

  // #region fixed repay

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
  ) public view returns (uint256 assets) {
    FixedLib.Position memory position;
    (position.principal, position.fee) = market.fixedBorrowPositions(maturity, account);
    uint256 totalPosition = position.principal + position.fee;
    if (totalPosition == 0) return 0;
    if (positionAssets > totalPosition) positionAssets = totalPosition;
    if (block.timestamp >= maturity) {
      return positionAssets + positionAssets.mulWad((block.timestamp - maturity) * market.penaltyRate());
    }
    return positionAssets - fixedDepositYield(market, maturity, position.scaleProportionally(positionAssets).principal);
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
  // #endregion

  function fixedDepositYield(Market market, uint256 maturity, uint256 assets) internal view returns (uint256 yield) {
    FixedLib.Pool memory p;
    (p.borrowed, p.supplied, p.unassignedEarnings, p.lastAccrual) = market.fixedPools(maturity);
    if (maturity > p.lastAccrual) {
      p.unassignedEarnings -= p.unassignedEarnings.mulDiv(block.timestamp - p.lastAccrual, maturity - p.lastAccrual);
    }
    (yield, ) = p.calculateDeposit(assets, market.backupFeeRate());
  }
}
