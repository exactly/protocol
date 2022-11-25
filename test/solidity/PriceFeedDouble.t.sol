// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Vm } from "forge-std/Vm.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { PriceFeedDouble, IPriceFeed } from "../../contracts/PriceFeedDouble.sol";
import { MockPriceFeed } from "../../contracts/mocks/MockPriceFeed.sol";

contract PriceFeedDoubleTest is Test {
  using FixedPointMathLib for uint256;

  PriceFeedDouble internal priceFeedDouble;
  MockPriceFeed internal btcPriceFeed;
  MockPriceFeed internal wbtcPriceFeed;

  function setUp() external {
    btcPriceFeed = new MockPriceFeed(18, 14 ether);
    wbtcPriceFeed = new MockPriceFeed(8, 99000000);
    priceFeedDouble = new PriceFeedDouble(btcPriceFeed, wbtcPriceFeed);
  }

  function testPriceFeedDoubleReturningPrice() external {
    assertEq(priceFeedDouble.latestAnswer(), 1386e16);
    wbtcPriceFeed.setPrice(100000000);
    assertEq(priceFeedDouble.latestAnswer(), 14 ether);
    assertEq(priceFeedDouble.decimals(), 18);
  }

  function testPriceFeedDoubleReturningAccurateDecimals() external {
    uint8 priceFeedOneDecimals = 11;
    priceFeedDouble = new PriceFeedDouble(
      new MockPriceFeed(priceFeedOneDecimals, 14 ether),
      new MockPriceFeed(23, 99000000)
    );
    assertEq(priceFeedDouble.decimals(), priceFeedOneDecimals);
  }

  function testPriceFeedDoubleWithNegativePriceShouldRevert() external {
    wbtcPriceFeed.setPrice(2);
    btcPriceFeed.setPrice(-1);
    vm.expectRevert();
    priceFeedDouble.latestAnswer();

    wbtcPriceFeed.setPrice(1);
    priceFeedDouble.latestAnswer();

    wbtcPriceFeed.setPrice(2);
    btcPriceFeed.setPrice(-1);
    vm.expectRevert();
    priceFeedDouble.latestAnswer();
  }

  function testPriceFeedDoubleWithActualOnChainValues() external {
    wbtcPriceFeed.setPrice(99409999);
    btcPriceFeed.setPrice(13895304563030516000);

    assertEq(priceFeedDouble.latestAnswer(), 13813322127155590325);
  }

  function testPriceFeedDoubleWithUsdPriceFeed() external {
    btcPriceFeed = new MockPriceFeed(8, 20_000e8);
    wbtcPriceFeed.setPrice(99000000);
    priceFeedDouble = new PriceFeedDouble(btcPriceFeed, wbtcPriceFeed);
    uint256 wbtcPriceInUSD = uint256(priceFeedDouble.latestAnswer());

    assertEq(wbtcPriceInUSD, 19_800e8);
    assertEq(priceFeedDouble.decimals(), 8);
  }
}
