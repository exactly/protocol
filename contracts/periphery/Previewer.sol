// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { InterestRateModel, AlreadyMatured } from "../InterestRateModel.sol";
import { ExactlyOracle } from "../ExactlyOracle.sol";
import { FixedLender } from "../FixedLender.sol";
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
    FixedLender market;
    string assetSymbol;
    uint256 oraclePrice;
    uint128 penaltyRate;
    uint128 adjustFactor;
    uint8 decimals;
    uint8 maxFuturePools;
    bool isCollateral;
    uint256 smartPoolShares;
    uint256 smartPoolAssets;
    MaturityPosition[] maturitySupplyPositions;
    MaturityPosition[] maturityBorrowPositions;
  }

  struct MaturityBitmap {
    uint256 base;
    uint256 packed;
  }

  constructor(Auditor auditor_) {
    auditor = auditor_;
  }

  /// @notice Gets the assets plus yield offered by a maturity when depositing a certain amount.
  /// @param market address of the market.
  /// @param maturity maturity date/pool where the assets will be deposited.
  /// @param assets amount of assets that will be deposited.
  /// @return positionAssets amount plus yield that the depositor will receive after maturity.
  function previewDepositAtMaturity(
    FixedLender market,
    uint256 maturity,
    uint256 assets
  ) external view returns (uint256 positionAssets) {
    if (block.timestamp > maturity) revert AlreadyMatured();

    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, pool.earningsUnassigned, pool.lastAccrual) = market.maturityPools(maturity);
    (uint256 smartPoolBorrowed, uint256 unassignedEarnings) = getPoolData(market, maturity);

    (uint256 yield, ) = market.interestRateModel().getYieldForDeposit(smartPoolBorrowed, unassignedEarnings, assets);
    positionAssets = assets + yield;
  }

  /// @notice Gets the amount plus fees to be repaid at maturity when borrowing certain amount of assets.
  /// @param market address of the market.
  /// @param maturity maturity date/pool where the assets will be borrowed.
  /// @param assets amount of assets that will be borrowed.
  /// @return positionAssets amount plus fees that the depositor will repay at maturity.
  function previewBorrowAtMaturity(
    FixedLender market,
    uint256 maturity,
    uint256 assets
  ) external view returns (uint256 positionAssets) {
    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, , ) = market.maturityPools(maturity);

    uint256 fees = assets.mulWadDown(
      market.interestRateModel().getRateToBorrow(
        maturity,
        block.timestamp,
        assets,
        pool.borrowed,
        pool.supplied,
        smartPoolAssetsAverage(market)
      )
    );
    positionAssets = assets + fees;
  }

  /// @notice Gets the amount to be withdrawn for a certain positionAmount of assets at maturity.
  /// @param market address of the market.
  /// @param maturity maturity date/pool where the assets will be withdrawn.
  /// @param positionAssets amount of assets that will be tried to withdraw.
  /// @return withdrawAssets amount that will be withdrawn.
  function previewWithdrawAtMaturity(
    FixedLender market,
    uint256 maturity,
    uint256 positionAssets
  ) external view returns (uint256 withdrawAssets) {
    if (block.timestamp >= maturity) return positionAssets;

    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, , ) = market.maturityPools(maturity);

    withdrawAssets = positionAssets.divWadDown(
      1e18 +
        market.interestRateModel().getRateToBorrow(
          maturity,
          block.timestamp,
          positionAssets,
          pool.borrowed,
          pool.supplied,
          smartPoolAssetsAverage(market)
        )
    );
  }

  /// @notice Gets the assets that will be repaid when repaying a certain amount at the current maturity.
  /// @param market address of the market.
  /// @param maturity maturity date/pool where the assets will be repaid.
  /// @param positionAssets amount of assets that will be subtracted from the position.
  /// @param borrower address of the borrower.
  /// @return repayAssets amount of assets that will be repaid.
  function previewRepayAtMaturity(
    FixedLender market,
    uint256 maturity,
    uint256 positionAssets,
    address borrower
  ) external view returns (uint256 repayAssets) {
    if (block.timestamp >= maturity) {
      return
        repayAssets = positionAssets + positionAssets.mulWadDown((block.timestamp - maturity) * market.penaltyRate());
    }

    (uint256 smartPoolBorrowed, uint256 unassignedEarnings) = getPoolData(market, maturity);
    PoolLib.Position memory debt;
    (debt.principal, debt.fee) = market.mpUserBorrowedAmount(maturity, borrower);
    PoolLib.Position memory coveredDebt = debt.scaleProportionally(positionAssets);

    (uint256 discount, ) = market.interestRateModel().getYieldForDeposit(
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
    ExactlyOracle oracle = auditor.oracle();
    uint256 markets = auditor.accountMarkets(account);
    uint256 maxValue = auditor.getAllMarkets().length;
    data = new MarketAccount[](maxValue);
    for (uint256 i = 0; i < maxValue; ++i) {
      FixedLender market = auditor.getAllMarkets()[i];
      (uint128 adjustFactor, uint8 decimals, , ) = auditor.markets(market);
      data[i] = MarketAccount({
        market: market,
        assetSymbol: market.asset().symbol(),
        oraclePrice: oracle.getAssetPrice(market),
        penaltyRate: uint128(market.penaltyRate()),
        adjustFactor: adjustFactor,
        decimals: decimals,
        maxFuturePools: market.maxFuturePools(),
        isCollateral: markets & (1 << i) != 0 ? true : false,
        smartPoolShares: market.balanceOf(account),
        smartPoolAssets: market.maxWithdraw(account),
        maturitySupplyPositions: maturityPositions(account, market.userMpSupplied, market.mpUserSuppliedAmount),
        maturityBorrowPositions: maturityPositions(account, market.userMpBorrowed, market.mpUserBorrowedAmount)
      });
    }
  }

  function maturityPositions(
    address account,
    function(address) external view returns (uint256) getMaturities,
    function(uint256, address) external view returns (uint256, uint256) getPositions
  ) internal view returns (MaturityPosition[] memory userMaturityPositions) {
    uint256 userMaturityCount = 0;
    MaturityPosition[] memory allMaturityPositions = new MaturityPosition[](224);
    MaturityBitmap memory maturities;
    maturities.packed = getMaturities(account);
    maturities.base = maturities.packed % (1 << 32);
    maturities.packed = maturities.packed >> 32;
    for (uint256 i = 0; i < 224; ++i) {
      if ((maturities.packed & (1 << i)) != 0) {
        uint256 maturity = maturities.base + (i * TSUtils.INTERVAL);
        (uint256 principal, uint256 fee) = getPositions(maturity, account);
        allMaturityPositions[userMaturityCount].maturity = maturity;
        allMaturityPositions[userMaturityCount].position = PoolLib.Position(principal, fee);
        ++userMaturityCount;
      }
      if ((1 << i) > maturities.packed) break;
    }

    userMaturityPositions = new MaturityPosition[](userMaturityCount);
    for (uint256 i = 0; i < userMaturityCount; ++i) userMaturityPositions[i] = allMaturityPositions[i];
  }

  function getPoolData(FixedLender market, uint256 maturity)
    internal
    view
    returns (uint256 smartPoolBorrowed, uint256 unassignedEarnings)
  {
    PoolLib.MaturityPool memory pool;
    (pool.borrowed, pool.supplied, pool.earningsUnassigned, pool.lastAccrual) = market.maturityPools(maturity);

    smartPoolBorrowed = pool.borrowed - Math.min(pool.borrowed, pool.supplied);
    unassignedEarnings =
      pool.earningsUnassigned -
      pool.earningsUnassigned.mulDivDown(block.timestamp - pool.lastAccrual, maturity - pool.lastAccrual);
  }

  function smartPoolAssetsAverage(FixedLender market) internal view returns (uint256) {
    uint256 dampSpeedFactor = market.smartPoolAssets() < market.smartPoolAssetsAverage()
      ? market.dampSpeedDown()
      : market.dampSpeedUp();
    uint256 averageFactor = uint256(
      1e18 - (-int256(dampSpeedFactor * (block.timestamp - market.lastAverageUpdate()))).expWad()
    );
    return
      market.smartPoolAssetsAverage().mulWadDown(1e18 - averageFactor) +
      averageFactor.mulWadDown(market.smartPoolAssets());
  }
}
