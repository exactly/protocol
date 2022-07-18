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
  using PoolLib for uint256;

  Auditor public immutable auditor;

  struct MaturityPosition {
    uint256 maturity;
    PoolLib.Position position;
  }

  struct MaturityLiquidity {
    uint256 maturity;
    uint256 assets;
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
    uint256 flexibleBorrowShares;
    uint256 flexibleBorrowAssets;
    uint256 flexibleBorrowRate;
    uint256 flexibleAvailableLiquidity;
    MaturityLiquidity[] fixedAvailableLiquidity;
    MaturityPosition[] fixedSupplyPositions;
    MaturityPosition[] fixedBorrowPositions;
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
  ) public view returns (uint256 positionAssets) {
    if (block.timestamp > maturity) revert AlreadyMatured();

    PoolLib.FixedPool memory pool;
    (pool.borrowed, pool.supplied, pool.earningsUnassigned, pool.lastAccrual) = market.fixedPools(maturity);
    (uint256 smartPoolBorrowed, uint256 unassignedEarnings) = getPoolData(market, maturity);

    (uint256 yield, ) = assets.getDepositYield(unassignedEarnings, smartPoolBorrowed, market.smartPoolFeeRate());
    positionAssets = assets + yield;
  }

  /// @notice Gets the assets plus yield offered by all VALID maturities when depositing a certain amount.
  /// @param market address of the market.
  /// @param assets amount of assets that will be deposited.
  /// @return positionAssetsMaturities array containing amount plus yield that user will receive after each maturity.
  function previewDepositAtAllMaturities(FixedLender market, uint256 assets)
    external
    view
    returns (MaturityLiquidity[] memory positionAssetsMaturities)
  {
    uint256 maxFuturePools = market.maxFuturePools();
    uint256 nextMaturity = block.timestamp - (block.timestamp % TSUtils.INTERVAL) + TSUtils.INTERVAL;
    positionAssetsMaturities = new MaturityLiquidity[](maxFuturePools);
    for (uint256 i = 0; i < maxFuturePools; i++) {
      uint256 maturity = nextMaturity + TSUtils.INTERVAL * i;

      positionAssetsMaturities[i].maturity = maturity;
      positionAssetsMaturities[i].assets = previewDepositAtMaturity(market, maturity, assets);
    }
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
    PoolLib.FixedPool memory pool;
    (pool.borrowed, pool.supplied, , ) = market.fixedPools(maturity);

    uint256 fees = assets.mulWadDown(
      market.interestRateModel().getFixedBorrowRate(
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

    PoolLib.FixedPool memory pool;
    (pool.borrowed, pool.supplied, , ) = market.fixedPools(maturity);

    withdrawAssets = positionAssets.divWadDown(
      1e18 +
        market.interestRateModel().getFixedBorrowRate(
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
    (debt.principal, debt.fee) = market.fixedBorrowPositions(maturity, borrower);
    PoolLib.Position memory coveredDebt = debt.scaleProportionally(positionAssets);

    (uint256 discount, ) = coveredDebt.principal.getDepositYield(
      unassignedEarnings,
      smartPoolBorrowed,
      market.smartPoolFeeRate()
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
        flexibleBorrowShares: market.flexibleBorrowPositions(account),
        flexibleBorrowAssets: flexibleBorrowAssets(account, market),
        flexibleBorrowRate: flexibleBorrowRate(market),
        flexibleAvailableLiquidity: flexibleAvailableLiquidity(market),
        fixedAvailableLiquidity: fixedAvailableLiquidity(market),
        fixedSupplyPositions: maturityPositions(account, market.fixedDeposits, market.fixedDepositPositions),
        fixedBorrowPositions: maturityPositions(account, market.fixedBorrows, market.fixedBorrowPositions)
      });
    }
  }

  function flexibleBorrowAssets(address account, FixedLender market) internal view returns (uint256 borrowedAssets) {
    uint256 shares = market.flexibleBorrowPositions(account);
    if (shares > 0) {
      uint256 totalBorrowedAssets = market.smartPoolFlexibleBorrows();
      uint256 spCurrentUtilization = totalBorrowedAssets.divWadDown(
        market.smartPoolAssets().divWadDown(market.interestRateModel().flexibleFullUtilization())
      );
      uint256 newDebt = totalBorrowedAssets.mulWadDown(
        market
          .interestRateModel()
          .getFlexibleBorrowRate(market.spPreviousUtilization(), spCurrentUtilization)
          .mulDivDown(block.timestamp - market.lastUpdatedSmartPoolRate(), 365 days)
      );
      uint256 supply = market.totalFlexibleBorrowsShares();

      borrowedAssets = supply == 0 ? shares : shares.mulDivDown(totalBorrowedAssets + newDebt, supply);
    }
  }

  function flexibleBorrowRate(FixedLender market) internal view returns (uint256) {
    InterestRateModel interestRateModel = market.interestRateModel();
    uint256 smartPoolAssets = market.smartPoolAssets();

    return
      smartPoolAssets > 0
        ? interestRateModel.getFlexibleBorrowRate(
          market.spPreviousUtilization(),
          market.smartPoolFlexibleBorrows().divWadDown(
            smartPoolAssets.divWadDown(interestRateModel.flexibleFullUtilization())
          )
        )
        : 0;
  }

  function fixedAvailableLiquidity(FixedLender market)
    internal
    view
    returns (MaturityLiquidity[] memory availableLiquidities)
  {
    uint256 maxFuturePools = market.maxFuturePools();
    uint256 nextMaturity = block.timestamp - (block.timestamp % TSUtils.INTERVAL) + TSUtils.INTERVAL;
    availableLiquidities = new MaturityLiquidity[](maxFuturePools);
    for (uint256 i = 0; i < maxFuturePools; i++) {
      uint256 maturity = nextMaturity + TSUtils.INTERVAL * i;
      PoolLib.FixedPool memory pool;
      (pool.borrowed, pool.supplied, , ) = market.fixedPools(maturity);

      uint256 borrowableAssets = market.smartPoolAssets().mulWadDown(1e18 - market.smartPoolReserveFactor());
      uint256 fixedDeposits = pool.supplied - Math.min(pool.supplied, pool.borrowed);

      availableLiquidities[i].maturity = maturity;
      availableLiquidities[i].assets =
        Math.min(
          borrowableAssets -
            Math.min(borrowableAssets, market.smartPoolFixedBorrows() + market.smartPoolFlexibleBorrows()),
          smartPoolAssetsAverage(market)
        ) +
        fixedDeposits;
    }
  }

  function flexibleAvailableLiquidity(FixedLender market) internal view returns (uint256) {
    uint256 borrowableAssets = market.smartPoolAssets().mulWadDown(1e18 - market.smartPoolReserveFactor());
    return
      borrowableAssets - Math.min(borrowableAssets, market.smartPoolFixedBorrows() + market.smartPoolFlexibleBorrows());
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
    PoolLib.FixedPool memory pool;
    (pool.borrowed, pool.supplied, pool.earningsUnassigned, pool.lastAccrual) = market.fixedPools(maturity);

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
