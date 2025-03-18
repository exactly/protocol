// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Market } from "../Market.sol";

library PreviewerLib {
  using FixedPointMathLib for uint256;

  function newFloatingDebt(Market market) internal view returns (uint256) {
    return
      market.floatingDebt().mulWadDown(
        market.interestRateModel().floatingRate(0).mulDivDown(
          block.timestamp - market.lastFloatingDebtUpdate(),
          365 days
        )
      );
  }
}
