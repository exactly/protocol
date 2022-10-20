// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import { AlreadyMatured } from "../InterestRateModel.sol";
import { FixedLib } from "../utils/FixedLib.sol";
import { Auditor, IPriceFeed } from "../Auditor.sol";
import { Market } from "../Market.sol";

/// @title Previewer
/// @notice Contract to be consumed by Exactly's front-end dApp.
contract Previewer {
  using FixedPointMathLib for uint256;
  using FixedPointMathLib for int256;
  using FixedLib for FixedLib.Position;
  using FixedLib for FixedLib.Pool;
  using FixedLib for uint256;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;

  struct MarketAccount {
    // market
    Market market;
    uint8 decimals;
    string assetSymbol;
    uint256 oraclePrice;
    uint256 penaltyRate;
    uint256 adjustFactor;
    uint8 maxFuturePools;
    FixedPool[] fixedPools;
    uint256 floatingBackupBorrowed;
    uint256 floatingAvailableAssets;
    uint256 totalFloatingBorrowAssets;
    uint256 totalFloatingDepositAssets;
    // account
    bool isCollateral;
    uint256 maxBorrowAssets;
    uint256 floatingBorrowShares;
    uint256 floatingBorrowAssets;
    uint256 floatingDepositShares;
    uint256 floatingDepositAssets;
    FixedPosition[] fixedDepositPositions;
    FixedPosition[] fixedBorrowPositions;
  }

  struct FixedMarket {
    Market market;
    uint8 decimals;
    uint256 assets;
    FixedPreview[] deposits;
    FixedPreview[] borrows;
  }

  struct FixedPosition {
    uint256 maturity;
    FixedLib.Position position;
  }

  struct FixedPreview {
    uint256 maturity;
    uint256 assets;
    uint256 utilization;
  }

  struct FixedPool {
    uint256 maturity;
    uint256 borrowed;
    uint256 supplied;
    uint256 available;
    uint256 utilization;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_) {
    auditor = auditor_;
  }

  /// @notice Function to get a certain account extended data.
  /// @param account address which the extended data will be calculated.
  /// @return data extended accountability of all markets for the account.
  function exactly(address account) external view returns (MarketAccount[] memory data) {
    uint256 markets = auditor.accountMarkets(account);
    uint256 maxValue = auditor.allMarkets().length;
    (uint256 adjustedCollateral, uint256 adjustedDebt) = auditor.accountLiquidity(account, Market(address(0)), 0);
    data = new MarketAccount[](maxValue);
    for (uint256 i = 0; i < maxValue; ++i) {
      Market market = auditor.marketList(i);
      Market.Account memory a;
      Auditor.MarketData memory m;
      (m.adjustFactor, m.decimals, m.index, m.isListed, m.priceFeed) = auditor.markets(market);
      uint256 oraclePrice = auditor.assetPrice(m.priceFeed);
      (a.fixedDeposits, a.fixedBorrows, a.floatingBorrowShares) = market.accounts(account);
      data[i] = MarketAccount({
        // market
        market: market,
        decimals: m.decimals,
        assetSymbol: market.asset().symbol(),
        oraclePrice: oraclePrice,
        penaltyRate: market.penaltyRate(),
        adjustFactor: m.adjustFactor,
        maxFuturePools: market.maxFuturePools(),
        fixedPools: fixedPools(market),
        floatingBackupBorrowed: market.floatingBackupBorrowed(),
        floatingAvailableAssets: floatingAvailableAssets(market),
        totalFloatingDepositAssets: market.totalAssets(),
        totalFloatingBorrowAssets: market.totalFloatingBorrowAssets(),
        // account
        isCollateral: markets & (1 << i) != 0 ? true : false,
        maxBorrowAssets: adjustedCollateral >= adjustedDebt
          ? (adjustedCollateral - adjustedDebt).mulDivUp(10**m.decimals, oraclePrice).mulWadUp(m.adjustFactor)
          : 0,
        floatingBorrowShares: a.floatingBorrowShares,
        floatingBorrowAssets: maxRepay(market, account),
        floatingDepositShares: market.balanceOf(account),
        floatingDepositAssets: market.maxWithdraw(account),
        fixedDepositPositions: maturityPositions(account, a.fixedDeposits, market.fixedDepositPositions),
        fixedBorrowPositions: maturityPositions(account, a.fixedBorrows, market.fixedBorrowPositions)
      });
    }
  }

  /// @notice Function to preview deposits and borrows at fixed rates in all markets.
  /// @param usdAmount amount in usd expressed with 18 decimals.
  /// @return data with fixed rate simulations for every market.
  function previewFixed(uint256 usdAmount) external view returns (FixedMarket[] memory data) {
    uint256 maxValue = auditor.allMarkets().length;
    data = new FixedMarket[](maxValue);
    for (uint256 i = 0; i < maxValue; ++i) {
      Market market = auditor.marketList(i);
      (, uint8 decimals, , , IPriceFeed priceFeed) = auditor.markets(market);
      uint256 assets = usdAmount.mulDivDown(10**decimals, auditor.assetPrice(priceFeed));
      data[i] = FixedMarket({
        market: market,
        decimals: decimals,
        assets: assets,
        deposits: previewDepositAtAllMaturities(market, assets),
        borrows: previewBorrowAtAllMaturities(market, assets)
      });
    }
  }

  /// @notice Gets the assets plus yield offered by a maturity when depositing a certain amount.
  /// @param market address of the market.
  /// @param maturity maturity date/pool where the assets will be deposited.
  /// @param assets amount of assets that will be deposited.
  /// @return amount plus yield that the depositor will receive after maturity.
  function previewDepositAtMaturity(
    Market market,
    uint256 maturity,
    uint256 assets
  ) public view returns (FixedPreview memory) {
    if (block.timestamp > maturity) revert AlreadyMatured();
    (uint256 borrowed, uint256 supplied, , ) = market.fixedPools(maturity);
    uint256 memFloatingAssetsAverage = market.previewFloatingAssetsAverage();

    return
      FixedPreview({
        maturity: maturity,
        assets: assets + fixedDepositYield(market, maturity, assets),
        utilization: memFloatingAssetsAverage > 0
          ? (borrowed + assets).divWadUp(supplied + memFloatingAssetsAverage)
          : 0
      });
  }

  /// @notice Gets the assets plus yield offered by all VALID maturities when depositing a certain amount.
  /// @param market address of the market.
  /// @param assets amount of assets that will be deposited.
  /// @return previews array containing amount plus yield that account will receive after each maturity.
  function previewDepositAtAllMaturities(Market market, uint256 assets)
    public
    view
    returns (FixedPreview[] memory previews)
  {
    uint256 maxFuturePools = market.maxFuturePools();
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    previews = new FixedPreview[](maxFuturePools);
    for (uint256 i = 0; i < maxFuturePools; i++) {
      previews[i] = previewDepositAtMaturity(market, maturity, assets);
      maturity += FixedLib.INTERVAL;
    }
  }

  /// @notice Gets the amount plus fees to be repaid at maturity when borrowing certain amount of assets.
  /// @param market address of the market.
  /// @param maturity maturity date/pool where the assets will be borrowed.
  /// @param assets amount of assets that will be borrowed.
  /// @return positionAssets amount plus fees that the depositor will repay at maturity.
  function previewBorrowAtMaturity(
    Market market,
    uint256 maturity,
    uint256 assets
  ) public view returns (FixedPreview memory) {
    FixedLib.Pool memory pool;
    (pool.borrowed, pool.supplied, , ) = market.fixedPools(maturity);
    uint256 memFloatingAssetsAverage = market.previewFloatingAssetsAverage();

    uint256 fees = assets.mulWadDown(
      market.interestRateModel().fixedBorrowRate(
        maturity,
        assets,
        pool.borrowed,
        pool.supplied,
        memFloatingAssetsAverage
      )
    );
    return
      FixedPreview({
        maturity: maturity,
        assets: assets + fees,
        utilization: memFloatingAssetsAverage > 0
          ? (pool.borrowed + assets).divWadUp(pool.supplied + memFloatingAssetsAverage)
          : 0
      });
  }

  /// @notice Gets the assets plus fees offered by all VALID maturities when borrowing a certain amount.
  /// @param market address of the market.
  /// @param assets amount of assets that will be borrowed.
  /// @return previews array containing amount plus yield that account will receive after each maturity.
  function previewBorrowAtAllMaturities(Market market, uint256 assets)
    public
    view
    returns (FixedPreview[] memory previews)
  {
    uint256 maxFuturePools = market.maxFuturePools();
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    previews = new FixedPreview[](maxFuturePools);
    for (uint256 i = 0; i < maxFuturePools; i++) {
      try this.previewBorrowAtMaturity(market, maturity, assets) returns (FixedPreview memory preview) {
        previews[i] = preview;
      } catch {
        previews[i] = FixedPreview({ maturity: maturity, assets: type(uint256).max, utilization: type(uint256).max });
      }
      maturity += FixedLib.INTERVAL;
    }
  }

  /// @notice Gets the amount to be withdrawn for a certain positionAmount of assets at maturity.
  /// @param market address of the market.
  /// @param maturity maturity date/pool where the assets will be withdrawn.
  /// @param positionAssets amount of assets that will be tried to withdraw.
  /// @return withdrawAssets amount that will be withdrawn.
  function previewWithdrawAtMaturity(
    Market market,
    uint256 maturity,
    uint256 positionAssets
  ) external view returns (uint256 withdrawAssets) {
    if (block.timestamp >= maturity) return positionAssets;

    FixedLib.Pool memory pool;
    (pool.borrowed, pool.supplied, , ) = market.fixedPools(maturity);

    withdrawAssets = positionAssets.divWadDown(
      1e18 +
        market.interestRateModel().fixedBorrowRate(
          maturity,
          positionAssets,
          pool.borrowed,
          pool.supplied,
          market.previewFloatingAssetsAverage()
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
    Market market,
    uint256 maturity,
    uint256 positionAssets,
    address borrower
  ) external view returns (uint256 repayAssets) {
    if (block.timestamp >= maturity) {
      return positionAssets + positionAssets.mulWadDown((block.timestamp - maturity) * market.penaltyRate());
    }

    FixedLib.Position memory position;
    (position.principal, position.fee) = market.fixedBorrowPositions(maturity, borrower);

    return positionAssets - fixedDepositYield(market, maturity, position.scaleProportionally(positionAssets).principal);
  }

  function fixedPools(Market market) internal view returns (FixedPool[] memory pools) {
    uint256 freshFloatingDebt = newFloatingDebt(market);
    pools = new FixedPool[](market.maxFuturePools());
    for (uint256 i = 0; i < market.maxFuturePools(); i++) {
      FixedLib.Pool memory pool;
      (pool.borrowed, pool.supplied, , ) = market.fixedPools(
        block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL * (i + 1)
      );

      uint256 maxAssets = (market.floatingAssets() + freshFloatingDebt).mulWadDown(1e18 - market.reserveFactor());
      uint256 memFloatingAssetsAverage = market.previewFloatingAssetsAverage();

      pools[i] = FixedPool({
        maturity: block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL * (i + 1),
        borrowed: pool.borrowed,
        supplied: pool.supplied,
        available: Math.min(
          maxAssets - Math.min(maxAssets, market.floatingBackupBorrowed() + market.floatingDebt() + freshFloatingDebt),
          memFloatingAssetsAverage
        ) +
          pool.supplied -
          Math.min(pool.supplied, pool.borrowed),
        utilization: memFloatingAssetsAverage > 0 ? pool.borrowed.divWadUp(pool.supplied + memFloatingAssetsAverage) : 0
      });
    }
  }

  function floatingAvailableAssets(Market market) internal view returns (uint256) {
    uint256 freshFloatingDebt = newFloatingDebt(market);
    uint256 maxAssets = (market.floatingAssets() + freshFloatingDebt).mulWadDown(1e18 - market.reserveFactor());
    return maxAssets - Math.min(maxAssets, market.floatingBackupBorrowed() + market.floatingDebt() + freshFloatingDebt);
  }

  function maturityPositions(
    address account,
    uint256 packedMaturities,
    function(uint256, address) external view returns (uint256, uint256) getPositions
  ) internal view returns (FixedPosition[] memory userMaturityPositions) {
    uint256 userMaturityCount = 0;
    FixedPosition[] memory allMaturityPositions = new FixedPosition[](224);
    uint256 maturity = packedMaturities & ((1 << 32) - 1);
    packedMaturities = packedMaturities >> 32;
    while (packedMaturities != 0) {
      if (packedMaturities & 1 != 0) {
        (uint256 principal, uint256 fee) = getPositions(maturity, account);
        allMaturityPositions[userMaturityCount].maturity = maturity;
        allMaturityPositions[userMaturityCount].position = FixedLib.Position(principal, fee);
        ++userMaturityCount;
      }
      packedMaturities >>= 1;
      maturity += FixedLib.INTERVAL;
    }

    userMaturityPositions = new FixedPosition[](userMaturityCount);
    for (uint256 i = 0; i < userMaturityCount; ++i) userMaturityPositions[i] = allMaturityPositions[i];
  }

  function fixedDepositYield(
    Market market,
    uint256 maturity,
    uint256 assets
  ) internal view returns (uint256 yield) {
    FixedLib.Pool memory pool;
    (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
    pool.unassignedEarnings -= pool.unassignedEarnings.mulDivDown(
      block.timestamp - pool.lastAccrual,
      maturity - pool.lastAccrual
    );
    (yield, ) = pool.calculateDeposit(assets, market.backupFeeRate());
  }

  function maxRepay(Market market, address borrower) internal view returns (uint256) {
    (, , uint256 floatingBorrowShares) = market.accounts(borrower);
    return market.previewRefund(floatingBorrowShares);
  }

  function newFloatingDebt(Market market) internal view returns (uint256) {
    uint256 memFloatingDebt = market.floatingDebt();
    uint256 memFloatingAssets = market.floatingAssets();
    uint256 newFloatingUtilization = memFloatingAssets > 0
      ? Math.min(memFloatingDebt.divWadUp(memFloatingAssets), 1e18)
      : 0;
    return
      memFloatingDebt.mulWadDown(
        market.interestRateModel().floatingBorrowRate(market.floatingUtilization(), newFloatingUtilization).mulDivDown(
          block.timestamp - market.lastFloatingDebtUpdate(),
          365 days
        )
      );
  }
}
