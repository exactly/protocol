// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { IPriceFeed } from "./utils/IPriceFeed.sol";

contract PriceFeedDouble is IPriceFeed {
  using FixedPointMathLib for uint256;

  /// @notice Main price feed where the price is fetched from.
  IPriceFeed public immutable priceFeedOne;
  /// @notice Number of decimals that the answer of this price feed has.
  uint8 public immutable decimals;
  /// @notice Second price feed where the asset's rate is fetched from.
  IPriceFeed public immutable priceFeedTwo;
  /// @notice Base units that are used to normalize the answer when multiplying by the second price feed rate.
  uint256 public immutable baseUnit;

  constructor(IPriceFeed priceFeedOne_, IPriceFeed priceFeedTwo_) {
    priceFeedOne = priceFeedOne_;
    decimals = priceFeedOne_.decimals();
    baseUnit = 10 ** priceFeedTwo_.decimals();
    priceFeedTwo = priceFeedTwo_;
  }

  /// @notice Returns the price feed's latest value considering the other price feed's rate.
  function latestAnswer() external view returns (int256) {
    return int256(uint256(priceFeedOne.latestAnswer()).mulDivDown(uint256(priceFeedTwo.latestAnswer()), baseUnit));
  }
}
