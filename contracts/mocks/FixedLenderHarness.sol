// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { FixedLender, InterestRateModel, ERC20, Auditor } from "../FixedLender.sol";
import "hardhat/console.sol";

contract FixedLenderHarness is FixedLender {
  struct ReturnValues {
    uint256 totalOwedNewBorrow;
    uint256 currentTotalDeposit;
    uint256 actualRepayAmount;
    uint256 earningsSP;
    uint256 debtCovered;
    uint256 redeemAmountDiscounted;
  }

  ReturnValues public returnValues;
  uint256 public timestamp;

  constructor(
    ERC20 asset,
    uint8 maxFuturePools,
    uint128 accumulatedEarningsSmoothFactor,
    Auditor auditor,
    InterestRateModel interestRateModel,
    uint256 penaltyRate,
    uint128 smartPoolReserveFactor,
    DampSpeed memory dampSpeed
  )
    FixedLender(
      asset,
      maxFuturePools,
      accumulatedEarningsSmoothFactor,
      auditor,
      interestRateModel,
      penaltyRate,
      smartPoolReserveFactor,
      dampSpeed
    )
  {
    timestamp = block.timestamp;
  }

  function borrowMPWithReturnValues(
    uint256 maturity,
    address borrower,
    uint256 amount,
    uint256 maxAmountAllowed
  ) external {
    (returnValues.totalOwedNewBorrow, returnValues.earningsSP) = borrowMP(maturity, borrower, amount, maxAmountAllowed);
  }

  function depositMaturityWithReturnValue(
    uint256 maturity,
    uint256 assets,
    uint256 minAssetsRequired,
    address receiver
  ) external {
    returnValues.currentTotalDeposit = depositAtMaturity(maturity, assets, minAssetsRequired, receiver);
  }

  function withdrawMaturityWithReturnValue(
    uint256 maturity,
    uint256 positionAssets,
    uint256 minAssetsRequired,
    address receiver,
    address owner
  ) external {
    returnValues.redeemAmountDiscounted = withdrawAtMaturity(
      maturity,
      positionAssets,
      minAssetsRequired,
      receiver,
      owner
    );
  }

  function repayMPWithReturnValues(
    uint256 maturity,
    address borrower,
    uint256 repayAmount,
    uint256 maxAmountAllowed
  ) external {
    (returnValues.actualRepayAmount, returnValues.debtCovered, returnValues.earningsSP) = repayMP(
      maturity,
      borrower,
      repayAmount,
      maxAmountAllowed
    );
  }

  function setSmartPoolAssets(uint256 smartPoolAssets_) external {
    smartPoolAssets = smartPoolAssets_;
  }

  // function to avoid range value validation
  function setFreePenaltyRate(uint256 penaltyRate_) external {
    penaltyRate = penaltyRate_;
  }
}
