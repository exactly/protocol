// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

import { Auditor, LiquidityVars, Market, MarketVars } from "../Auditor.sol";
import { Firewall } from "./Firewall.sol";

contract VerifiedAuditor is Auditor {
  using FixedPointMathLib for uint256;

  Firewall public firewall;

  constructor(uint256 priceDecimals_) Auditor(priceDecimals_) {}

  function initialize(LiquidationIncentive memory) public pure override {
    revert InvalidInitializer();
  }

  function initializeVerified(LiquidationIncentive memory liquidationIncentive_, Firewall firewall_) external {
    super.initialize(liquidationIncentive_);
    _setFirewall(firewall_);
  }

  function checkBorrow(Market market, address borrower) public override onlyAllowed(borrower) {
    super.checkBorrow(market, borrower);
  }

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

  function setFirewall(Firewall firewall_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setFirewall(firewall_);
  }

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
error NotAllowed(address account);
