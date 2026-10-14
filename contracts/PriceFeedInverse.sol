// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/src/utils/SafeCastLib.sol";

import { IPriceFeed } from "./utils/IPriceFeed.sol";

contract PriceFeedInverse is IPriceFeed {
  using FixedPointMathLib for uint256;
  using SafeCastLib for int256;

  /// @notice Source price feed whose answer is inverted.
  IPriceFeed public immutable priceFeed;
  /// @notice Number of decimals that the answer of this price feed has, same as the source feed's.
  uint8 public immutable decimals;
  /// @notice Square of the source feed's base unit, used as the numerator to invert its answer.
  uint256 public immutable baseUnitSquared;

  constructor(IPriceFeed priceFeed_) {
    priceFeed = priceFeed_;
    decimals = priceFeed_.decimals();
    baseUnitSquared = 10 ** (2 * uint256(decimals));
  }

  /// @notice Returns the inverse of the source feed's latest answer.
  /// @dev Rounds up, the conservative direction for debt-only markets, so the inverse can't truncate to zero.
  /// Reverts on a zero or negative answer.
  function latestAnswer() external view returns (int256) {
    return int256(baseUnitSquared.divUp(priceFeed.latestAnswer().toUint256()));
  }
}
