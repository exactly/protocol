// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { FixedPointMathLib } from "@rari-capital/solmate-v6/src/utils/FixedPointMathLib.sol";
import { FixedLender, NotFixedLender } from "./FixedLender.sol";
import { IOracle } from "./interfaces/IOracle.sol";
import { PoolLib } from "./utils/PoolLib.sol";
import {
  IAuditor,
  AuditorMismatch,
  BalanceOwed,
  BorrowCapReached,
  InsufficientLiquidity,
  InsufficientShortfall,
  InvalidParameter,
  LiquidatorNotBorrower,
  MarketAlreadyListed,
  MarketNotListed,
  TooMuchRepay
} from "./interfaces/IAuditor.sol";

contract Auditor is IAuditor, AccessControl {
  using FixedPointMathLib for uint256;

  // Struct to avoid stack too deep
  struct AccountLiquidity {
    uint256 balance;
    uint256 borrowBalance;
    uint256 oraclePrice;
    uint256 sumCollateral;
    uint256 sumDebt;
    uint8 decimals;
    uint128 collateralFactor;
  }

  // Struct for FixedLender's markets
  struct Market {
    string symbol;
    string name;
    uint128 collateralFactor;
    uint8 decimals;
    uint8 index;
    bool isListed;
  }

  // Protocol Management
  mapping(address => uint256) private accountAssets;
  mapping(FixedLender => Market) private markets;
  mapping(FixedLender => uint256) private borrowCaps;

  uint256 public constant CLOSE_FACTOR = 5e17;
  uint256 public liquidationIncentive;
  FixedLender[] public allMarkets;

  IOracle public oracle;

  /// @notice Event emitted when a new market is listed for borrow/lending.
  /// @param fixedLender address of the fixedLender market that it was listed.
  event MarketListed(FixedLender fixedLender);

  /// @notice Event emitted when a user enters a market to use his deposit as collateral for a loan.
  /// @param fixedLender address of the market that the user entered.
  /// @param account address of the user that just entered a market.
  event MarketEntered(FixedLender indexed fixedLender, address account);

  /// @notice Event emitted when a user leaves a market. Means that they would stop using their deposit as collateral
  /// and won't ask for any loans in this market.
  /// @param fixedLender address of the market that the user just left.
  /// @param account address of the user that just left a market.
  event MarketExited(FixedLender indexed fixedLender, address account);

  /// @notice Event emitted when a new Oracle has been set.
  /// @param newOracle address of the new oracle that is used to calculate liquidity.
  event OracleUpdated(IOracle newOracle);

  /// @notice Event emitted when a new liquidationIncentive has been set.
  /// @param newLiquidationIncentive represented with 1e18 decimals.
  event LiquidationIncentiveUpdated(uint256 newLiquidationIncentive);

  /// @notice Event emitted when a new borrow cap has been set for a certain fixedLender.
  /// If newBorrowCap is 0, that means that there's no cap.
  /// @param fixedLender address of the lender that has a new borrow cap.
  /// @param newBorrowCap new borrow cap expressed with 1e18 precision for the given market. Zero means no cap.
  event BorrowCapUpdated(FixedLender indexed fixedLender, uint256 newBorrowCap);

  /// @notice emitted when a collateral factor is changed by admin.
  /// @param fixedLender address of the market that has a new collateral factor.
  /// @param newCollateralFactor collateral factor for the underlying asset.
  event CollateralFactorUpdated(FixedLender indexed fixedLender, uint256 newCollateralFactor);

  constructor(IOracle _priceOracle, uint256 _liquidationIncentive) {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

    oracle = _priceOracle;
    liquidationIncentive = _liquidationIncentive;
  }

  /// @dev Allows wallet to enter certain markets (fixedLenderDAI, fixedLenderETH, etc).
  /// By performing this action, the wallet's money could be used as collateral.
  /// @param fixedLenders contracts addresses to enable for `msg.sender`.
  function enterMarkets(FixedLender[] calldata fixedLenders) external {
    for (uint256 i = 0; i < fixedLenders.length; ) {
      validateMarketListed(fixedLenders[i]);
      uint8 marketIndex = markets[fixedLenders[i]].index;

      uint256 assets = accountAssets[msg.sender];

      if ((assets & (1 << marketIndex)) != 0) return;
      accountAssets[msg.sender] = assets | (1 << marketIndex);

      emit MarketEntered(fixedLenders[i], msg.sender);

      unchecked {
        ++i;
      }
    }
  }

  /// @notice Removes fixedLender from sender's account liquidity calculation.
  /// @dev Sender must not have an outstanding borrow balance in the asset, or be providing necessary collateral
  /// for an outstanding borrow.
  /// @param fixedLender The address of the asset to be removed.
  function exitMarket(FixedLender fixedLender) external {
    validateMarketListed(fixedLender);
    uint8 marketIndex = markets[fixedLender].index;

    (uint256 amountHeld, uint256 borrowBalance) = fixedLender.getAccountSnapshot(msg.sender, PoolLib.MATURITY_ALL);

    // Fail if the sender has a borrow balance
    if (borrowBalance != 0) revert BalanceOwed();

    // Fail if the sender is not permitted to redeem all of their tokens
    validateAccountShortfall(fixedLender, msg.sender, amountHeld);

    uint256 assets = accountAssets[msg.sender];

    if ((assets & (1 << marketIndex)) == 0) return;
    accountAssets[msg.sender] = assets & ~(1 << marketIndex);

    emit MarketExited(fixedLender, msg.sender);
  }

  /// @dev Function to set Oracle's to be used.
  /// @param _priceOracle address of the new oracle.
  function setOracle(IOracle _priceOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
    oracle = _priceOracle;
    emit OracleUpdated(_priceOracle);
  }

  /// @notice Set liquidation incentive for the whole ecosystem.
  /// @dev Value can only be set between 20% and 5%.
  /// @param _liquidationIncentive new liquidation incentive. It's a factor, so 15% would be 1.15e18.
  function setLiquidationIncentive(uint256 _liquidationIncentive) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_liquidationIncentive > 1.2e18 || _liquidationIncentive < 1.05e18) revert InvalidParameter();
    liquidationIncentive = _liquidationIncentive;
    emit LiquidationIncentiveUpdated(_liquidationIncentive);
  }

  /// @dev Function to enable a certain FixedLender market.
  /// @param fixedLender address to add to the protocol.
  /// @param collateralFactor fixedLender's collateral factor for the underlying asset.
  /// @param symbol symbol of the market's underlying asset.
  /// @param name name of the market's underlying asset.
  /// @param decimals decimals of the market's underlying asset.
  function enableMarket(
    FixedLender fixedLender,
    uint128 collateralFactor,
    string memory symbol,
    string memory name,
    uint8 decimals
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (fixedLender.auditor() != this) revert AuditorMismatch();

    if (markets[fixedLender].isListed) revert MarketAlreadyListed();

    markets[fixedLender] = Market({
      isListed: true,
      collateralFactor: collateralFactor,
      symbol: symbol,
      name: name,
      decimals: decimals,
      index: uint8(allMarkets.length)
    });

    allMarkets.push(fixedLender);

    emit MarketListed(fixedLender);
  }

  /// @notice sets the collateral factor for a certain fixedLender.
  /// @dev Value can only be set between 90% and 30%.
  /// @param fixedLender address of the market to change collateral factor for.
  /// @param collateralFactor collateral factor for the underlying asset.
  function setCollateralFactor(FixedLender fixedLender, uint128 collateralFactor)
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
  {
    if (collateralFactor > 0.9e18 || collateralFactor < 0.3e18) revert InvalidParameter();
    markets[fixedLender].collateralFactor = collateralFactor;
    emit CollateralFactorUpdated(fixedLender, collateralFactor);
  }

  /// @notice Set the given borrow caps for the given fixedLender markets.
  /// Borrowing that brings total borrows to or above borrow cap will revert.
  /// @param fixedLenders The addresses of the markets (tokens) to change the borrow caps for.
  /// @param newBorrowCaps Values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
  function setMarketBorrowCaps(FixedLender[] calldata fixedLenders, uint256[] calldata newBorrowCaps)
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
  {
    if (fixedLenders.length == 0 || fixedLenders.length != newBorrowCaps.length) revert InvalidParameter();

    for (uint256 i = 0; i < fixedLenders.length; ) {
      validateMarketListed(fixedLenders[i]);

      borrowCaps[fixedLenders[i]] = newBorrowCaps[i];
      emit BorrowCapUpdated(fixedLenders[i], newBorrowCaps[i]);

      unchecked {
        ++i;
      }
    }
  }

  /// @dev Hook function to be called after calling the poolAccounting borrowMP function.
  /// Validates that the current state of the position and system are valid (liquidity).
  /// @param fixedLender address of the fixedLender that will lend money in a maturity.
  /// @param borrower address of the user that will borrow money from a maturity date.
  function validateBorrowMP(FixedLender fixedLender, address borrower) external override {
    validateMarketListed(fixedLender);
    uint8 marketIndex = markets[fixedLender].index;
    uint256 assets = accountAssets[borrower];

    // we validate borrow state
    if ((assets & (1 << marketIndex)) == 0) {
      // only fixedLenders may call validateBorrowMP if borrower not in market
      if (msg.sender != address(fixedLender)) revert NotFixedLender();

      accountAssets[borrower] = assets | (1 << marketIndex);
      emit MarketEntered(fixedLender, borrower);

      // it should be impossible to break this invariant
      assert((accountAssets[borrower] & (1 << marketIndex)) != 0);
    }

    uint256 borrowCap = borrowCaps[fixedLender];
    // Borrow cap of 0 corresponds to unlimited borrowing
    if (borrowCap != 0) {
      uint256 totalBorrows = fixedLender.totalMpBorrows();
      if (totalBorrows >= borrowCap) revert BorrowCapReached();
    }

    // We verify that current liquidity is not short
    (, uint256 shortfall) = accountLiquidity(borrower, fixedLender, 0, 0);

    if (shortfall > 0) revert InsufficientLiquidity();
  }

  /// @dev Function to allow/reject liquidation of assets.
  /// This function can be called externally, but only will have effect when called from a fixedLender.
  /// @param fixedLenderBorrowed market from where the debt is pending.
  /// @param fixedLenderCollateral market where the assets will be liquidated (should be msg.sender on FixedLender.sol).
  /// @param liquidator address that is liquidating the assets.
  /// @param borrower address which the assets are being liquidated.
  /// @param repayAmount to be repaid from the debt (outstanding debt * close factor should be bigger than this value).
  function liquidateAllowed(
    FixedLender fixedLenderBorrowed,
    FixedLender fixedLenderCollateral,
    address liquidator,
    address borrower,
    uint256 repayAmount
  ) external view override {
    if (borrower == liquidator) revert LiquidatorNotBorrower();

    // if markets are listed, they have the same auditor
    if (!markets[fixedLenderBorrowed].isListed || !markets[fixedLenderCollateral].isListed) revert MarketNotListed();

    // The borrower must have shortfall in order to be liquidatable
    (, uint256 shortfall) = accountLiquidity(borrower, FixedLender(address(0)), 0, 0);

    if (shortfall == 0) revert InsufficientShortfall();

    // The liquidator may not repay more than what is allowed by the CLOSE_FACTOR
    (, uint256 borrowBalance) = FixedLender(fixedLenderBorrowed).getAccountSnapshot(borrower, PoolLib.MATURITY_ALL);
    uint256 maxClose = CLOSE_FACTOR.fmul(borrowBalance, 1e18);
    if (repayAmount > maxClose) revert TooMuchRepay();
  }

  /// @dev Function to allow/reject seizing of assets.
  /// This function can be called externally, but only will have effect when called from a fixedLender.
  /// @param fixedLenderCollateral market where the assets will be seized (should be msg.sender on FixedLender.sol).
  /// @param fixedLenderBorrowed market from where the debt will be paid.
  /// @param liquidator address to validate where the seized assets will be received.
  /// @param borrower address to validate where the assets will be removed.
  function seizeAllowed(
    FixedLender fixedLenderCollateral,
    FixedLender fixedLenderBorrowed,
    address liquidator,
    address borrower
  ) external view override {
    if (borrower == liquidator) revert LiquidatorNotBorrower();

    // If markets are listed, they have also the same Auditor
    if (!markets[fixedLenderCollateral].isListed || !markets[fixedLenderBorrowed].isListed) revert MarketNotListed();
  }

  /// @dev Given a fixedLender address, it returns the corresponding market data.
  /// @param fixedLender Address of the contract where we are getting the data.
  function getMarketData(FixedLender fixedLender)
    external
    view
    returns (
      string memory,
      string memory,
      bool,
      uint256,
      uint8,
      FixedLender
    )
  {
    validateMarketListed(fixedLender);

    Market memory marketData = markets[fixedLender];
    return (
      marketData.symbol,
      marketData.name,
      marketData.isListed,
      marketData.collateralFactor,
      marketData.decimals,
      fixedLender
    );
  }

  /// @dev Function to get account's liquidity.
  /// @param account wallet to retrieve liquidity.
  function getAccountLiquidity(address account) external view override returns (uint256, uint256) {
    return accountLiquidity(account, FixedLender(address(0)), 0, 0);
  }

  /// @dev Function to calculate the amount of assets to be seized.
  /// Calculates the amount of collateral to be seized when a position is undercollaterized.
  /// @param fixedLenderCollateral market where the assets will be liquidated (should be msg.sender on FixedLender.sol).
  /// @param fixedLenderBorrowed market from where the debt is pending.
  /// @param actualRepayAmount repay amount in the borrowed asset.
  function liquidateCalculateSeizeAmount(
    FixedLender fixedLenderBorrowed,
    FixedLender fixedLenderCollateral,
    uint256 actualRepayAmount
  ) external view override returns (uint256) {
    // Read oracle prices for borrowed and collateral markets
    uint256 priceBorrowed = oracle.getAssetPrice(FixedLender(fixedLenderBorrowed).assetSymbol());
    uint256 priceCollateral = oracle.getAssetPrice(FixedLender(fixedLenderCollateral).assetSymbol());

    uint256 amountInUSD = actualRepayAmount.fmul(priceBorrowed, 10**markets[fixedLenderBorrowed].decimals);
    // 10**18: usd amount decimals
    uint256 seizeTokens = amountInUSD.fmul(10**markets[fixedLenderCollateral].decimals, priceCollateral);

    return seizeTokens.fmul(liquidationIncentive, 1e18);
  }

  /// @dev Function to retrieve all markets.
  function getAllMarkets() external view override returns (FixedLender[] memory) {
    return allMarkets;
  }

  /// @dev Function to be called before someone wants to interact with its smart pool position.
  /// This function checks if the user has no outstanding debts.
  /// This function is called indirectly from fixedLender contracts(withdraw), eToken transfers and directly from this
  /// contract when the user wants to exit a market.
  /// @param fixedLender address of the fixedLender where the smart pool belongs.
  /// @param account address of the user to check for possible shortfall.
  /// @param amount amount that the user wants to withdraw or transfer.
  function validateAccountShortfall(
    FixedLender fixedLender,
    address account,
    uint256 amount
  ) public view override {
    // If the user is not 'in' the market, then we can bypass the liquidity check
    if ((accountAssets[account] & (1 << markets[fixedLender].index)) == 0) return;

    // Otherwise, perform a hypothetical liquidity check to guard against shortfall
    (, uint256 shortfall) = accountLiquidity(account, fixedLender, amount, 0);
    if (shortfall > 0) revert InsufficientLiquidity();
  }

  /// @dev Function to get account's liquidity for a certain market/maturity pool.
  /// @param account wallet which the liquidity will be calculated.
  /// @param fixedLenderToSimulate fixedLender in which we want to simulate withdraw/borrow ops (see next two args).
  /// @param withdrawAmount amount to simulate withdraw.
  /// @param borrowAmount amount to simulate borrow.
  function accountLiquidity(
    address account,
    FixedLender fixedLenderToSimulate,
    uint256 withdrawAmount,
    uint256 borrowAmount
  ) internal view returns (uint256, uint256) {
    AccountLiquidity memory vars; // Holds all our calculation results

    // For each asset the account is in
    uint256 assets = accountAssets[account];
    uint8 maxValue = uint8(allMarkets.length);
    for (uint8 i = 0; i < maxValue; ) {
      if ((assets & (1 << i)) != 0) {
        FixedLender asset = allMarkets[i];
        vars.decimals = markets[asset].decimals;
        vars.collateralFactor = markets[asset].collateralFactor;

        // Read the balances
        (vars.balance, vars.borrowBalance) = asset.getAccountSnapshot(account, PoolLib.MATURITY_ALL);

        // Get the normalized price of the asset (18 decimals)
        vars.oraclePrice = oracle.getAssetPrice(asset.assetSymbol());

        // We sum all the collateral prices
        vars.sumCollateral += vars.balance.fmul(vars.oraclePrice, 10**vars.decimals).fmul(vars.collateralFactor, 1e18);

        // We sum all the debt
        vars.sumDebt += vars.borrowBalance.fmul(vars.oraclePrice, 10**vars.decimals);

        // Simulate the effects of borrowing from/lending to a pool
        if (asset == FixedLender(fixedLenderToSimulate)) {
          // Calculate the effects of borrowing fixedLenders
          if (borrowAmount != 0) vars.sumDebt += borrowAmount.fmul(vars.oraclePrice, 10**vars.decimals);

          // Calculate the effects of redeeming fixedLenders
          // (having less collateral is the same as having more debt for this calculation)
          if (withdrawAmount != 0) {
            vars.sumDebt += withdrawAmount.fmul(vars.oraclePrice, 10**vars.decimals).fmul(vars.collateralFactor, 1e18);
          }
        }
      }
      unchecked {
        ++i;
      }
      if ((1 << i) > assets) break;
    }

    // These are safe, as the underflow condition is checked first
    if (vars.sumCollateral > vars.sumDebt) {
      return (vars.sumCollateral - vars.sumDebt, 0);
    } else {
      return (0, vars.sumDebt - vars.sumCollateral);
    }
  }

  /// @dev This function verifies if market is listed as valid.
  /// @param fixedLender address of the fixedLender to be validated by the auditor.
  function validateMarketListed(FixedLender fixedLender) internal view {
    if (!markets[fixedLender].isListed) revert MarketNotListed();
  }
}
