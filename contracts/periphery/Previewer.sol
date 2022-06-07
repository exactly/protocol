// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedLender } from "../FixedLender.sol";
import { InterestRateModel, AlreadyMatured } from "../InterestRateModel.sol";
import { Auditor } from "../Auditor.sol";
import { PoolLib } from "../utils/PoolLib.sol";
import { TSUtils } from "../utils/TSUtils.sol";

/// @title Previewer
/// @notice Contract to be consumed by Exactly's front-end dApp.
contract Previewer {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;
  using PoolLib for PoolLib.Position;

  Auditor public immutable auditor;

  struct MaturityPosition {
    uint256 maturity;
    PoolLib.Position position;
  }

  struct MarketAccount {
    FixedLender fixedLender;
    string assetSymbol;
    MaturityPosition[] maturitySupplyPositions;
    MaturityPosition[] maturityBorrowPositions;
    uint256 smartPoolAssets;
    uint256 smartPoolShares;
    uint256 oraclePrice;
    uint128 penaltyRate;
    uint128 adjustFactor;
    uint8 decimals;
    bool isCollateral;
  }

  struct MaturityBitmap {
    uint256 encoded;
    uint256 base;
    uint256 packed;
  }

  constructor(Auditor auditor_) {
    auditor = auditor_;
  }

  /// @notice Gets the assets plus yield offered by a maturity when depositing a certain amount.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be deposited.
  /// @param assets amount of assets that will be deposited.
  /// @return positionAssets amount plus yield that the depositor will receive after maturity.
  function previewDepositAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 assets
  ) external view returns (uint256 positionAssets) {
    if (block.timestamp > maturity) revert AlreadyMatured();

    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, pool.earningsUnassigned, pool.lastAccrual) = fixedLender.maturityPools(maturity);
    (uint256 smartPoolBorrowed, uint256 unassignedEarnings) = getPoolData(fixedLender, maturity);

    (uint256 yield, ) = fixedLender.interestRateModel().getYieldForDeposit(
      smartPoolBorrowed,
      unassignedEarnings,
      assets
    );
    positionAssets = assets + yield;
  }

  /// @notice Gets the amount plus fees to be repayed at maturity when borrowing certain amount of assets.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be borrowed.
  /// @param assets amount of assets that will be borrowed.
  /// @return positionAssets amount plus fees that the depositor will repay at maturity.
  function previewBorrowAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 assets
  ) external view returns (uint256 positionAssets) {
    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, , ) = fixedLender.maturityPools(maturity);

    uint256 fees = assets.mulWadDown(
      fixedLender.interestRateModel().getRateToBorrow(
        maturity,
        block.timestamp,
        assets,
        pool.borrowed,
        pool.supplied,
        smartPoolAssetsAverage(fixedLender)
      )
    );
    positionAssets = assets + fees;
  }

  /// @notice Gets the amount to be withdrawn for a certain positionAmount of assets at maturity.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be withdrawn.
  /// @param positionAssets amount of assets that will be tried to withdraw.
  /// @return withdrawAssets amount that will be withdrawn.
  function previewWithdrawAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 positionAssets
  ) external view returns (uint256 withdrawAssets) {
    if (block.timestamp >= maturity) return positionAssets;

    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, , ) = fixedLender.maturityPools(maturity);

    withdrawAssets = positionAssets.divWadDown(
      1e18 +
        fixedLender.interestRateModel().getRateToBorrow(
          maturity,
          block.timestamp,
          positionAssets,
          pool.borrowed,
          pool.supplied,
          smartPoolAssetsAverage(fixedLender)
        )
    );
  }

  /// @notice Gets the assets that will be repaid when repaying a certain amount at the current maturity.
  /// @param fixedLender address of the market.
  /// @param maturity maturity date/pool where the assets will be repaid.
  /// @param positionAssets amount of assets that will be substracted from the position.
  /// @param borrower address of the borrower.
  /// @return repayAssets amount of assets that will be repaid.
  function previewRepayAtMaturity(
    FixedLender fixedLender,
    uint256 maturity,
    uint256 positionAssets,
    address borrower
  ) external view returns (uint256 repayAssets) {
    if (block.timestamp >= maturity) {
      return
        repayAssets =
          positionAssets +
          positionAssets.mulWadDown((block.timestamp - maturity) * fixedLender.penaltyRate());
    }

    (uint256 smartPoolBorrowed, uint256 unassignedEarnings) = getPoolData(fixedLender, maturity);
    PoolLib.Position memory debt;
    (debt.principal, debt.fee) = fixedLender.mpUserBorrowedAmount(maturity, borrower);
    PoolLib.Position memory coveredDebt = debt.scaleProportionally(positionAssets);

    (uint256 discount, ) = fixedLender.interestRateModel().getYieldForDeposit(
      smartPoolBorrowed,
      unassignedEarnings,
      coveredDebt.principal
    );
    repayAssets = positionAssets - discount;
  }

  /// @notice Function to get a certain account extended data.
  /// @param account address which the extended data will be calculated.
  /// @return data extended accountability of all markets for the account.
  function accounts(address account) external view returns (MarketAccount[] memory data) {
    uint256 assets = auditor.accountMarkets(account);
    uint256 maxValue = auditor.getAllMarkets().length;
    data = new MarketAccount[](maxValue);
    for (uint256 i = 0; i < maxValue; ++i) {
      data[i].fixedLender = auditor.allMarkets(i);
      data[i].assetSymbol = data[i].fixedLender.asset().symbol();
      (, , data[i].adjustFactor, data[i].decimals, , ) = auditor.markets(data[i].fixedLender);
      (data[i].smartPoolAssets, ) = data[i].fixedLender.getAccountSnapshot(account, PoolLib.MATURITY_ALL);
      data[i].smartPoolShares = data[i].fixedLender.convertToShares(data[i].smartPoolAssets);
      data[i].oraclePrice = auditor.oracle().getAssetPrice(data[i].fixedLender);
      data[i].isCollateral = assets & (1 << i) != 0 ? true : false;
      data[i].penaltyRate = uint128(data[i].fixedLender.penaltyRate());
      data[i].maturitySupplyPositions = maturityPoolPositions(
        account,
        data[i].fixedLender.userMpSupplied,
        data[i].fixedLender.mpUserSuppliedAmount
      );
      data[i].maturityBorrowPositions = maturityPoolPositions(
        account,
        data[i].fixedLender.userMpBorrowed,
        data[i].fixedLender.mpUserBorrowedAmount
      );
    }
  }

  function maturityPoolPositions(
    address account,
    function(address) external view returns (uint256) userMaturityOperation,
    function(uint256, address) external view returns (uint256, uint256) userMaturityOperationAmount
  ) internal view returns (MaturityPosition[] memory maturityPoolDataPositions) {
    MaturityBitmap memory maturityBitmap;
    maturityBitmap.encoded = userMaturityOperation(account);
    maturityBitmap.base = maturityBitmap.encoded % (1 << 32);
    maturityBitmap.packed = maturityBitmap.encoded >> 32;
    MaturityPosition[] memory maturityPositions = new MaturityPosition[](224);

    uint256 maturityCount = 0;
    for (uint256 j = 0; j < 224; ++j) {
      if ((maturityBitmap.packed & (1 << j)) != 0) {
        uint256 maturity = maturityBitmap.base + (j * TSUtils.INTERVAL);
        (uint256 principal, uint256 fee) = userMaturityOperationAmount(maturity, account);
        maturityPositions[maturityCount].maturity = maturity;
        maturityPositions[maturityCount].position = PoolLib.Position(principal, fee);
        ++maturityCount;
      }
      if ((1 << j) > maturityBitmap.packed) break;
    }

    maturityPoolDataPositions = new MaturityPosition[](maturityCount);
    for (uint256 j = 0; j < maturityCount; ++j) maturityPoolDataPositions[j] = maturityPositions[j];
  }

  function getPoolData(FixedLender fixedLender, uint256 maturity)
    internal
    view
    returns (uint256 smartPoolBorrowed, uint256 unassignedEarnings)
  {
    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, pool.earningsUnassigned, pool.lastAccrual) = fixedLender.maturityPools(maturity);

    smartPoolBorrowed = pool.borrowed - Math.min(pool.borrowed, pool.supplied);
    unassignedEarnings =
      pool.earningsUnassigned -
      pool.earningsUnassigned.mulDivDown(block.timestamp - pool.lastAccrual, maturity - pool.lastAccrual);
  }

  function smartPoolAssetsAverage(FixedLender fixedLender) internal view returns (uint256) {
    uint256 dampSpeedFactor = fixedLender.smartPoolAssets() < fixedLender.smartPoolAssetsAverage()
      ? fixedLender.dampSpeedDown()
      : fixedLender.dampSpeedUp();
    uint256 averageFactor = uint256(
      1e18 - (-int256(dampSpeedFactor * (block.timestamp - fixedLender.lastAverageUpdate()))).expWad()
    );
    return
      fixedLender.smartPoolAssetsAverage().mulWadDown(1e18 - averageFactor) +
      averageFactor.mulWadDown(fixedLender.smartPoolAssets());
  }
}
