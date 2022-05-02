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

  /// @notice Gets the yield offered by a maturity when depositing certain amount of assets.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be deposited.
  /// @param amount amount of assets that will be deposited.
  /// @return earnings amount that the depositor will receive after maturity.
  function previewYieldAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 amount
  ) external view returns (uint256 earnings) {
    if (block.timestamp > maturity) revert AlreadyMatured();

    InterestRateModel interestRateModel = fixedLender.interestRateModel();
    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, pool.earningsUnassigned, pool.lastAccrual) = fixedLender.maturityPools(maturity);

    uint256 unassignedEarnings = pool.earningsUnassigned -
      pool.earningsUnassigned.fmul(block.timestamp - pool.lastAccrual, maturity - pool.lastAccrual);
    uint256 borrowed = pool.borrowed;
    uint256 supplied = pool.supplied;
    uint256 smartPoolBorrowed = borrowed - Math.min(borrowed, supplied);

    (earnings, ) = interestRateModel.getYieldForDeposit(smartPoolBorrowed, unassignedEarnings, amount);
  }

  /// @notice Gets the fee charged by a maturity when borrowing certain amount of assets.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be borrowed.
  /// @param amount amount of assets that will be borrowed.
  /// @return fees amount that the depositor will also repay at maturity.
  function previewFeeAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 amount
  ) external view returns (uint256 fees) {
    InterestRateModel interestRateModel = fixedLender.interestRateModel();
    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, , ) = fixedLender.maturityPools(maturity);

    fees = amount.fmul(
      interestRateModel.getRateToBorrow(
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
}
