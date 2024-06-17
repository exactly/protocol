// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable-v4/utils/math/MathUpgradeable.sol";
import { Previewer, IPriceFeed, FixedLib } from "./Previewer.sol";
import { ERC20, Market, Auditor, DebtManager } from "./DebtManager.sol";

/// @title DebtPreviewer
/// @notice Contract to be consumed by Exactly's front-end dApp as a helper for `DebtManager`.
contract DebtPreviewer {
  using FixedPointMathLib for uint256;

  /// @notice DebtManager contract to be used to get Auditor and BalancerVault addresses.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  DebtManager public immutable debtManager;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(DebtManager debtManager_) {
    debtManager = debtManager_;
  }

  /// @notice Returns extended data useful to leverage or deleverage an account principal position.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account operating with the `DebtManager`.
  /// @param minHealthFactor The minimum health factor that the account must have after the leverage.
  /// @return extended leverage data.
  function leverage(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    uint256 minHealthFactor
  ) external view returns (Leverage memory) {
    assert(marketDeposit == marketBorrow);
    (, , uint256 floatingBorrowShares) = marketBorrow.accounts(account);
    uint256 deposit = marketDeposit.maxWithdraw(account);
    uint256 memMinDeposit = minDeposit(marketDeposit, marketBorrow, account, minHealthFactor);
    int256 principal = crossPrincipal(marketDeposit, marketBorrow, account);
    uint256 ratio = principal > 0 ? deposit.divWadDown(uint256(principal)) : 0;

    return
      Leverage({
        borrow: marketBorrow.previewRefund(floatingBorrowShares),
        deposit: deposit,
        principal: principal,
        ratio: ratio,
        maxRatio: maxRatio(marketDeposit, marketBorrow, account, principal, minHealthFactor),
        minDeposit: deposit >= memMinDeposit ? 0 : memMinDeposit - deposit,
        maxWithdraw: maxWithdraw(marketDeposit, marketBorrow, account, ratio, minHealthFactor),
        availableAssets: balancerAvailableLiquidity()
      });
  }

  /// @notice Returns minimum deposit based on account's current debt and a given health factor.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account operating with the markets.
  /// @param minHealthFactor The health factor that the account must have with the minimum deposit, isolated.
  function minDeposit(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    uint256 minHealthFactor
  ) internal view returns (uint256) {
    MinDepositVars memory vars;
    Auditor auditor = debtManager.auditor();
    (vars.adjustFactorIn, vars.decimalsIn, , , vars.priceFeedIn) = auditor.markets(marketDeposit);
    (vars.adjustFactorOut, vars.decimalsOut, , , vars.priceFeedOut) = auditor.markets(marketBorrow);

    return
      minHealthFactor
        .mulWadDown(floatingBorrowAssets(marketBorrow, account))
        .mulDivDown(auditor.assetPrice(vars.priceFeedOut), 10 ** vars.decimalsOut)
        .divWadDown(vars.adjustFactorOut.mulWadDown(vars.adjustFactorIn))
        .mulDivUp(10 ** vars.decimalsIn, auditor.assetPrice(vars.priceFeedIn));
  }

  /// @notice Returns the maximum ratio that an account can leverage its principal plus `assets` amount.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account that will be leveraged.
  /// @param deposit The amount of assets that will be added to the principal.
  /// @param ratio The ratio to be previewed.
  /// @param minHealthFactor The minimum health factor that the account must have after the leverage.
  function previewLeverage(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    uint256 deposit,
    uint256 ratio,
    uint256 minHealthFactor
  ) external view returns (Limit memory limit) {
    assert(marketDeposit == marketBorrow);
    uint256 currentRatio;
    (limit.principal, currentRatio, limit.maxRatio) = previewRatio(
      marketDeposit,
      marketBorrow,
      account,
      int256(deposit),
      minHealthFactor
    );

    limit.ratio = (ratio < currentRatio || ratio > limit.maxRatio) ? currentRatio : ratio;
    if (limit.principal <= 0) {
      limit.borrow = floatingBorrowAssets(marketBorrow, account);
      limit.deposit = marketDeposit.maxWithdraw(account) + deposit;
      return limit;
    }
    limit.deposit = uint256(limit.principal).mulWadUp(limit.ratio);

    limit.maxWithdraw = maxWithdraw(marketDeposit, marketBorrow, account, ratio, minHealthFactor);

    limit.borrow = uint256(limit.principal).mulWadDown(limit.ratio - 1e18);
  }

  /// @notice Returns the maximum ratio that an account can deleverage its principal minus `assets` amount.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account that will be deleveraged.
  /// @param withdraw The amount of assets that will be withdrawn from the principal.
  /// @param ratio The ratio to be previewed.
  /// @param minHealthFactor The minimum health factor that the account must have after the leverage.
  function previewDeleverage(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    uint256 withdraw,
    uint256 ratio,
    uint256 minHealthFactor
  ) external view returns (Limit memory limit) {
    assert(marketDeposit == marketBorrow);
    if ((limit.principal = crossPrincipal(marketDeposit, marketBorrow, account)) < 0) revert InvalidPreview();
    uint256 memMaxWithdraw = maxWithdraw(marketDeposit, marketBorrow, account, ratio, minHealthFactor);
    if (withdraw <= uint256(limit.principal)) {
      limit.principal -= int256(withdraw);
      limit.maxRatio = maxRatio(marketDeposit, marketBorrow, account, limit.principal, minHealthFactor);
    } else if (withdraw <= memMaxWithdraw) {
      limit.principal = int256(memMaxWithdraw - withdraw);
      limit.maxRatio = limit.principal > 0
        ? maxRatio(marketDeposit, marketBorrow, account, limit.principal, minHealthFactor)
        : 1e18;
    } else revert InvalidPreview();

    limit.ratio = ratio > limit.maxRatio ? limit.maxRatio : ratio;
    limit.maxWithdraw = memMaxWithdraw;

    uint256 borrowRepay = floatingBorrowAssets(marketBorrow, account) -
      previewAssetsOut(marketDeposit, marketBorrow, uint256(limit.principal).mulWadDown(limit.ratio - 1e18));

    limit.borrow = floatingBorrowAssets(marketBorrow, account) - borrowRepay;
    limit.deposit = marketDeposit.maxWithdraw(account) - withdraw - borrowRepay;
  }

  /// @notice Returns principal, current ratio and max ratio, considering assets to add or substract.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account to preview the ratio.
  /// @param assets The amount of assets that will be added or subtracted to the principal.
  /// @param minHealthFactor The minimum health factor that the account should have with the max ratio.
  function previewRatio(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    int256 assets,
    uint256 minHealthFactor
  ) internal view returns (int256 principal, uint256 current, uint256 max) {
    principal = crossPrincipal(marketDeposit, marketBorrow, account) + assets;
    max = maxRatio(marketDeposit, marketBorrow, account, principal, minHealthFactor);
    if (principal > 0) {
      current = uint256(int256(marketDeposit.maxWithdraw(account)) + assets).divWadUp(uint256(principal));
    }
  }

  /// @notice Returns the amount of `marketBorrow` underlying assets considering `amountIn` and assets oracle prices.
  /// @param marketDeposit The market of the assets accounted as `amountIn`.
  /// @param marketBorrow The market of the assets that will be returned.
  /// @param amountIn The amount of `marketDeposit` underlying assets.
  function previewAssetsOut(
    Market marketDeposit,
    Market marketBorrow,
    uint256 amountIn
  ) internal view returns (uint256) {
    Auditor auditor = debtManager.auditor();
    (, uint256 decimalsOut, , , IPriceFeed priceFeedOut) = auditor.markets(marketBorrow);
    (, uint256 decimalsIn, , , IPriceFeed priceFeedIn) = auditor.markets(marketDeposit);
    return
      amountIn.mulDivDown(auditor.assetPrice(priceFeedIn), 10 ** decimalsIn).mulDivDown(
        10 ** decimalsOut,
        auditor.assetPrice(priceFeedOut)
      );
  }

  /// @notice Returns the maximum ratio that an account can leverage its principal position.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account that will be leveraged.
  /// @param principal The updated principal of the account.
  /// @param minHealthFactor The minimum health factor that the account must have after the leverage.
  function maxRatio(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    int256 principal,
    uint256 minHealthFactor
  ) internal view returns (uint256) {
    Auditor auditor = debtManager.auditor();
    MaxRatioVars memory mr;
    (mr.adjustFactorIn, , , , mr.priceFeedIn) = auditor.markets(marketDeposit);
    (mr.adjustFactorOut, , , , ) = auditor.markets(marketBorrow);
    uint256 isolatedMaxRatio = minHealthFactor.divWadDown(
      minHealthFactor - mr.adjustFactorIn.mulWadDown(mr.adjustFactorOut)
    );
    if (principal <= 0) return isolatedMaxRatio;

    mr.marketMap = auditor.accountMarkets(account);
    mr.principalUSD = uint256(principal).mulDivDown(auditor.assetPrice(mr.priceFeedIn), 10 ** marketDeposit.decimals());
    for (mr.i = 0; mr.marketMap != 0; mr.marketMap >>= 1) {
      if (mr.marketMap & 1 != 0) {
        Auditor.MarketData memory md;
        Auditor.AccountLiquidity memory vars;
        mr.market = auditor.marketList(mr.i);
        (md.adjustFactor, md.decimals, , , md.priceFeed) = auditor.markets(mr.market);
        (vars.balance, vars.borrowBalance) = mr.market.accountSnapshot(account);
        vars.price = auditor.assetPrice(md.priceFeed);
        mr.baseUnit = 10 ** md.decimals;

        if (mr.market == marketBorrow) {
          mr.adjustedDebt += (vars.borrowBalance - floatingBorrowAssets(marketBorrow, account))
            .mulDivDown(vars.price, mr.baseUnit)
            .divWadUp(md.adjustFactor);
        } else {
          mr.adjustedDebt += vars.borrowBalance.mulDivUp(vars.price, mr.baseUnit).divWadUp(md.adjustFactor);
        }
        if (mr.market != marketDeposit) {
          mr.adjustedCollateral += vars.balance.mulDivDown(vars.price, mr.baseUnit).mulWadDown(md.adjustFactor);
        }
      }
      unchecked {
        ++mr.i;
      }
    }

    return
      Math.min(
        (mr.adjustedCollateral.mulWadDown(mr.adjustFactorOut) +
          minHealthFactor.mulWadDown(mr.principalUSD) -
          minHealthFactor.mulWadDown(mr.adjustedDebt.mulWadDown(mr.adjustFactorOut))).divWadDown(
            mr.principalUSD.mulWadDown(minHealthFactor - mr.adjustFactorIn.mulWadDown(mr.adjustFactorOut))
          ),
        isolatedMaxRatio
      );
  }

  function floatingBorrowAssets(Market market, address account) internal view returns (uint256) {
    (, , uint256 floatingBorrowShares) = market.accounts(account);
    return market.previewRefund(floatingBorrowShares);
  }

  /// @notice Returns the maximum amount that an account can withdraw from `marketDeposit` when leveraged.
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account to preview.
  /// @param ratio The ratio that the account is willing to deleverage to be able to withdraw more assets.
  /// @param minHealthFactor The minimum health factor that the account should have when withdrawing maxWithdraw.
  function maxWithdraw(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    uint256 ratio,
    uint256 minHealthFactor
  ) internal view returns (uint256) {
    MaxWithdrawVars memory mw;
    mw.principal = crossPrincipal(marketDeposit, marketBorrow, account);
    if (mw.principal <= 0) return 0;

    mw.auditor = debtManager.auditor();
    Auditor.MarketData memory md;
    Auditor.AccountLiquidity memory vars;
    mw.marketMap = mw.auditor.accountMarkets(account);
    mw.borrowAssets = floatingBorrowAssets(marketBorrow, account);
    for (mw.i = 0; mw.marketMap != 0; mw.marketMap >>= 1) {
      if (mw.marketMap & 1 != 0) {
        mw.market = mw.auditor.marketList(mw.i);
        (md.adjustFactor, md.decimals, , , md.priceFeed) = mw.auditor.markets(mw.market);
        uint256 baseUnit = 10 ** md.decimals;
        (vars.balance, vars.borrowBalance) = mw.market.accountSnapshot(account);
        vars.price = mw.auditor.assetPrice(md.priceFeed);
        {
          mw.memAdjColl = vars.balance.mulDivDown(vars.price, baseUnit).mulWadDown(md.adjustFactor);
          mw.memAdjDebt = vars.borrowBalance.mulDivDown(vars.price, baseUnit).divWadDown(md.adjustFactor);
          mw.adjustedCollateral += mw.memAdjColl;

          mw.adjustedDebt += mw.memAdjDebt;
          mw.otherDebt += mw.memAdjDebt;
          if (mw.market == marketBorrow) {
            mw.adjustedRepay = mw.borrowAssets.mulDivDown(vars.price, baseUnit).divWadDown(md.adjustFactor);
            mw.otherDebt -= mw.adjustedRepay;
          }
          if (marketDeposit != mw.market) {
            mw.otherCollateral += mw.memAdjColl;
          } else {
            mw.adjPrincipalForRepay = mw.borrowAssets.mulDivDown(vars.price, baseUnit).mulWadDown(md.adjustFactor);
            mw.adjustedPrincipal =
              (mw.market.maxWithdraw(account)).mulDivDown(vars.price, baseUnit).mulWadDown(md.adjustFactor) -
              mw.adjPrincipalForRepay;
          }
        }
      }
      unchecked {
        ++mw.i;
      }
    }
    {
      (mw.adjustFactorIn, , , , mw.priceFeedIn) = mw.auditor.markets(marketDeposit);
      (mw.adjustFactorOut, , , , ) = mw.auditor.markets(marketBorrow);
      mw.memOtherDebt = mw.otherDebt.mulWadDown(mw.adjustFactorOut).mulWadDown(minHealthFactor);
      mw.memOtherCollateral = (mw.otherCollateral).mulWadDown(mw.adjustFactorOut);
    }

    if (mw.memOtherDebt <= mw.memOtherCollateral) {
      return
        Math.min(
          Math
            .min(
              mw.adjustedCollateral + mw.adjustedRepay - mw.adjustedDebt - mw.adjPrincipalForRepay,
              mw.adjustedPrincipal
            )
            .mulDivDown(10 ** marketDeposit.decimals(), mw.auditor.assetPrice(mw.priceFeedIn))
            .divWadDown(mw.adjustFactorIn),
          uint256(mw.principal)
        );
    }

    return
      uint256(mw.principal) -
      (mw.memOtherDebt - mw.memOtherCollateral)
        .divWadDown(
          mw.adjustFactorIn.mulWadDown(ratio).mulWadDown(mw.adjustFactorOut) +
            minHealthFactor -
            ratio.mulWadDown(minHealthFactor)
        )
        .mulDivDown(10 ** marketDeposit.decimals(), mw.auditor.assetPrice(mw.priceFeedIn));
  }

  /// @notice Calculates the crossed principal amount for a given `account` in the input and output markets.
  /// @param marketDeposit The Market to withdraw the leveraged position.
  /// @param marketBorrow The Market to repay the leveraged position.
  /// @param account The account that will be deleveraged.
  function crossPrincipal(Market marketDeposit, Market marketBorrow, address account) internal view returns (int256) {
    uint256 decimalsIn;
    uint256 decimalsOut;
    IPriceFeed priceFeedIn;
    IPriceFeed priceFeedOut;
    Auditor auditor = debtManager.auditor();
    (, decimalsIn, , , priceFeedIn) = auditor.markets(marketDeposit);
    (, decimalsOut, , , priceFeedOut) = auditor.markets(marketBorrow);

    return
      int256(marketDeposit.maxWithdraw(account)) -
      int256(
        floatingBorrowAssets(marketBorrow, account)
          .mulDivDown(auditor.assetPrice(priceFeedOut), 10 ** decimalsOut)
          .mulDivDown(10 ** decimalsIn, auditor.assetPrice(priceFeedIn))
      );
  }

  /// @notice Returns Balancer Vault's available liquidity of each enabled underlying asset.
  function balancerAvailableLiquidity() internal view returns (AvailableAsset[] memory availableAssets) {
    Auditor auditor = debtManager.auditor();
    uint256 marketsCount = auditor.allMarkets().length;
    address balancerVault = address(debtManager.balancerVault());
    availableAssets = new AvailableAsset[](marketsCount);

    for (uint256 i = 0; i < marketsCount; ) {
      ERC20 asset = auditor.marketList(i).asset();
      availableAssets[i] = AvailableAsset({ asset: asset, liquidity: asset.balanceOf(balancerVault) });
      unchecked {
        ++i;
      }
    }
  }

  /// @notice returns rates based on inputs and leverage ratio impact on the borrow market
  /// @param marketDeposit The deposit Market.
  /// @param marketBorrow The borrow Market.
  /// @param account The account to preview.
  /// @param assets The amount of assets that should be added or substracted to the principal.
  /// @param targetRatio The target ratio to preview.
  /// @param depositRate The current deposit rate of the deposit market.
  /// @param nativeRate The current native rate of the deposit market.
  /// @param nativeRateBorrow The current native rate of the borrow market.
  function leverageRates(
    Market marketDeposit,
    Market marketBorrow,
    address account,
    int256 assets,
    uint256 targetRatio,
    uint256 depositRate,
    uint256 nativeRate,
    uint256 nativeRateBorrow
  ) external view returns (Rates memory rates) {
    RateVars memory vars;
    (vars.principal, vars.ratio, ) = previewRatio(marketDeposit, marketBorrow, account, assets, 1e18);
    vars.sameMarket = marketDeposit == marketBorrow;

    if (vars.principal <= 0) {
      vars.utilization = marketBorrow.totalFloatingBorrowAssets().divWadUp(marketBorrow.totalAssets());
    } else if (targetRatio < vars.ratio) {
      vars.diff = uint256(vars.principal).mulWadDown(vars.ratio - targetRatio);
      vars.utilization = (marketBorrow.totalFloatingBorrowAssets() -
        previewAssetsOut(marketDeposit, marketBorrow, vars.diff)).divWadUp(
          marketBorrow.totalAssets() - (vars.sameMarket ? vars.diff : 0)
        );
    } else {
      vars.diff = uint256(vars.principal).mulWadDown(targetRatio - vars.ratio);
      vars.utilization = (marketBorrow.totalFloatingBorrowAssets() +
        previewAssetsOut(marketDeposit, marketBorrow, vars.diff)).divWadUp(
          marketBorrow.totalAssets() + (vars.sameMarket ? vars.diff : 0)
        );
    }

    rates.borrow = marketBorrow.interestRateModel().floatingRate(vars.utilization).mulWadDown(targetRatio - 1e18);
    rates.deposit = depositRate.mulWadDown(targetRatio);
    rates.native = int256(nativeRate.mulWadDown(targetRatio)) - int256(nativeRateBorrow.mulWadDown(targetRatio - 1e18));
    rates.rewards = calculateRewards(
      rewardRates(marketDeposit),
      vars.sameMarket ? new RewardRate[](0) : rewardRates(marketBorrow),
      vars.sameMarket,
      targetRatio
    );
  }

  function calculateRewards(
    RewardRate[] memory depositRewards,
    RewardRate[] memory borrowRewards,
    bool sameMarket,
    uint256 targetRatio
  ) internal pure returns (RewardRate[] memory result) {
    result = new RewardRate[](depositRewards.length + borrowRewards.length);
    uint256 i;
    for (; i < depositRewards.length; ) {
      result[i].deposit = depositRewards[i].deposit.mulWadDown(targetRatio);
      if (sameMarket) {
        result[i].borrow = depositRewards[i].borrow.mulWadDown(targetRatio - 1e18);
      }
      result[i].asset = depositRewards[i].asset;
      result[i].assetName = depositRewards[i].assetName;
      result[i].assetSymbol = depositRewards[i].assetSymbol;
      unchecked {
        ++i;
      }
    }
    if (!sameMarket) {
      for (i = 0; i < borrowRewards.length; ) {
        result[i + depositRewards.length].borrow = borrowRewards[i].borrow.mulWadDown(targetRatio - 1e18);
        result[i + depositRewards.length].asset = borrowRewards[i].asset;
        result[i + depositRewards.length].assetName = borrowRewards[i].assetName;
        result[i + depositRewards.length].assetSymbol = borrowRewards[i].assetSymbol;
        unchecked {
          ++i;
        }
      }
    }
  }

  function rewardRates(Market market) internal view returns (RewardRate[] memory rewards) {
    Previewer.RewardsVars memory r;
    r.controller = market.rewardsController();
    Auditor auditor = debtManager.auditor();
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
      for (r.i = 0; r.i < rewards.length; ) {
        r.config = r.controller.rewardConfig(market, rewards[r.i].asset);
        (r.borrowIndex, r.depositIndex, ) = r.controller.rewardIndexes(market, rewards[r.i].asset);
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
        r.start = 0;
        for (r.maturity = r.firstMaturity; r.maturity <= r.maxMaturity; ) {
          (uint256 borrowed, ) = market.fixedPoolBalance(r.maturity);
          r.fixedDebt += borrowed;
          r.maturities[r.start] = r.maturity;
          unchecked {
            r.maturity += FixedLib.INTERVAL;
            ++r.start;
          }
        }
        rewards[r.i] = RewardRate({
          asset: rewards[r.i].asset,
          assetName: rewards[r.i].asset.name(),
          assetSymbol: rewards[r.i].asset.symbol(),
          borrow: (market.totalFloatingBorrowAssets() + r.fixedDebt) > 0
            ? (r.projectedBorrowIndex - r.borrowIndex)
              .mulDivDown(market.totalFloatingBorrowShares() + market.previewRepay(r.fixedDebt), r.underlyingBaseUnit)
              .mulWadDown(auditor.assetPrice(r.config.priceFeed))
              .mulDivDown(
                r.underlyingBaseUnit,
                (market.totalFloatingBorrowAssets() + r.fixedDebt).mulWadDown(auditor.assetPrice(r.underlyingPriceFeed))
              )
              .mulDivDown(365 days, r.deltaTime)
            : 0,
          deposit: market.totalAssets() > 0
            ? (r.projectedDepositIndex - r.depositIndex)
              .mulDivDown(market.totalSupply(), r.underlyingBaseUnit)
              .mulWadDown(auditor.assetPrice(r.config.priceFeed))
              .mulDivDown(
                r.underlyingBaseUnit,
                market.totalAssets().mulWadDown(auditor.assetPrice(r.underlyingPriceFeed))
              )
              .mulDivDown(365 days, r.deltaTime)
            : 0
        });
        unchecked {
          ++r.i;
        }
      }
    }
  }
}

