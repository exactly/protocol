// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { FixedLib } from "./utils/FixedLib.sol";
import { Market } from "./Market.sol";

contract InterestRateModel {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;

  /// @notice Threshold to define which method should be used to calculate the interest rates.
  /// @dev When `eta` (`delta / alpha`) is lower than this value, use simpson's rule for approximation.
  uint256 internal constant PRECISION_THRESHOLD = 7.5e14;

  /// @notice Scale factor of the fixed curve.
  uint256 public immutable fixedCurveA;
  /// @notice Origin intercept of the fixed curve.
  int256 public immutable fixedCurveB;
  /// @notice Asymptote of the fixed curve.
  uint256 public immutable fixedMaxUtilization;

  /// @notice Scale factor of the floating curve.
  uint256 public immutable floatingCurveA;
  /// @notice Origin intercept of the floating curve.
  int256 public immutable floatingCurveB;
  /// @notice Asymptote of the floating curve.
  uint256 public immutable floatingMaxUtilization;

  uint256 public immutable floatingNaturalUtilization;
  uint256 public immutable fixedNaturalUtilization;
  int256 public immutable growthSpeed;
  int256 public immutable sigmoidSpeed;
  uint256 public immutable maxRate;

  /// @dev auxiliary variable to save an extra operation.
  int256 internal immutable auxUNat;

  constructor(
    Market market_,
    uint256 curveA_,
    int256 curveB_,
    uint256 maxUtilization_,
    uint256 floatingNaturalUtilization_,
    int256 sigmoidSpeed_,
    int256 growthSpeed_,
    uint256 maxRate_
  ) {
    assert(maxUtilization_ > 1e18);

    market = market_;

    fixedCurveA = curveA_;
    fixedCurveB = curveB_;
    fixedMaxUtilization = maxUtilization_;

    floatingCurveA = curveA_;
    floatingCurveB = curveB_;
    floatingMaxUtilization = maxUtilization_;

    floatingNaturalUtilization = floatingNaturalUtilization_;
    fixedNaturalUtilization = 1e18 - floatingNaturalUtilization;

    auxUNat = int256(floatingNaturalUtilization.divWadDown(fixedNaturalUtilization)).lnWad();
    sigmoidSpeed = sigmoidSpeed_;
    growthSpeed = growthSpeed_;
    maxRate = maxRate_;

    // reverts if it's an invalid curve (such as one yielding a negative interest rate).
    fixedRate(0, 0);
    floatingRate(0, 0);
  }

  /// @notice Gets the rate to borrow a certain amount at a certain maturity with supply/demand values in the fixed rate
  /// pool and assets from the backup supplier.
  /// @param maturity maturity date for calculating days left to maturity.
  /// @param amount the current borrow's amount.
  /// @param borrowed ex-ante amount borrowed from this fixed rate pool.
  /// @param supplied deposits in the fixed rate pool.
  /// @param backupAssets backup supplier assets.
  /// @return rate of the fee that the borrower will have to pay (represented with 18 decimals).
  function fixedBorrowRate(
    uint256 maturity,
    uint256 amount,
    uint256 borrowed,
    uint256 supplied,
    uint256 backupAssets
  ) external view returns (uint256) {
    if (block.timestamp >= maturity) revert AlreadyMatured();

    uint256 potentialAssets = supplied + backupAssets;
    uint256 utilizationAfter = (borrowed + amount).divWadUp(potentialAssets);

    if (utilizationAfter > 1e18) revert UtilizationExceeded();

    uint256 utilizationBefore = borrowed.divWadDown(potentialAssets);

    return fixedRate(utilizationBefore, utilizationAfter).mulDivDown(maturity - block.timestamp, 365 days);
  }

  /// @notice Returns the current annualized fixed rate to borrow with supply/demand values in the fixed rate pool and
  /// assets from the backup supplier.
  /// @param borrowed amount borrowed from the fixed rate pool.
  /// @param supplied deposits in the fixed rate pool.
  /// @param backupAssets backup supplier assets.
  /// @return rate of the fee that the borrower will have to pay, with 18 decimals precision.
  /// @return utilization current utilization rate, with 18 decimals precision.
  function minFixedRate(
    uint256 borrowed,
    uint256 supplied,
    uint256 backupAssets
  ) external view returns (uint256 rate, uint256 utilization) {
    utilization = borrowed.divWadUp(supplied + backupAssets);
    rate = fixedRate(utilization, utilization);
  }

  /// @notice Returns the interest rate integral from `u0` to `u1`, using the analytical solution (ln).
  /// @dev Uses the fixed rate curve parameters.
  /// Handles special case where delta utilization tends to zero, using simpson's rule.
  /// @param utilizationBefore ex-ante utilization rate, with 18 decimals precision.
  /// @param utilizationAfter ex-post utilization rate, with 18 decimals precision.
  /// @return the interest rate, with 18 decimals precision.
  function fixedRate(uint256 utilizationBefore, uint256 utilizationAfter) internal view returns (uint256) {
    uint256 alpha = fixedMaxUtilization - utilizationBefore;
    uint256 delta = utilizationAfter - utilizationBefore;
    int256 r = int256(
      delta.divWadDown(alpha) < PRECISION_THRESHOLD
        ? (fixedCurveA.divWadDown(alpha) +
          fixedCurveA.mulDivDown(4e18, fixedMaxUtilization - ((utilizationAfter + utilizationBefore) / 2)) +
          fixedCurveA.divWadDown(fixedMaxUtilization - utilizationAfter)) / 6
        : fixedCurveA.mulDivDown(
          uint256(int256(alpha.divWadDown(fixedMaxUtilization - utilizationAfter)).lnWad()),
          delta
        )
    ) + fixedCurveB;
    assert(r >= 0);
    return uint256(r);
  }

  function baseRate(uint256 uFloating, uint256 uGlobal) public view returns (uint256) {
    if (uFloating > uGlobal) revert UtilizationExceeded();
    if (uGlobal >= 1e18) return type(uint256).max;

    int256 r = int256(floatingCurveA.divWadDown(floatingMaxUtilization - uFloating)) + floatingCurveB;
    assert(r >= 0);

    if (uGlobal == 0) return uint256(r);

    uint256 globalFactor = uint256(
      ((-growthSpeed *
        int256(
          1e18 -
            uint256(1e18)
              .divWadDown(
                uint256(
                  1e18 +
                    (-((sigmoidSpeed * (int256(uGlobal.divWadDown(1e18 - uGlobal)).lnWad() - auxUNat)) / 1e18)).expWad()
                )
              )
              .mulWadDown(uGlobal)
        ).lnWad()) / 1e18).expWad()
    );

    if (globalFactor > type(uint256).max / uint256(r)) return type(uint256).max;

    return uint256(r).mulWadUp(globalFactor);
  }

  function floatingRate(uint256 uFloating, uint256 uGlobal) public view returns (uint256) {
    uint256 base = baseRate(uFloating, uGlobal);
    return base > maxRate ? maxRate : base;
  }

  // Legacy interface, kept for compatibility.

  /// @notice Market where the interest rate model is used. Keeps compatibility with legacy interest rate model.
  Market public immutable market;

  /// @dev Deprecated in favor of `floatingRate(uFloating, uGlobal)`.
  function floatingRate(uint256) public view returns (uint256) {
    uint256 floatingAssets = market.floatingAssets();
    uint256 floatingDebt = market.floatingDebt();
    return
      floatingRate(
        floatingAssets != 0 ? floatingDebt.divWadUp(floatingAssets) : 0,
        globalUtilization(floatingAssets, floatingDebt, market.floatingBackupBorrowed())
      );
  }

  function previewFloatingAssetsAverage(uint256 maturity) internal view returns (uint256) {
    FixedLib.Pool memory pool;
    (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
    uint256 memFloatingAssets = market.floatingAssets() +
      pool.unassignedEarnings.mulDivDown(block.timestamp - pool.lastAccrual, maturity - pool.lastAccrual);
    uint256 memFloatingAssetsAverage = market.floatingAssetsAverage();
    uint256 averageFactor = uint256(
      1e18 -
        (
          -int256(
            memFloatingAssets < memFloatingAssetsAverage
              ? market.dampSpeedDown()
              : market.dampSpeedUp() * (block.timestamp - market.lastAverageUpdate())
          )
        ).expWad()
    );
    return memFloatingAssetsAverage.mulWadDown(1e18 - averageFactor) + averageFactor.mulWadDown(memFloatingAssets);
  }

  function totalFloatingBorrowAssets(
    uint256 floatingAssets,
    uint256 floatingDebt,
    uint256 backupBorrowed,
    uint256 lastFloatingDebtUpdate
  ) internal view returns (uint256) {
    return
      floatingDebt +
      floatingDebt.mulWadDown(
        floatingRate(
          floatingAssets != 0 ? floatingDebt.divWadUp(floatingAssets) : 0,
          globalUtilization(floatingAssets, floatingDebt, backupBorrowed)
        ).mulDivDown(block.timestamp - lastFloatingDebtUpdate, 365 days)
      );
  }

  function globalUtilization(
    uint256 floatingAssets,
    uint256 floatingDebt,
    uint256 backupBorrowed
  ) internal pure returns (uint256) {
    return floatingAssets != 0 ? 1e18 - (floatingAssets - floatingDebt - backupBorrowed).divWadDown(floatingAssets) : 0;
  }
}

error AlreadyMatured();
error UtilizationExceeded();
