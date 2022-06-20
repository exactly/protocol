// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { FixedLender, NotFixedLender } from "./FixedLender.sol";
import { ExactlyOracle } from "./ExactlyOracle.sol";
import { PoolLib } from "./utils/PoolLib.sol";

contract Auditor is AccessControl {
  using FixedPointMathLib for uint256;

  // Struct to avoid stack too deep
  struct AccountLiquidity {
    uint256 balance;
    uint256 borrowBalance;
    uint256 oraclePrice;
  }

  // Struct for FixedLender's markets
  struct Market {
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

  // Protocol Management
  mapping(address => uint256) public accountMarkets;
  mapping(FixedLender => Market) public markets;

  uint256 public liquidationIncentive;
  FixedLender[] public allMarkets;

  ExactlyOracle public oracle;

  /// @notice Event emitted when a new market is listed for borrow/lending.
  /// @param fixedLender address of the fixedLender market that was listed.
  event MarketListed(FixedLender fixedLender, uint8 decimals);

  /// @notice Event emitted when a user enters a market to use his deposit as collateral for a loan.
  /// @param fixedLender address of the market that the user entered.
  /// @param account address of the user that just entered a market.
  event MarketEntered(FixedLender indexed fixedLender, address indexed account);

  /// @notice Event emitted when a user leaves a market. Means that they would stop using their deposit as collateral
  /// and won't ask for any loans in this market.
  /// @param fixedLender address of the market that the user just left.
  /// @param account address of the user that just left a market.
  event MarketExited(FixedLender indexed fixedLender, address indexed account);

  /// @notice Event emitted when a new Oracle has been set.
  /// @param newOracle address of the new oracle that is used to calculate liquidity.
  event OracleSet(ExactlyOracle newOracle);

  /// @notice Event emitted when a new liquidationIncentive has been set.
  /// @param newLiquidationIncentive represented with 1e18 decimals.
  event LiquidationIncentiveSet(uint256 newLiquidationIncentive);

  /// @notice Event emitted when a adjust factor is changed by admin.
  /// @param fixedLender address of the market that has a new adjust factor.
  /// @param newAdjustFactor adjust factor for the underlying asset.
  event AdjustFactorSet(FixedLender indexed fixedLender, uint256 newAdjustFactor);

  event log(string);
  event logs(bytes);

  event log_address(address);
  event log_bytes32(bytes32);
  event log_int(int256);
  event log_uint(uint256);
  event log_bytes(bytes);
  event log_string(string);

  event log_named_address(string key, address val);
  event log_named_bytes32(string key, bytes32 val);
  event log_named_decimal_int(string key, int256 val, uint256 decimals);
  event log_named_decimal_uint(string key, uint256 val, uint256 decimals);
  event log_named_int(string key, int256 val);
  event log_named_uint(string key, uint256 val);
  event log_named_bytes(string key, bytes val);
  event log_named_string(string key, string val);

  constructor(ExactlyOracle oracle_, uint256 liquidationIncentive_) {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

    setOracle(oracle_);
    setLiquidationIncentive(liquidationIncentive_);
  }

  /// @notice Allows assets of a certain `fixedLender` market to be used as collateral for borrowing other assets.
  /// @param fixedLender market to enable as collateral for `msg.sender`.
  function enterMarket(FixedLender fixedLender) external {
    validateMarketListed(fixedLender);
    uint256 marketIndex = markets[fixedLender].index;

    uint256 marketMap = accountMarkets[msg.sender];

    if ((marketMap & (1 << marketIndex)) != 0) return;
    accountMarkets[msg.sender] = marketMap | (1 << marketIndex);

    emit MarketEntered(fixedLender, msg.sender);
  }

  /// @notice Removes fixedLender from sender's account liquidity calculation.
  /// @dev Sender must not have an outstanding borrow balance in the asset, or be providing necessary collateral
  /// for an outstanding borrow.
  /// @param fixedLender The address of the asset to be removed.
  function exitMarket(FixedLender fixedLender) external {
    validateMarketListed(fixedLender);
    uint256 marketIndex = markets[fixedLender].index;

    (uint256 assets, uint256 debt) = fixedLender.getAccountSnapshot(msg.sender);

    // Fail if the sender has a borrow balance
    if (debt != 0) revert BalanceOwed();

    // Fail if the sender is not permitted to redeem all of their tokens
    validateAccountShortfall(fixedLender, msg.sender, assets);

    uint256 marketMap = accountMarkets[msg.sender];

    if ((marketMap & (1 << marketIndex)) == 0) return;
    accountMarkets[msg.sender] = marketMap & ~(1 << marketIndex);

    emit MarketExited(fixedLender, msg.sender);
  }

  /// @notice Sets Oracle's to be used.
  /// @param _priceOracle address of the new oracle.
  function setOracle(ExactlyOracle _priceOracle) public onlyRole(DEFAULT_ADMIN_ROLE) {
    oracle = _priceOracle;
    emit OracleSet(_priceOracle);
  }

  /// @notice Sets liquidation incentive for the whole ecosystem.
  /// @dev Value can only be set between 20% and 5%.
  /// @param _liquidationIncentive new liquidation incentive. It's a factor, so 15% would be 1.15e18.
  function setLiquidationIncentive(uint256 _liquidationIncentive) public onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_liquidationIncentive > 1.2e18 || _liquidationIncentive < 1.05e18) revert InvalidParameter();
    liquidationIncentive = _liquidationIncentive;
    emit LiquidationIncentiveSet(_liquidationIncentive);
  }

  /// @notice Enables a certain FixedLender market.
  /// @dev Enabling more than 256 markets will cause an overflow when casting market index to uint8.
  /// @param fixedLender address to add to the protocol.
  /// @param adjustFactor fixedLender's adjust factor for the underlying asset.
  /// @param decimals decimals of the market's underlying asset.
  function enableMarket(
    FixedLender fixedLender,
    uint128 adjustFactor,
    uint8 decimals
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (fixedLender.auditor() != this) revert AuditorMismatch();

    if (markets[fixedLender].isListed) revert MarketAlreadyListed();

    markets[fixedLender] = Market({
      isListed: true,
      adjustFactor: adjustFactor,
      decimals: decimals,
      index: uint8(allMarkets.length)
    });

    allMarkets.push(fixedLender);

    emit MarketListed(fixedLender, decimals);
    setAdjustFactor(fixedLender, adjustFactor);
  }

  /// @notice Sets the adjust factor for a certain fixedLender.
  /// @dev Market should be listed and value can only be set between 90% and 30%.
  /// @param fixedLender address of the market to change adjust factor for.
  /// @param adjustFactor adjust factor for the underlying asset.
  function setAdjustFactor(FixedLender fixedLender, uint128 adjustFactor) public onlyRole(DEFAULT_ADMIN_ROLE) {
    validateMarketListed(fixedLender);
    if (adjustFactor > 0.9e18 || adjustFactor < 0.3e18) revert InvalidParameter();
    markets[fixedLender].adjustFactor = adjustFactor;
    emit AdjustFactorSet(fixedLender, adjustFactor);
  }

  /// @notice Validates that the current state of the position and system are valid (liquidity).
  /// @dev Hook function to be called after adding the borrowed debt to the user position.
  /// @param fixedLender address of the fixedLender where the borrow is made.
  /// @param borrower address of the account that will repay the debt.
  function validateBorrow(FixedLender fixedLender, address borrower) external {
    validateMarketListed(fixedLender);
    uint256 marketIndex = markets[fixedLender].index;
    uint256 marketMap = accountMarkets[borrower];

    // we validate borrow state
    if ((marketMap & (1 << marketIndex)) == 0) {
      // only fixedLenders may call validateBorrow if borrower not in market
      if (msg.sender != address(fixedLender)) revert NotFixedLender();

      accountMarkets[borrower] = marketMap | (1 << marketIndex);
      emit MarketEntered(fixedLender, borrower);

      // it should be impossible to break this invariant
      assert((accountMarkets[borrower] & (1 << marketIndex)) != 0);
    }

    // We verify that current liquidity is not short
    (uint256 collateral, uint256 debt) = accountLiquidity(borrower, fixedLender, 0);
    if (collateral < debt) revert InsufficientLiquidity();
  }

  /// @notice Allows/rejects liquidation of assets.
  /// @dev This function can be called externally, but only will have effect when called from a fixedLender.
  /// @param repayMarket market from where the debt is pending.
  /// @param seizeMarket market where the assets will be liquidated (should be msg.sender on FixedLender.sol).
  /// @param liquidator address that is liquidating the assets.
  /// @param borrower address which the assets are being liquidated.
  function checkLiquidation(
    FixedLender repayMarket,
    FixedLender seizeMarket,
    address liquidator,
    address borrower
  ) external returns (uint256 maxRepayAssets, bool moreCollateral) {
    if (borrower == liquidator) revert SelfLiquidation();

    // if markets are listed, they have the same auditor
    if (!markets[repayMarket].isListed || !markets[seizeMarket].isListed) revert MarketNotListed();

    MarketVars memory repay;
    LiquidityVars memory usd;
    uint256 marketMap = accountMarkets[borrower];
    uint256 marketCount = allMarkets.length;
    for (uint256 i = 0; i < marketCount; ) {
      if ((marketMap & (1 << i)) != 0) {
        FixedLender market = allMarkets[i];
        Market memory memMarket = markets[market];
        MarketVars memory m = MarketVars({
          price: oracle.getAssetPrice(market),
          adjustFactor: memMarket.adjustFactor,
          decimals: memMarket.decimals
        });

        if (market == repayMarket) repay = m;

        (uint256 collateral, uint256 debt) = market.getAccountSnapshot(borrower);

        emit log_named_uint("decimals", m.decimals);
        emit log_named_decimal_uint("        collateral", collateral, m.decimals);
        emit log_named_decimal_uint("              debt", debt, m.decimals);
        emit log_named_decimal_uint("             price", m.price, 18);
        emit log_named_decimal_uint("      adjustFactor", m.adjustFactor, 18);
        emit log_named_decimal_uint(
          "adjustedCollateral",
          collateral.mulDivDown(m.price, 10**m.decimals).mulWadDown(m.adjustFactor),
          18
        );
        emit log_named_decimal_uint(
          "      adjustedDebt",
          debt.mulDivUp(m.price, 10**m.decimals).divWadUp(m.adjustFactor),
          18
        );

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

    uint256 adjustFactor = usd.adjustedCollateral.mulDivUp(
      usd.totalDebt,
      usd.totalCollateral.mulWadDown(usd.adjustedDebt)
    );
    uint256 closeFactor = (TARGET_HEALTH - usd.adjustedCollateral.divWadUp(usd.adjustedDebt)).divWadUp(
      TARGET_HEALTH - adjustFactor.mulWadDown(liquidationIncentive)
    );
    maxRepayAssets = Math
      .min(usd.totalDebt.mulWadUp(Math.min(1e18, closeFactor)), usd.seizeAvailable.divWadUp(liquidationIncentive))
      .mulDivUp(10**repay.decimals, repay.price);
    moreCollateral = usd.totalCollateral > usd.seizeAvailable;

    emit log("global");
    emit log_named_decimal_uint("   totalCollateral", usd.totalCollateral, 18);
    emit log_named_decimal_uint("adjustedCollateral", usd.adjustedCollateral, 18);
    emit log_named_decimal_uint("  collateralFactor", usd.adjustedCollateral.divWadUp(usd.totalCollateral), 18);
    emit log_named_decimal_uint("         totalDebt", usd.totalDebt, 18);
    emit log_named_decimal_uint("      adjustedDebt", usd.adjustedDebt, 18);
    emit log_named_decimal_uint("        debtFactor", usd.totalDebt.divWadUp(usd.adjustedDebt), 18);
    emit log_named_decimal_uint("      adjustFactor", adjustFactor, 18);
    emit log_named_decimal_uint("      healthFactor", usd.adjustedCollateral.divWadUp(usd.adjustedDebt), 18);
    emit log_named_decimal_uint("       closeFactor", closeFactor, 18);
    emit log_named_decimal_uint("       maxRepayUSD", usd.totalDebt.mulWadUp(Math.min(1e18, closeFactor)), 18);
    emit log_named_uint("    repay.decimals", repay.decimals);
    emit log_named_decimal_uint("       repay.price", repay.price, 18);
    emit log_named_decimal_uint("    maxRepayAssets", maxRepayAssets, repay.decimals);
  }

  /// @notice Allow/rejects seizing of assets.
  /// @dev This function can be called externally, but only will have effect when called from a fixedLender.
  /// @param seizeMarket market where the assets will be seized (should be msg.sender on FixedLender.sol).
  /// @param repayMarket market from where the debt will be paid.
  /// @param liquidator address to validate where the seized assets will be received.
  /// @param borrower address to validate where the assets will be removed.
  function seizeAllowed(
    FixedLender seizeMarket,
    FixedLender repayMarket,
    address liquidator,
    address borrower
  ) external view {
    if (borrower == liquidator) revert SelfLiquidation();

    // If markets are listed, they have also the same Auditor
    if (!markets[seizeMarket].isListed || !markets[repayMarket].isListed) revert MarketNotListed();
  }

  /// @notice Calculates the amount of collateral to be seized when a position is undercollaterized.
  /// @param repayMarket market from where the debt is pending.
  /// @param seizeMarket market where the assets will be liquidated (should be msg.sender on FixedLender.sol).
  /// @param actualRepayAmount repay amount in the borrowed asset.
  /// @return amount of collateral to be seized.
  function liquidateCalculateSeizeAmount(
    FixedLender repayMarket,
    FixedLender seizeMarket,
    uint256 actualRepayAmount
  ) external view returns (uint256) {
    // Read oracle prices for borrowed and collateral markets
    uint256 priceBorrowed = oracle.getAssetPrice(repayMarket);
    uint256 priceCollateral = oracle.getAssetPrice(seizeMarket);

    uint256 amountInUSD = actualRepayAmount.mulDivDown(priceBorrowed, 10**markets[repayMarket].decimals);
    // 10**18: usd amount decimals
    uint256 seizeTokens = amountInUSD.mulDivUp(10**markets[seizeMarket].decimals, priceCollateral);

    return seizeTokens.mulWadDown(liquidationIncentive);
  }

  /// @notice Retrieves all markets.
  function getAllMarkets() external view returns (FixedLender[] memory) {
    return allMarkets;
  }

  /// @notice Checks if the user has an account liquidity shortfall
  /// @dev This function is called indirectly from fixedLender contracts(withdraw), eToken transfers and directly from
  /// this contract when the user wants to exit a market.
  /// @param fixedLender address of the fixedLender where the smart pool belongs.
  /// @param account address of the user to check for possible shortfall.
  /// @param amount amount that the user wants to withdraw or transfer.
  function validateAccountShortfall(
    FixedLender fixedLender,
    address account,
    uint256 amount
  ) public view {
    // If the user is not 'in' the market, then we can bypass the liquidity check
    if ((accountMarkets[account] & (1 << markets[fixedLender].index)) == 0) return;

    // Otherwise, perform a hypothetical liquidity check to guard against shortfall
    (uint256 collateral, uint256 debt) = accountLiquidity(account, fixedLender, amount);
    if (collateral < debt) revert InsufficientLiquidity();
  }

  /// @notice Returns account's liquidity for a certain market.
  /// @param account wallet which the liquidity will be calculated.
  /// @param fixedLenderToSimulate fixedLender in which we want to simulate withdraw/borrow ops (see next two args).
  /// @param withdrawAmount amount to simulate withdraw.
  /// @return sumCollateral sum of all collateral, already multiplied by each adjust factor. denominated in usd.
  /// @return sumDebt sum of all debt. denominated in usd.
  function accountLiquidity(
    address account,
    FixedLender fixedLenderToSimulate,
    uint256 withdrawAmount
  ) public view returns (uint256 sumCollateral, uint256 sumDebt) {
    AccountLiquidity memory vars; // Holds all our calculation results

    // For each asset the account is in
    uint256 marketMap = accountMarkets[account];
    uint256 maxValue = allMarkets.length;
    for (uint256 i = 0; i < maxValue; ) {
      if ((marketMap & (1 << i)) != 0) {
        FixedLender market = allMarkets[i];
        uint256 decimals = markets[market].decimals;
        uint256 adjustFactor = markets[market].adjustFactor;

        // Read the balances
        (vars.balance, vars.borrowBalance) = market.getAccountSnapshot(account);

        // Get the normalized price of the asset (18 decimals)
        vars.oraclePrice = oracle.getAssetPrice(market);

        // We sum all the collateral prices
        sumCollateral += vars.balance.mulDivDown(vars.oraclePrice, 10**decimals).mulWadDown(adjustFactor);

        // We sum all the debt
        sumDebt += vars.borrowBalance.mulDivDown(vars.oraclePrice, 10**decimals);
        // sumDebt += vars.borrowBalance.mulDivUp(vars.oraclePrice, 10**decimals).divWadUp(adjustFactor);

        // Simulate the effects of borrowing from/lending to a pool
        if (market == FixedLender(fixedLenderToSimulate)) {
          // Calculate the effects of redeeming fixedLenders
          // (having less collateral is the same as having more debt for this calculation)
          if (withdrawAmount != 0) {
            sumDebt += withdrawAmount.mulDivDown(vars.oraclePrice, 10**decimals).mulWadDown(adjustFactor);
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
  /// @param fixedLender address of the fixedLender to be validated by the auditor.
  function validateMarketListed(FixedLender fixedLender) internal view {
    if (!markets[fixedLender].isListed) revert MarketNotListed();
  }
}

error AuditorMismatch();
error BalanceOwed();
error InsufficientLiquidity();
error InsufficientShortfall();
error InvalidParameter();
error MarketAlreadyListed();
error MarketNotListed();
error SelfLiquidation();
