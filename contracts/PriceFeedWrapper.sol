// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { IPriceFeed } from "./utils/IPriceFeed.sol";

contract PriceFeedWrapper is IPriceFeed {
  using FixedPointMathLib for uint256;

  IPriceFeed public immutable mainPriceFeed;
  uint8 public immutable decimals;
  address public immutable wrapper;
  bytes4 public immutable conversionSelector;
  uint256 public immutable baseUnit;

  constructor(
    IPriceFeed mainPriceFeed_,
    address wrapper_,
    bytes4 conversionSelector_,
    uint256 baseUnit_
  ) {
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

    return int256(rate.mulDivDown(uint256(mainPrice), baseUnit));
  }
}