error InvalidPreview();

struct Leverage {
  uint256 ratio;
  uint256 borrow;
  uint256 deposit;
  int256 principal;
  uint256 maxRatio;
  uint256 minDeposit;
  uint256 maxWithdraw;
  AvailableAsset[] availableAssets;
}

struct AvailableAsset {
  ERC20 asset;
  uint256 liquidity;
}

struct Pool {
  address tokenA;
  address tokenB;
}

struct Limit {
  uint256 ratio;
  uint256 borrow;
  uint256 deposit;
  int256 principal;
  uint256 maxRatio;
  uint256 maxWithdraw;
}

struct MaxRatioVars {
  uint256 i;
  uint256 baseUnit;
  uint256 marketMap;
  uint256 principalUSD;
  uint256 adjustedDebt;
  uint256 adjustFactorIn;
  uint256 adjustFactorOut;
  uint256 adjustedCollateral;
  IPriceFeed priceFeedIn;
  Market market;
}

struct MaxWithdrawVars {
  uint256 i;
  int256 principal;
  uint256 marketMap;
  uint256 otherDebt;
  uint256 memAdjDebt;
  uint256 memAdjColl;
  uint256 memOtherDebt;
  uint256 adjustedDebt;
  uint256 borrowAssets;
  uint256 adjustedRepay;
  uint256 adjustFactorIn;
  uint256 adjustFactorOut;
  uint256 otherCollateral;
  uint256 adjustedPrincipal;
  uint256 memOtherCollateral;
  uint256 adjustedCollateral;
  uint256 adjPrincipalForRepay;
  IPriceFeed priceFeedIn;
  Auditor auditor;
  Market market;
}

struct MinDepositVars {
  uint256 decimalsIn;
  uint256 decimalsOut;
  uint256 adjustFactorIn;
  IPriceFeed priceFeedIn;
  uint256 adjustFactorOut;
  IPriceFeed priceFeedOut;
}

struct Rates {
  int256 native;
  uint256 borrow;
  uint256 deposit;
  RewardRate[] rewards;
}

struct RewardRate {
  ERC20 asset;
  string assetName;
  string assetSymbol;
  uint256 borrow;
  uint256 deposit;
}

struct RateVars {
  uint256 diff;
  uint256 ratio;
  bool sameMarket;
  int256 principal;
  uint256 utilization;
}
