// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

import { Auditor, Market } from "../Auditor.sol";

contract IntegrationPreviewer {
  using FixedPointMathLib for uint256;

  /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
  Auditor public immutable auditor;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor(Auditor auditor_) {
    auditor = auditor_;
  }

  function healthFactor(address account) external view returns (uint256) {
    (uint256 adjustedCollateral, uint256 adjustedDebt) = auditor.accountLiquidity(account, Market(address(0)), 0);
    if (adjustedDebt == 0) return type(uint256).max;
    return adjustedCollateral.divWadDown(adjustedDebt);
  }
}
