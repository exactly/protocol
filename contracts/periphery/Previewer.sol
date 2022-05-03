// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { FixedPointMathLib } from "@rari-capital/solmate-v6/src/utils/FixedPointMathLib.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedLender } from "../FixedLender.sol";
import { InterestRateModel, AlreadyMatured } from "../InterestRateModel.sol";
import { PoolLib } from "../utils/PoolLib.sol";

/// @title Previewer
/// @notice Contract to be consumed by Exactly's front-end dApp.
contract Previewer {
  using FixedPointMathLib for uint256;
  using PoolLib for PoolLib.Position;

  /// @notice Gets the yield offered by a maturity when depositing certain amount of assets.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be deposited.
  /// @param amount amount of assets that will be deposited.
  /// @return yield that the depositor will receive after maturity.
  function previewDepositAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 amount
  ) external view returns (uint256 yield) {
    if (block.timestamp > maturity) revert AlreadyMatured();

    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, pool.earningsUnassigned, pool.lastAccrual) = fixedLender.maturityPools(maturity);
    (uint256 smartPoolBorrowed, uint256 unassignedEarnings) = getPoolData(fixedLender, maturity);

    (yield, ) = fixedLender.interestRateModel().getYieldForDeposit(smartPoolBorrowed, unassignedEarnings, amount);
  }

  /// @notice Gets the fee charged by a maturity when borrowing certain amount of assets.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be borrowed.
  /// @param amount amount of assets that will be borrowed.
  /// @return fees that the depositor will also repay at maturity.
  function previewBorrowAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 amount
  ) external view returns (uint256 fees) {
    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, , ) = fixedLender.maturityPools(maturity);

    fees = amount.fmul(
      fixedLender.interestRateModel().getRateToBorrow(
        maturity,
        block.timestamp,
        amount,
        pool.borrowed,
        pool.supplied,
        fixedLender.smartPoolBalance()
      ),
      1e18
    );
  }

  /// @notice Gets the fee charged by a maturity when withdrawing certain amount of assets before maturity.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be withdrawn.
  /// @param amount amount of assets that will be withdrawn.
  /// @return fees that will be charged to the withdrawer.
  function previewWithdrawAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 amount
  ) external view returns (uint256 fees) {
    if (block.timestamp >= maturity) revert AlreadyMatured();

    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, , ) = fixedLender.maturityPools(maturity);

    fees =
      amount -
      amount.fdiv(
        1e18 +
          fixedLender.interestRateModel().getRateToBorrow(
            maturity,
            block.timestamp,
            amount,
            pool.borrowed,
            pool.supplied,
            fixedLender.smartPoolBalance()
          ),
        1e18
      );
  }

  /// @notice Gets the discount offered by a maturity when repaying certain amount of assets before maturity.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be discounted when repaying.
  /// @param amount amount of assets that will be repayed.
  /// @return discount that the repayer will receive.
  function previewRepayAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 amount,
    address borrower
  ) external view returns (uint256 discount) {
    if (block.timestamp >= maturity) revert AlreadyMatured();

    (uint256 smartPoolBorrowed, uint256 unassignedEarnings) = getPoolData(fixedLender, maturity);
    PoolLib.Position memory debt;
    (debt.principal, debt.fee) = fixedLender.mpUserBorrowedAmount(maturity, borrower);
    PoolLib.Position memory coveredDebt = debt.scaleProportionally(amount);

    (discount, ) = fixedLender.interestRateModel().getYieldForDeposit(
      smartPoolBorrowed,
      unassignedEarnings,
      coveredDebt.principal
    );
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
