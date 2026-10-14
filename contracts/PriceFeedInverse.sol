// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/src/utils/SafeCastLib.sol";
import { IPriceFeed } from "./utils/IPriceFeed.sol";

contract PriceFeedInverse is IPriceFeed {
  using FixedPointMathLib for uint256;
  using SafeCastLib for int256;

  /// @notice Price feed whose answer is inverted.
  IPriceFeed public immutable priceFeed;
  /// @notice Number of decimals that the answer of this price feed has, same as the inverted feed's.
  uint8 public immutable decimals;
  /// @notice Base unit of the inverted feed's answer.
  uint256 public immutable baseUnit;

  constructor(IPriceFeed priceFeed_) {
    priceFeed = priceFeed_;
    decimals = priceFeed_.decimals();
    baseUnit = 10 ** decimals;
  }

  /// @notice Returns the inverse of the price feed's latest answer.
  /// @dev Rounds up, the conservative direction for debt-only markets, so the inverse can't truncate to zero.
  /// Reverts on a zero or negative answer.
  function latestAnswer() external view returns (int256) {
    return int256(baseUnit.mulDivUp(baseUnit, priceFeed.latestAnswer().toUint256()));
  }
}
