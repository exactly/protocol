// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { Market, NotMarket } from "./Market.sol";
import { ExactlyOracle } from "./ExactlyOracle.sol";
import { FixedLib } from "./utils/FixedLib.sol";

contract Auditor is AccessControl {
  using FixedPointMathLib for uint256;

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

  uint256 public constant TARGET_HEALTH = 1.25e18;

  mapping(address => uint256) public accountMarkets;
  mapping(Market => MarketData) public markets;

  LiquidationIncentive public liquidationIncentive;
  Market[] public allMarkets;

  ExactlyOracle public oracle;

  /// @notice Event emitted when a new market is listed for borrow/lending.
  /// @param market address of the market that was listed.
  event MarketListed(Market market, uint8 decimals);

  /// @notice Event emitted when a user enters a market to use his deposit as collateral for a loan.
  /// @param market address of the market that the user entered.
  /// @param account address of the user that just entered a market.
  event MarketEntered(Market indexed market, address indexed account);

  /// @notice Event emitted when a user leaves a market. Means that they would stop using their deposit as collateral
  /// and won't ask for any loans in this market.
  /// @param market address of the market that the user just left.
  /// @param account address of the user that just left a market.
  event MarketExited(Market indexed market, address indexed account);

  /// @notice Event emitted when a new Oracle has been set.
  /// @param newOracle address of the new oracle that is used to calculate liquidity.
  event OracleSet(ExactlyOracle newOracle);

  /// @notice Event emitted when a new liquidationIncentive has been set.
  /// @param newLiquidationIncentive represented with 18 decimals.
  event LiquidationIncentiveSet(LiquidationIncentive newLiquidationIncentive);

  /// @notice Event emitted when a adjust factor is changed by admin.
  /// @param market address of the market that has a new adjust factor.
  /// @param newAdjustFactor adjust factor for the underlying asset.
  event AdjustFactorSet(Market indexed market, uint256 newAdjustFactor);

  constructor(ExactlyOracle oracle_, LiquidationIncentive memory liquidationIncentive_) {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setOracle(oracle_);
    setLiquidationIncentive(liquidationIncentive_);
  }

  /// @notice Allows assets of a certain `market` market to be used as collateral for borrowing other assets.
  /// @param market market to enable as collateral for `msg.sender`.
  function enterMarket(Market market) external {
    validateMarketListed(market);
    uint256 marketIndex = markets[market].index;

    uint256 marketMap = accountMarkets[msg.sender];

    if ((marketMap & (1 << marketIndex)) != 0) return;
    accountMarkets[msg.sender] = marketMap | (1 << marketIndex);

    emit MarketEntered(market, msg.sender);
  }

  /// @notice Removes market from sender's account liquidity calculation.
  /// @dev Sender must not have an outstanding borrow balance in the asset, or be providing necessary collateral
  /// for an outstanding borrow.
  /// @param market The address of the asset to be removed.
  function exitMarket(Market market) external {
    validateMarketListed(market);
    uint256 marketIndex = markets[market].index;

    (uint256 assets, uint256 debt) = market.getAccountSnapshot(msg.sender);

    // Fail if the sender has a borrow balance
    if (debt != 0) revert BalanceOwed();

    // Fail if the sender is not permitted to redeem all of their tokens
    validateAccountShortfall(market, msg.sender, assets);

    uint256 marketMap = accountMarkets[msg.sender];

    if ((marketMap & (1 << marketIndex)) == 0) return;
    accountMarkets[msg.sender] = marketMap & ~(1 << marketIndex);

    emit MarketExited(market, msg.sender);
  }

  /// @notice Sets Oracle's to be used.
  /// @param _priceOracle address of the new oracle.
  function setOracle(ExactlyOracle _priceOracle) public onlyRole(DEFAULT_ADMIN_ROLE) {
    oracle = _priceOracle;
    emit OracleSet(_priceOracle);
  }

  /// @notice Sets liquidation incentive for the whole ecosystem.
  /// @dev Value can only be set between 20% and 5%.
  /// @param liquidationIncentive_ new liquidation incentive.
  function setLiquidationIncentive(LiquidationIncentive memory liquidationIncentive_)
    public
    onlyRole(DEFAULT_ADMIN_ROLE)
  {
    if (
      liquidationIncentive_.liquidator > 0.2e18 ||
      liquidationIncentive_.liquidator < 0.05e18 ||
      liquidationIncentive_.lenders > 0.1e18
    ) {
      revert InvalidParameter();
    }
    liquidationIncentive = liquidationIncentive_;
    emit LiquidationIncentiveSet(liquidationIncentive_);
  }

  /// @notice Enables a certain market.
  /// @dev Enabling more than 256 markets will cause an overflow when casting market index to uint8.
  /// @param market address to add to the protocol.
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
      index: uint8(allMarkets.length)
    });

    allMarkets.push(market);

    emit MarketListed(market, decimals);
    setAdjustFactor(market, adjustFactor);
  }

  /// @notice Sets the adjust factor for a certain market.
  /// @dev MarketData should be listed and value can only be set between 90% and 30%.
  /// @param market address of the market to change adjust factor for.
  /// @param adjustFactor adjust factor for the underlying asset.
  function setAdjustFactor(Market market, uint128 adjustFactor) public onlyRole(DEFAULT_ADMIN_ROLE) {
    validateMarketListed(market);
    if (adjustFactor > 0.9e18 || adjustFactor < 0.3e18) revert InvalidParameter();
    markets[market].adjustFactor = adjustFactor;
    emit AdjustFactorSet(market, adjustFactor);
  }

  /// @notice Validates that the current state of the position and system are valid (liquidity).
  /// @dev Hook function to be called after adding the borrowed debt to the user position.
  /// @param market address of the market where the borrow is made.
  /// @param borrower address of the account that will repay the debt.
  function validateBorrow(Market market, address borrower) external {
    validateMarketListed(market);
    uint256 marketIndex = markets[market].index;
    uint256 marketMap = accountMarkets[borrower];

    // we validate borrow state
    if ((marketMap & (1 << marketIndex)) == 0) {
      // only markets may call validateBorrow if borrower not in market
      if (msg.sender != address(market)) revert NotMarket();

      accountMarkets[borrower] = marketMap | (1 << marketIndex);
      emit MarketEntered(market, borrower);

      // it should be impossible to break this invariant
      assert((accountMarkets[borrower] & (1 << marketIndex)) != 0);
    }

    // We verify that current liquidity is not short
    (uint256 collateral, uint256 debt) = accountLiquidity(borrower, market, 0);
    if (collateral < debt) revert InsufficientLiquidity();
  }

  /// @notice Allows/rejects liquidation of assets.
  /// @dev This function can be called externally, but only will have effect when called from a market.
  /// @param repayMarket market from where the debt is pending.
  /// @param seizeMarket market where the assets will be liquidated (should be msg.sender on Market.sol).
  /// @param borrower address which the assets are being liquidated.
  /// @param maxLiquidatorAssets maximum amount the liquidator can pay.
  function checkLiquidation(
    Market repayMarket,
    Market seizeMarket,
    address borrower,
    uint256 maxLiquidatorAssets
  ) external view returns (uint256 maxRepayAssets, bool moreCollateral) {
    // if markets are listed, they have the same auditor
    if (!markets[repayMarket].isListed || !markets[seizeMarket].isListed) revert MarketNotListed();

    MarketVars memory repay;
    LiquidityVars memory usd;
    uint256 marketMap = accountMarkets[borrower];
    uint256 marketCount = allMarkets.length;
    for (uint256 i = 0; i < marketCount; ) {
      if ((marketMap & (1 << i)) != 0) {
        Market market = allMarkets[i];
        MarketData memory memMarket = markets[market];
        MarketVars memory m = MarketVars({
          price: oracle.getAssetPrice(market),
          adjustFactor: memMarket.adjustFactor,
          decimals: memMarket.decimals
        });

        if (market == repayMarket) repay = m;

        (uint256 collateral, uint256 debt) = market.getAccountSnapshot(borrower);

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
      maxLiquidatorAssets < type(uint256).max
        ? maxLiquidatorAssets.divWadDown(1e18 + memIncentive.lenders)
        : type(uint256).max
    );
    moreCollateral = usd.totalCollateral > usd.seizeAvailable;
  }

  /// @notice Allow/rejects seizing of assets.
  /// @dev This function can be called externally, but only will have effect when called from a market.
  /// @param seizeMarket market where the assets will be seized (should be msg.sender on Market.sol).
  /// @param repayMarket market from where the debt will be paid.
  function checkSeize(Market seizeMarket, Market repayMarket) external view {
    // If markets are listed, they have also the same Auditor
    if (!markets[seizeMarket].isListed || !markets[repayMarket].isListed) revert MarketNotListed();
  }

  /// @notice Calculates the amount of collateral to be seized when a position is undercollateralized.
  /// @param repayMarket market from where the debt is pending.
  /// @param seizeMarket market where the assets will be liquidated (should be msg.sender on Market.sol).
  /// @param actualRepayAssets repay amount in the borrowed asset.
  function liquidateCalculateSeizeAmount(
    Market repayMarket,
    Market seizeMarket,
    address borrower,
    uint256 actualRepayAssets
  ) external view returns (uint256 seizeAssets, uint256 lendersAssets) {
    // Read oracle prices for borrowed and collateral markets
    uint256 priceBorrowed = oracle.getAssetPrice(repayMarket);
    uint256 priceCollateral = oracle.getAssetPrice(seizeMarket);

    uint256 amountInUSD = actualRepayAssets.mulDivUp(priceBorrowed, 10**markets[repayMarket].decimals);
    // 10**18: usd amount decimals
    seizeAssets = Math.min(
      amountInUSD.mulDivUp(10**markets[seizeMarket].decimals, priceCollateral).mulWadUp(
        1e18 + liquidationIncentive.liquidator + liquidationIncentive.lenders
      ),
      seizeMarket.maxWithdraw(borrower)
    );
    lendersAssets = actualRepayAssets.mulWadDown(liquidationIncentive.lenders);
  }

  /// @notice Retrieves all markets.
  function getAllMarkets() external view returns (Market[] memory) {
    return allMarkets;
  }

  /// @notice Checks if the user has an account liquidity shortfall
  /// @dev This function is called indirectly from market contracts(withdraw), eToken transfers and directly from
  /// this contract when the user wants to exit a market.
  /// @param market address of the market where the operation will happen.
  /// @param account address of the user to check for possible shortfall.
  /// @param amount amount that the user wants to withdraw or transfer.
  function validateAccountShortfall(
    Market market,
    address account,
    uint256 amount
  ) public view {
    // If the user is not 'in' the market, then we can bypass the liquidity check
    if ((accountMarkets[account] & (1 << markets[market].index)) == 0) return;

    // Otherwise, perform a hypothetical liquidity check to guard against shortfall
    (uint256 collateral, uint256 debt) = accountLiquidity(account, market, amount);
    if (collateral < debt) revert InsufficientLiquidity();
  }

  /// @notice Returns account's liquidity for a certain market.
  /// @param account wallet which the liquidity will be calculated.
  /// @param marketToSimulate market in which we want to simulate withdraw/borrow ops (see next two args).
  /// @param withdrawAmount amount to simulate withdraw.
  /// @return sumCollateral sum of all collateral, already multiplied by each adjust factor. denominated in usd.
  /// @return sumDebtPlusEffects sum of all debt. denominated in usd.
  function accountLiquidity(
    address account,
    Market marketToSimulate,
    uint256 withdrawAmount
  ) public view returns (uint256 sumCollateral, uint256 sumDebtPlusEffects) {
    AccountLiquidity memory vars; // Holds all our calculation results

    // For each asset the account is in
    uint256 marketMap = accountMarkets[account];
    uint256 maxValue = allMarkets.length;
    for (uint256 i = 0; i < maxValue; ) {
      if ((marketMap & (1 << i)) != 0) {
        Market market = allMarkets[i];
        uint256 decimals = markets[market].decimals;
        uint256 adjustFactor = markets[market].adjustFactor;

        // Read the balances
        (vars.balance, vars.borrowBalance) = market.getAccountSnapshot(account);

        // Get the normalized price of the asset (18 decimals)
        vars.oraclePrice = oracle.getAssetPrice(market);

        // We sum all the collateral prices
        sumCollateral += vars.balance.mulDivDown(vars.oraclePrice, 10**decimals).mulWadDown(adjustFactor);

        // We sum all the debt
        sumDebtPlusEffects += vars.borrowBalance.mulDivUp(vars.oraclePrice, 10**decimals).divWadUp(adjustFactor);

        // Simulate the effects of withdrawing from a pool
        if (market == marketToSimulate) {
          // Calculate the effects of redeeming markets
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

  /// @notice Verifies if market is listed as valid.
  /// @param market address of the market to be validated by the auditor.
  function validateMarketListed(Market market) internal view {
    if (!markets[market].isListed) revert MarketNotListed();
  }
}

error AuditorMismatch();
error BalanceOwed();
error InsufficientLiquidity();
error InsufficientShortfall();
error InvalidParameter();
error MarketAlreadyListed();
error MarketNotListed();
