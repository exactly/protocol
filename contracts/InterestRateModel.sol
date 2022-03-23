// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";

import { PoolLib } from "./utils/PoolLib.sol";
import {
  IInterestRateModel,
  AlreadyMatured,
  InvalidAmount,
  MaxUtilizationExceeded
} from "./interfaces/IInterestRateModel.sol";

contract InterestRateModel is IInterestRateModel, AccessControl {
  using PoolLib for PoolLib.MaturityPool;
  using FixedPointMathLib for uint256;
  uint256 private constant YEAR = 365 days;

  // Parameters to the system, expressed with 1e18 decimals
  uint256 public curveParameterA;
  int256 public curveParameterB;
  uint256 public maxUtilizationRate;
  uint256 public fullUtilizationRate;
  uint256 public spFeeRate;

  /// @notice emitted when the curve parameters are changed by admin.
  /// @param a new curve parameter A.
  /// @param b new curve parameter B.
  /// @param maxUtilizationRate new max utilization rate.
  /// @param fullUtilizationRate new full utilization rate.
  event CurveParametersUpdated(uint256 a, int256 b, uint256 maxUtilizationRate, uint256 fullUtilizationRate);

  /// @notice emitted when the spFeeRate parameter is changed by admin.
  /// @param spFeeRate rate charged to the mp depositors to be accrued by the sp borrowers.
  event SpFeeRateUpdated(uint256 spFeeRate);

  constructor(
    uint256 _curveParameterA,
    int256 _curveParameterB,
    uint256 _maxUtilizationRate,
    uint256 _fullUtilizationRate,
    uint256 _spFeeRate
  ) {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setCurveParameters(_curveParameterA, _curveParameterB, _maxUtilizationRate, _fullUtilizationRate);
    spFeeRate = _spFeeRate;
  }

  /// @dev Sets the rate charged to the mp depositors to be accrued by the sp borrowers.
  /// @param _spFeeRate percentage amount represented with 1e18 decimals.
  function setSPFeeRate(uint256 _spFeeRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
    spFeeRate = _spFeeRate;

    emit SpFeeRateUpdated(_spFeeRate);
  }

  /// @notice gets this model's curve parameters.
  /// @return parameters (curveA, curveB, maxUtilizationRate, fullUtilizationRate).
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
    return (curveParameterA, curveParameterB, maxUtilizationRate, fullUtilizationRate);
  }

  /// @dev Calculate the amount of revenue sharing between the smart pool and the new MP depositor.
  /// @param suppliedSP amount of money currently being supplied in the maturity pool.
  /// @param unassignedEarnings earnings not yet accrued to the SP that should be shared with the current depositor.
  /// @param amount amount being provided by the MP depositor.
  /// @return earningsShare : yield to be given to the MP depositor.
  function getYieldForDeposit(
    uint256 suppliedSP,
    uint256 unassignedEarnings,
    uint256 amount
  ) external view override returns (uint256 earningsShare, uint256 earningsShareSP) {
    if (suppliedSP != 0) {
      // User can't make more fees after the total borrowed amount
      earningsShare = unassignedEarnings.fmul(Math.min(amount, suppliedSP), suppliedSP);
      earningsShareSP = earningsShare.fmul(spFeeRate, 1e18);
      earningsShare -= earningsShareSP;
    }
  }

  /// @dev updates this model's curve parameters.
  /// @param curveA curve parameter A.
  /// @param curveB curve parameter B.
  /// @param _maxUtilizationRate % of MP supp.
  /// @param _fullUtilizationRate full UR.
  function setCurveParameters(
    uint256 curveA,
    int256 curveB,
    uint256 _maxUtilizationRate,
    uint256 _fullUtilizationRate
  ) public onlyRole(DEFAULT_ADMIN_ROLE) {
    curveParameterA = curveA;
    curveParameterB = curveB;
    maxUtilizationRate = _maxUtilizationRate;
    fullUtilizationRate = _fullUtilizationRate;
    // we call the getPointInCurve function with an utilization rate of
    // zero to force it to revert in the tx that sets it, and not be able
    // to set an invalid curve (such as one yielding a negative interest
    // rate). Doing it works because it's a monotonously increasing function.
    getPointInCurve(0);

    emit CurveParametersUpdated(curveA, curveB, _maxUtilizationRate, _fullUtilizationRate);
  }

  /// @notice Get fee to borrow a certain amount in a certain maturity with supply/demand values in the maturity pool
  /// and supply/demand values in the smart pool.
  /// @dev liquidity limits aren't checked, that's the responsibility of pool.takeMoney.
  /// @param maturityDate maturity date for calculating days left to maturity.
  /// @param currentDate the curent block timestamp. Recieved from caller for easier testing.
  /// @param amount the current borrow's amount.
  /// @param borrowedMP ex-ante amount borrowed from this maturity.
  /// @param suppliedMP deposits in maturity pool.
  /// @param totalSupplySP total supply in the smart pool.
  /// @return fee the borrower will have to pay, as a factor (1% interest is represented as the wad for 0.01 == 10^16).
  function getRateToBorrow(
    uint256 maturityDate,
    uint256 currentDate,
    uint256 amount,
    uint256 borrowedMP,
    uint256 suppliedMP,
    uint256 totalSupplySP
  ) public view override returns (uint256) {
    if (currentDate >= maturityDate) revert AlreadyMatured();

    uint256 supplied = suppliedMP + totalSupplySP.fdiv(fullUtilizationRate, 1e18);
    uint256 utilizationBefore = borrowedMP.fdiv(supplied, 1e18);
    uint256 utilizationAfter = (borrowedMP + amount).fdiv(supplied, 1e18);

    if (utilizationAfter > fullUtilizationRate) revert MaxUtilizationExceeded();

    uint256 rate = simpsonIntegrator(utilizationBefore, utilizationAfter);
    return rate.fmul(maturityDate - currentDate, YEAR);
  }

  /// @notice Returns the interest rate integral from u_{t} to u_{t+1}, approximated via the simpson method.
  /// @dev calls the other two integrators, and also checks there is an actual difference in utilization rate.
  /// @param utilizationBefore ex-ante utilization rate, with 18 decimals precision.
  /// @param utilizationAfter ex-post utilization rate, with 18 decimals precision.
  /// @return fee the approximated fee, with 18 decimals precision.
  function simpsonIntegrator(uint256 utilizationBefore, uint256 utilizationAfter) internal view returns (uint256) {
    // there's no domain reason to forbid amounts of zero, but that'd cause the denominator in bot`
    if (utilizationAfter <= utilizationBefore) revert InvalidAmount();
    return
      (trapezoidIntegrator(utilizationBefore, utilizationAfter) +
        (midpointIntegrator(utilizationBefore, utilizationAfter) << 1)) / 3;
  }

  /// @notice Returns the interest rate for an utilization rate, reading the A, B and U_{max} parameters from storage.
  /// @dev reverts if the curve has invalid parameters (those returning a negative interest rate).
  /// @param utilizationRate already-computed utilization rate, with 18 decimals precision.
  /// @return fee the fee corresponding to that utilization rate, with 18 decimals precision.
  function getPointInCurve(uint256 utilizationRate) internal view returns (uint256) {
    int256 rate = int256(curveParameterA.fdiv(maxUtilizationRate - utilizationRate, 1e18)) + curveParameterB;
    // this curve _could_ go below zero if the parameters are set wrong.
    assert(rate >= 0);
    return uint256(rate);
  }

  /// @notice Returns the interest rate integral from u_{t} to u_{t+1}, approximated via the trapezoid method.
  /// @dev calls the getPointInCurve function many times.
  /// @param ut ex-ante utilization rate, with 18 decimals precision.
  /// @param ut1 ex-post utilization rate, with 18 decimals precision.
  /// @return fee the approximated fee, with 18 decimals precision.
  function trapezoidIntegrator(uint256 ut, uint256 ut1) internal view returns (uint256) {
    uint256 denominator = ut1 - ut;
    uint256 delta = denominator >> 2;
    return
      (delta >> 1).fmul(
        getPointInCurve(ut) +
          (getPointInCurve(ut + delta) << 1) +
          (getPointInCurve(ut + (delta << 1)) << 1) +
          (getPointInCurve(ut + 3 * delta) << 1) +
          getPointInCurve(ut1),
        denominator
      );
  }

  /// @notice Returns the interest rate integral from u_{t} to u_{t+1}, approximated via the midpoint method.
  /// @dev calls the getPointInCurve function many times.
  /// @param ut ex-ante utilization rate, with 18 decimals precision.
  /// @param ut1 ex-post utilization rate, with 18 decimals precision.
  /// @return fee the approximated fee, with 18 decimals precision.
  function midpointIntegrator(uint256 ut, uint256 ut1) internal view returns (uint256) {
    uint256 denominator = ut1 - ut;
    uint256 delta = denominator >> 2;
    return
      delta.fmul(
        getPointInCurve(ut + delta.fmul(0.5e18, 1e18)) +
          getPointInCurve(ut + delta.fmul(1.5e18, 1e18)) +
          getPointInCurve(ut + delta.fmul(2.5e18, 1e18)) +
          getPointInCurve(ut + delta.fmul(3.5e18, 1e18)),
        denominator
      );
  }
}
