// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Math } from "@openzeppelin/contracts-v4/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { FixedLib } from "./utils/FixedLib.sol";
import { Market } from "./Market.sol";

contract InterestRateModel {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;
  using SafeCast for uint256;
  using SafeCast for int256;

  /// @notice Scale factor of the floating curve.
  uint256 public immutable floatingCurveA;
  /// @notice Origin intercept of the floating curve.
  int256 public immutable floatingCurveB;
  /// @notice Asymptote of the floating curve.
  uint256 public immutable floatingMaxUtilization;

  /// @notice natural level of utilization, represented with 18 decimals.
  uint256 public immutable naturalUtilization;
  /// @notice speed of growth for the base rate, represented with 18 decimals.
  int256 public immutable growthSpeed;
  /// @notice speed of the sigmoid curve, represented with 18 decimals.
  int256 public immutable sigmoidSpeed;
  /// @notice spread factor for the fixed rate, represented with 18 decimals.
  int256 public immutable spreadFactor;
  /// @notice speed of maturity for the fixed rate, represented with 18 decimals.
  int256 public immutable maturitySpeed;
  /// @notice time preference for the fixed rate, represented with 18 decimals.
  int256 public immutable timePreference;
  /// @notice liquidity naturally designated to fixed pools, represented with 18 decimals.
  uint256 public immutable fixedAllocation;
  /// @notice maximum interest rate, represented with 18 decimals.
  uint256 public immutable maxRate;
  /// @notice speed of maturity for the fixed rate, represented with 18 decimals.
  int256 public immutable maturityDurationSpeed;
  uint256 public immutable durationThreshold;
  int256 public immutable durationGrowthLaw;
  int256 public immutable penaltyDurationFactor;

  /// @dev maximum input value for expWad, ~ln((2^255 - 1) / 1e18), represented with 18 decimals.
  int256 internal constant EXP_THRESHOLD = 135305999368893231588;
  /// @dev auxiliary variable to save an extra operation.
  int256 internal immutable auxSigmoid;

  /// @notice set of parameters used to initialize the interest rate model.
  Parameters internal _parameters;

  constructor(Parameters memory p, Market market_) {
    assert(
      p.minRate > 0 &&
        p.naturalRate > 0 &&
        p.maxUtilization > 1e18 &&
        p.naturalUtilization > 0 &&
        p.naturalUtilization < 1e18 &&
        p.growthSpeed > 0 &&
        p.sigmoidSpeed > 0 &&
        p.spreadFactor > 0 &&
        p.maturitySpeed > 0 &&
        p.maxRate > 0 &&
        p.maxRate <= 15_000e16
    );

    _parameters = p;
    growthSpeed = p.growthSpeed.toInt256();
    sigmoidSpeed = p.sigmoidSpeed.toInt256();
    spreadFactor = p.spreadFactor.toInt256();
    maturitySpeed = p.maturitySpeed.toInt256();
    floatingMaxUtilization = p.maxUtilization;
    naturalUtilization = p.naturalUtilization;
    maturityDurationSpeed = p.maturityDurationSpeed.toInt256();
    durationThreshold = p.durationThreshold;
    durationGrowthLaw = p.durationGrowthLaw.toInt256();
    penaltyDurationFactor = p.penaltyDurationFactor.toInt256();

    floatingCurveA =
      ((p.naturalRate.mulWadUp(
        uint256(((growthSpeed * (1e18 - int256(p.naturalUtilization / 2)).lnWad()) / 1e18).expWad())
      ) - p.minRate) *
        (p.maxUtilization - p.naturalUtilization) *
        (p.maxUtilization)) /
      (p.naturalUtilization * 1e18);
    floatingCurveB = int256(p.minRate) - int256(floatingCurveA.divWadDown(p.maxUtilization));

    market = market_;
    fixedCurveA = address(market_) != address(0) ? floatingCurveA : 0;
    fixedCurveB = address(market_) != address(0) ? floatingCurveB : int256(0);
    fixedMaxUtilization = address(market_) != address(0) ? p.maxUtilization : 0;

    timePreference = p.timePreference;
    fixedAllocation = p.fixedAllocation;
    maxRate = p.maxRate;

    auxSigmoid = int256(naturalUtilization.divWadDown(1e18 - naturalUtilization)).lnWad();

    // reverts if it's an invalid curve (such as one yielding a negative interest rate).
    // fixedRate(block.timestamp + FixedLib.INTERVAL - (block.timestamp % FixedLib.INTERVAL), 2, 1, 1, 2, 2);
    baseRate(1e18 - 1, 1e18 - 1);
  }

  /// @notice fixed rate with given conditions, represented with 18 decimals.
  /// @param maturity maturity of the pool.
  /// @param maxPools number of pools available in the time horizon.
  /// @param uFixed fixed utilization of the pool.
  /// @param uFloating floating utilization of the pool.
  /// @param uGlobal global utilization of the pool.
  /// @param uGlobalAverage global utilization average of the pool.
  /// @return the minimum between `base * spread` and `maxRate` with given conditions.
  function fixedRate(
    uint256 maturity,
    uint256 maxPools,
    uint256 uFixed,
    uint256 uFloating,
    uint256 uGlobal,
    uint256 uGlobalAverage,
    uint256 maturityDebtDuration
  ) public view returns (uint256) {
    if (block.timestamp >= maturity) revert AlreadyMatured();
    if (uFixed > uGlobal || uFloating > uGlobal) revert UtilizationExceeded();
    if (uGlobal == 0) return baseRate(0, 0);

    uint256 maturityAllocation = market.maturityAllocation(maturity - block.timestamp);
    uint256 maturityAllocationNext = market.maturityAllocation(maturity - block.timestamp + FixedLib.INTERVAL);
    uint256 maturityNaturalUtilization = uGlobal.mulWadUp(
      uint256(market.fixedBorrowThreshold()).mulWadDown(uint256(market.minThresholdFactor())) /
        market.maxFuturePools() +
        maturityAllocation -
        maturityAllocationNext
    );
    FixedVars memory v;
    v.sqFNatPools = (maturityAllocation * 1e18) / maturityNaturalUtilization;
    v.fNatPools = (v.sqFNatPools * 1e18).sqrt();
    v.fixedFactor = (uFixed * 1e18) / maturityNaturalUtilization;
    v.natPools =
      ((2e18 - v.sqFNatPools.toInt256()) * 1e36) /
      (v.fNatPools.toInt256() * (1e18 - v.fNatPools.toInt256()));
    v.maturityFactor = (maturity - block.timestamp).divWadDown(maxPools * FixedLib.INTERVAL);
    int256 excessDuration = (
      maturityDebtDuration != 0
        ? ((durationGrowthLaw * (maturityDebtDuration.divWadDown(durationThreshold)).toInt256().lnWad()) / 1e18)
          .expWad()
        : int256(0)
    ) - 1e18;

    uint256 spread = (1e18 +
      (((maturitySpeed * (v.maturityFactor).toInt256().lnWad()) / 1e18).expWad() *
        (timePreference +
          (spreadFactor *
            ((v.natPools * (v.fixedFactor * 1e18).sqrt().toInt256()) /
              1e18 +
              ((1e18 - v.natPools) * v.fixedFactor.toInt256()) /
              1e18 -
              1e18)) /
          1e18)) /
      1e18 +
      ((((((maturityDurationSpeed * (v.maturityFactor).toInt256().lnWad()) / 1e18).expWad() * penaltyDurationFactor) /
        1e18) * (excessDuration > 0 && maturityDebtDuration >= durationThreshold ? excessDuration : int256(0))) / 1e18))
      .toUint256();
    uint256 base = baseRate(uFloating, uGlobalAverage);

    if (base >= maxRate.divWadDown(spread)) return maxRate;
    return base.mulWadUp(spread);
  }

  /// @notice base rate with given conditions, represented with 18 decimals.
  /// @param uFloating floating utilization of the pool.
  /// @param uGlobal global utilization of the pool.
  /// @return the base rate, without capping.
  function baseRate(uint256 uFloating, uint256 uGlobal) internal view returns (uint256) {
    if (uGlobal >= 1e18) return type(uint256).max;

    uint256 r = ((floatingCurveA.divWadDown(floatingMaxUtilization - uFloating)).toInt256() + floatingCurveB)
      .toUint256();

    if (uGlobal == 0) return r;

    int256 x = -((sigmoidSpeed * (int256(uGlobal.divWadDown(1e18 - uGlobal)).lnWad() - auxSigmoid)) / 1e18);
    uint256 sigmoid = x > EXP_THRESHOLD ? 0 : uint256(1e18).divWadDown(1e18 + x.expWad().toUint256());
    x = (-growthSpeed * (1e18 - sigmoid.mulWadDown(uGlobal)).toInt256().lnWad()) / 1e18;
    uint256 globalFactor = ((x > EXP_THRESHOLD ? EXP_THRESHOLD : x).expWad()).toUint256();

    if (globalFactor > type(uint256).max / r) return type(uint256).max;

    return r.mulWadUp(globalFactor);
  }

  /// @notice floating rate with given conditions, represented with 18 decimals.
  /// @param uFloating floating utilization of the pool.
  /// @param uGlobal global utilization of the pool.
  /// @return the minimum between `baseRate` and `maxRate` with given conditions.
  function floatingRate(uint256 uFloating, uint256 uGlobal) public view returns (uint256) {
    if (uFloating > uGlobal) revert UtilizationExceeded();
    return Math.min(baseRate(uFloating, uGlobal), maxRate);
  }

  function parameters() external view returns (Parameters memory) {
    return _parameters;
  }

  // Legacy interface, kept for compatibility.

  /// @notice Market where the interest rate model is used. Keeps compatibility with legacy interest rate model.
  Market public immutable market;
  uint256 public immutable fixedCurveA;
  int256 public immutable fixedCurveB;
  uint256 public immutable fixedMaxUtilization;

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

  /// @dev Deprecated in favor of `fixedRate(maturity, maxPools, uFixed, uFloating, uGlobal)`
  function fixedBorrowRate(
    uint256 maturity,
    uint256 amount,
    uint256 borrowed,
    uint256 supplied,
    uint256
  ) external view returns (uint256) {
    if (block.timestamp >= maturity) revert AlreadyMatured();
    uint256 floatingAssets = market.floatingAssets();
    uint256 floatingDebt = market.totalFloatingBorrowAssets();
    uint256 newBorrowed = borrowed + amount;
    uint256 backupBorrowed = market.floatingBackupBorrowed() +
      newBorrowed -
      Math.min(Math.max(borrowed, supplied), newBorrowed);
    uint256 maturityDebtDuration = maturityDuration(maturity, amount);

    return
      fixedRate(
        maturity,
        market.maxFuturePools(),
        fixedUtilization(supplied, newBorrowed, floatingAssets),
        floatingAssets != 0 ? floatingDebt.divWadUp(floatingAssets) : 0,
        globalUtilization(floatingAssets, floatingDebt, backupBorrowed),
        market.previewGlobalUtilizationAverage(),
        maturityDebtDuration
      ).mulDivDown(maturity - block.timestamp, 365 days);
  }

  /// @dev deprecated in favor of `fixedRate(maturity, maxPools, uFixed, uFloating, uGlobal)`
  function minFixedRate(uint256, uint256, uint256) external view returns (uint256 rate, uint256 utilization) {
    uint256 floatingAssets = market.floatingAssetsAverage();
    utilization = market.previewGlobalUtilizationAverage();
    uint256 uFloating = floatingAssets != 0 ? market.floatingDebt().divWadUp(floatingAssets) : 0;
    if (uFloating > utilization) revert UtilizationExceeded();
    rate = baseRate(uFloating, utilization);
  }

  /// @dev deprecated in favor of `fixedRate(maturity, maxPools, uFixed, uFloating, uGlobal, uGlobalAverage)`
  function fixedRate(
    uint256 maturity,
    uint256 maxPools,
    uint256 uFixed,
    uint256 uFloating,
    uint256 uGlobal
  ) external view returns (uint256) {
    return
      fixedRate(
        maturity,
        maxPools,
        uFixed,
        uFloating,
        uGlobal,
        market.previewGlobalUtilizationAverage(),
        maturityDuration(maturity, 0)
      );
  }

  function globalUtilization(
    uint256 floatingAssets,
    uint256 floatingDebt,
    uint256 backupBorrowed
  ) internal pure returns (uint256) {
    return floatingAssets != 0 ? (floatingDebt + backupBorrowed).divWadUp(floatingAssets) : 0;
  }

  function fixedUtilization(
    uint256 supplied,
    uint256 borrowed,
    uint256 floatingAssets
  ) internal pure returns (uint256) {
    return floatingAssets != 0 && borrowed > supplied ? (borrowed - supplied).divWadUp(floatingAssets) : 0;
  }

  function maturityDuration(uint256 maturity, uint256 assets) internal view returns (uint256 duration) {
    uint256 memFloatingAssetsAverage = market.previewFloatingAssetsAverage();
    if (memFloatingAssetsAverage == 0) return 0;
    {
      uint256 latestMaturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL);
      uint256 maxMaturity = latestMaturity + (market.maxFuturePools()) * FixedLib.INTERVAL;
      for (uint256 i = latestMaturity + FixedLib.INTERVAL; i <= maxMaturity; i += FixedLib.INTERVAL) {
        (uint256 borrowed, uint256 supplied, , ) = market.fixedPools(i);
        if (i == maturity) borrowed += assets;
        uint256 borrows = borrowed > supplied ? borrowed - supplied : 0;
        duration += borrows.mulDivDown(maturity - block.timestamp, 365 days).divWadDown(memFloatingAssetsAverage);
      }
    }
  }
}

error AlreadyMatured();
error UtilizationExceeded();

struct Parameters {
  uint256 minRate;
  uint256 naturalRate;
  uint256 maxUtilization;
  uint256 naturalUtilization;
  uint256 growthSpeed;
  uint256 sigmoidSpeed;
  uint256 spreadFactor;
  uint256 maturitySpeed;
  int256 timePreference;
  uint256 fixedAllocation;
  uint256 maxRate;
  uint256 maturityDurationSpeed;
  uint256 durationThreshold;
  uint256 durationGrowthLaw;
  uint256 penaltyDurationFactor;
}

struct FixedVars {
  uint256 sqFNatPools;
  uint256 fNatPools;
  uint256 fixedFactor;
  int256 natPools;
  uint256 maturityFactor;
}
