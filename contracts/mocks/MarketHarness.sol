// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.16;

import { Auditor, ERC20, InterestRateModel, Market } from "../Market.sol";

contract MarketHarness is Market {
  uint256 public returnValue;

  constructor(
    ERC20 asset_,
    Auditor auditor_,
    uint8 maxFuturePools_,
    uint128 earningsAccumulatorSmoothFactor_,
    InterestRateModel interestRateModel_,
    uint256 penaltyRate_,
    uint256 backupFeeRate_,
    uint128 reserveFactor_,
    uint256 dampSpeedUp_,
    uint256 dampSpeedDown_
  )
    Market(
      asset_,
      auditor_,
      maxFuturePools_,
      earningsAccumulatorSmoothFactor_,
      interestRateModel_,
      penaltyRate_,
      backupFeeRate_,
      reserveFactor_,
      dampSpeedUp_,
      dampSpeedDown_
    )
  {}

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
