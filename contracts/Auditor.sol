// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Initializable } from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable-v4/utils/math/MathUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/access/AccessControlUpgradeable.sol";
import { IPriceFeed } from "./utils/IPriceFeed.sol";
import { Market } from "./Market.sol";

contract Auditor is Initializable, AccessControlUpgradeable {
  using FixedPointMathLib for uint256;

  /// @notice Address that a market should have as price feed to consider as base price and avoid external price call.
  address public constant BASE_FEED = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  /// @notice Target health factor that the account should have after it's liquidated to prevent cascade liquidations.
  uint256 public constant TARGET_HEALTH = 1.25e18;
  /// @notice Maximum value the liquidator can send and still have granular control of max assets.
  /// Above this threshold, they should send `type(uint256).max`.
  uint256 public constant ASSETS_THRESHOLD = type(uint256).max / 1e18;

  /// @notice Decimals that the answer of all price feeds should have.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  uint256 public immutable priceDecimals;
  /// @notice Base factor to scale the price returned by the feed to 18 decimals.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  uint256 internal immutable baseFactor;
  /// @notice Base price used if the feed to fetch the price from is `BASE_FEED`.
  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  uint256 internal immutable basePrice;

  /// @notice Tracks the markets' indexes that an account has entered as collateral.
  mapping(address => uint256) public accountMarkets;
  /// @notice Stores market parameters per each enabled market.
  mapping(Market => MarketData) public markets;
  /// @notice Array of all enabled markets.
  Market[] public marketList;

  /// @notice Liquidation incentive factors for the liquidator and the lenders of the market where the debt is repaid.
  LiquidationIncentive public liquidationIncentive;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(uint256 priceDecimals_) {
    priceDecimals = priceDecimals_;
    baseFactor = 10 ** (18 - priceDecimals_);
    basePrice = 10 ** priceDecimals_;

    _disableInitializers();
  }

  /// @notice Initializes the contract.
  /// @dev can only be called once.
  function initialize(LiquidationIncentive memory liquidationIncentive_) external initializer {
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setLiquidationIncentive(liquidationIncentive_);
  }

  /// @notice Allows assets of a certain market to be used as collateral for borrowing other assets.
  /// @param market market to enabled as collateral.
  function enterMarket(Market market) external {
    MarketData storage m = markets[market];
    if (!m.isListed) revert MarketNotListed();

    uint256 marketMap = accountMarkets[msg.sender];
    uint256 marketMask = 1 << m.index;

    if ((marketMap & marketMask) != 0) return;
    accountMarkets[msg.sender] = marketMap | marketMask;

    emit MarketEntered(market, msg.sender);
  }

  /// @notice Removes market from sender's account liquidity calculation.
  /// @dev Sender must not have an outstanding borrow balance in the asset, or be providing necessary collateral
  /// for an outstanding borrow.
  /// @param market market to be disabled as collateral.
  function exitMarket(Market market) external {
    MarketData storage m = markets[market];
    if (!m.isListed) revert MarketNotListed();

    (uint256 assets, uint256 debt) = market.accountSnapshot(msg.sender);

    // fail if the sender has a borrow balance
    if (debt != 0) revert RemainingDebt();

    // fail if the sender is not permitted to redeem all of their assets
    checkShortfall(market, msg.sender, assets);

    uint256 marketMap = accountMarkets[msg.sender];
    uint256 marketMask = 1 << m.index;

    if ((marketMap & marketMask) == 0) return;
    accountMarkets[msg.sender] = marketMap & ~marketMask;

    emit MarketExited(market, msg.sender);
  }

  /// @notice Returns account's liquidity calculation.
  /// @param account account in which the liquidity will be calculated.
  /// @param marketToSimulate market in which to simulate withdraw operation.
  /// @param withdrawAmount amount to simulate as withdraw.
  /// @return sumCollateral sum of all collateral, already multiplied by each adjust factor (denominated in base).
  /// @return sumDebtPlusEffects sum of all debt divided by adjust factor considering withdrawal (denominated in base).
  function accountLiquidity(
    address account,
    Market marketToSimulate,
    uint256 withdrawAmount
  ) public view returns (uint256 sumCollateral, uint256 sumDebtPlusEffects) {
    AccountLiquidity memory vars; // holds all our calculation results

    // for each asset the account is in
    uint256 marketMap = accountMarkets[account];
    for (uint256 i = 0; marketMap != 0; marketMap >>= 1) {
      if (marketMap & 1 != 0) {
        Market market = marketList[i];
        MarketData storage m = markets[market];
        uint256 baseUnit = 10 ** m.decimals;
        uint256 adjustFactor = m.adjustFactor;

        // read the balances
        (vars.balance, vars.borrowBalance) = market.accountSnapshot(account);

        // get the normalized price of the asset (18 decimals)
        vars.price = assetPrice(m.priceFeed);

        // sum all the collateral prices
        sumCollateral += vars.balance.mulDivDown(vars.price, baseUnit).mulWadDown(adjustFactor);

        // sum all the debt
        sumDebtPlusEffects += vars.borrowBalance.mulDivUp(vars.price, baseUnit).divWadUp(adjustFactor);

        // simulate the effects of withdrawing from a pool
        if (market == marketToSimulate) {
          // calculate the effects of redeeming markets
          // (having less collateral is the same as having more debt for this calculation)
          if (withdrawAmount != 0) {
            sumDebtPlusEffects += withdrawAmount.mulDivDown(vars.price, baseUnit).mulWadDown(adjustFactor);
          }
        }
      }
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Validates that the current state of the position and system are valid.
  /// @dev To be called after adding the borrowed debt to the account position.
  /// @param market address of the market where the borrow is made.
  /// @param borrower address of the account that will repay the debt.
  function checkBorrow(Market market, address borrower) external {
    MarketData storage m = markets[market];
    if (!m.isListed) revert MarketNotListed();

    uint256 marketMap = accountMarkets[borrower];
    uint256 marketMask = 1 << m.index;

    // validate borrow state
    if ((marketMap & marketMask) == 0) {
      // only markets may call checkBorrow if borrower not in market
      if (msg.sender != address(market)) revert NotMarket();

      accountMarkets[borrower] = marketMap | marketMask;
      emit MarketEntered(market, borrower);
    }

    // verify that current liquidity is not short
    (uint256 collateral, uint256 debt) = accountLiquidity(borrower, Market(address(0)), 0);
    if (collateral < debt) revert InsufficientAccountLiquidity();
  }

  /// @notice Checks if the account has liquidity shortfall.
  /// @param market address of the market where the operation will happen.
  /// @param account address of the account to check for possible shortfall.
  /// @param amount amount that the account wants to withdraw or transfer.
  function checkShortfall(Market market, address account, uint256 amount) public view {
    // if the account is not 'in' the market, bypass the liquidity check
    if ((accountMarkets[account] & (1 << markets[market].index)) == 0) return;

    // otherwise, perform a hypothetical liquidity check to guard against shortfall
    (uint256 collateral, uint256 debt) = accountLiquidity(account, market, amount);
    if (collateral < debt) revert InsufficientAccountLiquidity();
  }

  /// @notice Allows/rejects liquidation of assets.
  /// @dev This function can be called externally, but only will have effect when called from a market.
  /// @param repayMarket market from where the debt is being repaid.
  /// @param seizeMarket market from where the liquidator will seize assets.
  /// @param borrower address in which the assets are being liquidated.
  /// @param maxLiquidatorAssets maximum amount of debt the liquidator is willing to accept.
  /// @return maxRepayAssets capped amount of debt the liquidator is allowed to repay.
  function checkLiquidation(
    Market repayMarket,
    Market seizeMarket,
    address borrower,
    uint256 maxLiquidatorAssets
  ) external view virtual returns (uint256 maxRepayAssets) {
    // if markets are listed, they have the same auditor
    if (!markets[repayMarket].isListed || !markets[seizeMarket].isListed) revert MarketNotListed();

    MarketVars memory repay;
    LiquidityVars memory base;
    uint256 marketMap = accountMarkets[borrower];
    for (uint256 i = 0; marketMap != 0; marketMap >>= 1) {
      if (marketMap & 1 != 0) {
        Market market = marketList[i];
        MarketData storage marketData = markets[market];
        MarketVars memory m = MarketVars({
          price: assetPrice(marketData.priceFeed),
          adjustFactor: marketData.adjustFactor,
          baseUnit: 10 ** marketData.decimals
        });

        if (market == repayMarket) repay = m;

        (uint256 collateral, uint256 debt) = market.accountSnapshot(borrower);

        uint256 value = debt.mulDivUp(m.price, m.baseUnit);
        base.totalDebt += value;
        base.adjustedDebt += value.divWadUp(m.adjustFactor);

        value = collateral.mulDivDown(m.price, m.baseUnit);
        base.totalCollateral += value;
        base.adjustedCollateral += value.mulWadDown(m.adjustFactor);
        if (market == seizeMarket) base.seizeAvailable = value;
      }
      unchecked {
        ++i;
      }
    }

    return maxRepayAmount(base, repay, maxLiquidatorAssets, borrower);
  }

  function maxRepayAmount(
    LiquidityVars memory base,
    MarketVars memory repay,
    uint256 maxLiquidatorAssets,
    address
  ) internal view virtual returns (uint256 maxRepayAssets) {
    if (base.adjustedCollateral >= base.adjustedDebt) revert InsufficientShortfall();

    LiquidationIncentive memory memIncentive = liquidationIncentive;
    uint256 adjustFactor = base.adjustedCollateral.mulWadDown(base.totalDebt).divWadUp(
      base.adjustedDebt.mulWadUp(base.totalCollateral)
    );
    uint256 closeFactor = (TARGET_HEALTH - base.adjustedCollateral.divWadUp(base.adjustedDebt)).divWadUp(
      TARGET_HEALTH - adjustFactor.mulWadDown(1e18 + memIncentive.liquidator + memIncentive.lenders)
    );
    maxRepayAssets = Math.min(
      Math
        .min(
          base.totalDebt.mulWadUp(Math.min(1e18, closeFactor)),
          base.seizeAvailable.divWadUp(1e18 + memIncentive.liquidator + memIncentive.lenders)
        )
        .mulDivUp(repay.baseUnit, repay.price),
      maxLiquidatorAssets < ASSETS_THRESHOLD
        ? maxLiquidatorAssets.divWadDown(1e18 + memIncentive.lenders)
        : maxLiquidatorAssets
    );
  }

  /// @notice Allow/rejects seizing of assets.
  /// @dev This function can be called externally, but only will have effect when called from a market.
  /// @param repayMarket market from where the debt will be repaid.
  /// @param seizeMarket market where the assets will be seized.
  function checkSeize(Market repayMarket, Market seizeMarket) external view {
    // if markets are listed, they also point to the same Auditor
    if (!markets[seizeMarket].isListed || !markets[repayMarket].isListed) revert MarketNotListed();
  }

  /// @notice Calculates the amount of collateral to be seized when a position is undercollateralized.
  /// @param repayMarket market from where the debt will be repaid.
  /// @param seizeMarket market from where the assets will be seized by the liquidator.
  /// @param borrower account in which assets are being seized.
  /// @param actualRepayAssets amount being repaid.
  /// @return lendersAssets amount to be added for other lenders as a compensation of bad debt clearing.
  /// @return seizeAssets amount that can be seized by the liquidator.
  function calculateSeize(
    Market repayMarket,
    Market seizeMarket,
    address borrower,
    uint256 actualRepayAssets
  ) external view returns (uint256 lendersAssets, uint256 seizeAssets) {
    // read prices for borrowed and collateral markets
    uint256 priceBorrowed = assetPrice(markets[repayMarket].priceFeed);
    uint256 priceCollateral = assetPrice(markets[seizeMarket].priceFeed);
    uint256 baseAmount = actualRepayAssets.mulDivUp(priceBorrowed, 10 ** markets[repayMarket].decimals);

    return computeSeize(seizeMarket, baseAmount, priceCollateral, borrower, actualRepayAssets);
  }

  function computeSeize(
    Market seizeMarket,
    uint256 baseAmount,
    uint256 priceCollateral,
    address borrower,
    uint256 actualRepayAssets
  ) internal view virtual returns (uint256 lendersAssets, uint256 seizeAssets) {
    LiquidationIncentive memory memIncentive = liquidationIncentive;
    lendersAssets = actualRepayAssets.mulWadDown(memIncentive.lenders);

    seizeAssets = Math.min(
      baseAmount.mulDivUp(10 ** markets[seizeMarket].decimals, priceCollateral).mulWadUp(
        1e18 + memIncentive.liquidator + memIncentive.lenders
      ),
      seizeMarket.maxWithdraw(borrower)
    );
  }

  /// @notice Checks if account has debt with no collateral, if so then call `clearBadDebt` from each market.
  /// @dev Collateral is multiplied by price and adjust factor to be accurately evaluated as positive collateral asset.
  /// @param account account in which debt is being checked.
  function handleBadDebt(address account) external {
    uint256 memMarketMap = accountMarkets[account];
    uint256 marketMap = memMarketMap;
    for (uint256 i = 0; marketMap != 0; marketMap >>= 1) {
      if (marketMap & 1 != 0) {
        Market market = marketList[i];
        MarketData storage m = markets[market];
        uint256 assets = market.maxWithdraw(account);
        if (assets.mulDivDown(assetPrice(m.priceFeed), 10 ** m.decimals).mulWadDown(m.adjustFactor) > 0) return;
      }
      unchecked {
        ++i;
      }
    }

    marketMap = memMarketMap;
    for (uint256 i = 0; marketMap != 0; marketMap >>= 1) {
      if (marketMap & 1 != 0) marketList[i].clearBadDebt(account);
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Gets the asset price of a price feed.
  /// @dev If Chainlink's asset price is <= 0 the call is reverted.
  /// @param priceFeed address of Chainlink's Price Feed aggregator used to query the asset price.
  /// @return The price of the asset scaled to 18-digit decimals.
  function assetPrice(IPriceFeed priceFeed) public view returns (uint256) {
    if (address(priceFeed) == BASE_FEED) return basePrice;

    int256 price = priceFeed.latestAnswer();
    if (price <= 0) revert InvalidPrice();
    return uint256(price) * baseFactor;
  }

  /// @notice Retrieves all markets.
  function allMarkets() external view returns (Market[] memory) {
    return marketList;
  }

  /// @notice Enables a certain market.
  /// @dev Enabling more than 256 markets will cause an overflow when casting market index to uint8.
  /// @param market market to add to the protocol.
  /// @param priceFeed address of Chainlink's Price Feed aggregator used to query the asset price in base.
  /// @param adjustFactor market's adjust factor for the underlying asset.
  function enableMarket(
    Market market,
    IPriceFeed priceFeed,
    uint128 adjustFactor
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (market.auditor() != this) revert AuditorMismatch();
    if (markets[market].isListed) revert MarketAlreadyListed();
    if (address(priceFeed) != BASE_FEED && priceFeed.decimals() != priceDecimals) revert InvalidPriceFeed();

    uint8 decimals = market.decimals();
    markets[market] = MarketData({
      isListed: true,
      adjustFactor: adjustFactor,
      decimals: decimals,
      index: uint8(marketList.length),
      priceFeed: priceFeed
    });

    marketList.push(market);

    emit MarketListed(market, decimals);
    emit PriceFeedSet(market, priceFeed);
    emit AdjustFactorSet(market, adjustFactor);
  }

  /// @notice Sets the adjust factor for a certain market.
  /// @param market address of the market to change adjust factor for.
  /// @param adjustFactor adjust factor for the underlying asset.
  function setAdjustFactor(Market market, uint128 adjustFactor) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (!markets[market].isListed) revert MarketNotListed();

    markets[market].adjustFactor = adjustFactor;
    emit AdjustFactorSet(market, adjustFactor);
  }

  /// @notice Sets the Chainlink Price Feed Aggregator source for a market.
  /// @param market market address of the asset.
  /// @param priceFeed address of Chainlink's Price Feed aggregator used to query the asset price in base.
  function setPriceFeed(Market market, IPriceFeed priceFeed) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (address(priceFeed) != BASE_FEED && priceFeed.decimals() != priceDecimals) revert InvalidPriceFeed();
    markets[market].priceFeed = priceFeed;
    emit PriceFeedSet(market, priceFeed);
  }

  /// @notice Sets liquidation incentive (liquidator and lenders) for the whole ecosystem.
  /// @param liquidationIncentive_ new liquidation incentive.
  function setLiquidationIncentive(
    LiquidationIncentive memory liquidationIncentive_
  ) public onlyRole(DEFAULT_ADMIN_ROLE) {
    liquidationIncentive = liquidationIncentive_;
    emit LiquidationIncentiveSet(liquidationIncentive_);
  }

  /// @notice Emitted when a new market is listed for borrow/lending.
  /// @param market address of the market that was listed.
  /// @param decimals decimals of the market's underlying asset.
  event MarketListed(Market indexed market, uint8 decimals);

  /// @notice Emitted when an account enters a market to use his deposit as collateral for a loan.
  /// @param market address of the market that the account entered.
  /// @param account address of the account that just entered a market.
  event MarketEntered(Market indexed market, address indexed account);

  /// @notice Emitted when an account leaves a market.
  /// Means that they would stop using their deposit as collateral and won't ask for any loans in this market.
  /// @param market address of the market that the account just left.
  /// @param account address of the account that just left a market.
  event MarketExited(Market indexed market, address indexed account);

  /// @notice Emitted when a adjust factor is changed by admin.
  /// @param market address of the market that has a new adjust factor.
  /// @param adjustFactor adjust factor for the underlying asset.
  event AdjustFactorSet(Market indexed market, uint256 adjustFactor);

  /// @notice Emitted when a new liquidationIncentive has been set.
  /// @param liquidationIncentive represented with 18 decimals.
  event LiquidationIncentiveSet(LiquidationIncentive liquidationIncentive);

  /// @notice Emitted when a market and prie feed is changed by admin.
  /// @param market address of the asset used to get the price.
  /// @param priceFeed address of Chainlink's Price Feed aggregator used to query the asset price in base.
  event PriceFeedSet(Market indexed market, IPriceFeed indexed priceFeed);

  /// @notice Stores the market parameters used for liquidity calculations.
  /// @param adjustFactor used to asses the lending power of the market's underlying asset.
  /// @param decimals number of decimals of the market's underlying asset.
  /// @param index index of the market in the `marketList`.
  /// @param isListed true if the market is enabled.
  /// @param priceFeed address of the price feed used to query the asset's price.
  struct MarketData {
    uint128 adjustFactor;
    uint8 decimals;
    uint8 index;
    bool isListed;
    IPriceFeed priceFeed;
  }

  /// @notice Stores the liquidator and lenders factors used in liquidations to calculate the amount to seize.
  /// @param liquidator factor used to calculate the extra bonus a liquidator can seize.
  /// @param lenders factor used to calculate the bonus that the pool lenders receive.
  struct LiquidationIncentive {
    uint128 liquidator;
    uint128 lenders;
  }

  /// @notice Used as memory access to temporary store account liquidity data.
  /// @param balance collateral balance of the account.
  /// @param borrowBalance borrow balance of the account.
  /// @param price asset price returned by the price feed with 18 decimals.
  struct AccountLiquidity {
    uint256 balance;
    uint256 borrowBalance;
    uint256 price;
  }
}

error AuditorMismatch();
error InsufficientAccountLiquidity();
error InsufficientShortfall();
error InvalidPrice();
error InvalidPriceFeed();
error MarketAlreadyListed();
error MarketNotListed();
error NotMarket();
error RemainingDebt();

struct MarketVars {
  uint256 price;
  uint256 baseUnit;
  uint128 adjustFactor;
}

struct LiquidityVars {
  uint256 totalDebt;
  uint256 totalCollateral;
  uint256 adjustedDebt;
  uint256 adjustedCollateral;
  uint256 seizeAvailable;
}
