// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable-v4/utils/math/MathUpgradeable.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { InterestRateModel as IRM, Parameters, AlreadyMatured } from "../InterestRateModel.sol";
import { RewardsController } from "../RewardsController.sol";
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
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  IPriceFeed public immutable basePriceFeed;

  struct MarketAccount {
    // market
    Market market;
    string symbol;
    uint8 decimals;
    address asset;
    string assetName;
    string assetSymbol;
    bool isFrozen;
    InterestRateModel interestRateModel;
    uint256 usdPrice;
    uint256 penaltyRate;
    uint256 adjustFactor;
    uint8 maxFuturePools;
    uint256 reserveFactor;
    FixedPool[] fixedPools;
    RewardRate[] rewardRates;
    uint256 floatingBorrowRate;
    uint256 floatingUtilization;
    uint256 floatingAssets;
    uint256 floatingDebt;
    uint256 floatingBackupBorrowed;
    uint256 floatingAvailableAssets;
    uint256 totalFloatingBorrowAssets;
    uint256 totalFloatingDepositAssets;
    uint256 totalFloatingBorrowShares;
    uint256 totalFloatingDepositShares;
    // account
    bool isCollateral;
    uint256 maxBorrowAssets;
    uint256 floatingBorrowShares;
    uint256 floatingBorrowAssets;
    uint256 floatingDepositShares;
    uint256 floatingDepositAssets;
    FixedPosition[] fixedDepositPositions;
    FixedPosition[] fixedBorrowPositions;
    ClaimableReward[] claimableRewards;
  }

  struct RewardRate {
    ERC20 asset;
    string assetName;
    string assetSymbol;
    uint256 usdPrice;
    uint256 borrow;
    uint256 floatingDeposit;
    uint256[] maturities;
  }

  struct ClaimableReward {
    address asset;
    string assetName;
    string assetSymbol;
    uint256 amount;
  }

  struct InterestRateModel {
    address id;
    Parameters parameters;
  }

  struct FixedPosition {
    uint256 maturity;
    uint256 previewValue;
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
    uint256 depositRate;
    uint256 minBorrowRate;
    uint256 optimalDeposit;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_, IPriceFeed basePriceFeed_) {
    auditor = auditor_;
    basePriceFeed = basePriceFeed_;
  }

  /// @notice Function to get a certain account extended data.
  /// @param account address which the extended data will be calculated.
  /// @return data extended accountability of all markets for the account.
  function exactly(address account) external view returns (MarketAccount[] memory data) {
    uint256 markets = auditor.accountMarkets(account);
    uint256 maxValue = auditor.allMarkets().length;
    (uint256 adjustedCollateral, uint256 adjustedDebt) = auditor.accountLiquidity(account, Market(address(0)), 0);
    uint256 basePrice = address(basePriceFeed) != address(0)
      ? uint256(basePriceFeed.latestAnswer()) * 10 ** (18 - basePriceFeed.decimals())
      : 1e18;
    data = new MarketAccount[](maxValue);
    for (uint256 i = 0; i < maxValue; ++i) {
      Market market = auditor.marketList(i);
      Market.Account memory a;
      Auditor.MarketData memory m;
      (a.fixedDeposits, a.fixedBorrows, a.floatingBorrowShares) = market.accounts(account);
      (m.adjustFactor, m.decimals, m.index, m.isListed, m.priceFeed) = auditor.markets(market);
      IRM irm = market.interestRateModel();
      data[i] = MarketAccount({
        // market
        market: market,
        symbol: market.symbol(),
        decimals: m.decimals,
        asset: address(market.asset()),
        assetName: market.asset().name(),
        assetSymbol: market.asset().symbol(),
        isFrozen: market.isFrozen(),
        interestRateModel: InterestRateModel({ id: address(irm), parameters: irm.parameters() }),
        usdPrice: auditor.assetPrice(m.priceFeed).mulWadDown(basePrice),
        penaltyRate: market.penaltyRate(),
        adjustFactor: m.adjustFactor,
        maxFuturePools: market.maxFuturePools(),
        reserveFactor: market.reserveFactor(),
        fixedPools: fixedPools(market),
        rewardRates: rewardRates(market, basePrice),
        floatingBorrowRate: irm.floatingRate(0),
        floatingUtilization: market.floatingAssets() > 0
          ? Math.min(market.floatingDebt().divWadUp(market.floatingAssets()), 1e18)
          : 0,
        floatingAssets: market.floatingAssets(),
        floatingDebt: market.floatingDebt(),
        floatingBackupBorrowed: market.floatingBackupBorrowed(),
        floatingAvailableAssets: floatingAvailableAssets(market),
        totalFloatingBorrowAssets: market.totalFloatingBorrowAssets(),
        totalFloatingDepositAssets: market.totalAssets(),
        totalFloatingBorrowShares: market.totalFloatingBorrowShares(),
        totalFloatingDepositShares: market.totalSupply(),
        // account
        isCollateral: markets & (1 << i) != 0 ? true : false,
        maxBorrowAssets: adjustedCollateral >= adjustedDebt
          ? (adjustedCollateral - adjustedDebt).mulDivUp(10 ** m.decimals, auditor.assetPrice(m.priceFeed)).mulWadUp(
            m.adjustFactor
          )
          : 0,
        floatingBorrowShares: a.floatingBorrowShares,
        floatingBorrowAssets: market.previewRefund(a.floatingBorrowShares),
        floatingDepositShares: market.balanceOf(account),
        floatingDepositAssets: market.maxWithdraw(account),
        fixedDepositPositions: fixedPositions(
          market,
          account,
          a.fixedDeposits,
          market.fixedDepositPositions,
          this.previewWithdrawAtMaturity
        ),
        fixedBorrowPositions: fixedPositions(
          market,
          account,
          a.fixedBorrows,
          market.fixedBorrowPositions,
          this.previewRepayAtMaturity
        ),
        claimableRewards: claimableRewards(market, account)
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
    FixedLib.Pool memory pool;
    (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
    uint256 memFloatingAssetsAverage = previewFloatingAssetsAverage(
      market,
      pool.unassignedEarnings.mulDivDown(block.timestamp - pool.lastAccrual, maturity - pool.lastAccrual)
    );

    return
      FixedPreview({
        maturity: maturity,
        assets: assets + fixedDepositYield(market, maturity, assets),
        utilization: memFloatingAssetsAverage > 0
          ? pool.borrowed.divWadUp(pool.supplied + assets + memFloatingAssetsAverage)
          : 0
      });
  }

  /// @notice Gets the assets plus yield offered by all VALID maturities when depositing a certain amount.
  /// @param market address of the market.
  /// @param assets amount of assets that will be deposited.
  /// @return previews array containing amount plus yield that account will receive after each maturity.
  function previewDepositAtAllMaturities(
    Market market,
    uint256 assets
  ) external view returns (FixedPreview[] memory previews) {
    uint256 maxFuturePools = market.maxFuturePools();
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    previews = new FixedPreview[](maxFuturePools);
    for (uint256 i = 0; i < maxFuturePools; ) {
      previews[i] = previewDepositAtMaturity(market, maturity, assets);
      maturity += FixedLib.INTERVAL;
      unchecked {
        ++i;
      }
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
    (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
    uint256 memFloatingAssetsAverage = previewFloatingAssetsAverage(
      market,
      maturity > pool.lastAccrual
        ? pool.unassignedEarnings.mulDivDown(block.timestamp - pool.lastAccrual, maturity - pool.lastAccrual)
        : pool.unassignedEarnings
    );

    uint256 fees = assets.mulWadUp(
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
  function previewBorrowAtAllMaturities(
    Market market,
    uint256 assets
  ) external view returns (FixedPreview[] memory previews) {
    uint256 maxFuturePools = market.maxFuturePools();
    uint256 maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
    previews = new FixedPreview[](maxFuturePools);
    for (uint256 i = 0; i < maxFuturePools; ) {
      try this.previewBorrowAtMaturity(market, maturity, assets) returns (FixedPreview memory preview) {
        previews[i] = preview;
      } catch {
        previews[i] = FixedPreview({ maturity: maturity, assets: type(uint256).max, utilization: type(uint256).max });
      }
      maturity += FixedLib.INTERVAL;
      unchecked {
        ++i;
      }
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
    uint256 positionAssets,
    address owner
  ) public view returns (FixedPreview memory) {
    (FixedLib.Pool memory pool, uint256 principal, uint256 memFloatingAssetsAverage) = previewData(
      market,
      maturity,
      positionAssets,
      owner,
      false
    );

    return
      FixedPreview({
        maturity: maturity,
        assets: block.timestamp < maturity
          ? positionAssets.divWadDown(
            1e18 +
              market.interestRateModel().fixedBorrowRate(
                maturity,
                positionAssets,
                pool.borrowed,
                pool.supplied,
                memFloatingAssetsAverage
              )
          )
          : positionAssets,
        utilization: memFloatingAssetsAverage > 0
          ? pool.borrowed.divWadUp(pool.supplied + memFloatingAssetsAverage - principal)
          : 0
      });
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
  ) public view returns (FixedPreview memory) {
    (FixedLib.Pool memory pool, uint256 principal, uint256 memFloatingAssetsAverage) = previewData(
      market,
      maturity,
      positionAssets,
      borrower,
      true
    );

    return
      FixedPreview({
        maturity: maturity,
        assets: block.timestamp < maturity
          ? positionAssets - fixedDepositYield(market, maturity, principal)
          : positionAssets + positionAssets.mulWadDown((block.timestamp - maturity) * market.penaltyRate()),
        utilization: memFloatingAssetsAverage > 0
          ? (pool.borrowed > principal ? pool.borrowed - principal : 0).divWadUp(
            pool.supplied + memFloatingAssetsAverage
          )
          : 0
      });
  }

  function previewData(
    Market market,
    uint256 maturity,
    uint256 positionAssets,
    address account,
    bool isRepay
  ) internal view returns (FixedLib.Pool memory pool, uint256, uint256) {
    (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
    FixedLib.Position memory position;
    (position.principal, position.fee) = isRepay
      ? market.fixedBorrowPositions(maturity, account)
      : market.fixedDepositPositions(maturity, account);
    return (
      pool,
      position.scaleProportionally(positionAssets).principal,
      previewFloatingAssetsAverage(
        market,
        maturity > pool.lastAccrual
          ? pool.unassignedEarnings.mulDivDown(block.timestamp - pool.lastAccrual, maturity - pool.lastAccrual)
          : (isRepay ? pool.unassignedEarnings * (block.timestamp - pool.lastAccrual) : pool.unassignedEarnings)
      )
    );
  }

  function fixedPools(Market market) internal view returns (FixedPool[] memory pools) {
    FixedPoolVars memory f;
    f.totalFloatingBorrowAssets = market.totalFloatingBorrowAssets();
    f.freshFloatingDebt = newFloatingDebt(market);
    f.maxFuturePools = market.maxFuturePools();
    pools = new FixedPool[](f.maxFuturePools);
    for (uint256 i = 0; i < f.maxFuturePools; ) {
      f.maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL * (i + 1);
      FixedLib.Pool memory pool;
      (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(f.maturity);
      f.backupEarnings = pool.unassignedEarnings.mulDivDown(
        block.timestamp - pool.lastAccrual,
        f.maturity - pool.lastAccrual
      );
      f.floatingAssetsAverage = previewFloatingAssetsAverage(market, f.backupEarnings);
      f.optimalDeposit = pool.borrowed - Math.min(pool.borrowed, pool.supplied);
      pool.unassignedEarnings -= f.backupEarnings;
      f.liquidity = (market.floatingAssets() + f.freshFloatingDebt).mulWadDown(1e18 - market.reserveFactor());
      f.floatingUtilization = f.floatingAssetsAverage > 0
        ? f.totalFloatingBorrowAssets.divWadUp(f.floatingAssetsAverage)
        : 0;
      f.fixedUtilization = f.floatingAssetsAverage > 0 && pool.borrowed > pool.supplied
        ? (pool.borrowed - pool.supplied).divWadUp(f.floatingAssetsAverage)
        : 0;
      f.globalUtilization = f.floatingAssetsAverage != 0
        ? (f.totalFloatingBorrowAssets + market.floatingBackupBorrowed()).divWadUp(f.floatingAssetsAverage)
        : 0;
      pools[i] = FixedPool({
        maturity: f.maturity,
        borrowed: pool.borrowed,
        supplied: pool.supplied,
        available: Math.min(
          f.liquidity -
            Math.min(f.liquidity, market.floatingBackupBorrowed() + market.floatingDebt() + f.freshFloatingDebt),
          f.floatingAssetsAverage
        ) +
          pool.supplied -
          Math.min(pool.supplied, pool.borrowed),
        utilization: f.fixedUtilization,
        optimalDeposit: f.optimalDeposit,
        depositRate: uint256(365 days).mulDivDown(
          f.optimalDeposit > 0
            ? (pool.unassignedEarnings.mulWadDown(1e18 - market.backupFeeRate())).divWadDown(f.optimalDeposit)
            : 0,
          f.maturity - block.timestamp
        ),
        minBorrowRate: market.interestRateModel().fixedRate(
          f.maturity,
          f.maxFuturePools,
          f.fixedUtilization,
          f.floatingUtilization,
          f.globalUtilization
        )
      });
      unchecked {
        ++i;
      }
    }
  }

  function rewardRates(Market market, uint256 basePrice) internal view returns (RewardRate[] memory rewards) {
    RewardsVars memory r;
    r.controller = market.rewardsController();
    if (address(r.controller) != address(0)) {
      (, r.underlyingDecimals, , , r.underlyingPriceFeed) = auditor.markets(market);
      unchecked {
        r.underlyingBaseUnit = 10 ** r.underlyingDecimals;
      }
      r.deltaTime = 1 hours;
      r.rewardList = r.controller.allRewards();
      rewards = new RewardRate[](r.rewardList.length);
      {
        uint256 index;
        for (r.i = 0; r.i < r.rewardList.length; ++r.i) {
          (r.start, , ) = r.controller.distributionTime(market, r.rewardList[r.i]);
          if (r.start == 0) continue;
          rewards[index++].asset = r.rewardList[r.i];
        }
        RewardRate[] memory rewardList = rewards;
        rewards = new RewardRate[](index);
        for (r.i = 0; r.i < rewards.length; ++r.i) rewards[r.i] = rewardList[r.i];
      }
      for (r.i = 0; r.i < rewards.length; ++r.i) {
        r.config = r.controller.rewardConfig(market, rewards[r.i].asset);
        r.rewardPrice = auditor.assetPrice(r.config.priceFeed);
        (r.borrowIndex, r.depositIndex, ) = r.controller.rewardIndexes(market, rewards[r.i].asset);
        (r.start, , ) = r.controller.distributionTime(market, rewards[r.i].asset);
        (r.projectedBorrowIndex, r.projectedDepositIndex, ) = r.controller.previewAllocation(
          market,
          rewards[r.i].asset,
          block.timestamp > r.config.start ? r.deltaTime : 0
        );
        r.firstMaturity = r.start - (r.start % FixedLib.INTERVAL) + FixedLib.INTERVAL;
        r.maxMaturity =
          block.timestamp -
          (block.timestamp % FixedLib.INTERVAL) +
          (FixedLib.INTERVAL * market.maxFuturePools());
        r.maturities = new uint256[]((r.maxMaturity - r.firstMaturity) / FixedLib.INTERVAL + 1);
        r.maturity = r.firstMaturity;
        for (uint256 i = 0; r.maturity <= r.maxMaturity; ++i) {
          (uint256 borrowed, ) = market.fixedPoolBalance(r.maturity);
          r.fixedDebt += borrowed;
          r.maturities[i] = r.maturity;
          unchecked {
            r.maturity += FixedLib.INTERVAL;
          }
        }
        rewards[r.i] = RewardRate({
          asset: rewards[r.i].asset,
          assetName: rewards[r.i].asset.name(),
          assetSymbol: rewards[r.i].asset.symbol(),
          usdPrice: r.rewardPrice.mulWadDown(basePrice),
          borrow: (market.totalFloatingBorrowAssets() + r.fixedDebt) > 0
            ? (r.projectedBorrowIndex - r.borrowIndex)
              .mulDivDown(market.totalFloatingBorrowShares() + market.previewRepay(r.fixedDebt), r.underlyingBaseUnit)
              .mulWadDown(r.rewardPrice)
              .mulDivDown(
                r.underlyingBaseUnit,
                (market.totalFloatingBorrowAssets() + r.fixedDebt).mulWadDown(auditor.assetPrice(r.underlyingPriceFeed))
              )
              .mulDivDown(365 days, r.deltaTime)
            : 0,
          floatingDeposit: market.totalAssets() > 0
            ? (r.projectedDepositIndex - r.depositIndex)
              .mulDivDown(market.totalSupply(), r.underlyingBaseUnit)
              .mulWadDown(r.rewardPrice)
              .mulDivDown(
                r.underlyingBaseUnit,
                market.totalAssets().mulWadDown(auditor.assetPrice(r.underlyingPriceFeed))
              )
              .mulDivDown(365 days, r.deltaTime)
            : 0,
          maturities: r.maturities
        });
      }
    }
  }

  function claimableRewards(Market market, address account) internal view returns (ClaimableReward[] memory rewards) {
    RewardsController rewardsController = market.rewardsController();
    if (address(rewardsController) != address(0)) {
      ERC20[] memory rewardList = rewardsController.allRewards();

      rewards = new ClaimableReward[](rewardList.length);
      RewardsController.MarketOperation[] memory marketOps = new RewardsController.MarketOperation[](1);
      bool[] memory ops = new bool[](2);
      ops[0] = true;
      ops[1] = false;
      marketOps[0] = RewardsController.MarketOperation({ market: market, operations: ops });

      for (uint256 i = 0; i < rewardList.length; ) {
        (uint32 start, , ) = rewardsController.distributionTime(market, rewardList[i]);
        if (start != 0) {
          rewards[i] = ClaimableReward({
            asset: address(rewardList[i]),
            assetName: rewardList[i].name(),
            assetSymbol: rewardList[i].symbol(),
            amount: rewardsController.claimable(marketOps, account, rewardList[i])
          });
        }
        unchecked {
          ++i;
        }
      }
    }
  }

  function previewFloatingAssetsAverage(Market market, uint256 backupEarnings) internal view returns (uint256) {
    uint256 memFloatingAssets = market.floatingAssets() + backupEarnings;
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

  function floatingAvailableAssets(Market market) internal view returns (uint256) {
    uint256 freshFloatingDebt = newFloatingDebt(market);
    uint256 maxAssets = (market.floatingAssets() + freshFloatingDebt).mulWadDown(1e18 - market.reserveFactor());
    return maxAssets - Math.min(maxAssets, market.floatingBackupBorrowed() + market.floatingDebt() + freshFloatingDebt);
  }

  function fixedPositions(
    Market market,
    address account,
    uint256 packedMaturities,
    function(uint256, address) external view returns (uint256, uint256) getPosition,
    function(Market, uint256, uint256, address) external view returns (FixedPreview memory) previewValue
  ) internal view returns (FixedPosition[] memory userMaturityPositions) {
    uint256 userMaturityCount = 0;
    FixedPosition[] memory allMaturityPositions = new FixedPosition[](224);
    uint256 maturity = packedMaturities & ((1 << 32) - 1);
    packedMaturities = packedMaturities >> 32;
    while (packedMaturities != 0) {
      if (packedMaturities & 1 != 0) {
        uint256 positionAssets;
        {
          (uint256 principal, uint256 fee) = getPosition(maturity, account);
          positionAssets = principal + fee;
          allMaturityPositions[userMaturityCount].position = FixedLib.Position(principal, fee);
        }
        try previewValue(market, maturity, positionAssets, account) returns (FixedPreview memory fixedPreview) {
          allMaturityPositions[userMaturityCount].previewValue = fixedPreview.assets;
        } catch {
          allMaturityPositions[userMaturityCount].previewValue = positionAssets;
        }
        allMaturityPositions[userMaturityCount].maturity = maturity;
        ++userMaturityCount;
      }
      packedMaturities >>= 1;
      maturity += FixedLib.INTERVAL;
    }

    userMaturityPositions = new FixedPosition[](userMaturityCount);
    for (uint256 i = 0; i < userMaturityCount; ) {
      userMaturityPositions[i] = allMaturityPositions[i];
      unchecked {
        ++i;
      }
    }
  }

  function fixedDepositYield(Market market, uint256 maturity, uint256 assets) internal view returns (uint256 yield) {
    FixedLib.Pool memory pool;
    (pool.borrowed, pool.supplied, pool.unassignedEarnings, pool.lastAccrual) = market.fixedPools(maturity);
    if (maturity > pool.lastAccrual) {
      pool.unassignedEarnings -= pool.unassignedEarnings.mulDivDown(
        block.timestamp - pool.lastAccrual,
        maturity - pool.lastAccrual
      );
    }
    (yield, ) = pool.calculateDeposit(assets, market.backupFeeRate());
  }

  function newFloatingDebt(Market market) internal view returns (uint256) {
    return
      market.floatingDebt().mulWadDown(
        market.interestRateModel().floatingRate(0).mulDivDown(
          block.timestamp - market.lastFloatingDebtUpdate(),
          365 days
        )
      );
  }

  struct RewardsVars {
    RewardsController controller;
    uint256 lastUpdate;
    uint256 depositIndex;
    uint256 borrowIndex;
    uint256 projectedDepositIndex;
    uint256 projectedBorrowIndex;
    uint256 underlyingBaseUnit;
    uint256[] maturities;
    IPriceFeed underlyingPriceFeed;
    RewardsController.Config config;
    ERC20[] rewardList;
    uint256 underlyingDecimals;
    uint256 deltaTime;
    uint256 i;
    uint256 start;
    uint256 maturity;
    uint256 fixedDebt;
    uint256 rewardPrice;
    uint256 maxMaturity;
    uint256 firstMaturity;
  }

  struct FixedPoolVars {
    uint256 floatingAssetsAverage;
    uint256 freshFloatingDebt;
    uint256 optimalDeposit;
    uint256 backupEarnings;
    uint256 maxFuturePools;
    uint256 liquidity;
    uint256 maturity;
    uint256 floatingUtilization;
    uint256 fixedUtilization;
    uint256 globalUtilization;
    uint256 totalFloatingBorrowAssets;
  }
}

error InvalidRewardsLength();
