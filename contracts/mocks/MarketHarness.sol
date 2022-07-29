// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import { Market, InterestRateModel, ERC20, Auditor } from "../Market.sol";

contract MarketHarness is Market {
  uint256 public returnValue;

  constructor(
    ERC20 asset,
    uint8 maxFuturePools,
    uint128 earningsAccumulatorSmoothFactor,
    Auditor auditor,
    InterestRateModel interestRateModel,
    uint256 penaltyRate,
    uint256 backupFeeRate,
    uint128 reserveFactor,
    DampSpeed memory dampSpeed
  )
    Market(
      asset,
      maxFuturePools,
      earningsAccumulatorSmoothFactor,
      auditor,
      interestRateModel,
      penaltyRate,
      backupFeeRate,
      reserveFactor,
      dampSpeed
    )
  {} // solhint-disable-line no-empty-blocks

  function borrowMaturityWithReturnValue(
    uint256 maturity,
    uint256 assets,
    uint256 maxAssetsAllowed,
    address receiver,
    address borrower
  ) external {
    returnValue = borrowAtMaturity(maturity, assets, maxAssetsAllowed, receiver, borrower);
  }

  function depositMaturityWithReturnValue(
    uint256 maturity,
    uint256 assets,
    uint256 minAssetsRequired,
    address receiver
  ) external {
    returnValue = depositAtMaturity(maturity, assets, minAssetsRequired, receiver);
  }

  function withdrawMaturityWithReturnValue(
    uint256 maturity,
    uint256 positionAssets,
    uint256 minAssetsRequired,
    address receiver,
    address owner
  ) external {
    returnValue = withdrawAtMaturity(maturity, positionAssets, minAssetsRequired, receiver, owner);
  }

  function repayMaturityWithReturnValue(
    uint256 maturity,
    uint256 positionAssets,
    uint256 maxAssetsAllowed,
    address borrower
  ) external {
    returnValue = repayAtMaturity(maturity, positionAssets, maxAssetsAllowed, borrower);
  }

  // function to avoid range value validation
  function setFreePenaltyRate(uint256 penaltyRate_) external {
    penaltyRate = penaltyRate_;
  }
}
