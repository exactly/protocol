// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.16;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

import { InvalidParameter } from "./Auditor.sol";

contract InterestRateModel is AccessControl {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;
  using FixedPointMathLib for int256;

  /// @notice Expressed with 1e18 decimals.
  struct Curve {
    uint128 a;
    int128 b;
    uint128 maxUtilization;
  }

  /// @notice Fixed rate model curve parameters.
  Curve public fixedCurve;
  /// @notice Floating rate model curve parameters.
  Curve public floatingCurve;
  /// @notice Fixed rate model full utilization.
  uint128 public fixedFullUtilization;
  /// @notice Floating rate model full utilization.
  uint128 public floatingFullUtilization;

  constructor(
    Curve memory fixedCurve_,
    uint128 fixedFullUtilization_,
    Curve memory floatingCurve_,
    uint128 floatingFullUtilization_
  ) {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setFixedParameters(fixedCurve_, fixedFullUtilization_);
    setFloatingParameters(floatingCurve_, floatingFullUtilization_);
  }

  /// @notice Gets the rate to borrow a certain amount at a certain maturity with supply/demand values in the fixed rate
  /// pool and assets from the backup supplier.
  /// @param maturity maturity date for calculating days left to maturity.
  /// @param amount the current borrow's amount.
  /// @param borrowed ex-ante amount borrowed from this maturity.
  /// @param supplied deposits in the fixed rate pool.
  /// @param backupAssets backup supplier assets.
  /// @return rate of the fee that the borrower will have to pay (represented with 1e18 decimals).
  function fixedBorrowRate(
    uint256 maturity,
    uint256 amount,
    uint256 borrowed,
    uint256 supplied,
    uint256 backupAssets
  ) external view returns (uint256) {
    if (block.timestamp >= maturity) revert AlreadyMatured();

    uint256 fullUtilization = fixedFullUtilization;

    uint256 potentialAssets = supplied + backupAssets.divWadDown(fullUtilization);
    uint256 utilizationBefore = borrowed.divWadDown(potentialAssets);
    uint256 utilizationAfter = (borrowed + amount).divWadDown(potentialAssets);

    if (utilizationAfter > fullUtilization) revert UtilizationExceeded();

    return fixedRate(utilizationBefore, utilizationAfter).mulDivDown(maturity - block.timestamp, 365 days);
  }

  /// @notice Returns the interest rate integral from utilizationBefore to utilizationAfter.
  /// @dev Minimum and maximum checks to avoid negative rate.
  /// @param utilizationBefore ex-ante utilization rate, with 18 decimals precision.
  /// @param utilizationAfter ex-post utilization rate, with 18 decimals precision.
  /// @return the interest rate, with 18 decimals precision.
  function floatingBorrowRate(uint256 utilizationBefore, uint256 utilizationAfter) external view returns (uint256) {
    if (utilizationAfter > floatingFullUtilization) revert UtilizationExceeded();

    return floatingRate(Math.min(utilizationBefore, utilizationAfter), Math.max(utilizationBefore, utilizationAfter));
  }

  /// @notice Returns the interest rate integral from `u0` to `u1`, using the analytical solution (ln).
  /// @dev Uses the fixed rate curve parameters.
  /// Handles special case where delta utilization tends to zero, using l'hôpital's rule.
  /// @param utilizationBefore ex-ante utilization rate, with 18 decimals precision.
  /// @param utilizationAfter ex-post utilization rate, with 18 decimals precision.
  /// @return the interest rate, with 18 decimals precision.
  function fixedRate(uint256 utilizationBefore, uint256 utilizationAfter) internal view returns (uint256) {
    Curve memory curve = fixedCurve;
    int256 r = int256(
      utilizationAfter - utilizationBefore < 2.5e9
        ? curve.a.divWadDown(curve.maxUtilization - utilizationBefore)
        : curve.a.mulDivDown(
          uint256(
            int256((curve.maxUtilization - utilizationBefore).divWadDown(curve.maxUtilization - utilizationAfter))
              .lnWad()
          ),
          utilizationAfter - utilizationBefore
        )
    ) + curve.b;
    assert(r >= 0);
    return uint256(r);
  }

  /// @notice Returns the interest rate integral from `u0` to `u1`, using the analytical solution (ln).
  /// @dev Uses the floating rate curve parameters.
  /// Handles special case where delta utilization tends to zero, using l'hôpital's rule.
  /// @param utilizationBefore ex-ante utilization rate, with 18 decimals precision.
  /// @param utilizationAfter ex-post utilization rate, with 18 decimals precision.
  /// @return the interest rate, with 18 decimals precision.
  function floatingRate(uint256 utilizationBefore, uint256 utilizationAfter) internal view returns (uint256) {
    Curve memory curve = floatingCurve;
    int256 r = int256(
      utilizationAfter - utilizationBefore < 2.5e9
        ? curve.a.divWadDown(curve.maxUtilization - utilizationBefore)
        : curve.a.mulDivDown(
          uint256(
            int256((curve.maxUtilization - utilizationBefore).divWadDown(curve.maxUtilization - utilizationAfter))
              .lnWad()
          ),
          utilizationAfter - utilizationBefore
        )
    ) + curve.b;
    assert(r >= 0);
    return uint256(r);
  }

  /// @notice Updates this model's fixed rate curve parameters.
  /// @param curve new fixed rate curve parameters.
  /// @param fullUtilization new fixed rate full utilization.
  function setFixedParameters(Curve memory curve, uint128 fullUtilization) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (
      fullUtilization > 52e18 ||
      fullUtilization < 1e18 ||
      fullUtilization >= curve.maxUtilization ||
      fullUtilization < curve.maxUtilization / 3
    ) revert InvalidParameter();

    fixedCurve = curve;
    fixedFullUtilization = fullUtilization;

    // reverts if it's an invalid curve (such as one yielding a negative interest rate).
    fixedRate(0, 0);

    emit FixedParametersSet(curve, fullUtilization);
  }

  /// @notice Updates this model's floating rate curve parameters.
  /// @param curve new floating rate curve parameters.
  /// @param fullUtilization new floating rate full utilization.
  function setFloatingParameters(Curve memory curve, uint128 fullUtilization) public onlyRole(DEFAULT_ADMIN_ROLE) {
    floatingCurve = curve;
    floatingFullUtilization = fullUtilization;

    // reverts if it's an invalid curve (such as one yielding a negative interest rate).
    floatingRate(0, 0);

    emit FloatingParametersSet(curve, fullUtilization);
  }

  /// @notice Emitted when the fixed rate curve parameters are changed by admin.
  /// @param curve new fixed rate curve parameters.
  /// @param fullUtilization new fixed rate full utilization.
  event FixedParametersSet(Curve curve, uint128 fullUtilization);

  /// @notice Emitted when the floating curve parameters are changed by admin.
  /// @param curve new floating rate curve parameters.
  /// @param fullUtilization new floating rate full utilization.
  event FloatingParametersSet(Curve curve, uint128 fullUtilization);
}

error AlreadyMatured();
error UtilizationExceeded();
