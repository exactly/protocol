// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";

import { InvalidParameter } from "./Auditor.sol";
import { PoolLib } from "./utils/PoolLib.sol";

contract InterestRateModel is AccessControl {
  using PoolLib for PoolLib.MaturityPool;
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;

  // Parameters to the system, expressed with 1e18 decimals
  uint256 public curveParameterA;
  int256 public curveParameterB;
  uint256 public maxUtilization;
  uint256 public fullUtilization;
  uint256 public spFeeRate;

  /// @notice Emitted when the curve parameters are changed by admin.
  /// @param a new curve parameter A.
  /// @param b new curve parameter B.
  /// @param maxUtilization new max utilization rate.
  /// @param fullUtilization new full utilization rate.
  event CurveParametersUpdated(uint256 a, int256 b, uint256 maxUtilization, uint256 fullUtilization);

  /// @notice Emitted when the spFeeRate parameter is changed by admin.
  /// @param spFeeRate rate charged to the mp suppliers to be accrued by the sp suppliers.
  event SpFeeRateUpdated(uint256 spFeeRate);

  constructor(
    uint256 _curveParameterA,
    int256 _curveParameterB,
    uint256 _maxUtilization,
    uint256 _fullUtilization,
    uint256 _spFeeRate
  ) {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setCurveParameters(_curveParameterA, _curveParameterB, _maxUtilization, _fullUtilization);
    spFeeRate = _spFeeRate;
  }

  /// @notice Sets the rate charged to the mp depositors that the sp suppliers will retain for initially providing
  /// liquidity.
  /// @dev Value can only be set between 20% and 0%.
  /// @param _spFeeRate percentage amount represented with 1e18 decimals.
  function setSPFeeRate(uint256 _spFeeRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_spFeeRate > 0.2e18) revert InvalidParameter();
    spFeeRate = _spFeeRate;
    emit SpFeeRateUpdated(_spFeeRate);
  }

  /// @notice Gets this model's curve parameters.
  /// @return parameters (_curveA, _curveB, maxUtilization, fullUtilization).
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
  /// @param suppliedSP amount of money currently being supplied in the maturity pool.
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
  /// @param _curveParameterA curve parameter A.
  /// @param _curveParameterB curve parameter B.
  /// @param _maxUtilization % of MP supp.
  /// @param _fullUtilization full UR.
  function setCurveParameters(
    uint256 _curveParameterA,
    int256 _curveParameterB,
    uint256 _maxUtilization,
    uint256 _fullUtilization
  ) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (
      _fullUtilization > 52e18 ||
      _fullUtilization < 1e18 ||
      _fullUtilization >= _maxUtilization ||
      _fullUtilization < _maxUtilization / 3
    ) revert InvalidParameter();

    curveParameterA = _curveParameterA;
    curveParameterB = _curveParameterB;
    maxUtilization = _maxUtilization;
    fullUtilization = _fullUtilization;

    // reverts if it's an invalid curve (such as one yielding a negative interest rate).
    // doing it works because it's a monotonously increasing function.
    rate(0, 0);

    emit CurveParametersUpdated(_curveParameterA, _curveParameterB, _maxUtilization, _fullUtilization);
  }

  /// @notice Gets fee to borrow a certain amount in a certain maturity with supply/demand values in the maturity pool
  /// and supply/demand values in the smart pool.
  /// @param maturity maturity date for calculating days left to maturity.
  /// @param currentDate the current block timestamp. Received from caller for easier testing.
  /// @param amount the current borrow's amount.
  /// @param borrowedMP ex-ante amount borrowed from this maturity.
  /// @param suppliedMP deposits in maturity pool.
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
