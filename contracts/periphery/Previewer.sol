// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { FixedPointMathLib } from "@rari-capital/solmate-v6/src/utils/FixedPointMathLib.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedLender } from "../FixedLender.sol";
import { InterestRateModel, AlreadyMatured } from "../InterestRateModel.sol";
import { Auditor } from "../Auditor.sol";
import { PoolLib } from "../utils/PoolLib.sol";

/// @title Previewer
/// @notice Contract to be consumed by Exactly's front-end dApp.
contract Previewer {
  using FixedPointMathLib for uint256;
  using PoolLib for PoolLib.Position;

  /// @notice Gets the assets plus yield offered by a maturity when depositing a certain amount.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be deposited.
  /// @param assets amount of assets that will be deposited.
  /// @return positionAssets amount plus yield that the depositor will receive after maturity.
  function previewDepositAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 assets
  ) external view returns (uint256 positionAssets) {
    if (block.timestamp > maturity) revert AlreadyMatured();

    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, pool.earningsUnassigned, pool.lastAccrual) = fixedLender.maturityPools(maturity);
    (uint256 smartPoolBorrowed, uint256 unassignedEarnings) = getPoolData(fixedLender, maturity);

    (uint256 yield, ) = fixedLender.interestRateModel().getYieldForDeposit(
      smartPoolBorrowed,
      unassignedEarnings,
      assets
    );
    positionAssets = assets + yield;
  }

  /// @notice Gets the amount plus fees to be repayed at maturity when borrowing certain amount of assets.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be borrowed.
  /// @param assets amount of assets that will be borrowed.
  /// @return positionAssets amount plus fees that the depositor will repay at maturity.
  function previewBorrowAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 assets
  ) external view returns (uint256 positionAssets) {
    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, , ) = fixedLender.maturityPools(maturity);

    uint256 fees = assets.fmul(
      fixedLender.interestRateModel().getRateToBorrow(
        maturity,
        block.timestamp,
        assets,
        pool.borrowed,
        pool.supplied,
        fixedLender.smartPoolBalance()
      ),
      1e18
    );
    positionAssets = assets + fees;
  }

  /// @notice Gets the amount to be withdrawn for a certain positionAmount of assets at maturity.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be withdrawn.
  /// @param positionAssets amount of assets that will be tried to withdraw.
  /// @return withdrawAssets amount that will be withdrawn.
  function previewWithdrawAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 positionAssets
  ) external view returns (uint256 withdrawAssets) {
    if (block.timestamp >= maturity) return positionAssets;

    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, , ) = fixedLender.maturityPools(maturity);

    withdrawAssets = positionAssets.fdiv(
      1e18 +
        fixedLender.interestRateModel().getRateToBorrow(
          maturity,
          block.timestamp,
          positionAssets,
          pool.borrowed,
          pool.supplied,
          fixedLender.smartPoolBalance()
        ),
      1e18
    );
  }

  /// @notice Gets the assets that will be repaid when repaying a certain amount at the current maturity.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be repaid.
  /// @param positionAssets amount of assets that will be substracted from the position.
  /// @param borrower address of the borrower.
  /// @return repayAssets amount of assets that will be repaid.
  function previewRepayAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 positionAssets,
    address borrower
  ) external view returns (uint256 repayAssets) {
    if (block.timestamp >= maturity)
      return
        repayAssets =
          positionAssets +
          positionAssets.fmul((block.timestamp - maturity) * fixedLender.penaltyRate(), 1e18);

    (uint256 smartPoolBorrowed, uint256 unassignedEarnings) = getPoolData(fixedLender, maturity);
    PoolLib.Position memory debt;
    (debt.principal, debt.fee) = fixedLender.mpUserBorrowedAmount(maturity, borrower);
    PoolLib.Position memory coveredDebt = debt.scaleProportionally(positionAssets);

    (uint256 discount, ) = fixedLender.interestRateModel().getYieldForDeposit(
      smartPoolBorrowed,
      unassignedEarnings,
      coveredDebt.principal
    );
    repayAssets = positionAssets - discount;
  }

  /// @notice Function to get a certain account liquidity.
  /// @param auditor address of the auditor.
  /// @param account address which the liquidity will be calculated.
  /// @return sumCollateral sum of all collateral, already multiplied by each collateral factor. denominated in usd.
  /// @return sumDebt sum of all debt. denominated in usd.
  function accountLiquidity(Auditor auditor, address account)
    external
    view
    returns (uint256 sumCollateral, uint256 sumDebt)
  {
    Auditor.AccountLiquidity memory vars; // Holds all our calculation results

    // For each asset the account is in
    uint256 assets = auditor.accountAssets(account);
    uint256 maxValue = auditor.getAllMarkets().length;
    uint256 decimals;
    uint256 collateralFactor;
    for (uint256 i = 0; i < maxValue; ) {
      if ((assets & (1 << i)) != 0) {
        FixedLender asset = auditor.allMarkets(i);

        (, , collateralFactor, decimals, , ) = auditor.markets(asset);

        // Read the balances
        (vars.balance, vars.borrowBalance) = asset.getAccountSnapshot(account, PoolLib.MATURITY_ALL);

        // Get the normalized price of the asset (18 decimals)
        vars.oraclePrice = auditor.oracle().getAssetPrice(asset.assetSymbol());

        // We sum all the collateral prices
        sumCollateral += vars.balance.fmul(vars.oraclePrice, 10**decimals).fmul(collateralFactor, 1e18);

        // We sum all the debt
        sumDebt += vars.borrowBalance.fmul(vars.oraclePrice, 10**decimals);
      }
      unchecked {
        ++i;
      }
      if ((1 << i) > assets) break;
    }
  }

  function getPoolData(FixedLender fixedLender, uint256 maturity)
    internal
    view
    returns (uint256 smartPoolBorrowed, uint256 unassignedEarnings)
  {
    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, pool.earningsUnassigned, pool.lastAccrual) = fixedLender.maturityPools(maturity);

    smartPoolBorrowed = pool.borrowed - Math.min(pool.borrowed, pool.supplied);
    unassignedEarnings =
      pool.earningsUnassigned -
      pool.earningsUnassigned.fmul(block.timestamp - pool.lastAccrual, maturity - pool.lastAccrual);
  }
}
