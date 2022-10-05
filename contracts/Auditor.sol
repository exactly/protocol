// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.16;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { MathUpgradeable as Math } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ExactlyOracle } from "./ExactlyOracle.sol";
import { Market } from "./Market.sol";

contract Auditor is Initializable, AccessControlUpgradeable {
  using FixedPointMathLib for uint256;

  uint256 public constant TARGET_HEALTH = 1.25e18;
  uint256 public constant ASSETS_THRESHOLD = type(uint256).max / 1e18;

  mapping(address => uint256) public accountMarkets;
  mapping(Market => MarketData) public markets;
  Market[] public marketList;

  LiquidationIncentive public liquidationIncentive;

  ExactlyOracle public oracle;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(ExactlyOracle oracle_, LiquidationIncentive memory liquidationIncentive_) external initializer {
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setOracle(oracle_);
    setLiquidationIncentive(liquidationIncentive_);
  }

  /// @notice Allows assets of a certain market to be used as collateral for borrowing other assets.
  /// @param market market to enabled as collateral.
  function enterMarket(Market market) external {
    MarketData memory m = markets[market];
    if (!m.isListed) revert MarketNotListed();

    uint256 marketMap = accountMarkets[msg.sender];

    if ((marketMap & (1 << m.index)) != 0) return;
    accountMarkets[msg.sender] = marketMap | (1 << m.index);

    emit MarketEntered(market, msg.sender);
  }

  /// @notice Removes market from sender's account liquidity calculation.
  /// @dev Sender must not have an outstanding borrow balance in the asset, or be providing necessary collateral
  /// for an outstanding borrow.
  /// @param market market to be disabled as collateral.
  function exitMarket(Market market) external {
    MarketData memory m = markets[market];
    if (!m.isListed) revert MarketNotListed();

    (uint256 assets, uint256 debt) = market.accountSnapshot(msg.sender);

    // fail if the sender has a borrow balance
    if (debt != 0) revert RemainingDebt();

    // fail if the sender is not permitted to redeem all of their assets
    checkShortfall(market, msg.sender, assets);

    uint256 marketMap = accountMarkets[msg.sender];

    if ((marketMap & (1 << m.index)) == 0) return;
    accountMarkets[msg.sender] = marketMap & ~(1 << m.index);

    emit MarketExited(market, msg.sender);
  }

  /// @notice Returns account's liquidity calculation.
  /// @param account account in which the liquidity will be calculated.
  /// @param marketToSimulate market in which to simulate withdraw operation.
  /// @param withdrawAmount amount to simulate as withdraw.
  /// @return sumCollateral sum of all collateral, already multiplied by each adjust factor (denominated in usd).
  /// @return sumDebtPlusEffects sum of all debt divided by adjust factor considering withdrawal (denominated in usd).
  function accountLiquidity(
    address account,
    Market marketToSimulate,
    uint256 withdrawAmount
  ) public view returns (uint256 sumCollateral, uint256 sumDebtPlusEffects) {
    AccountLiquidity memory vars; // holds all our calculation results

    // for each asset the account is in
    uint256 marketMap = accountMarkets[account];
    uint256 maxValue = marketList.length;
    for (uint256 i = 0; i < maxValue; ) {
      if ((marketMap & (1 << i)) != 0) {
        Market market = marketList[i];
        uint256 decimals = markets[market].decimals;
        uint256 adjustFactor = markets[market].adjustFactor;

        // read the balances
        (vars.balance, vars.borrowBalance) = market.accountSnapshot(account);

        // get the normalized price of the asset (18 decimals)
        vars.oraclePrice = oracle.assetPrice(market);

        // sum all the collateral prices
        sumCollateral += vars.balance.mulDivDown(vars.oraclePrice, 10**decimals).mulWadDown(adjustFactor);

        // sum all the debt
        sumDebtPlusEffects += vars.borrowBalance.mulDivUp(vars.oraclePrice, 10**decimals).divWadUp(adjustFactor);

        // simulate the effects of withdrawing from a pool
        if (market == marketToSimulate) {
          // calculate the effects of redeeming markets
          // (having less collateral is the same as having more debt for this calculation)
          if (withdrawAmount != 0) {
            sumDebtPlusEffects += withdrawAmount.mulDivDown(vars.oraclePrice, 10**decimals).mulWadDown(adjustFactor);
          }
        }
      }
      unchecked {
        ++i;
      }
      if ((1 << i) > marketMap) break;
    }
  }

  /// @notice Validates that the current state of the position and system are valid.
  /// @dev To be called after adding the borrowed debt to the account position.
  /// @param market address of the market where the borrow is made.
  /// @param borrower address of the account that will repay the debt.
  function checkBorrow(Market market, address borrower) external {
    MarketData memory m = markets[market];
    if (!m.isListed) revert MarketNotListed();
    uint256 marketMap = accountMarkets[borrower];

    // validate borrow state
    if ((marketMap & (1 << m.index)) == 0) {
      // only markets may call checkBorrow if borrower not in market
      if (msg.sender != address(market)) revert NotMarket();

      accountMarkets[borrower] = marketMap | (1 << m.index);
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
  function checkShortfall(
    Market market,
    address account,
    uint256 amount
  ) public view {
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
  ) external view returns (uint256 maxRepayAssets) {
    // if markets are listed, they have the same auditor
    if (!markets[repayMarket].isListed || !markets[seizeMarket].isListed) revert MarketNotListed();

    MarketVars memory repay;
    LiquidityVars memory usd;
    uint256 marketMap = accountMarkets[borrower];
    uint256 marketCount = marketList.length;
    for (uint256 i = 0; i < marketCount; ) {
      if ((marketMap & (1 << i)) != 0) {
        Market market = marketList[i];
        MarketData memory memMarket = markets[market];
        MarketVars memory m = MarketVars({
          price: oracle.assetPrice(market),
          adjustFactor: memMarket.adjustFactor,
          decimals: memMarket.decimals
        });

        if (market == repayMarket) repay = m;

        (uint256 collateral, uint256 debt) = market.accountSnapshot(borrower);

        uint256 value = debt.mulDivUp(m.price, 10**m.decimals);
        usd.totalDebt += value;
        usd.adjustedDebt += value.divWadUp(m.adjustFactor);

        value = collateral.mulDivDown(m.price, 10**m.decimals);
        usd.totalCollateral += value;
        usd.adjustedCollateral += value.mulWadDown(m.adjustFactor);
        if (market == seizeMarket) usd.seizeAvailable = value;
      }
      unchecked {
        ++i;
      }
      if ((1 << i) > marketMap) break;
    }

    if (usd.adjustedCollateral >= usd.adjustedDebt) revert InsufficientShortfall();

    LiquidationIncentive memory memIncentive = liquidationIncentive;
    uint256 adjustFactor = usd.adjustedCollateral.divWadUp(usd.totalCollateral).mulWadUp(
      usd.totalDebt.divWadUp(usd.adjustedDebt)
    );
    uint256 closeFactor = (TARGET_HEALTH - usd.adjustedCollateral.divWadUp(usd.adjustedDebt)).divWadUp(
      TARGET_HEALTH - adjustFactor.mulWadDown(1e18 + memIncentive.liquidator + memIncentive.lenders)
    );
    maxRepayAssets = Math.min(
      Math
        .min(
          usd.totalDebt.mulWadUp(Math.min(1e18, closeFactor)),
          usd.seizeAvailable.divWadUp(1e18 + memIncentive.liquidator + memIncentive.lenders)
        )
        .mulDivUp(10**repay.decimals, repay.price),
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
    // If markets are listed, they have also the same Auditor
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
    LiquidationIncentive memory memIncentive = liquidationIncentive;
    lendersAssets = actualRepayAssets.mulWadDown(memIncentive.lenders);

    // read oracle prices for borrowed and collateral markets
    uint256 priceBorrowed = oracle.assetPrice(repayMarket);
    uint256 priceCollateral = oracle.assetPrice(seizeMarket);
    uint256 amountInUSD = actualRepayAssets.mulDivUp(priceBorrowed, 10**markets[repayMarket].decimals);

    // 10**18: usd amount decimals
    seizeAssets = Math.min(
      amountInUSD.mulDivUp(10**markets[seizeMarket].decimals, priceCollateral).mulWadUp(
        1e18 + memIncentive.liquidator + memIncentive.lenders
      ),
      seizeMarket.maxWithdraw(borrower)
    );
  }

  /// @notice Checks if account has debt with no collateral, if so then call `clearBadDebt` from each market.
  /// @dev Collateral is multiplied by price and adjust factor to be accurately evaluated as positive collateral asset.
  /// @param account account in which debt is being checked.
  function handleBadDebt(address account) external {
    uint256 marketCount = marketList.length;
    uint256 marketMap = accountMarkets[account];
    for (uint256 i = 0; i < marketCount; ) {
      if ((marketMap & (1 << i)) != 0) {
        Market market = marketList[i];
        MarketData storage m = markets[market];
        uint256 assets = market.maxWithdraw(account);
        if (assets.mulDivDown(oracle.assetPrice(market), 10**m.decimals).mulWadDown(m.adjustFactor) > 0) return;
      }

      unchecked {
        ++i;
      }
    }

    for (uint256 i = 0; i < marketCount; ) {
      marketList[i].clearBadDebt(account);
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Retrieves all markets.
  function allMarkets() external view returns (Market[] memory) {
    return marketList;
  }

  /// @notice Enables a certain market.
  /// @dev Enabling more than 256 markets will cause an overflow when casting market index to uint8.
  /// @param market market to add to the protocol.
  /// @param adjustFactor market's adjust factor for the underlying asset.
  /// @param decimals decimals of the market's underlying asset.
  function enableMarket(
    Market market,
    uint128 adjustFactor,
    uint8 decimals
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (market.auditor() != this) revert AuditorMismatch();

    if (markets[market].isListed) revert MarketAlreadyListed();

    markets[market] = MarketData({
      isListed: true,
      adjustFactor: adjustFactor,
      decimals: decimals,
      index: uint8(marketList.length)
    });

    marketList.push(market);

    emit MarketListed(market, decimals);
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

  /// @notice Sets liquidation incentive (liquidator and lenders) for the whole ecosystem.
  /// @param liquidationIncentive_ new liquidation incentive.
  function setLiquidationIncentive(LiquidationIncentive memory liquidationIncentive_)
    public
    onlyRole(DEFAULT_ADMIN_ROLE)
  {
    liquidationIncentive = liquidationIncentive_;
    emit LiquidationIncentiveSet(liquidationIncentive_);
  }

  /// @notice Sets Oracle's to be used.
  /// @param oracle_ address of the new oracle.
  function setOracle(ExactlyOracle oracle_) public onlyRole(DEFAULT_ADMIN_ROLE) {
    oracle = oracle_;
    emit OracleSet(oracle_);
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

  /// @notice Emitted when a new Oracle has been set.
  /// @param oracle address of the new oracle that is used to calculate liquidity.
  event OracleSet(ExactlyOracle indexed oracle);

  struct LiquidationIncentive {
    uint128 liquidator;
    uint128 lenders;
  }

  struct AccountLiquidity {
    uint256 balance;
    uint256 borrowBalance;
    uint256 oraclePrice;
  }

  struct MarketData {
    uint128 adjustFactor;
    uint8 decimals;
    uint8 index;
    bool isListed;
  }
}

error AuditorMismatch();
error InsufficientAccountLiquidity();
error InsufficientShortfall();
error MarketAlreadyListed();
error MarketNotListed();
error NotMarket();
error RemainingDebt();

struct MarketVars {
  uint256 price;
  uint128 adjustFactor;
  uint8 decimals;
}

struct LiquidityVars {
  uint256 totalDebt;
  uint256 totalCollateral;
  uint256 adjustedDebt;
  uint256 adjustedCollateral;
  uint256 seizeAvailable;
}
