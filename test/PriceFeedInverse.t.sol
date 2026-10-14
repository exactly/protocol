// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/src/utils/SafeCastLib.sol";
import { Auditor } from "../contracts/Auditor.sol";
import { PriceFeedInverse } from "../contracts/PriceFeedInverse.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";

contract PriceFeedInverseTest is Test {
  using FixedPointMathLib for uint256;

  PriceFeedInverse internal priceFeedInverse;
  MockPriceFeed internal usdArsPriceFeed;

  function setUp() external {
    usdArsPriceFeed = new MockPriceFeed(8, 1_607.5387e8);
    priceFeedInverse = new PriceFeedInverse(usdArsPriceFeed);
  }

  function test_constructor_setsPriceFeedDecimalsAndBaseUnit() external view {
    assertEq(address(priceFeedInverse.priceFeed()), address(usdArsPriceFeed));
    assertEq(priceFeedInverse.decimals(), 8);
    assertEq(priceFeedInverse.baseUnit(), 1e8);
  }

  function test_latestAnswer_returnsInverse() external {
    assertEq(priceFeedInverse.latestAnswer(), 62_207);

    usdArsPriceFeed.setPrice(159_503_620_000);
    assertEq(priceFeedInverse.latestAnswer(), 62_695);
  }

  function test_latestAnswer_returnsExactInverse_whenDivisionIsExact() external {
    usdArsPriceFeed.setPrice(2e8);
    assertEq(priceFeedInverse.latestAnswer(), 0.5e8);
    usdArsPriceFeed.setPrice(1e8);
    assertEq(priceFeedInverse.latestAnswer(), 1e8);
  }

  function test_latestAnswer_matchesGreaterScale_withHighPrices() external {
    int256[5] memory prices = [int256(1_607.5387e8), 16_075.387e8, 160_753.87e8, 1e16, 1e16 + 1];
    uint256[5] memory expected = [uint256(62_207), 6_221, 623, 1, 1];
    for (uint256 i = 0; i < prices.length; ++i) {
      usdArsPriceFeed.setPrice(prices[i]);
      assertEq(priceFeedInverse.latestAnswer(), int256(expected[i]));
      assertEq(expected[i], inverseAtScale(uint256(prices[i]), 1e18));
      assertEq(expected[i], inverseAtScale(uint256(prices[i]), 1e36));
    }
  }

  function test_latestAnswer_reverts_whenAnswerIsZero() external {
    usdArsPriceFeed.setPrice(0);
    vm.expectRevert(FixedPointMathLib.MulDivFailed.selector);
    priceFeedInverse.latestAnswer();
  }

  function test_latestAnswer_reverts_whenAnswerIsNegative() external {
    usdArsPriceFeed.setPrice(-1);
    vm.expectRevert(SafeCastLib.Overflow.selector);
    priceFeedInverse.latestAnswer();

    usdArsPriceFeed.setPrice(type(int256).min);
    vm.expectRevert(SafeCastLib.Overflow.selector);
    priceFeedInverse.latestAnswer();
  }

  function test_latestAnswer_returnsOne_whenAnswerIsAboveBaseUnitSquared() external {
    usdArsPriceFeed.setPrice(1e16);
    assertEq(priceFeedInverse.latestAnswer(), 1);

    usdArsPriceFeed.setPrice(1e16 + 1);
    assertEq(priceFeedInverse.latestAnswer(), 1);
  }

  function test_assetPrice_returnsPrice_whenAnswerIsAboveBaseUnitSquared() external {
    Auditor auditor = new Auditor(8);
    usdArsPriceFeed.setPrice(1e16 + 1);
    assertEq(auditor.assetPrice(priceFeedInverse), 1e10);
  }

  function testFuzz_latestAnswer_returnsOne_whenAnswerIsAboveBaseUnitSquared(int256 price) external {
    price = bound(price, 1e16, 2 ** 176 - 1);
    usdArsPriceFeed.setPrice(price);
    assertEq(priceFeedInverse.latestAnswer(), 1);
    assertEq(new Auditor(8).assetPrice(priceFeedInverse), 1e10);
  }

  function testFuzz_latestAnswer_roundsUp(int256 price) external {
    price = bound(price, 1, 2 ** 176 - 1);
    usdArsPriceFeed.setPrice(price);

    uint256 roundedDown = 1e16 / uint256(price);
    bool isExact = 1e16 % uint256(price) == 0;
    assertEq(priceFeedInverse.latestAnswer(), int256(isExact ? roundedDown : roundedDown + 1));
  }

  function testFuzz_latestAnswer_matchesGreaterScale(int256 price) external {
    price = bound(price, 1, 2 ** 176 - 1);
    usdArsPriceFeed.setPrice(price);

    uint256 answer = uint256(priceFeedInverse.latestAnswer());
    assertEq(answer, inverseAtScale(uint256(price), 1e18));
    assertEq(answer, inverseAtScale(uint256(price), 1e36));
  }

  function testFuzz_latestAnswer_reverts_whenAnswerIsNegative(int256 price) external {
    price = bound(price, type(int256).min, -1);
    usdArsPriceFeed.setPrice(price);
    vm.expectRevert(SafeCastLib.Overflow.selector);
    priceFeedInverse.latestAnswer();
  }

  function inverseAtScale(uint256 price, uint256 scale) internal pure returns (uint256) {
    return scale.mulDivUp(1e8, price).mulDivUp(1e8, scale);
  }
}
