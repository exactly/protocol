// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { Vm } from "forge-std/Vm.sol";
import { Test, stdError } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { PriceFeedWrapper, IPriceFeed } from "../contracts/PriceFeedWrapper.sol";
import { MockPriceFeed } from "../contracts/mocks/MockPriceFeed.sol";
import { MockStETH } from "../contracts/mocks/MockStETH.sol";

contract PriceFeedWrapperTest is Test {
  using FixedPointMathLib for uint256;

  PriceFeedWrapper internal priceFeedWrapper;
  MockPriceFeed internal stETHPriceFeed;
  MockPriceFeed internal ethPriceFeed;
  MockStETH internal mockStETH;

  function setUp() external {
    stETHPriceFeed = new MockPriceFeed(18, 0.99e18);
    mockStETH = new MockStETH(1090725952265553962);
    priceFeedWrapper = new PriceFeedWrapper(
      stETHPriceFeed,
      address(mockStETH),
      MockStETH.getPooledEthByShares.selector,
      1e18
    );
  }

  function testPriceFeedWrapperReturningPrice() external {
    assertEq(priceFeedWrapper.latestAnswer(), 1079818692742898422);
  }

  function testPriceFeedWrapperWithNegativePriceShouldRevert() external {
    mockStETH.setPooledEthByShares(2);
    stETHPriceFeed.setPrice(-1);
    vm.expectRevert();
    priceFeedWrapper.latestAnswer();

    mockStETH.setPooledEthByShares(1);
    priceFeedWrapper.latestAnswer();

    mockStETH.setPooledEthByShares(2);
    stETHPriceFeed.setPrice(-2);
    vm.expectRevert();
    priceFeedWrapper.latestAnswer();
  }

  function testPriceFeedWrapperWithActualOnChainValues() external {
    stETHPriceFeed.setPrice(998005785048528100);
    mockStETH.setPooledEthByShares(1091431067373002184);
    uint256 wStEthPriceInEth = uint256(priceFeedWrapper.latestAnswer());

    assertApproxEqRel(wStEthPriceInEth.mulWadDown(1296e18), 1411e18, 1e18);
  }

  function testPriceFeedWrapperReturningPriceAfterRebase() external {
    mockStETH.setPooledEthByShares(mockStETH.pooledEthByShares() + 0.01 ether);
    assertEq(priceFeedWrapper.latestAnswer(), 1089718692742898422);
  }

  function testPriceFeedWrapperWithUsdPriceFeed() external {
    stETHPriceFeed = new MockPriceFeed(8, 200e8);
    mockStETH = new MockStETH(1e18);
    priceFeedWrapper = new PriceFeedWrapper(
      stETHPriceFeed,
      address(mockStETH),
      MockStETH.getPooledEthByShares.selector,
      1e18
    );
    uint256 wstETHPriceInUSD = uint256(priceFeedWrapper.latestAnswer());

    assertEq(wstETHPriceInUSD, 200e8);
  }
}
