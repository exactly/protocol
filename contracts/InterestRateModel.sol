// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";

import { InvalidParameter } from "./Auditor.sol";

contract InterestRateModel is AccessControl {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;

  // Parameters to the system, expressed with 1e18 decimals
  uint256 public curveParameterA;
  int256 public curveParameterB;
  uint256 public maxUtilization;
  uint256 public fullUtilization;
  uint256 public spFeeRate;
  uint256 public smartPoolUtilizationRate = 0.05e18;

  /// @notice Emitted when the curve parameters are changed by admin.
  /// @param a new curve parameter A.
  /// @param b new curve parameter B.
  /// @param maxUtilization new max utilization rate.
  /// @param fullUtilization new full utilization rate.
  event CurveParametersSet(uint256 a, int256 b, uint256 maxUtilization, uint256 fullUtilization);

  /// @notice Emitted when the spFeeRate parameter is changed by admin.
  /// @param spFeeRate rate charged to the mp suppliers to be accrued by the sp suppliers.
  event SpFeeRateSet(uint256 spFeeRate);

  constructor(
    uint256 curveParameterA_,
    int256 curveParameterB_,
    uint256 maxUtilization_,
    uint256 fullUtilization_,
    uint256 spFeeRate_
  ) {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setCurveParameters(curveParameterA_, curveParameterB_, maxUtilization_, fullUtilization_);
    setSPFeeRate(spFeeRate_);
  }

  /// @notice Sets the rate charged to the mp depositors that the sp suppliers will retain for initially providing
  /// liquidity.
  /// @dev Value can only be set between 20% and 0%.
  /// @param spFeeRate_ percentage amount represented with 1e18 decimals.
  function setSPFeeRate(uint256 spFeeRate_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (spFeeRate_ > 0.2e18) revert InvalidParameter();
    spFeeRate = spFeeRate_;
    emit SpFeeRateSet(spFeeRate_);
  }

  /// @notice Gets this model's curve parameters.
  /// @return parameters (curveA, curveB, maxUtilization, fullUtilization).
  function getCurveParameters()
    external
    view
    returns (
      uint256,
      int256,
      uint256,
      uint256
    )
  {
    return (curveParameterA, curveParameterB, maxUtilization, fullUtilization);
  }

  /// @notice Calculates the amount of revenue sharing between the smart pool and the new MP supplier.
  /// @param suppliedSP amount of money currently being supplied in the fixed rate pool.
  /// @param unassignedEarnings earnings not yet accrued to the SP that should be shared with the current supplier.
  /// @param amount amount being provided by the MP supplier.
  /// @return earningsShare yield to be offered to the MP supplier.
  /// @return earningsShareSP yield to be accrued by the SP suppliers for initially providing the liquidity.
  function getYieldForDeposit(
    uint256 suppliedSP,
    uint256 unassignedEarnings,
    uint256 amount
  ) external view returns (uint256 earningsShare, uint256 earningsShareSP) {
    if (suppliedSP != 0) {
      // User can't make more fees after the total borrowed amount
      earningsShare = unassignedEarnings.mulDivDown(Math.min(amount, suppliedSP), suppliedSP);
      earningsShareSP = earningsShare.mulWadDown(spFeeRate);
      earningsShare -= earningsShareSP;
    }
  }

  /// @notice Updates this model's curve parameters.
  /// @dev FullUR can only be between 1 and 52. UMaxUR can only be higher than FullUR and at most 3 times FullUR.
  /// @param curveParameterA_ curve parameter A.
  /// @param curveParameterB_ curve parameter B.
  /// @param maxUtilization_ % of MP supp.
  /// @param fullUtilization_ full UR.
  function setCurveParameters(
    uint256 curveParameterA_,
    int256 curveParameterB_,
    uint256 maxUtilization_,
    uint256 fullUtilization_
  ) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (
      fullUtilization_ > 52e18 ||
      fullUtilization_ < 1e18 ||
      fullUtilization_ >= maxUtilization_ ||
      fullUtilization_ < maxUtilization_ / 3
    ) revert InvalidParameter();

    curveParameterA = curveParameterA_;
    curveParameterB = curveParameterB_;
    maxUtilization = maxUtilization_;
    fullUtilization = fullUtilization_;

    // reverts if it's an invalid curve (such as one yielding a negative interest rate).
    // doing it works because it's a monotonously increasing function.
    rate(0, 0);

    emit CurveParametersSet(curveParameterA_, curveParameterB_, maxUtilization_, fullUtilization_);
  }

  /// @notice Gets fee to borrow a certain amount at a certain maturity with supply/demand values in the fixed rate pool
  /// and supply/demand values in the smart pool.
  /// @param maturity maturity date for calculating days left to maturity.
  /// @param currentDate the current block timestamp. Received from caller for easier testing.
  /// @param amount the current borrow's amount.
  /// @param borrowedMP ex-ante amount borrowed from this maturity.
  /// @param suppliedMP deposits in the fixed rate pool.
  /// @param smartPoolAssetsAverage the average of the smart pool's assets.
  /// @return fee the borrower will have to pay, as a factor (1% interest is represented as the wad for 0.01 == 10^16).
  function getRateToBorrow(
    uint256 maturity,
    uint256 currentDate,
    uint256 amount,
    uint256 borrowedMP,
    uint256 suppliedMP,
    uint256 smartPoolAssetsAverage
  ) public view returns (uint256) {
    if (currentDate >= maturity) revert AlreadyMatured();

    uint256 supplied = suppliedMP + smartPoolAssetsAverage.divWadDown(fullUtilization);
    uint256 utilizationBefore = borrowedMP.divWadDown(supplied);
    uint256 utilizationAfter = (borrowedMP + amount).divWadDown(supplied);

    if (utilizationAfter > fullUtilization) revert UtilizationExceeded();

    return rate(utilizationBefore, utilizationAfter).mulDivDown(maturity - currentDate, 365 days);
  }

  /// @notice Returns the interest rate integral from `u0` to `u1`, using the analytical solution (ln).
  /// @dev handles special case where delta utilization tends to zero, using l'hôpital's rule.
  /// @param utilizationBefore ex-ante utilization rate, with 18 decimals precision.
  /// @param utilizationAfter ex-post utilization rate, with 18 decimals precision.
  /// @return the interest rate, with 18 decimals precision.
  function rate(uint256 utilizationBefore, uint256 utilizationAfter) internal view returns (uint256) {
    int256 r = int256(
      utilizationAfter - utilizationBefore < 2.5e9
        ? curveParameterA.divWadDown(maxUtilization - utilizationBefore)
        : curveParameterA.mulDivDown(
          uint256(int256((maxUtilization - utilizationBefore).divWadDown(maxUtilization - utilizationAfter)).lnWad()),
          utilizationAfter - utilizationBefore
        )
    ) + curveParameterB;
    assert(r >= 0);
    return uint256(r);
  }
}

error AlreadyMatured();
error InvalidAmount();
error UtilizationExceeded();
