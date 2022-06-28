// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";

import { InvalidParameter } from "./Auditor.sol";

contract InterestRateModel is AccessControl {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;
  using FixedPointMathLib for int256;

  // Parameters to the system, expressed with 1e18 decimals
  uint128 public fixedCurveA;
  int128 public fixedCurveB;
  uint128 public fixedMaxUtilization;
  uint128 public fixedFullUtilization;

  uint128 public flexibleCurveA;
  int128 public flexibleCurveB;
  uint128 public flexibleMaxUtilization;
  uint128 public flexibleFullUtilization;

  uint256 public spFeeRate;

  /// @notice Emitted when the fixed curve parameters are changed by admin.
  /// @param fixedCurveA new curve parameter A.
  /// @param fixedCurveB new curve parameter B.
  /// @param fixedMaxUtilization new max utilization rate.
  /// @param fixedFullUtilization new full utilization rate.
  event FixedCurveParametersSet(
    uint128 fixedCurveA,
    int128 fixedCurveB,
    uint128 fixedMaxUtilization,
    uint128 fixedFullUtilization
  );

  /// @notice Emitted when the flexible curve parameters are changed by admin.
  /// @param flexibleCurveA new curve parameter A.
  /// @param flexibleCurveB new curve parameter B.
  /// @param flexibleMaxUtilization new max utilization rate.
  /// @param flexibleFullUtilization new full utilization rate.
  event FlexibleCurveParametersSet(
    uint128 flexibleCurveA,
    int128 flexibleCurveB,
    uint128 flexibleMaxUtilization,
    uint128 flexibleFullUtilization
  );

  /// @notice Emitted when the spFeeRate parameter is changed by admin.
  /// @param spFeeRate rate charged to the mp suppliers to be accrued by the sp suppliers.
  event SpFeeRateSet(uint256 spFeeRate);

  constructor(
    uint128 fixedCurveA_,
    int128 fixedCurveB_,
    uint128 fixedMaxUtilization_,
    uint128 fixedFullUtilization_,
    uint128 flexibleCurveA_,
    int128 flexibleCurveB_,
    uint128 flexibleMaxUtilization_,
    uint128 flexibleFullUtilization_,
    uint256 spFeeRate_
  ) {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setFixedCurveParameters(fixedCurveA_, fixedCurveB_, fixedMaxUtilization_, fixedFullUtilization_);
    setFlexibleCurveParameters(flexibleCurveA_, flexibleCurveB_, flexibleMaxUtilization_, flexibleFullUtilization_);
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

  /// @notice Gets this model's fixed curve rate parameters.
  /// @return parameters (fixedCurveA, fixedCurveB, fixedMaxUtilization, fixedFullUtilization).
  function getFixedCurveParameters()
    external
    view
    returns (
      uint128,
      int128,
      uint128,
      uint128
    )
  {
    return (fixedCurveA, fixedCurveB, fixedMaxUtilization, fixedFullUtilization);
  }

  /// @notice Gets this model's flexible curve rate parameters.
  /// @return parameters (flexibleCurveA, flexibleCurveB, flexibleMaxUtilization, flexibleFullUtilization).
  function getFlexibleCurveParameters()
    external
    view
    returns (
      uint128,
      int128,
      uint128,
      uint128
    )
  {
    return (flexibleCurveA, flexibleCurveB, flexibleMaxUtilization, flexibleFullUtilization);
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

  /// @notice Updates this model's fixed curve parameters.
  /// @dev FullUR can only be between 1 and 52. UMaxUR can only be higher than FullUR and at most 3 times FullUR.
  /// @param fixedCurveA_ curve parameter A.
  /// @param fixedCurveB_ curve parameter B.
  /// @param fixedMaxUtilization_ max UR.
  /// @param fixedFullUtilization_ full UR.
  function setFixedCurveParameters(
    uint128 fixedCurveA_,
    int128 fixedCurveB_,
    uint128 fixedMaxUtilization_,
    uint128 fixedFullUtilization_
  ) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (
      fixedFullUtilization_ > 52e18 ||
      fixedFullUtilization_ < 1e18 ||
      fixedFullUtilization_ >= fixedMaxUtilization_ ||
      fixedFullUtilization_ < fixedMaxUtilization_ / 3
    ) revert InvalidParameter();

    fixedCurveA = fixedCurveA_;
    fixedCurveB = fixedCurveB_;
    fixedMaxUtilization = fixedMaxUtilization_;
    fixedFullUtilization = fixedFullUtilization_;

    // reverts if it's an invalid curve (such as one yielding a negative interest rate).
    // doing it works because it's a monotonously increasing function.
    fixedRate(0, 0);

    emit FixedCurveParametersSet(fixedCurveA_, fixedCurveB_, fixedMaxUtilization_, fixedFullUtilization_);
  }

  /// @notice Updates this model's flexible curve parameters.
  /// @param flexibleCurveA_ curve parameter A.
  /// @param flexibleCurveB_ curve parameter B.
  /// @param flexibleMaxUtilization_ max UR.
  /// @param flexibleFullUtilization_ full UR.
  function setFlexibleCurveParameters(
    uint128 flexibleCurveA_,
    int128 flexibleCurveB_,
    uint128 flexibleMaxUtilization_,
    uint128 flexibleFullUtilization_
  ) public onlyRole(DEFAULT_ADMIN_ROLE) {
    flexibleCurveA = flexibleCurveA_;
    flexibleCurveB = flexibleCurveB_;
    flexibleMaxUtilization = flexibleMaxUtilization_;
    flexibleFullUtilization = flexibleFullUtilization_;

    // reverts if it's an invalid curve (such as one yielding a negative interest rate).
    // doing it works because it's a monotonously increasing function.
    flexibleRate(0, 0);

    emit FlexibleCurveParametersSet(
      flexibleCurveA_,
      flexibleCurveB_,
      flexibleMaxUtilization_,
      flexibleFullUtilization_
    );
  }

  /// @notice Gets the rate to borrow a certain amount at a certain maturity with supply/demand values in the fixed rate
  /// pool and supply/demand values in the smart pool.
  /// @param maturity maturity date for calculating days left to maturity.
  /// @param currentDate the current block timestamp. Received from caller for easier testing.
  /// @param amount the current borrow's amount.
  /// @param borrowedMP ex-ante amount borrowed from this maturity.
  /// @param suppliedMP deposits in the fixed rate pool.
  /// @param smartPoolAssetsAverage the average of the smart pool's assets.
  /// @return rate of the fee that the borrower will have to pay (represented with 1e18 decimals).
  function getRateToBorrow(
    uint256 maturity,
    uint256 currentDate,
    uint256 amount,
    uint256 borrowedMP,
    uint256 suppliedMP,
    uint256 smartPoolAssetsAverage
  ) public view returns (uint256) {
    if (currentDate >= maturity) revert AlreadyMatured();

    uint256 supplied = suppliedMP + smartPoolAssetsAverage.divWadDown(fixedFullUtilization);
    uint256 utilizationBefore = borrowedMP.divWadDown(supplied);
    uint256 utilizationAfter = (borrowedMP + amount).divWadDown(supplied);

    if (utilizationAfter > fixedFullUtilization) revert UtilizationExceeded();

    return fixedRate(utilizationBefore, utilizationAfter).mulDivDown(maturity - currentDate, 365 days);
  }

  /// @notice Returns the interest rate integral from utilizationBefore to utilizationAfter.
  /// @dev Minimum and maximum checks to avoid negative rate.
  /// @param utilizationBefore ex-ante utilization rate, with 18 decimals precision.
  /// @param utilizationAfter ex-post utilization rate, with 18 decimals precision.
  /// @return the interest rate, with 18 decimals precision.
  function getFlexibleBorrowRate(uint256 utilizationBefore, uint256 utilizationAfter) external view returns (uint256) {
    if (utilizationAfter > flexibleFullUtilization) revert UtilizationExceeded();

    return flexibleRate(Math.min(utilizationBefore, utilizationAfter), Math.max(utilizationBefore, utilizationAfter));
  }

  /// @notice Returns the interest rate integral from `u0` to `u1`, using the analytical solution (ln).
  /// @dev Uses the fixed rate curve parameters.
  /// Handles special case where delta utilization tends to zero, using l'hôpital's rule.
  /// @param utilizationBefore ex-ante utilization rate, with 18 decimals precision.
  /// @param utilizationAfter ex-post utilization rate, with 18 decimals precision.
  /// @return the interest rate, with 18 decimals precision.
  function fixedRate(uint256 utilizationBefore, uint256 utilizationAfter) internal view returns (uint256) {
    int256 r = int256(
      utilizationAfter - utilizationBefore < 2.5e9
        ? fixedCurveA.divWadDown(fixedMaxUtilization - utilizationBefore)
        : fixedCurveA.mulDivDown(
          uint256(
            int256((fixedMaxUtilization - utilizationBefore).divWadDown(fixedMaxUtilization - utilizationAfter)).lnWad()
          ),
          utilizationAfter - utilizationBefore
        )
    ) + fixedCurveB;
    assert(r >= 0);
    return uint256(r);
  }

  /// @notice Returns the interest rate integral from `u0` to `u1`, using the analytical solution (ln).
  /// @dev Uses the flexible rate curve parameters.
  /// Handles special case where delta utilization tends to zero, using l'hôpital's rule.
  /// @param utilizationBefore ex-ante utilization rate, with 18 decimals precision.
  /// @param utilizationAfter ex-post utilization rate, with 18 decimals precision.
  /// @return the interest rate, with 18 decimals precision.
  function flexibleRate(uint256 utilizationBefore, uint256 utilizationAfter) internal view returns (uint256) {
    int256 r = int256(
      utilizationAfter - utilizationBefore < 2.5e9
        ? flexibleCurveA.divWadDown(flexibleMaxUtilization - utilizationBefore)
        : flexibleCurveA.mulDivDown(
          uint256(
            int256((flexibleMaxUtilization - utilizationBefore).divWadDown(flexibleMaxUtilization - utilizationAfter))
              .lnWad()
          ),
          utilizationAfter - utilizationBefore
        )
    ) + flexibleCurveB;
    assert(r >= 0);
    return uint256(r);
  }
}

error AlreadyMatured();
error InvalidAmount();
error UtilizationExceeded();
