// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17; // solhint-disable-line one-contract-per-file

import { Test, stdError } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/src/utils/SafeCastLib.sol";
import { Auditor } from "../contracts/Auditor.sol";
import { IAggregatorProxy, PriceFeedInverse } from "../contracts/PriceFeedInverse.sol";

contract PriceFeedInverseTest is Test {
  using FixedPointMathLib for uint256;

  PriceFeedInverse internal priceFeedInverse;
  MockAggregatorProxy internal usdArsPriceFeed;

  function setUp() external {
    usdArsPriceFeed = new MockAggregatorProxy(8, 1, 1_607.5387e8);
    priceFeedInverse = new PriceFeedInverse(usdArsPriceFeed);
  }

  function test_constructor_setsPriceFeedDecimalsAndBaseUnitSquared() external view {
    assertEq(address(priceFeedInverse.priceFeed()), address(usdArsPriceFeed));
    assertEq(priceFeedInverse.decimals(), 8);
    assertEq(priceFeedInverse.baseUnitSquared(), 1e16);
  }

  function test_constructor_reverts_whenBaseUnitSquaredOverflows() external {
    MockAggregatorProxy priceFeed = new MockAggregatorProxy(39, 1, 1);
    vm.expectRevert(stdError.arithmeticError);
    new PriceFeedInverse(priceFeed);
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
    vm.expectRevert(FixedPointMathLib.DivFailed.selector);
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

  function test_getRoundData_returnsInverse_withRoundDataUnchanged() external {
    usdArsPriceFeed.setRound(1_595.0362e8, 100, 200);
    uint80 roundId = usdArsPriceFeed.latestRound();

    (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = priceFeedInverse
      .getRoundData(roundId);
    assertEq(id, roundId);
    assertEq(answer, 62_695);
    assertEq(startedAt, 100);
    assertEq(updatedAt, 200);
    assertEq(answeredInRound, roundId);
  }

  function test_getRoundData_returnsInverse_whenRoundIsHistorical() external {
    uint80 roundId = usdArsPriceFeed.latestRound();
    usdArsPriceFeed.setPrice(1_595.0362e8);

    (uint80 id, int256 answer, , , ) = priceFeedInverse.getRoundData(roundId);
    assertEq(id, roundId);
    assertEq(answer, 62_207);
  }

  function test_getRoundData_returnsZero_whenAnswerIsZero() external {
    usdArsPriceFeed.setPrice(0);
    (, int256 answer, , , ) = priceFeedInverse.getRoundData(usdArsPriceFeed.latestRound());
    assertEq(answer, 0);
  }

  function test_getRoundData_returnsZero_whenRoundHasNoData() external {
    uint80 roundId = usdArsPriceFeed.latestRound() + 1;

    (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = priceFeedInverse
      .getRoundData(roundId);
    assertEq(id, roundId);
    assertEq(answer, 0);
    assertEq(startedAt, 0);
    assertEq(updatedAt, 0);
    assertEq(answeredInRound, roundId);
  }

  function test_getRoundData_reverts_whenAnswerIsNegative() external {
    usdArsPriceFeed.setPrice(-1);
    uint80 roundId = usdArsPriceFeed.latestRound();
    vm.expectRevert(SafeCastLib.Overflow.selector);
    priceFeedInverse.getRoundData(roundId);
  }

  function test_latestRoundData_returnsInverse_withRoundDataUnchanged() external {
    usdArsPriceFeed.setRound(1_595.0362e8, 100, 200);

    (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = priceFeedInverse
      .latestRoundData();
    assertEq(id, usdArsPriceFeed.latestRound());
    assertEq(answer, 62_695);
    assertEq(startedAt, 100);
    assertEq(updatedAt, 200);
    assertEq(answeredInRound, usdArsPriceFeed.latestRound());
  }

  function test_latestRoundData_reverts_whenAnswerIsZero() external {
    usdArsPriceFeed.setPrice(0);
    vm.expectRevert(FixedPointMathLib.DivFailed.selector);
    priceFeedInverse.latestRoundData();
  }

  function test_latestRoundData_reverts_whenAnswerIsNegative() external {
    usdArsPriceFeed.setPrice(-1);
    vm.expectRevert(SafeCastLib.Overflow.selector);
    priceFeedInverse.latestRoundData();
  }

  function test_phaseId_returnsSourcePhaseId() external {
    assertEq(priceFeedInverse.phaseId(), 1);

    MockAggregatorProxy priceFeed = new MockAggregatorProxy(8, 3, 1);
    assertEq(new PriceFeedInverse(priceFeed).phaseId(), 3);
  }

  function testFuzz_latestRoundData_matchesLatestAnswer(int256 price) external {
    price = bound(price, 1, 2 ** 176 - 1);
    usdArsPriceFeed.setPrice(price);

    int256 latestAnswer = priceFeedInverse.latestAnswer();
    (, int256 latestRoundAnswer, , , ) = priceFeedInverse.latestRoundData();
    (, int256 roundAnswer, , , ) = priceFeedInverse.getRoundData(usdArsPriceFeed.latestRound());
    assertEq(latestRoundAnswer, latestAnswer);
    assertEq(roundAnswer, latestAnswer);
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

contract MockAggregatorProxy is IAggregatorProxy {
  uint8 public immutable decimals;
  uint16 public immutable phaseId;
  uint80 public latestRound;
  mapping(uint80 roundId => Round) public rounds;

  constructor(uint8 decimals_, uint16 phaseId_, int256 price_) {
    decimals = decimals_;
    phaseId = phaseId_;
    latestRound = uint80(phaseId_) << 64;
    setPrice(price_);
  }

  function latestAnswer() external view returns (int256) {
    return rounds[latestRound].answer;
  }

  function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
    return getRoundData(latestRound);
  }

  function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
    Round memory round = rounds[roundId];
    return (roundId, round.answer, round.startedAt, round.updatedAt, roundId);
  }

  function setPrice(int256 price) public {
    setRound(price, block.timestamp, block.timestamp);
  }

  function setRound(int256 answer, uint256 startedAt, uint256 updatedAt) public {
    rounds[++latestRound] = Round(answer, startedAt, updatedAt);
  }

  struct Round {
    int256 answer;
    uint256 startedAt;
    uint256 updatedAt;
  }
}
