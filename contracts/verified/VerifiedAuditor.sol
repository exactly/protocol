// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";

import { Auditor, LiquidityVars, Market, MarketVars, RemainingDebt } from "../Auditor.sol";
import { Firewall } from "./Firewall.sol";
import { VerifiedMarket } from "./VerifiedMarket.sol";

/// @title VerifiedAuditor
/// @notice Auditor contract that can only be used by allowed accounts.
contract VerifiedAuditor is Auditor {
  using FixedPointMathLib for uint256;

  /// @notice Firewall contract that controls the allowed accounts.
  Firewall public firewall;

  /// @dev Empty constructor for super call.
  constructor(uint256 priceDecimals_) Auditor(priceDecimals_) {}

  /// @notice Disabled initializer.
  function initialize(LiquidationIncentive memory) public pure override {
    revert InvalidInitializer();
  }

  /// @notice Initializes the verified auditor.
  /// @param liquidationIncentive_ The liquidation incentive to set.
  /// @param firewall_ The firewall to set.
  function initializeVerified(LiquidationIncentive memory liquidationIncentive_, Firewall firewall_) external {
    super.initialize(liquidationIncentive_);
    _setFirewall(firewall_);
  }

  /// @notice Calls super function after requiring the borrower to be allowed.
  /// @param market The market to check the borrow for.
  /// @param borrower The address of the borrower to check the borrow for.
  function checkBorrow(Market market, address borrower) public override onlyAllowed(borrower) {
    super.checkBorrow(market, borrower);
  }

  /// @notice Calls super function after requiring the account to be allowed.
  /// @param market The market to check the shortfall for.
  /// @param account The address of the account to check the shortfall for.
  /// @param amount The amount to check the shortfall for.
  function checkShortfall(Market market, address account, uint256 amount) public view override onlyAllowed(account) {
    super.checkShortfall(market, account, amount);
  }

  /// @notice Locks the assets of a disallowed account.
  /// @dev Requires all debt to have been repaid and sender to be allowed.
  /// @param account The address of the account to lock the assets for.
  function lock(address account) external onlyAllowed(msg.sender) {
    if (firewall.isAllowed(account)) revert InvalidOperation();

    uint256 marketMap = accountMarkets[account];
    for (uint256 i = 0; marketMap != 0; marketMap >>= 1) {
      if (marketMap & 1 != 0) {
        Market market = marketList[i];
        (, uint256 debt) = market.accountSnapshot(account);
        if (debt != 0) revert RemainingDebt();
      }
      unchecked {
        ++i;
      }
    }

    for (uint256 i = 0; i < marketList.length; ++i) VerifiedMarket(address(marketList[i])).lock(account);
  }

  /// @notice Unlocks the assets of an allowed account.
  /// @dev Requires sender to be allowed.
  /// @param account The address of the account to unlock the assets for.
  function unlock(address account) external onlyAllowed(msg.sender) {
    if (!firewall.isAllowed(account)) revert InvalidOperation();

    for (uint256 i = 0; i < marketList.length; ++i) VerifiedMarket(address(marketList[i])).unlock(account);
  }

  /// @notice Calculates the maximum amount of assets the liquidator is allowed to repay.
  ///   If the account is disallowed, removes incentives and does not require the account to be underwater.
  /// @param base The base liquidity variables.
  /// @param repay The repay liquidity variables.
  /// @param maxLiquidatorAssets The maximum amount of assets the liquidator is willing to accept.
  /// @param borrower The address of the borrower to check the max repay amount for.
  /// @return The maximum amount of assets the liquidator is allowed to repay.
  function maxRepayAmount(
    LiquidityVars memory base,
    MarketVars memory repay,
    uint256 maxLiquidatorAssets,
    address borrower
  ) internal view override returns (uint256) {
    if (firewall.isAllowed(borrower)) return super.maxRepayAmount(base, repay, maxLiquidatorAssets, borrower);

    return
      Math.min(
        Math.min(base.totalDebt, base.seizeAvailable).mulDivUp(repay.baseUnit, repay.price),
        maxLiquidatorAssets
      );
  }

  function computeSeize(
    Market seizeMarket,
    uint256 baseAmount,
    uint256 priceCollateral,
    address borrower,
    uint256 actualRepayAssets
  ) internal view override returns (uint256 lendersAssets, uint256 seizeAssets) {
    if (firewall.isAllowed(borrower)) {
      return super.computeSeize(seizeMarket, baseAmount, priceCollateral, borrower, actualRepayAssets);
    }

    return (
      0,
      Math.min(
        baseAmount.mulDivUp(10 ** markets[seizeMarket].decimals, priceCollateral),
        seizeMarket.maxWithdraw(borrower)
      )
    );
  }

  /// @notice Sets the firewall.
  /// @dev Only callable by the admin role.
  /// @param firewall_ The firewall to set.
  function setFirewall(Firewall firewall_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setFirewall(firewall_);
  }

  /// @notice Requires the account to be allowed on the firewall.
  /// @param account The account address to check.
  function _requireAllowed(address account) internal view {
    if (!firewall.isAllowed(account)) revert NotAllowed(account);
  }

  function _setFirewall(Firewall firewall_) internal {
    firewall = firewall_;
    emit FirewallSet(firewall_);
  }

  modifier onlyAllowed(address account) {
    _requireAllowed(account);
    _;
  }
}

/// @notice Emitted when the firewall is set.
/// @param firewall the new firewall.
event FirewallSet(Firewall indexed firewall);

error InvalidInitializer();
error InvalidOperation();
error NotAllowed(address account);
