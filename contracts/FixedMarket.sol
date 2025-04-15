// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { FixedLib } from "./utils/FixedLib.sol";
import { Market } from "./Market.sol";

contract FixedMarket {
  using FixedPointMathLib for int256;
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for uint128;

  Market public market;

  constructor(Market _market) {
    market = _market;
  }

  function fixedRate(uint256 maturity) external view returns (uint256) {
    (uint256 borrowed, uint256 supplied, , ) = market.fixedPools(maturity);
    uint256 memFloatingAssets = market.floatingAssets();
    uint256 memFloatingDebt = market.floatingDebt();
    return
      market.interestRateModel().fixedRate(
        maturity,
        market.maxFuturePools(),
        fixedUtilization(supplied, borrowed, memFloatingAssets),
        floatingUtilization(memFloatingAssets, memFloatingDebt),
        globalUtilization(memFloatingAssets, memFloatingDebt, market.floatingBackupBorrowed()),
        previewGlobalUtilizationAverage()
      );
  }

  /// @notice Returns the current `floatingAssetsAverage` without updating the storage variable.
  /// @return projected `floatingAssetsAverage`.
  function previewFloatingAssetsAverage() public view returns (uint256) {
    uint256 memFloatingAssets = market.floatingAssets();
    uint256 memFloatingAssetsAverage = market.floatingAssetsAverage();
    uint256 dampSpeedFactor = memFloatingAssets < memFloatingAssetsAverage
      ? market.floatingAssetsDampSpeedDown()
      : market.floatingAssetsDampSpeedUp();
    uint256 averageFactor = uint256(
      1e18 - (-int256(dampSpeedFactor * (block.timestamp - market.lastAverageUpdate()))).expWad()
    );
    return memFloatingAssetsAverage.mulWadDown(1e18 - averageFactor) + averageFactor.mulWadDown(memFloatingAssets);
  }

  function previewGlobalUtilizationAverage() public view returns (uint256) {
    uint256 memGlobalUtilization = globalUtilization(
      market.floatingAssets(),
      market.floatingDebt(),
      market.floatingBackupBorrowed()
    );
    uint256 memGlobalUtilizationAverage = market.globalUtilizationAverage();
    uint256 dampSpeedFactor = memGlobalUtilization < memGlobalUtilizationAverage
      ? market.uDampSpeedDown()
      : market.uDampSpeedUp();
    uint256 averageFactor = uint256(
      1e18 - (-int256(dampSpeedFactor * (block.timestamp - market.lastAverageUpdate()))).expWad()
    );
    return
      memGlobalUtilizationAverage.mulWadDown(1e18 - averageFactor) + averageFactor.mulWadDown(memGlobalUtilization);
  }

  /// @notice Checks if the account can borrow at a certain fixed pool.
  /// @param maturity maturity date of the fixed pool.
  /// @param assets amount of assets to borrow.
  /// @return true if the account can borrow at the given maturity, false otherwise.
  function canBorrowAtMaturity(uint256 maturity, uint256 assets) external view returns (bool) {
    uint256 totalBorrows;
    {
      uint256 maxTime = market.maxFuturePools() * FixedLib.INTERVAL;
      for (uint256 i = maturity; i <= maxTime; i += FixedLib.INTERVAL) {
        (uint256 borrowed, uint256 supplied, , ) = market.fixedPools(i);
        if (i == maturity) borrowed += assets;
        totalBorrows += borrowed > supplied ? borrowed - supplied : 0;
      }
    }
    uint256 memFloatingAssetsAverage = previewFloatingAssetsAverage();
    return
      memFloatingAssetsAverage != 0
        ? totalBorrows.divWadDown(memFloatingAssetsAverage) <
          uint256(
            (market.fixedBorrowThreshold() *
              ((((market.curveFactor() *
                int256(
                  (maturity - block.timestamp - (FixedLib.INTERVAL - (block.timestamp % FixedLib.INTERVAL)) + 1)
                    .divWadDown(market.maxFuturePools() * FixedLib.INTERVAL)
                ).lnWad()) / 1e18).expWad() * market.minThresholdFactor()) / 1e18).expWad()) / 1e18
          ) &&
          market.floatingBackupBorrowed() + assets <
          memFloatingAssetsAverage.mulWadDown(uint256(market.fixedBorrowThreshold()))
        : true;
  }

  /// @notice Gets all borrows and penalties for an account.
  /// @param borrower account to return status snapshot for fixed and floating borrows.
  /// @return debt the total debt, denominated in number of assets.
  function previewDebt(address borrower) external view returns (uint256 debt) {
    (, uint256 packedMaturities, uint256 floatingBorrowShares) = market.accounts(borrower);
    uint256 maturity = packedMaturities & ((1 << 32) - 1);
    packedMaturities = packedMaturities >> 32;
    // calculate all maturities using the base maturity and the following bits representing the following intervals
    while (packedMaturities != 0) {
      if (packedMaturities & 1 != 0) {
        (uint256 principal, uint256 fee) = market.fixedBorrowPositions(maturity, borrower);
        uint256 positionAssets = principal + fee;

        debt += positionAssets;

        if (block.timestamp > maturity) {
          debt += positionAssets.mulWadDown((block.timestamp - maturity) * market.penaltyRate());
        }
      }
      packedMaturities >>= 1;
      maturity += FixedLib.INTERVAL;
    }
    // calculate floating borrowed debt
    uint256 shares = floatingBorrowShares;
    if (shares != 0) debt += market.previewRefund(shares);
  }

  /// @notice Calculates the total floating debt, considering elapsed time since last update and current interest rate.
  /// @return actual floating debt plus projected interest.
  function totalFloatingBorrowAssets() external view returns (uint256) {
    uint256 memFloatingDebt = market.floatingDebt();
    uint256 memFloatingAssets = market.floatingAssets();
    uint256 newDebt = memFloatingDebt.mulWadDown(
      market
        .interestRateModel()
        .floatingRate(
          floatingUtilization(memFloatingAssets, memFloatingDebt),
          globalUtilization(memFloatingAssets, memFloatingDebt, market.floatingBackupBorrowed())
        )
        .mulDivDown(block.timestamp - market.lastFloatingDebtUpdate(), 365 days)
    );
    return memFloatingDebt + newDebt;
  }

  /// @notice Calculates the earnings to be distributed from the accumulator given the current timestamp.
  /// @return earnings to be distributed from the accumulator.
  function accumulatedEarnings() external view returns (uint256 earnings) {
    uint256 elapsed = block.timestamp - market.lastAccumulatorAccrual();
    if (elapsed == 0) return 0;
    return
      market.earningsAccumulator().mulDivDown(
        elapsed,
        elapsed + market.earningsAccumulatorSmoothFactor().mulWadDown(market.maxFuturePools() * FixedLib.INTERVAL)
      );
  }

  /// @notice Retrieves global utilization of the floating pool.
  /// @dev Internal function to avoid code duplication.
  function globalUtilization(uint256 assets, uint256 debt, uint256 backupBorrowed) internal pure returns (uint256) {
    return assets != 0 ? (debt + backupBorrowed).divWadUp(assets) : 0;
  }

  /// @notice Retrieves floating utilization of the floating pool.
  /// @dev Internal function to avoid code duplication.
  function floatingUtilization(uint256 assets, uint256 debt) internal pure returns (uint256) {
    return assets != 0 ? debt.divWadUp(assets) : 0;
  }

  /// @notice Adds a maturity date to the borrow or supply positions of the account.
  /// @param encoded encoded maturity dates where the account borrowed or supplied to.
  /// @param maturity the new maturity where the account will borrow or supply to.
  /// @return updated encoded maturity dates.
  function setMaturity(uint256 encoded, uint256 maturity) external pure returns (uint256) {
    // initialize the maturity with also the 1st bit on the 33th position set
    if (encoded == 0) return maturity | (1 << 32);

    uint256 baseMaturity = encoded & ((1 << 32) - 1);
    if (maturity < baseMaturity) {
      // if the new maturity is lower than the base, set it as the new base
      // wipe clean the last 32 bits, shift the amount of `INTERVAL` and set the new value with the 33rd bit set
      uint256 range = (baseMaturity - maturity) / FixedLib.INTERVAL;
      if (encoded >> (256 - range) != 0) revert MaturityOverflow();
      encoded = ((encoded >> 32) << (32 + range));
      return maturity | encoded | (1 << 32);
    } else {
      uint256 range = (maturity - baseMaturity) / FixedLib.INTERVAL;
      if (range > 223) revert MaturityOverflow();
      return encoded | (1 << (32 + range));
    }
  }

  /// @notice Retrieves fixed utilization of the floating pool.
  /// @dev Internal function to avoid code duplication.
  function fixedUtilization(uint256 supplied, uint256 borrowed, uint256 assets) internal pure returns (uint256) {
    return assets != 0 && borrowed > supplied ? (borrowed - supplied).divWadUp(assets) : 0;
  }
}

error MaturityOverflow();
