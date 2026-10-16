// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/src/utils/SafeCastLib.sol";

import { IPriceFeed } from "./utils/IPriceFeed.sol";

contract PriceFeedInverse is IPriceFeed {
  using FixedPointMathLib for uint256;
  using SafeCastLib for int256;

  /// @notice Source price feed whose answer is inverted.
  IAggregatorProxy public immutable priceFeed;
  /// @notice Number of decimals that the answer of this price feed has, same as the source feed's.
  uint8 public immutable decimals;
  /// @notice Square of the source feed's base unit, used as the numerator to invert its answer.
  uint256 public immutable baseUnitSquared;

  constructor(IAggregatorProxy priceFeed_) {
    priceFeed = priceFeed_;
    decimals = priceFeed_.decimals();
    baseUnitSquared = 10 ** (2 * uint256(decimals));
  }

  /// @notice Returns the inverse of the source feed's latest answer.
  /// @dev Rounds up, the conservative direction for debt-only markets, so the inverse can't truncate to zero.
  /// Reverts on a zero or negative answer.
  function latestAnswer() external view returns (int256) {
    return inverse(priceFeed.latestAnswer());
  }

  /// @notice Returns the source feed's data for `roundId_`, with the answer inverted like `latestAnswer`.
  /// @dev A zero answer, which the source returns for rounds without data, is kept as zero.
  function getRoundData(
    uint80 roundId_
  )
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    (roundId, answer, startedAt, updatedAt, answeredInRound) = priceFeed.getRoundData(roundId_);
    if (answer != 0) answer = inverse(answer);
  }

  /// @notice Returns the source feed's latest round data, with the answer inverted like `latestAnswer`.
  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    (roundId, answer, startedAt, updatedAt, answeredInRound) = priceFeed.latestRoundData();
    answer = inverse(answer);
  }

  /// @notice Returns the source feed's current phase id.
  function phaseId() external view returns (uint16) {
    return priceFeed.phaseId();
  }

  function inverse(int256 answer) internal view returns (int256) {
    return int256(baseUnitSquared.divUp(answer.toUint256()));
  }
}

interface IAggregatorProxy is IPriceFeed {
  function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80);

  function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);

  function phaseId() external view returns (uint16);
}
