// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { IPriceFeed } from "./utils/IPriceFeed.sol";

contract PriceFeedWrapper is IPriceFeed {
  using FixedPointMathLib for uint256;

  /// @notice Main price feed where the price is fetched from.
  IPriceFeed public immutable mainPriceFeed;
  /// @notice Number of decimals that the answer of this price feed has.
  uint8 public immutable decimals;
  /// @notice Address of the wrapper contract where the asset rate is fetched from.
  address public immutable wrapper;
  /// @notice Function selector of the wrapper contract where the asset rate is fetched from.
  bytes4 public immutable conversionSelector;
  /// @notice Base units that are sent to the conversion function to get the asset rate.
  uint256 public immutable baseUnit;

  constructor(IPriceFeed mainPriceFeed_, address wrapper_, bytes4 conversionSelector_, uint256 baseUnit_) {
    mainPriceFeed = mainPriceFeed_;
    decimals = mainPriceFeed_.decimals();
    wrapper = wrapper_;
    conversionSelector = conversionSelector_;
    baseUnit = baseUnit_;
  }

  /// @notice Returns the price feed's latest value considering the wrapped asset's rate.
  function latestAnswer() external view returns (int256) {
    int256 mainPrice = mainPriceFeed.latestAnswer();

    (, bytes memory data) = address(wrapper).staticcall(abi.encodeWithSelector(conversionSelector, baseUnit));
    uint256 rate = abi.decode(data, (uint256));

    return int256(uint256(mainPrice).mulDivDown(rate, baseUnit));
  }
}
